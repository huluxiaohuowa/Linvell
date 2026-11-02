import AppKit
import LinvellCore

extension WorkspaceController {
    var reviewScope: (project: String,host: String?)? {
        if let remoteConnection { return (remoteDirectory,remoteConnection.host) }
        return root.map { ($0.url.path,nil) }
    }
    func addEditorReview(_ pane: EditorPane) {
        guard let scope = reviewScope else { show(GitError.command("Open a project before adding review comments.")); return }
        let document = pane.document
        guard document.remote?.connection.host == scope.host,
              let path = document.remote?.path ?? document.fileURL?.path,
              path.hasPrefix(scope.project.hasSuffix("/") ? scope.project : scope.project+"/") else {
            show(GitError.command("Review comments must belong to the current workspace.")); return
        }
        do {
            let prefix = scope.project.hasSuffix("/") ? scope.project : scope.project+"/"
            let comment = try ReviewComment.editor(path:String(path.dropFirst(prefix.count)),text:pane.textView.string,range:pane.textView.selectedRange())
            composeReview(comment)
        } catch { show(error) }
    }
    func composeReview(_ snapshot: ReviewComment) {
        guard let scope = reviewScope,let window else { return }
        let store = ReviewCommentStore(project:scope.project,host:scope.host)
        let alert = NSAlert(); alert.messageText = L.text("Add Review Comment…"); alert.informativeText = snapshot.location
        let note = NSTextView(frame:NSRect(x:0,y:0,width:440,height:130)); note.isRichText = false; note.font = Theme.editorFont; note.isAutomaticQuoteSubstitutionEnabled = false
        let scroll = NSScrollView(frame:note.frame); scroll.documentView = note; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        note.setAccessibilityLabel(L.text("Review feedback"))
        alert.accessoryView = scroll; alert.addButton(withTitle:L.text("Save Comment")); alert.addButton(withTitle:L.text("Cancel")); alert.window.initialFirstResponder = note
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn,let self else { return }
            do {
                var comment = snapshot; comment.note = note.string.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !comment.note.isEmpty,comment.note.utf8.count <= 16000 else { throw GitError.command("Enter review feedback (up to 16 KB).") }
                var comments = try store.load(); comments.append(comment); try store.save(comments)
                self.status.stringValue = L.format("%d review comments saved",comments.count)
            } catch { self.show(error) }
        }
    }
    @objc func addCurrentReview() { if let activePane { addEditorReview(activePane) } else { gitWorkspaceView?.addReviewComment() } }
    @objc func showReviewComments() {
        guard let scope = reviewScope,let window else { return }
        do {
            let store = ReviewCommentStore(project:scope.project,host:scope.host)
            let panel = try ReviewCommentsPanel(store:store,owner:window)
            reviewPanel = panel
            panel.onPaste = { [weak self] comments in self?.chooseReviewAgent(comments,project:scope.project,host:scope.host) }
        } catch { show(error) }
    }
    func reviewTargets(project: String,host: String?) -> [(AgentWorkspace,AgentRuntime)] {
        allAgentWorkspaces.flatMap { workspace in
            workspace.runtimes.filter { $0.directory == project && $0.context.host == host && $0.terminal.process.running }.map { (workspace,$0) }
        }
    }
    private func chooseReviewAgent(_ comments: [ReviewComment],project: String,host: String?) {
        guard !comments.isEmpty,let window else { return }
        let targets = reviewTargets(project:project,host:host)
        guard !targets.isEmpty else {
            show(GitError.command("Start or resume an agent in this workspace, then paste the saved review comments.")); return
        }
        let options = targets.map { workspace,runtime in
            PickerOption(title:runtime.context.kind.title+" · "+runtime.title,detail:runtime.directory+" · "+(host ?? L.text("This Mac")),invoke:{ [weak self,weak workspace,weak runtime] in
                guard let self,let workspace,let runtime else { return }
                do {
                    try self.pasteReview(comments,project:project,host:host,workspace:workspace,runtime:runtime)
                } catch { self.show(error) }
            })
        }
        picker = QuickPicker(title:L.text("Paste Review into Agent…"),options:options,owner:window)
    }
    func pasteReview(_ comments: [ReviewComment],project: String,host: String?,workspace: AgentWorkspace,runtime: AgentRuntime) throws {
        guard reviewScope?.project == project,reviewScope?.host == host,
              reviewTargets(project:project,host:host).contains(where:{ $0.0 === workspace && $0.1 === runtime }) else { throw GitError.command("The selected agent no longer belongs to this workspace.") }
        guard runtime.terminal.getTerminal().bracketedPasteMode else { throw GitError.command("The agent is not ready for a multiline paste. Wait for its input prompt, or copy the review draft.") }
        let prompt = ReviewComment.prompt(comments,directory:project)
        guard prompt.utf8.count <= 256000 else { throw GitError.command("The review draft is too large. Remove some comments before pasting.") }
        workspace.activate(runtime); showAgents()
        let bytes = Array(("\u{1b}[200~"+prompt+"\u{1b}[201~").utf8)
        runtime.terminal.send(data:bytes[...])
        status.stringValue = L.text("Review pasted as a draft. Submit it in the agent when ready.")
    }
}

