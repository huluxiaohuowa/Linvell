import AppKit
import LinvellCore
import ImageIO
import UniformTypeIdentifiers

/// The file list remains available while reviewing source, history and patches.
final class GitReviewPanel: NSWindowController, NSWindowDelegate {
    struct File {
        let path: String
        let patch: (() throws -> String)?
        var indexSide: Bool? = nil
        var images: (() throws -> (Data?,Data?))? = nil
    }

    struct Context {
        var title: String? = nil
        var base: String? = nil
        var target: String? = nil
        var statistics: String? = nil
        var message: String? = nil
        var statisticsProvider: (() throws -> String)? = nil
        var onSwap: (() -> Void)? = nil
        var primaryActionTitle: String? = nil
        var primaryAction: (() -> Void)? = nil
    }
    private let reviewContext: Context
    private let reloadFiles: (() throws -> [File])?
    private let fileTree = GitReviewFileTree()
    private let contextStatistics = Theme.label("",size:11,color:Theme.secondary)
    private let metadata = Theme.label("",size:11,color:Theme.secondary)
    private let historyMessage = NSTextField(wrappingLabelWithString:"")
    private let messageScroll = NSScrollView()
    private let retry = Theme.actionButton("Retry",target:nil,action:nil)
    private let sourceWrap = NSButton(checkboxWithTitle:L.text("Wrap Lines"),target:nil,action:nil)
    private let fileLayout = Theme.segmented([L.text("List"),L.text("Directory Tree")])
    private var largePaths: Set<String> = []
    private var historyEntries: [GitFileHistoryEntry] = []
    private var historyTip: String?
    private var historyFingerprint: String? = ""
    private var defaultsObserver: NSObjectProtocol?
    private var renderedFont: NSFont = Theme.editorFont
    private var displayFingerprint: String? = ""
    private var applyingIndex = false
    private var pendingRefresh = false
    private let initialIndexSide: Bool?
    private let repository: GitRepository
    private var files: [File]
    private let search = Theme.searchField()
    private let modes = Theme.segmented([L.text("File Content"),L.text("File History"),L.text("Diff")])
    private let revisions = Theme.choiceButton()
    private let copyRevision = Theme.actionButton("Copy Commit Hash",target:nil,action:nil)
    private let diffControls = NSStackView()
    private let fileCount = Theme.label("",size:11,color:Theme.secondary)
    private let large = Theme.actionButton("Load Large Plain Text",target:nil,action:nil)
    private let find = Theme.actionButton("Find in File",target:nil,action:nil)
    private let more = Theme.actionButton("Load More",target:nil,action:nil)
    private let openFile: ((URL) -> Void)?
    private let text = GitPatchTextView.scrollableTextView()
    private let sections = NSStackView()
    private let patchView = GitReviewDiffView(frame:NSRect(x:0,y:0,width:700,height:500))
    private let detail = NSView()
    private let multi = NSView()
    private let imagePane = NSView()
    private let toggle = Theme.actionButton("Multiple Diffs",target:nil,action:nil)
    private var active: File?
    private var commits: [GitCommit] = []
    private var expanded: Set<String> = []
    private var generation = UUID()
    private var refreshTimer: Timer?
    private var refreshing = false
    private var sourceFingerprint: String?
    private let directoryMode: Bool
    private weak var parentWindow: NSWindow?

