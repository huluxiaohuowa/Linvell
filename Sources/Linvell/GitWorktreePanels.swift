import AppKit
import LinvellCore

/// Native adaptation of FoldGit's worktree sheets and staged completion (dufu, MIT).
class GitNativeSheet: NSWindowController, NSWindowDelegate {
    let body = NSStackView(),footer = NSStackView(),message = NSTextField(wrappingLabelWithString:"")
    private var retained: GitNativeSheet?
    private let bodyScroll = NSScrollView()
    private var bodyHeight: NSLayoutConstraint!
    var working = false { didSet { footer.arrangedSubviews.forEach { ($0 as? NSControl)?.isEnabled = !working }; window?.standardWindowButton(.closeButton)?.isEnabled = !working } }
    init(title: String,owner: NSWindow,width: CGFloat = 650) {
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:width,height:480),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        super.init(window:panel); retained = self; panel.title = L.text(title); panel.delegate = self
        panel.appearance = NSAppearance(named:Theme.isDark ? .darkAqua : .aqua); panel.backgroundColor = Theme.panel
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 10
        footer.orientation = .horizontal; footer.spacing = 8
        message.textColor = .secondaryLabelColor; message.maximumNumberOfLines = 5; message.isSelectable = true
        message.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        bodyScroll.documentView = body; bodyScroll.hasVerticalScroller = true; bodyScroll.drawsBackground = false
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([body.leadingAnchor.constraint(equalTo:bodyScroll.contentView.leadingAnchor),
                                     body.trailingAnchor.constraint(equalTo:bodyScroll.contentView.trailingAnchor),
                                     body.topAnchor.constraint(equalTo:bodyScroll.contentView.topAnchor)])
        bodyHeight = bodyScroll.heightAnchor.constraint(equalToConstant:320)
        // The window and the preferred viewport resize together; permit their intermediate frame.
        bodyHeight.priority = NSLayoutConstraint.Priority(999); bodyHeight.isActive = true
        let content = NSStackView(views:[bodyScroll,message,footer]); content.orientation = .vertical; content.spacing = 12
        bodyScroll.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true
        message.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true
        Theme.pin(content,in:panel.contentView!,inset:20)
        let close = button("Close",#selector(closeSheet)); close.keyEquivalent = "\u{1b}"; footer.addArrangedSubview(close)
        owner.beginSheet(panel) { [weak self] _ in self?.retained = nil }
    }
    required init?(coder: NSCoder) { fatalError() }
    static func alert(owner: NSWindow) -> NSAlert {
        let alert = NSAlert(); alert.window.appearance = owner.effectiveAppearance; return alert
    }
    func button(_ title: String,_ action: Selector) -> NSButton { NSButton(title:L.text(title),target:self,action:action) }
    func installDocumentStack(_ stack: NSStackView,in scroll: NSScrollView) {
        scroll.documentView = stack; stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:scroll.contentView.leadingAnchor),
                                     stack.trailingAnchor.constraint(equalTo:scroll.contentView.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo:scroll.contentView.topAnchor)])
    }
    func row(_ label: String,_ field: NSView) {
        field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        if let text = field as? NSTextField {
            text.usesSingleLineMode = true; text.lineBreakMode = .byTruncatingMiddle
            if !text.isEditable { text.toolTip = text.stringValue; text.isSelectable = true }
        }
        let row = Theme.stack([Theme.label(label),field],spacing:10)
        body.addArrangedSubview(row); row.widthAnchor.constraint(equalTo:body.widthAnchor).isActive = true
    }
    func fit() {
        guard let window else { return }
        message.toolTip = message.stringValue
        window.contentView?.layoutSubtreeIfNeeded()
        let height = max(40,body.fittingSize.height)
        bodyHeight.constant = min(height,max(260,(window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800)-180)
        window.setContentSize(NSSize(width:window.contentView!.bounds.width,height:bodyHeight.constant+130))
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func clear() { body.arrangedSubviews.forEach { $0.removeFromSuperview() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if working { return false }; closeSheet(); return false }
    @objc func closeSheet() { guard !working,let window else { return }; window.sheetParent?.endSheet(window); window.orderOut(nil); retained = nil }
    func run<T>(_ title: String,_ operation: @escaping () throws -> T,then: @escaping (T) -> Void) {
        guard !working else { return }; working = true; message.stringValue = L.text(title)
        DispatchQueue.global(qos:.userInitiated).async { [self] in
            let result = Result(catching:operation)
            DispatchQueue.main.async { [self] in
                working = false
                switch result { case .success(let value): message.stringValue = ""; then(value); fit()
                case .failure(let error): message.stringValue = L.text(error.localizedDescription); fit() }
            }
        }
    }
}

enum GitWorktreePanels {
    static func create(repository: GitRepository,owner: NSWindow,onCreated: @escaping (String) -> Void) {
        _ = GitWorktreeCreatePanel(repository:repository,owner:owner,onCreated:onCreated)
    }
    static func manage(repository: GitRepository,owner: NSWindow,canRemove: @escaping (String) -> Bool,onOpen: @escaping (String) -> Void,onRelocated: @escaping (String,String?) -> Void,onFinish: ((GitWorktreeEntry) -> Void)? = nil) {
        _ = GitWorktreeManagePanel(repository:repository,owner:owner,canRemove:canRemove,onOpen:onOpen,onRelocated:onRelocated,onFinish:onFinish)
    }
    static func finish(entry: GitWorktreeEntry,repository: GitRepository,owner: NSWindow,canRemove: @escaping (String) -> Bool,onOpen: @escaping (String) -> Void,onOpenFile: @escaping (GitRepository,String) -> Void,onChanged: @escaping () -> Void,onRelocated: ((String,String?) -> Void)? = nil) {
        _ = GitWorktreeFinishPanel(entry:entry,repository:repository,owner:owner,canRemove:canRemove,onOpen:onOpen,onOpenFile:onOpenFile,onChanged:onChanged,onRelocated:onRelocated)
    }
}

final class GitWorktreeCreatePanel: GitNativeSheet {
    let repository: GitRepository,onCreated: (String) -> Void
    let mode = NSPopUpButton(),branch = NSTextField(),revision = NSTextField(string:"HEAD"),parent = NSTextField(),name = NSTextField(),existing = NSPopUpButton()
    init(repository: GitRepository,owner: NSWindow,onCreated: @escaping (String) -> Void) {
        self.repository = repository; self.onCreated = onCreated
        super.init(title:"New Worktree",owner:owner)
        parent.stringValue = (repository.directory as NSString).deletingLastPathComponent
        name.stringValue = (repository.directory as NSString).lastPathComponent+"-worktree"
        mode.addItems(withTitles:[L.text("New Branch"),L.text("Existing Branch"),L.text("Detached HEAD")]); mode.target = self; mode.action = #selector(render)
        footer.addArrangedSubview(button("Create Worktree",#selector(create)))
        render()
        run("Loading branches…",{ () -> [String] in
            let occupied = Set(try repository.worktrees().map(\.branch))
            return try repository.run(["for-each-ref","--format=%(refname:short)","refs/heads/"]).split(whereSeparator:\.isNewline).map(String.init).filter { !occupied.contains($0) }
        }) { [self] branches in existing.addItems(withTitles:branches) }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func render() {
        clear(); row("Branch",mode)
        if mode.indexOfSelectedItem == 0 { row("New Branch",branch) }
        if mode.indexOfSelectedItem == 1 { row("Existing Branch",existing) } else { row("Start Point",revision) }
        row("Parent Folder",parent)
        if repository.remote == nil { body.addArrangedSubview(button("Choose Parent Folder…",#selector(chooseParent))) }
        row("Folder Name",name); fit()
    }
    @objc func chooseParent() {
        guard let window else { return }; let panel = NSOpenPanel(); panel.appearance = window.effectiveAppearance; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath:parent.stringValue)
        panel.beginSheetModal(for:window) { [self] response in if response == .OK,let url = panel.url { parent.stringValue = url.path } }
    }
    @objc func create() {
        let leaf = name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),branchName = branch.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !leaf.isEmpty,leaf != ".",leaf != "..",!leaf.contains("/"),!leaf.contains("\0"),parent.stringValue.hasPrefix("/") else { message.stringValue = L.text("Choose an absolute parent folder and a valid folder name."); return }
        let path = (parent.stringValue as NSString).appendingPathComponent(leaf),selected = mode.indexOfSelectedItem
        let start = revision.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard selected == 1 ? existing.selectedItem != nil : !start.isEmpty && (selected == 2 || !branchName.isEmpty) else { message.stringValue = L.text("Choose a branch or enter a start point."); return }
        let args: [String] = selected == 1 ? ["worktree","add","--",path,existing.titleOfSelectedItem ?? ""] : selected == 2 ? ["worktree","add","--detach","--",path,start] : ["worktree","add","-b",branchName,"--",path,start]
        run("Creating worktree…",{ [repository] in _ = try repository.run(args,timeout:120) }) { [self] in closeSheet(); onCreated(path) }
    }
}

final class GitWorktreeManagePanel: GitNativeSheet {
    let repository: GitRepository,canRemove: (String) -> Bool,onOpen: (String) -> Void,onRelocated: (String,String?) -> Void
    private var trees: [GitWorktreeEntry] = []
    let onFinish: ((GitWorktreeEntry) -> Void)?
    private let list = NSStackView()
    init(repository: GitRepository,owner: NSWindow,canRemove: @escaping (String) -> Bool,onOpen: @escaping (String) -> Void,onRelocated: @escaping (String,String?) -> Void,onFinish: ((GitWorktreeEntry) -> Void)?) {
        self.onFinish = onFinish
        self.repository = repository; self.canRemove = canRemove; self.onOpen = onOpen; self.onRelocated = onRelocated
        super.init(title:"Manage Worktrees",owner:owner,width:780)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 12
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; installDocumentStack(list,in:scroll)
        scroll.heightAnchor.constraint(equalToConstant:320).isActive = true; scroll.widthAnchor.constraint(equalToConstant:730).isActive = true
        body.addArrangedSubview(scroll)
        for (title,action) in [("New Worktree",#selector(add)),("Refresh",#selector(reloadTrees)),("Prune Missing Worktrees",#selector(prune))] { footer.addArrangedSubview(button(title,action)) }
        reloadTrees()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func reloadTrees() {
        run("Reading worktrees…",{ [repository] in try repository.worktrees().map { tree in (tree,(try? repository.worktreeDetail(tree,against:"")) ?? "") } }) { [self] values in
            trees = values.map(\.0); list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (index,value) in values.enumerated() {
                let tree = value.0,label = NSTextField(wrappingLabelWithString:(tree.branch.isEmpty ? L.text("Detached HEAD") : tree.branch)+" · "+tree.path+"\n"+GitWorktreeStatusText.localized(value.1))
                label.toolTip = tree.path; if index == 0 { label.stringValue = L.text("Main Worktree")+" · "+label.stringValue }; if tree.path == repository.directory { label.stringValue = L.text("Current")+" · "+label.stringValue }; if tree.locked { label.stringValue += "\n"+L.text("Locked")+" · "+tree.lockReason }; if tree.prunable { label.stringValue += "\n"+L.text("Missing Worktree")+" · "+tree.pruneReason }; label.toolTip = label.stringValue; label.isSelectable = true; label.maximumNumberOfLines = 6
                label.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
                list.addArrangedSubview(label); label.widthAnchor.constraint(equalTo:list.widthAnchor).isActive = true
                var actions = [("Copy Path",#selector(copyPath(_:))),("Open",#selector(openTree(_:)))]
                if index != 0,!tree.branch.isEmpty,onFinish != nil { actions.append(("Finish Worktree",#selector(finishTree(_:)))) }
                if index != 0 { actions += [(tree.locked ? "Unlock Worktree" : "Lock Worktree",#selector(lockTree(_:))),("Move Worktree",#selector(moveTree(_:))),("Remove Worktree",#selector(removeTree(_:)))] }
                for start in stride(from:0,to:actions.count,by:3) {
                    let buttons = NSStackView(); buttons.spacing = 6
                    for (title,action) in actions[start..<min(start+3,actions.count)] {
                        let control = button(title,action); control.tag = index; control.isEnabled = title == "Copy Path" || !tree.prunable; buttons.addArrangedSubview(control)
                    }
                    list.addArrangedSubview(buttons); buttons.widthAnchor.constraint(lessThanOrEqualTo:list.widthAnchor).isActive = true
                }
            }
            fit()
        }
    }
    private func tree(_ sender: NSButton) -> GitWorktreeEntry? { trees.indices.contains(sender.tag) ? trees[sender.tag] : nil }
    @objc func finishTree(_ sender: NSButton) { guard let tree = tree(sender) else { return }; closeSheet(); onFinish?(tree) }
    @objc func copyPath(_ sender: NSButton) { guard let tree = tree(sender) else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(tree.path,forType:.string) }
    @objc func openTree(_ sender: NSButton) { guard let tree = tree(sender),!tree.prunable else { return }; onOpen(tree.path) }
    @objc func add() { guard let window else { return }; GitWorktreePanels.create(repository:repository,owner:window) { [self] path in onOpen(path); reloadTrees() } }
    @objc func lockTree(_ sender: NSButton) { guard let tree = tree(sender) else { return }; run("Updating worktree…",{ [repository] in _ = try repository.run(["worktree",tree.locked ? "unlock" : "lock","--",tree.path]) }) { [self] in reloadTrees() } }
    @objc func moveTree(_ sender: NSButton) {
        guard let tree = tree(sender),!tree.locked,canRemove(tree.path),let window else { message.stringValue = L.text("Close the worktree window and stop its agents before moving it."); return }
        let alert = GitNativeSheet.alert(owner:window); alert.messageText = L.text("Move Worktree"); let path = NSTextField(string:tree.path+"-moved"); path.frame.size = NSSize(width:500,height:24); alert.accessoryView = path
        alert.addButton(withTitle:L.text("Move")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [self] response in
            guard response == .alertFirstButtonReturn,canRemove(tree.path),path.stringValue.hasPrefix("/") else { return }; let destination = path.stringValue
            run("Moving worktree…",{ [repository] in _ = try repository.run(["worktree","move","--",tree.path,destination]) }) { [self] in onRelocated(tree.path,destination); reloadTrees() }
        }
    }
    @objc func removeTree(_ sender: NSButton) {
        guard let tree = tree(sender),!tree.locked,canRemove(tree.path),let window else { message.stringValue = L.text("Close the worktree window and stop its agents before removing it."); return }
        let alert = GitNativeSheet.alert(owner:window); alert.messageText = L.text("Remove Worktree?"); alert.informativeText = tree.path+"\n"+L.text("The clean folder and its ignored files are removed. The branch is kept."); alert.addButton(withTitle:L.text("Remove")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [self] response in guard response == .alertFirstButtonReturn,canRemove(tree.path) else { return }
            run("Removing worktree…",{ [repository] in _ = try repository.run(["worktree","remove","--",tree.path]) }) { [self] in onRelocated(tree.path,nil); reloadTrees() }
        }
    }
    @objc func prune() {
        let missing = trees.filter(\.prunable)
        guard missing.allSatisfy({ canRemove($0.path) }) else { message.stringValue = L.text("Close the worktree window and stop its agents before removing it."); return }
        run("Pruning missing worktrees…",{ [repository] in _ = try repository.run(["worktree","prune","--expire","now"]); return Set(try repository.worktrees().map(\.path)) }) { [self] remaining in
            for tree in missing where !remaining.contains(tree.path) { onRelocated(tree.path,nil) }; reloadTrees()
        }
    }
}

final class GitWorktreeFinishPanel: GitNativeSheet {
    let entry: GitWorktreeEntry,repository: GitRepository,canRemove: (String) -> Bool,onOpen: (String) -> Void,onOpenFile: (GitRepository,String) -> Void,onChanged: () -> Void
    let targets = NSPopUpButton(),removeFolder = NSButton(checkboxWithTitle:L.text("Remove Worktree Folder"),target:nil,action:nil),deleteBranch = NSButton(checkboxWithTitle:L.text("Delete Local Source Branch"),target:nil,action:nil)
    let proceed = NSButton()
    var plan: GitWorktreeCompletionPlan?,merged = false
    let onRelocated: ((String,String?) -> Void)?
    var sourceRemoved = false
    var conflicts: [GitChange] = []
    init(entry: GitWorktreeEntry,repository: GitRepository,owner: NSWindow,canRemove: @escaping (String) -> Bool,onOpen: @escaping (String) -> Void,onOpenFile: @escaping (GitRepository,String) -> Void,onChanged: @escaping () -> Void,onRelocated: ((String,String?) -> Void)? = nil) {
        self.onRelocated = onRelocated
        self.entry = entry; self.repository = repository; self.canRemove = canRemove; self.onOpen = onOpen; self.onOpenFile = onOpenFile; self.onChanged = onChanged
        super.init(title:"Finish Worktree",owner:owner,width:760)
        targets.target = self; targets.action = #selector(preview)
        removeFolder.state = canRemove(entry.path) ? .on : .off
        removeFolder.target = self; removeFolder.action = #selector(updateCleanup)
        proceed.title = L.text("Merge into Target"); proceed.target = self; proceed.action = #selector(advance); footer.addArrangedSubview(proceed)
        run("Loading target branches…",{ [repository] in try repository.run(["for-each-ref","--format=%(refname:short)","refs/heads/"]).split(whereSeparator:\.isNewline).map(String.init).filter { $0 != entry.branch } }) { [self] branches in
            targets.addItems(withTitles:branches); if branches.contains("main") { targets.selectItem(withTitle:"main") }; preview()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func preview() {
        guard !merged,let target = targets.titleOfSelectedItem else { return }
        plan = nil; proceed.isEnabled = false
        run("Reviewing worktree…",{ [repository,entry] in try repository.prepareWorktreeFinish(entry,into:target) }) { [self] value in plan = value; merged = !value.merge.pending && value.commitCount == 0 && !value.switchesBranch; render() }
    }
    func render() {
        clear(); row("Source",Theme.label(entry.branch+" · "+entry.path)); row("Target Branch",targets); targets.isEnabled = !merged
        guard let plan else { return }
        row("Target Worktree",Theme.label(plan.merge.destination.directory)); row("Commits to Merge",Theme.label(String(plan.commitCount)))
        body.addArrangedSubview(button("Open Source Worktree",#selector(openSource))); body.addArrangedSubview(button("Open Target Worktree",#selector(openTarget)))
        if merged {
            body.addArrangedSubview(Theme.label("Merge Complete — review and test the target before pushing.")); body.addArrangedSubview(removeFolder); body.addArrangedSubview(deleteBranch); body.addArrangedSubview(Theme.label("Removing the folder also deletes ignored files. Remote branches are kept.")); updateCleanup(); proceed.title = L.text("Finish Cleanup")
        } else if plan.merge.pending {
            run("Reading merge conflicts…",{ try plan.merge.conflicts() }) { [self] values in
                conflicts = values
                for (index,conflict) in values.enumerated() {
                    let line = NSStackView(); line.spacing = 5
                    let path = Theme.label(conflict.path); path.toolTip = conflict.path; path.maximumNumberOfLines = 1; path.lineBreakMode = .byTruncatingMiddle
                    path.setContentCompressionResistancePriority(.defaultLow,for:.horizontal); line.addArrangedSubview(path)
                    for (title,action) in [("Compare",#selector(compare(_:))),("Use Current",#selector(current(_:))),("Use Incoming",#selector(incoming(_:))),("Edit",#selector(edit(_:))),("Mark Resolved",#selector(mark(_:))),("Delete",#selector(deleteConflict(_:)))] { let control = button(title,action); control.tag = index; line.addArrangedSubview(control) }
                    body.addArrangedSubview(line); line.widthAnchor.constraint(equalTo:body.widthAnchor).isActive = true
                }
                body.addArrangedSubview(button("Refresh Conflicts",#selector(refreshConflicts))); body.addArrangedSubview(button("Abort Merge",#selector(abortMerge)))
                proceed.title = L.text("Continue Merge"); proceed.isEnabled = values.isEmpty
            }
        } else {
            if plan.switchesBranch { body.addArrangedSubview(Theme.label("The target directory will switch to the selected branch before merging.")) }
            body.addArrangedSubview(button("Refresh Review",#selector(preview))); proceed.title = L.text("Merge into Target"); proceed.isEnabled = true
        }
        fit()
    }
    @objc func updateCleanup() { deleteBranch.isEnabled = removeFolder.state == .on; if removeFolder.state == .off { deleteBranch.state = .off } }
    @objc func openSource() { onOpen(entry.path) }
    @objc func openTarget() { if let plan { onOpen(plan.merge.destination.directory) } }
    @objc func refreshConflicts() { render() }
    @objc func advance() {
        guard let plan else { return }
        if merged {
            let remove = removeFolder.state == .on,delete = deleteBranch.state == .on
            guard !remove || canRemove(entry.path) else { message.stringValue = L.text("Close the source worktree window and stop its agents, or keep its folder."); return }
            run("Finishing cleanup…",{ [repository] in
                let result = Result { try repository.cleanupWorktreeFinish(plan,removeFolder:remove,deleteBranch:delete) }
                let removed = remove && ((try? plan.merge.destination.worktrees().contains { $0.path == plan.merge.source.path }) == false)
                return (result,removed)
            }) { [self] result,removed in
                if removed,!sourceRemoved {
                    sourceRemoved = true
                    let location: WorkspaceSession = repository.remote.map { .ssh(host:$0.host,path:entry.path) } ?? .local(path:entry.path)
                    if let error = GitRepositoryOrganization.relocate(location,to:nil) { message.stringValue = error }
                    onRelocated?(entry.path,nil); onChanged()
                }
                switch result {
                case .success:
                    message.stringValue = L.text(remove ? "Worktree removed. Cleanup complete." : "Worktree and branch kept. Cleanup complete."); proceed.isEnabled = false; proceed.title = L.text("Worktree Finished"); removeFolder.isEnabled = false; deleteBranch.isEnabled = false; onChanged()
                case .failure(let error): message.stringValue = (removed ? L.text("Worktree removed. Branch cleanup can be retried.")+"\n" : "")+L.text(error.localizedDescription)
                }
            }
        } else {
            run("Merging into target…",{ [repository] in if plan.merge.pending { try plan.merge.continueWithoutCleanup(); return nil as GitWorktreeMerge? }; return try repository.mergeWorktree(plan) }) { [self] pending in merged = pending == nil; onChanged(); render() }
        }
    }
    private func resolve(_ sender: NSButton,_ work: @escaping (GitWorktreeMerge,String) throws -> Void) { guard let plan,conflicts.indices.contains(sender.tag) else { return }; let path = conflicts[sender.tag].path; run("Resolving conflict…",{ try work(plan.merge,path) }) { [self] in onChanged(); render() } }
    @objc func current(_ sender: NSButton) { resolve(sender) { try $0.resolve($1,useIncoming:false) } }
    @objc func incoming(_ sender: NSButton) { resolve(sender) { try $0.resolve($1,useIncoming:true) } }
    @objc func mark(_ sender: NSButton) { resolve(sender) { try $0.markResolved($1) } }
    @objc func deleteConflict(_ sender: NSButton) {
        guard let window,conflicts.indices.contains(sender.tag) else { return }
        let alert = GitNativeSheet.alert(owner:window); alert.messageText = L.text("Delete Conflicted File?"); alert.informativeText = conflicts[sender.tag].path; alert.addButton(withTitle:L.text("Delete")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [self] response in if response == .alertFirstButtonReturn { resolve(sender) { try $0.deleteConflict($1) } } }
    }
    @objc func edit(_ sender: NSButton) { guard let plan,conflicts.indices.contains(sender.tag) else { return }; onOpenFile(plan.merge.destination,conflicts[sender.tag].path) }
    @objc func compare(_ sender: NSButton) {
        guard let plan,conflicts.indices.contains(sender.tag),let window else { return }; let path = conflicts[sender.tag].path
        run("Reading conflict versions…",{ try plan.merge.versions(path) }) { versions in let alert = GitNativeSheet.alert(owner:window); alert.messageText = path
            let text = NSTextView(frame:NSRect(x:0,y:0,width:650,height:300)); text.isEditable = false; text.string = L.text("CURRENT")+"\n"+(versions.current ?? L.text("Deleted"))+"\n\n"+L.text("INCOMING")+"\n"+(versions.incoming ?? L.text("Deleted")); alert.accessoryView = text; alert.addButton(withTitle:L.text("Done")); alert.beginSheetModal(for:window) }
    }
    @objc func abortMerge() { guard let plan,let window else { return }; let alert = GitNativeSheet.alert(owner:window); alert.messageText = L.text("Abort Merge?"); alert.informativeText = L.text("Edits made while resolving this merge may be discarded."); alert.addButton(withTitle:L.text("Abort Merge")); alert.addButton(withTitle:L.text("Cancel")); alert.beginSheetModal(for:window) { [self] response in guard response == .alertFirstButtonReturn else { return }; run("Aborting merge…",{ try plan.merge.abort() }) { [self] in onChanged(); preview() } } }
}