final class ReviewCommentsPanel: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let store: ReviewCommentStore
    var comments: [ReviewComment]
    let table = ResponsiveTableView(),preview = NSTextView()
    weak var parentWindow: NSWindow?
    var onPaste: (([ReviewComment]) -> Void)?
    init(store: ReviewCommentStore,owner: NSWindow) throws {
        self.store = store; comments = try store.load(); self.parentWindow = owner
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:760,height:560),styleMask:[.titled],backing:.buffered,defer:false)
        panel.title = L.text("Review Comments…"); panel.appearance = owner.appearance; panel.backgroundColor = Theme.panel
        super.init(window:panel)
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("review")); table.addTableColumn(column); table.headerView = nil; table.rowHeight = 48
        table.dataSource = self; table.delegate = self; table.setAccessibilityLabel(L.text("Saved review comments"))
        let list = ResponsiveScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.heightAnchor.constraint(equalToConstant:170).isActive = true
        preview.isEditable = false; preview.isRichText = false; preview.font = Theme.editorFont; preview.setAccessibilityLabel(L.text("Review draft")); preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true
        let detail = ResponsiveScrollView(); detail.documentView = preview; detail.hasVerticalScroller = true
        func button(_ title: String,_ action: Selector) -> NSButton { Theme.actionButton(title,target:self,action:action) }
        let actions = Theme.stack([button("Remove Comment",#selector(removeComment)),button("Copy Draft",#selector(copyDraft)),NSView(),button("Paste into Agent…",#selector(pasteDraft)),button("Close",#selector(closePanel))],spacing:8)
        Theme.pin(Theme.stack([Theme.label("Comments stay saved until you remove them.",size:12,color:Theme.secondary),list,detail,actions],orientation:.vertical,spacing:12),in:panel.contentView!,inset:18)
        table.reloadData(); if !comments.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }; updatePreview()
        owner.beginSheet(panel)
    }
    required init?(coder: NSCoder) { fatalError() }
    func numberOfRows(in tableView: NSTableView) -> Int { comments.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        guard comments.indices.contains(row) else { return nil }
        let location = Theme.label(comments[row].location,size:11,color:Theme.secondary),note = Theme.label(comments[row].note,size:13)
        [location,note].forEach { $0.lineBreakMode = .byTruncatingTail; $0.maximumNumberOfLines = 1 }
        return Theme.stack([location,note],orientation:.vertical,spacing:4)
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updatePreview() }
    private func updatePreview() {
        preview.string = comments.indices.contains(table.selectedRow) ? ReviewComment.prompt([comments[table.selectedRow]],directory:project) : L.text("No review comments yet.")
    }
    @objc func removeComment() {
        guard comments.indices.contains(table.selectedRow) else { return }
        do {
            var updated = comments; updated.remove(at:table.selectedRow); try store.save(updated); comments = updated
            table.reloadData(); if !comments.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }; updatePreview()
        } catch { let alert = NSAlert(error:error); if let window { alert.beginSheetModal(for:window) } }
    }
    private var project: String { (parentWindow?.windowController as? WorkspaceController)?.reviewScope?.project ?? "" }
    @objc func copyDraft() { guard !comments.isEmpty else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ReviewComment.prompt(comments,directory:project),forType:.string) }
    @objc func pasteDraft() { guard !comments.isEmpty else { return }; closePanel(); onPaste?(comments) }
    @objc func closePanel() { if let window { parentWindow?.endSheet(window); window.orderOut(nil) } }
}