    init(repository: GitRepository,files: [File],owner: NSWindow,onOpen: ((URL) -> Void)? = nil,context: Context = Context(),reloadFiles: (() throws -> [File])? = nil) {
        self.reviewContext = context; self.reloadFiles = reloadFiles
        self.initialIndexSide = files.compactMap(\.indexSide).first
        self.directoryMode = !files.isEmpty && files.allSatisfy { $0.patch == nil }
        self.repository = repository
        self.files = files
        self.parentWindow = owner
        self.openFile = onOpen
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:1040,height:680),
                            styleMask:[.titled,.resizable,.closable],backing:.buffered,defer:false)
        super.init(window:panel)
        panel.title = context.title ?? L.text("Repository Review")
        panel.delegate = self
        ThemedWindow.install(panel)
        search.placeholderString = L.text("Filter files")
        search.target = self; search.action = #selector(renderFileList)
        search.sendsSearchStringImmediately = true
        modes.target = self; modes.action = #selector(refreshDetail)
        modes.selectedSegment = files.contains { $0.patch != nil } ? 2 : 0
        revisions.target = self; revisions.action = #selector(showRevision)
        revisions.isHidden = true
        revisions.widthAnchor.constraint(lessThanOrEqualToConstant:280).isActive = true
        revisions.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        copyRevision.target = self; copyRevision.action = #selector(copyRevisionHash); copyRevision.isHidden = true
        large.target = self; large.action = #selector(loadLargePlainText)
        more.isHidden = true; more.target = self; more.action = #selector(loadMore)
        configure(sections)
        let sidebar = Theme.stack([search,fileTree,fileCount],orientation:.vertical,spacing:8)
        fileTree.onSelect = { [weak self] path in
            guard let self,let file = self.files.first(where:{ $0.path == path }) else { return }; self.select(file)
        }
        fileTree.onVisibilityChange = { [weak self] in if self?.multi.isHidden == false { self?.renderSections() } }
        search.heightAnchor.constraint(equalToConstant:26).isActive = true
        if let view = text.documentView as? NSTextView {
            configurePreview(view)
            text.verticalRulerView = GitReviewLineRuler(scroll:text,editor:view)
            text.hasVerticalRuler = true
            text.rulersVisible = true
        }
        Theme.pin(text,in:detail)
        Theme.pin(patchView,in:detail); patchView.isHidden = true
        let multiple = scrolling(sections)
        Theme.pin(multiple,in:multi)
        multi.isHidden = true
        Theme.pin(multi,in:detail)
        Theme.pin(imagePane,in:detail); imagePane.isHidden = true
        toggle.target = self; toggle.action = #selector(toggleMultiple)
        toggle.isHidden = !files.contains { $0.patch != nil }
        let expandFolders = Theme.actionButton("Expand Folders",target:self,action:#selector(expandFolders))
        let collapseFolders = Theme.actionButton("Collapse Folders",target:self,action:#selector(collapseFolders))
        let expand = Theme.actionButton("Expand Diffs",target:self,action:#selector(expandDiffs))
        let collapse = Theme.actionButton("Collapse Diffs",target:self,action:#selector(collapseDiffs))
        expand.keyEquivalent = String(UnicodeScalar(NSRightArrowFunctionKey)!); expand.keyEquivalentModifierMask = .option
        collapse.keyEquivalent = String(UnicodeScalar(NSLeftArrowFunctionKey)!); collapse.keyEquivalentModifierMask = .option
        sidebar.addArrangedSubview(Theme.stack([expandFolders,collapseFolders],spacing:4))
        let close = Theme.actionButton("Close",target:self,action:#selector(closeReview))
        expand.isHidden = toggle.isHidden; collapse.isHidden = toggle.isHidden
        sourceWrap.target = self; sourceWrap.action = #selector(toggleSourceWrap)
        sourceWrap.state = UserDefaults.standard.bool(forKey:"git.wrapDiff") ? .on : .off
        retry.target = self; retry.action = #selector(refreshDetail); retry.isHidden = true
        fileLayout.selectedSegment = UserDefaults.standard.object(forKey:"git.reviewTree") as? Bool == false ? 0 : 1
        fileLayout.target = self; fileLayout.action = #selector(changeFileLayout)
        let bar = Theme.stack([modes,large,sourceWrap,retry,NSView(),close],spacing:5)
        bar.heightAnchor.constraint(equalToConstant:30).isActive = true
        find.target = self; find.action = #selector(findInFile)
        find.keyEquivalent = "f"; find.keyEquivalentModifierMask = .command
        let open = Theme.actionButton("Open File",target:self,action:#selector(openActiveFile))
        open.isHidden = onOpen == nil
        diffControls.spacing = 5
        for control in [toggle,fileLayout,expand,collapse] as [NSView] { diffControls.addArrangedSubview(control) }
        let controls = Theme.stack([diffControls,revisions,copyRevision,more,NSView(),find,open],spacing:5)
        controls.heightAnchor.constraint(equalToConstant:30).isActive = true
        metadata.maximumNumberOfLines = 2
        historyMessage.isSelectable = true; historyMessage.maximumNumberOfLines = 0
        historyMessage.isHidden = true
        messageScroll.documentView = historyMessage; messageScroll.hasVerticalScroller = true
        messageScroll.heightAnchor.constraint(equalToConstant:90).isActive = true
        messageScroll.isHidden = true
        var contextControls: [NSView] = []
        if let base = context.base,let target = context.target {
            contextControls.append(Theme.label(base+" → "+target,size:12,weight:.semibold))
        }
        if context.onSwap != nil { contextControls.append(Theme.actionButton("Swap Commits",target:self,action:#selector(swapComparison))) }
        if let title = context.primaryActionTitle,context.primaryAction != nil { contextControls.append(Theme.actionButton(title,target:self,action:#selector(primaryAction),primary:true)) }
        if context.statistics != nil || context.statisticsProvider != nil {
            contextStatistics.stringValue = context.statistics ?? L.text("Reading repository…")
            contextControls.append(contextStatistics)
        }
        var rightViews: [NSView] = [Theme.stack(contextControls,spacing:6)]
        if let message = context.message,!message.isEmpty { rightViews.append(GitReviewContextMessageView(message:message)) }
        rightViews += [bar,controls,metadata,messageScroll,detail]
        let right = Theme.stack(rightViews,orientation:.vertical,spacing:8)
        let panes = ResizablePanes(); panes.position = 280; panes.secondMinimum = 520
        let leftPane = Surface(Theme.panel),rightPane = Surface(Theme.canvas)
        Theme.pin(sidebar,in:leftPane,inset:8)
        Theme.pin(right,in:rightPane,inset:8)
        panes.addArrangedSubview(leftPane); panes.addArrangedSubview(rightPane)
        Theme.pin(panes,in:panel.contentView!)
        renderFileList()
        if let first = files.first { select(first) }
        if !toggle.isHidden,UserDefaults.standard.bool(forKey:"git.expandReviewDiffs") { expandDiffs() }
        owner.beginSheet(panel)
        defaultsObserver = NotificationCenter.default.addObserver(forName:UserDefaults.didChangeNotification,object:nil,queue:.main) { [weak self] _ in self?.preferencesChanged() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval:5,repeats:true) { [weak self] _ in self?.refreshFromDisk() }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { refreshTimer?.invalidate(); if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) } }

    private func configure(_ stack: NSStackView) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
    }

    private func scrolling(_ stack: NSStackView) -> NSScrollView {
        ReviewStackScroll(stack:stack)
    }

    @objc private func renderFileList() {
        fileTree.update(paths:files.map(\.path),query:search.stringValue,selection:active?.path)
        fileCount.stringValue = L.format("Files: %d",files.count)
        if !multi.isHidden { renderSections() }
    }
    @objc private func expandFolders() { fileTree.setExpanded(true) }
    @objc private func collapseFolders() { fileTree.setExpanded(false) }
    @objc private func toggleFolder(_ sender: NSButton) { if let path = sender.identifier?.rawValue { fileTree.toggle(path:path) } }
    @objc private func changeFileLayout() {
        UserDefaults.standard.set(fileLayout.selectedSegment == 1,forKey:"git.reviewTree")
        if !multi.isHidden { renderSections() }
    }
    @objc private func swapComparison() { closeReview(); reviewContext.onSwap?() }
    @objc private func primaryAction() { closeReview(); reviewContext.primaryAction?() }
    @objc private func toggleSourceWrap() {
        UserDefaults.standard.set(sourceWrap.state == .on,forKey:"git.wrapDiff"); configureSourceWrapping()
    }
    private func configureSourceWrapping() {
        guard let view = text.documentView as? NSTextView else { return }
        let wraps = sourceWrap.state == .on && !(active.map { largePaths.contains($0.path) } ?? false)
        view.isHorizontallyResizable = !wraps; view.autoresizingMask = wraps ? .width : []
        view.textContainer?.widthTracksTextView = wraps
        view.textContainer?.containerSize = NSSize(width:wraps ? max(1,text.contentSize.width-16) : CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.hasHorizontalScroller = !wraps
        if wraps { view.setFrameSize(NSSize(width:text.contentSize.width,height:max(1,view.frame.height))) }
    }
    private func preferencesChanged() {
        sourceWrap.state = UserDefaults.standard.bool(forKey:"git.wrapDiff") ? .on : .off
        configureSourceWrapping()
        if renderedFont != Theme.editorFont {
            renderedFont = Theme.editorFont
            if !multi.isHidden { renderSections() } else { refreshDetail() }
        }
    }

    private func select(_ file: File) {
        imagePane.isHidden = true
        sourceFingerprint = ""
        active = file
        fileTree.select(path:file.path)
        multi.isHidden = true
        text.isHidden = false
        refreshDetail()
    }

    @objc private func refreshDetail() {
        guard let active else { return }
        generation = UUID()
        large.isHidden = true
        sourceWrap.isHidden = modes.selectedSegment != 0
        retry.isHidden = true
        metadata.stringValue = active.path
        find.isEnabled = !Self.isImage(active.path)
        diffControls.isHidden = modes.selectedSegment != 2
        copyRevision.isHidden = true
        historyMessage.isHidden = modes.selectedSegment != 1
        messageScroll.isHidden = historyMessage.isHidden
        if modes.selectedSegment != 1 { historyMessage.stringValue = "" }
        configureSourceWrapping()
        imagePane.isHidden = true
        patchView.isHidden = true
        multi.isHidden = true; text.isHidden = false; revisions.isHidden = true; more.isHidden = true
        let repo = repository
        if let view = text.documentView as? GitPatchTextView { configureIndexActions(view,file:active,enabled:modes.selectedSegment == 2) }
        switch modes.selectedSegment {
        case 0:
            if Self.isImage(active.path) { showImages { (nil,try repo.workingFileData(active.path,largeFile:true)) } }
            else {
                let plain = largePaths.contains(active.path)
                readText(sourcePath:plain ? nil : active.path) { try repo.workingFilePreviewWithSize(active.path,largeFile:plain) }
            }
        case 1: readHistory(for:active,offset:0)
        default:
            if let images = active.images,Self.isImage(active.path) { showImages(images,file:active) }
            else if let patch = active.patch { showPatch(file:active,load:patch) }
            else { show(L.text("Select a revision in File History to view its diff.")) }
        }
    }

    @objc private func openActiveFile() {
        guard let active else { return }
        closeReview()
        openFile?(repository.root.appendingPathComponent(active.path))
    }

    @objc private func loadLargePlainText() {
        guard let active else { return }
        largePaths.insert(active.path)
        refreshDetail()
    }

    @objc private func loadMore() {
        guard let active else { return }
        readHistory(for:active,offset:commits.count)
    }

    private func readHistory(for file: File,offset: Int) {
        let request = UUID(),repo = repository,pageSize = 100
        let oldSelection = historyEntries.indices.contains(revisions.indexOfSelectedItem) ? historyEntries[revisions.indexOfSelectedItem].commit.hash : nil
        if offset == 0 { historyTip = nil }
        let pinnedTip = historyTip
        generation = request
        more.isEnabled = false
        if offset == 0 { show(L.text("Reading repository…")) }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { () throws -> (String?,[GitFileHistoryEntry]) in
                guard let tip = try? pinnedTip ?? repo.resolvedRevision("HEAD") else { return (nil,[]) }
                return (tip,try repo.fileHistoryEntries(file.path,revision:tip,limit:pageSize+1,offset:offset))
            }
            DispatchQueue.main.async {
                guard let self,self.generation == request else { return }
                self.more.isEnabled = true
                switch result {
                case .success(let (tip,page)):
                    self.historyTip = tip
                    let items = Array(page.prefix(pageSize))
                    if offset == 0 { self.historyEntries = []; self.revisions.removeAllItems() }
                    self.historyEntries += items
                    self.commits = self.historyEntries.map(\.commit)
                    self.revisions.addItems(withTitles:items.map { String($0.commit.hash.prefix(12))+"  "+$0.commit.subject+" · "+$0.commit.author+" · "+$0.commit.date })
                    if offset == 0,let oldSelection,let index = self.historyEntries.firstIndex(where:{ $0.commit.hash == oldSelection }) { self.revisions.selectItem(at:index) }
                    self.revisions.isHidden = self.commits.isEmpty
                    self.copyRevision.isHidden = self.commits.isEmpty
                    self.more.isHidden = page.count <= pageSize
                    if self.commits.isEmpty { self.show(L.text("No commits yet")) }
                    else if offset == 0 { self.showRevision() }
                case .failure(let error): self.show(error.localizedDescription)
                }
            }
        }
    }

    @objc private func copyRevisionHash() {
        guard historyEntries.indices.contains(revisions.indexOfSelectedItem) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(historyEntries[revisions.indexOfSelectedItem].commit.hash,forType:.string)
    }
    @objc private func showRevision() {
        let index = revisions.indexOfSelectedItem
        guard let active,commits.indices.contains(index) else { return }
        let repo = repository,entry = historyEntries[index],commit = entry.commit
        historyMessage.isHidden = false; messageScroll.isHidden = false
        historyMessage.stringValue = commit.message+"\n"+commit.author+" <"+commit.email+"> · "+commit.date+"\n"+L.text("Compared with the first parent")
        let messageWidth = max(300,messageScroll.contentSize.width)
        let messageHeight = (historyMessage.stringValue as NSString).boundingRect(with:NSSize(width:messageWidth,height:CGFloat.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:historyMessage.font ?? NSFont.systemFont(ofSize:13)]).height+12
        historyMessage.frame = NSRect(x:0,y:0,width:messageWidth,height:max(90,messageHeight))
        copyRevision.toolTip = commit.hash
        metadata.stringValue = active.path+" · "+String(commit.hash.prefix(12))
        if Self.isImage(entry.newPath ?? "") || Self.isImage(entry.oldPath ?? "") {
            showImages { try repo.fileHistoryImages(entry) }
        } else { showPatch(file:File(path:entry.newPath ?? entry.oldPath ?? active.path,patch:nil),load:{ try repo.fileHistoryDiff(entry) }) }
    }

    private func showPatch(file: File,load: @escaping () throws -> String) {
        let request = UUID(); generation = request
        text.isHidden = true; imagePane.isHidden = true; patchView.isHidden = false
        find.isEnabled = true
        configureIndexActions(patchView.editor,file:file,enabled:true)
        patchView.unstaging = file.indexSide == true
        patchView.apply = patchView.editor.apply
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result(catching:load)
            DispatchQueue.main.async {
                guard let self,self.generation == request else { return }
                let patch = (try? result.get()) ?? self.errorText(result)
                if let images = file.images,Self.patchContainsImagePath(patch) { self.showImages(images,file:file); return }
                self.patchView.render(patch,path:file.path)
                self.metadata.stringValue = file.path+" · "+GitDiffRendering.summary(patch)
            }
        }
    }

    private func readText(sourcePath: String? = nil,_ load: @escaping () throws -> (text:String,bytes:Int)) {
        let request = UUID()
        generation = request
        patchView.isHidden = true
        show(L.text("Reading repository…"))
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result(catching:load)
            let tokens = sourcePath.flatMap { path in
                (try? result.get()).map { SourceSyntax.analyze($0.text,path:path).tokens }
            }
            DispatchQueue.main.async {
                guard let self,self.generation == request else { return }
                let value = (try? result.get().text) ?? self.errorText(result)
                guard let view = self.text.documentView as? NSTextView else { return }
                self.retry.isHidden = true
                self.large.isHidden = true
                switch result {
                case .success:
                    let plain = self.active.map { self.largePaths.contains($0.path) } ?? false
                    self.metadata.stringValue = (self.active?.path ?? "")+" · "+ByteCountFormatter.string(fromByteCount:Int64((try? result.get().bytes) ?? value.utf8.count),countStyle:.file)+(plain ? " · "+L.text("Plain Text") : "")
                case .failure:
                    self.retry.isHidden = false
                    self.large.isHidden = !(value.contains("too large") || value.contains("plain-text"))
                    self.metadata.stringValue = self.active?.path ?? ""
                }
                guard let tokens else {
                    view.textStorage?.setAttributedString(NSAttributedString(string:value,attributes:[.font:Theme.editorFont,.foregroundColor:Theme.foreground]))
                    self.configureSourceWrapping(); self.text.verticalRulerView?.needsDisplay = true
                    return
                }
                let styled = NSMutableAttributedString(string:value,attributes:[.font:Theme.editorFont,.foregroundColor:Theme.foreground])
                for token in tokens {
                    styled.addAttribute(.foregroundColor,value:GitDiffRendering.color(token.kind),range:token.range)
                }
                view.textStorage?.setAttributedString(styled)
                self.configureSourceWrapping()
                self.text.verticalRulerView?.needsDisplay = true
            }
        }
    }

    private func errorText<T>(_ result: Result<T,Error>) -> String {
        if case .failure(let error) = result { return error.localizedDescription }
        return ""
    }

    static func patchContainsImagePath(_ patch: String) -> Bool {
        patch.components(separatedBy:"\n").contains { line in
            for prefix in ["rename from ","rename to ","--- a/","+++ b/"] where line.hasPrefix(prefix) {
                let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in:CharacterSet(charactersIn:"\""))
                if isImage(path) { return true }
            }
            return false
        }
    }
    static func isImage(_ path: String) -> Bool {
        guard let type = UTType(filenameExtension:URL(fileURLWithPath:path).pathExtension) else { return false }
        return (CGImageSourceCopyTypeIdentifiers() as! [String]).contains(type.identifier)
    }

    private func showImages(_ load: @escaping () throws -> (Data?,Data?),file: File? = nil) {
        let request = UUID()
        generation = request
        patchView.isHidden = true
        imagePane.isHidden = false; text.isHidden = true; multi.isHidden = true
        find.isEnabled = false
        imagePane.subviews.forEach { $0.removeFromSuperview() }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result(catching:load)
            DispatchQueue.main.async {
                guard let self,self.generation == request else { return }
                switch result {
                case .success(let (before,after)):
                    let comparison = GitImageComparison(before:before,after:after)
                    if let file,let staged = file.indexSide {
                        comparison.fileActionTitle = L.text(staged ? "Unstage File" : "Stage File")
                        comparison.onFileAction = { [weak self] in self?.updateIndex(file:file,patch:nil) }
                    }
                    Theme.pin(comparison,in:self.imagePane)
                case .failure(let error):
                    self.imagePane.isHidden = true; self.text.isHidden = false
                    self.show(error.localizedDescription)
                }
            }
        }
    }

    private func configureIndexActions(_ view: GitPatchTextView,file: File,enabled: Bool) {
        guard enabled,let staged = file.indexSide else { view.apply = nil; return }
        view.unstaging = staged
        view.apply = { [weak self] patch in self?.updateIndex(file:file,patch:patch) }
    }
    private func updateIndex(file: File,patch: GitHunk?) {
        guard !applyingIndex,let staged = file.indexSide else { return }
        applyingIndex = true
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result {
                if let patch { try self.repository.applyHunk(patch,unstage:false) }
                else if let change = try self.repository.changes().first(where:{ $0.path == file.path }) {
                    guard !change.conflicted else { throw GitError.command("Resolve conflicts before staging this file.") }
                    if staged { try self.repository.unstage(change) } else { try self.repository.stage(change) }
                }
            }
            DispatchQueue.main.async {
                self.applyingIndex = false
                if case .failure(let error) = result,let window = self.window { Theme.errorAlert(error).beginSheetModal(for:window) }
                self.refreshFromDisk(force:true)
            }
        }
    }
    @objc private func findInFile() {
        if !patchView.isHidden { patchView.find(); return }
        if !multi.isHidden {
            let previews = sections.arrangedSubviews.compactMap { $0 as? GitReviewDiffView }
            let focused = previews.first { preview in
                guard let responder = window?.firstResponder as? NSView else { return false }
                return responder.isDescendant(of:preview)
            }
            (focused ?? previews.first)?.find(); return
        }
        guard !text.isHidden,let view = text.documentView as? NSTextView else { return }
        window?.makeFirstResponder(view)
        let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
        view.performFindPanelAction(item)
    }

    private func configurePreview(_ view: NSTextView) {
        view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.isEditable = false
        view.font = Theme.editorFont
        view.backgroundColor = Theme.liveCanvas
        view.textColor = Theme.liveForeground
        view.textContainerInset = NSSize(width:8,height:8)
    }

    private func show(_ value: String) {
        (text.documentView as? NSTextView)?.string = value
        text.verticalRulerView?.needsDisplay = true
    }

    @objc private func toggleMultiple() {
        if multi.isHidden { renderSections() }
        else { refreshDetail() }
    }

    @objc private func expandDiffs() {
        expanded = Set(files.filter { $0.patch != nil }.map(\.path))
        renderSections()
    }

    @objc private func collapseDiffs() {
        expanded.removeAll()
        renderSections()
    }

    @objc private func toggleSection(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        if expanded.remove(path) == nil { expanded.insert(path) }
        renderSections()
    }

    private func renderSections() {
        generation = UUID()
        modes.selectedSegment = 2
        large.isHidden = true; sourceWrap.isHidden = true; retry.isHidden = true; historyMessage.isHidden = true; messageScroll.isHidden = true
        imagePane.isHidden = true
        patchView.isHidden = true
        revisions.isHidden = true; copyRevision.isHidden = true; diffControls.isHidden = false
        more.isHidden = true; text.isHidden = true; multi.isHidden = false
        sections.arrangedSubviews.forEach { $0.removeFromSuperview() }
        find.isEnabled = fileTree.visiblePaths.contains { expanded.contains($0) && !Self.isImage($0) }
        var pending: [(File,GitReviewDiffView)] = []
        var imageLoads: [((() throws -> (Data?,Data?)),NSView,File)] = []
        for entry in fileTree.visibleRows {
            if entry.directory {
                if fileLayout.selectedSegment == 1 {
                    let row = NSButton(title:String(repeating:"  ",count:entry.depth)+"▱ "+(entry.path as NSString).lastPathComponent,target:self,action:#selector(toggleFolder(_:)))
                    row.identifier = NSUserInterfaceItemIdentifier(entry.path); sections.addArrangedSubview(row)
                }
                continue
            }
            guard let file = files.first(where:{ $0.path == entry.path }),file.patch != nil else { continue }
            let row = NSButton(title:(expanded.contains(file.path) ? "▾ " : "▸ ")+file.path,target:self,action:#selector(toggleSection(_:)))
            row.identifier = NSUserInterfaceItemIdentifier(file.path)
            sections.addArrangedSubview(row)
            if expanded.contains(file.path) {
                if Self.isImage(file.path),let load = file.images {
                    let container = NSView(frame:NSRect(x:0,y:0,width:700,height:400))
                    container.identifier = NSUserInterfaceItemIdentifier("review-image")
                    container.heightAnchor.constraint(equalToConstant:400).isActive = true
                    sections.addArrangedSubview(container)
                    container.widthAnchor.constraint(equalTo:sections.widthAnchor).isActive = true
                    imageLoads.append((load,container,file))
                    continue
                }
                let preview = GitReviewDiffView(frame:NSRect(x:0,y:0,width:700,height:400))
                preview.continuous = true
                let height = preview.heightAnchor.constraint(equalToConstant:70); height.isActive = true
                preview.onHeightChange = { [weak preview,weak self] in
                    guard let preview else { return }; height.constant = preview.measuredHeight
                    (self?.sections.enclosingScrollView as? ReviewStackScroll)?.fitDocument()
                }
                sections.addArrangedSubview(preview)
                let width = preview.widthAnchor.constraint(equalTo:sections.widthAnchor)
                width.priority = .defaultHigh; width.isActive = true
                configureIndexActions(preview.editor,file:file,enabled:true)
                preview.unstaging = file.indexSide == true
                preview.apply = preview.editor.apply
                preview.editor.string = L.text("Reading repository…")
                pending.append((file,preview))
            }
        }
        (sections.enclosingScrollView as? ReviewStackScroll)?.fitDocument()
        let request = generation,loads = pending,images = imageLoads
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            for (load,container,file) in images {
                let result = Result(catching:load)
                DispatchQueue.main.async { [container] in
                    guard let self,self.generation == request else { return }
                    if case .success(let (before,after)) = result {
                        let comparison = GitImageComparison(before:before,after:after)
                        if let staged = file.indexSide {
                            comparison.fileActionTitle = L.text(staged ? "Unstage File" : "Stage File")
                            comparison.onFileAction = { [weak self] in self?.updateIndex(file:file,patch:nil) }
                        }
                        comparison.continuous = true
                        comparison.onHeightChange = { [weak comparison,weak container,weak self] in
                            guard let comparison,let container else { return }
                            container.constraints.first(where:{ $0.firstAttribute == .height && $0.secondItem == nil })?.constant = comparison.measuredHeight
                            (self?.sections.enclosingScrollView as? ReviewStackScroll)?.fitDocument()
                        }
                        Theme.pin(comparison,in:container)
                    }
                    else { Theme.pin(Theme.label(self.errorText(result.map { _ in "" })),in:container) }
                }
            }
            for (file,preview) in loads {
                let result = Result { try file.patch?() ?? "" }
                let imageResult: Result<(Data?,Data?),Error>? = (try? result.get()).flatMap { patch in
                    guard Self.patchContainsImagePath(patch),let load = file.images else { return nil }
                    return Result(catching:load)
                }
                DispatchQueue.main.async {
                    guard let self,self.generation == request else { return }
                    if case .success(let (before,after)) = imageResult,
                       let index = self.sections.arrangedSubviews.firstIndex(of:preview) {
                        let comparison = GitImageComparison(before:before,after:after)
                        if let staged = file.indexSide {
                            comparison.fileActionTitle = L.text(staged ? "Unstage File" : "Stage File")
                            comparison.onFileAction = { [weak self] in self?.updateIndex(file:file,patch:nil) }
                        }
                        comparison.continuous = true
                        let height = comparison.heightAnchor.constraint(equalToConstant:comparison.measuredHeight); height.isActive = true
                        comparison.onHeightChange = { [weak comparison,weak self] in
                            guard let comparison else { return }; height.constant = comparison.measuredHeight
                            (self?.sections.enclosingScrollView as? ReviewStackScroll)?.fitDocument()
                        }
                        preview.removeFromSuperview(); self.sections.insertArrangedSubview(comparison,at:index)
                        comparison.widthAnchor.constraint(equalTo:self.sections.widthAnchor).isActive = true
                        self.find.isEnabled = self.sections.arrangedSubviews.contains { $0 is GitReviewDiffView }
                        (self.sections.enclosingScrollView as? ReviewStackScroll)?.fitDocument()
                    } else { preview.render((try? result.get()) ?? self.errorText(result),path:file.path) }
                }
            }
        }
    }

    private func refreshedFiles() throws -> [File] {
        if let reloadFiles { return try reloadFiles() }
        if directoryMode { return try repository.reviewFiles().map { File(path:$0,patch:nil) } }
        if let staged = initialIndexSide {
            let repo = repository
            return try repo.changes().filter { staged ? $0.staged : $0.unstaged }.map { change in
                File(path:change.path,patch:{ try repo.diff(change,staged:staged) },indexSide:change.conflicted ? nil : staged,images:{
                    let head = try? repo.resolvedRevision("HEAD")
                    let before = staged ? head.flatMap { try? repo.blobData($0,path:change.originalPath ?? change.path) } : try? repo.blobData(":",path:change.path)
                    let after = staged ? try? repo.blobData(":",path:change.path) : try? repo.workingFileData(change.path,largeFile:true)
                    return (before,after)
                })
            }
        }
        return files
    }
    func refreshFromDisk(force: Bool = false) {
        guard (force || NSApp.isActive),window?.sheetParent != nil else { return }
        if refreshing { if force { pendingRefresh = true }; return }
        refreshing = true
        let repo = repository,path = active?.path,requestMode = modes.selectedSegment
        DispatchQueue.global(qos:.utility).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.refreshedFiles() }
            let statistics = try? self.reviewContext.statisticsProvider?()
            let head = try? repo.resolvedRevision("HEAD")
            let fingerprint = path.flatMap { try? repo.run(["hash-object","--",$0]) } ?? "missing"
            let updated = (try? result.get()) ?? self.files
            let patchFingerprint = requestMode == 2 ? updated.map { $0.path+((try? $0.patch?()) ?? "") }.joined(separator:"\0") : ""
            DispatchQueue.main.async {
                self.refreshing = false
                defer {
                    if self.pendingRefresh { self.pendingRefresh = false; self.refreshFromDisk(force:true) }
                }
                guard self.window?.sheetParent != nil else { return }
                if let statistics { self.contextStatistics.stringValue = statistics }
                if case .failure(let error) = result {
                    self.metadata.stringValue = error.localizedDescription; self.retry.isHidden = false
                    return
                }
                let pathsChanged = updated.map(\.path) != self.files.map(\.path)
                self.files = updated
                if let path { self.active = updated.first(where:{ $0.path == path }) ?? updated.first }
                else { self.active = updated.first }
                if pathsChanged { self.renderFileList() }
                let sourceChanged = self.sourceFingerprint != nil && self.sourceFingerprint != fingerprint
                let historyChanged = self.historyFingerprint != nil && self.historyFingerprint != head
                let patchChanged = self.displayFingerprint != nil && self.displayFingerprint != patchFingerprint
                self.sourceFingerprint = fingerprint; self.historyFingerprint = head; self.displayFingerprint = patchFingerprint
                guard force || pathsChanged || (requestMode == 0 && sourceChanged) || (requestMode == 1 && historyChanged) || (requestMode == 2 && patchChanged) else { return }
                if self.active == nil {
                    self.sections.arrangedSubviews.forEach { $0.removeFromSuperview() }
                    self.patchView.isHidden = true; self.imagePane.isHidden = true; self.text.isHidden = false
                    self.show(L.text("No Changes")); return
                }
                if !self.multi.isHidden { self.renderSections() } else { self.refreshDetail() }
            }
        }
    }

    @objc private func closeReview() {
        refreshTimer?.invalidate()
        generation = UUID()
        if let window { parentWindow?.endSheet(window) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeReview(); return false }
}


private final class ReviewStackScroll: NSScrollView {
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let stack: NSStackView

    init(stack: NSStackView) {
        self.stack = stack
        super.init(frame:.zero)
        hasVerticalScroller = true
        drawsBackground = false
        let document = Document()
        documentView = document
        stack.translatesAutoresizingMaskIntoConstraints = true
        document.addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        fitDocument()
    }

    func fitDocument() {
        guard let documentView else { return }
        let width = max(0,contentSize.width)
        let rows = stack.arrangedSubviews
        let height = rows.reduce(CGFloat(0)) { total,row in
            total + (row.constraints.first(where:{ $0.firstAttribute == .height && $0.secondItem == nil })?.constant ?? max(24,row.intrinsicContentSize.height))
        } + CGFloat(max(0,rows.count-1))*stack.spacing
        let size = NSSize(width:width,height:max(contentSize.height,height+8))
        if documentView.frame.size != size { documentView.setFrameSize(size) }
        let frame = NSRect(x:4,y:4,width:max(0,width-8),height:height)
        if stack.frame != frame { stack.frame = frame }
    }
}
