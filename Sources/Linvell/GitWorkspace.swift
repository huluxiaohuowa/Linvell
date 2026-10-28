import AppKit
import LinvellCore

final class GitWorkspace: NSView, NSTableViewDataSource, NSTableViewDelegate {
    let repository: GitRepository
    let table = NSTableView(),diff = NSTextView()
    let mode = NSSegmentedControl(labels:[L.text("Changes"),L.text("History")],trackingMode:.selectOne,target:nil,action:nil)
    let side = NSSegmentedControl(labels:[L.text("Working Tree"),L.text("Staged")],trackingMode:.selectOne,target:nil,action:nil)
    let message = NSTextField(),caption = Theme.label("",size:12,color:Theme.secondary)
    var changes: [GitChange] = [],commits: [GitCommit] = []
    var graph: [GitGraphRow] = []
    var onOpen: ((URL) -> Void)?
    private var busy = false,generation = UUID(),refreshGeneration = UUID()
    private var actions: [NSControl] = []
    init(project: URL) {
        repository = GitRepository(root:project)
        super.init(frame:.zero)
        wantsLayer = true; layer?.backgroundColor = Theme.canvas.cgColor
        appearance = NSAppearance(named:Theme.profile.isDark ? .darkAqua : .aqua)
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(reload)
        side.selectedSegment = 0; side.target = self; side.action = #selector(selectionChanged)
        message.placeholderString = L.text("Commit message — staged changes only")
        message.font = .systemFont(ofSize:14)
        let refresh = button("Refresh",#selector(reload)),stage = button("Stage",#selector(stageSelected)),unstage = button("Unstage",#selector(unstageSelected)),commit = button("Commit",#selector(commitStaged)),open = button("Open File",#selector(openSelected))
        let branches = button("Branches…",#selector(branches)),fetch = button("Fetch",#selector(fetch)),pull = button("Pull",#selector(pull)),push = button("Push",#selector(push))
        let bar = Theme.stack([Theme.label("Git",size:24,weight:.semibold),mode,NSView(),branches,refresh],spacing:12)
        let operations = Theme.stack([side,stage,unstage,open,NSView()],spacing:8)
        let network = Theme.stack([caption,NSView(),fetch,pull,push],spacing:8)
        let commitBar = Theme.stack([message,commit],spacing:12)
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("changes")); column.width = 400; column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.autoresizingMask = [.width]
        table.headerView = nil; table.rowHeight = 54; table.dataSource = self; table.delegate = self
        table.backgroundColor = Theme.panel; table.target = self; table.action = #selector(selectionChanged)
        table.setAccessibilityLabel(L.text("Git changes and history"))
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.drawsBackground = false; list.scrollerStyle = .overlay
        diff.isEditable = false; diff.isRichText = false; diff.font = Theme.editorFont; diff.backgroundColor = Theme.canvas; diff.textColor = Theme.foreground
        diff.isHorizontallyResizable = true; diff.textContainer?.widthTracksTextView = false; diff.textContainer?.containerSize = NSSize(width:100000,height:CGFloat.greatestFiniteMagnitude)
        diff.frame = NSRect(x:0,y:0,width:600,height:400); diff.isVerticallyResizable = true; diff.textContainerInset = NSSize(width:16,height:16)
        diff.setAccessibilityLabel(L.text("Git diff"))
        let preview = NSScrollView(); preview.documentView = diff; preview.hasVerticalScroller = true; preview.hasHorizontalScroller = true; preview.drawsBackground = false; preview.scrollerStyle = .overlay
        let split = ResizablePanes(); split.firstMinimum = 280; split.secondMinimum = 280
        split.position = 400; split.addArrangedSubview(list); split.addArrangedSubview(preview)
        Theme.pin(Theme.stack([bar,network,operations,commitBar,split],orientation:.vertical,spacing:14),in:self,inset:20)
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refreshTheme() {
        layer?.backgroundColor = Theme.canvas.cgColor; appearance = NSAppearance(named:Theme.profile.isDark ? .darkAqua : .aqua)
        table.backgroundColor = Theme.panel; diff.backgroundColor = Theme.canvas
        table.reloadData(); selectionChanged()
    }
    private func button(_ title: String,_ action: Selector) -> NSButton {
        let button = Theme.actionButton(title,target:self,action:action); actions.append(button); return button
    }
    func numberOfRows(in tableView: NSTableView) -> Int { mode.selectedSegment == 0 ? changes.count : commits.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let title: String,detail: String
        if mode.selectedSegment == 0 {
            let change = changes[row]
            title = "\(change.index)\(change.worktree)  \(URL(fileURLWithPath:change.path).lastPathComponent)"
            detail = change.path
        } else {
            let commit = commits[row]
            title = String(commit.hash.prefix(8))+"  "+commit.subject
            detail = commit.author+" · "+String(commit.date.prefix(10))+(commit.refs.isEmpty ? "" : " · "+commit.refs)
        }
        let a = Theme.label(title,size:13,weight:.medium),b = Theme.label(detail,size:11,color:Theme.secondary)
        a.lineBreakMode = .byTruncatingTail; b.lineBreakMode = .byTruncatingMiddle
        let stack = Theme.stack([a,b],orientation:.vertical,spacing:5); stack.alignment = .leading
        if mode.selectedSegment == 1,graph.indices.contains(row) { return Theme.stack([GitGraphView(graph[row]),stack],spacing:6) }
        return stack
    }
    private func perform(_ title: String,_ work: @escaping () throws -> Void) {
        guard !busy else { return }; busy = true; caption.stringValue = L.text(title)
        actions.forEach { $0.isEnabled = false }; mode.isEnabled = false; side.isEnabled = false
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                self.actions.forEach { $0.isEnabled = true }; self.mode.isEnabled = true; self.side.isEnabled = true
                if case .failure(let error) = result { self.caption.stringValue = error.localizedDescription }
                else { self.reload() }
            }
        }
    }
    @objc func reload() {
        guard !busy else { return }
        let request = UUID(); refreshGeneration = request; let repo = repository
        caption.stringValue = L.text("Reading repository…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { () throws -> ([GitChange],[GitCommit],String) in
                let changes = try repo.changes()
                let commits = (try? repo.history()) ?? []
                let branch = (try? repo.run(["status","--short","--branch","--untracked-files=no"]).components(separatedBy:.newlines).first) ?? ""
                return (changes,commits,branch)
            }
            DispatchQueue.main.async {
                guard let self,self.refreshGeneration == request else { return }
                switch result {
                case .success(let (changes,commits,branch)):
                    self.changes = changes; self.commits = commits; self.graph = GitGraph.layout(commits)
                    self.caption.stringValue = branch+" · "+L.format("%d changed files",changes.count)
                    self.table.reloadData(); self.diff.string = ""
                    if self.numberOfRows(in:self.table) > 0 { self.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); self.selectionChanged() }
                case .failure(let error): self.caption.stringValue = error.localizedDescription; self.changes = []; self.commits = []; self.table.reloadData()
                }
            }
        }
    }
    @objc func selectionChanged() {
        let row = table.selectedRow,history = mode.selectedSegment == 1
        guard row >= 0,row < (history ? commits.count : changes.count) else { return }
        let request = UUID(); generation = request; let repo = repository,staged = side.selectedSegment == 1
        let change = history ? nil : changes[row],hash = history ? commits[row].hash : nil
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let text: String
            do { text = try hash.map(repo.commitDiff) ?? repo.diff(change!,staged:staged) }
            catch { text = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self,self.generation == request else { return }
                let rendered = NSMutableAttributedString(string:text,attributes:[.font:Theme.editorFont,.foregroundColor:Theme.foreground])
                (text as NSString).enumerateSubstrings(in:NSRange(location:0,length:text.utf16.count),options:.byLines) { line,range,_,_ in
                    guard let line else { return }
                    if line.hasPrefix("+") { rendered.addAttribute(.foregroundColor,value:NSColor.systemGreen,range:range) }
                    else if line.hasPrefix("-") { rendered.addAttribute(.foregroundColor,value:NSColor.systemRed,range:range) }
                    else if line.hasPrefix("@@") { rendered.addAttribute(.foregroundColor,value:Theme.accent,range:range) }
                }
                self.diff.textStorage?.setAttributedString(rendered)
                self.diff.minSize = self.diff.enclosingScrollView?.contentSize ?? .zero
                self.diff.sizeToFit(); self.diff.scrollRangeToVisible(NSRange(location:0,length:0))
            }
        }
    }
    private var selectedChange: GitChange? { mode.selectedSegment == 0 && changes.indices.contains(table.selectedRow) ? changes[table.selectedRow] : nil }
    @objc private func stageSelected() { guard let change = selectedChange else { return }; let repo = repository; perform("Staging…") { try repo.stage(change) } }
    @objc private func unstageSelected() { guard let change = selectedChange else { return }; let repo = repository; perform("Unstaging…") { try repo.unstage(change) } }
    @objc private func openSelected() { if let change = selectedChange { onOpen?(repository.root.appendingPathComponent(change.path)) } }
    @objc private func commitStaged() {
        let text = message.stringValue,repo = repository
        perform("Committing…") { try repo.commit(text) }
    }
    @objc private func fetch() { let repo = repository; perform("Fetching…") { _ = try repo.run(["fetch","--all"],timeout:120) } }
    @objc private func pull() { let repo = repository; perform("Pulling (fast-forward only)…") { _ = try repo.run(["pull","--ff-only"],timeout:120) } }
    @objc private func push() { let repo = repository; perform("Pushing…") { _ = try repo.run(["push"],timeout:120) } }
    @objc private func branches() {
        let repo = repository
        let alert = NSAlert(); alert.messageText = L.text("Switch or create a branch")
        let name = NSTextField(frame:NSRect(x:0,y:0,width:360,height:28)); name.placeholderString = L.text("Branch name")
        alert.accessoryView = name; alert.addButton(withTitle:L.text("Switch")); alert.addButton(withTitle:L.text("Create")); alert.addButton(withTitle:L.text("Cancel"))
        let response = alert.runModal(),branch = name.stringValue
        guard response != .alertThirdButtonReturn,!branch.isEmpty,!branch.hasPrefix("-") else { return }
        perform("Switching branch…") {
            _ = try repo.run(["check-ref-format","--branch",branch])
            _ = try repo.run(response == .alertFirstButtonReturn ? ["switch",branch] : ["switch","-c",branch])
        }
    }
}
