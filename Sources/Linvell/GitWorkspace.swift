import AppKit
import LinvellCore

final class GitWorkspace: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var repository: GitRepository
    let workspaceDirectory: String
    let table = ResponsiveTableView(),diff = NSTextView()
    let mode = NSSegmentedControl(labels:[L.text("Changes"),L.text("Commit Graph"),L.text("Submodules"),L.text("Git Operations")],trackingMode:.selectOne,target:nil,action:nil)
    let side = NSSegmentedControl(labels:[L.text("Working Tree"),L.text("Staged")],trackingMode:.selectOne,target:nil,action:nil)
    let message = NSTextField(),caption = Theme.label("",size:12,color:Theme.secondary)
    var changes: [GitChange] = [],commits: [GitCommit] = []
    var graph: [GitGraphRow] = []
    var onOpen: ((URL) -> Void)?
    var onOpenRepository: ((GitRepository) -> Void)?
    let pages = NSView()
    var mainPage: NSView?
    var submodulePage: GitSubmoduleView?
    var actionsPage: GitActionsView?
    var running: Bool { actionsPage?.running == true }
    func shutdown() { actionsPage?.terminate() }
    let branchesTable = ResponsiveTableView()
    private var branchNames: [String] = []
    private var changesControls: NSStackView!
    private var commitControls: NSStackView!
    private let detailTitle = Theme.label("",size:16,weight:.semibold)
    private let detailMetadata = Theme.label("",size:11,color:Theme.secondary)
    private let hunkPicker = Theme.choiceButton()
    private var hunkAction: NSButton!
    private var hunkControls: NSStackView!
    private var hunks: [GitHunk] = []
    private var busy = false,generation = UUID(),refreshGeneration = UUID()
    private var actions: [NSControl] = []
    convenience init(project: URL) { self.init(repository:GitRepository(root:project)) }
    init(repository: GitRepository) {
        self.repository = repository; workspaceDirectory = repository.directory
        let project = repository.root
        super.init(frame:.zero)
        wantsLayer = true; layer?.backgroundColor = Theme.canvas.cgColor
        appearance = NSAppearance(named:Theme.profile.isDark ? .darkAqua : .aqua)
        mode.selectedSegment = 1; mode.target = self; mode.action = #selector(modeChanged)
        side.selectedSegment = 0; side.target = self; side.action = #selector(selectionChanged)
        message.placeholderString = L.text("Commit message — staged changes only")
        message.font = .systemFont(ofSize:14)
        message.maximumNumberOfLines = 3; message.usesSingleLineMode = false; message.cell?.wraps = true
        message.heightAnchor.constraint(equalToConstant:62).isActive = true
        let refresh = button("Refresh",#selector(reload)),stage = button("Stage",#selector(stageSelected)),unstage = button("Unstage",#selector(unstageSelected)),commit = button("Commit",#selector(commitStaged)),open = button("Open File",#selector(openSelected))
        let branches = button("Branches…",#selector(branches)),fetch = button("Fetch",#selector(fetch)),pull = button("Pull",#selector(pull)),push = button("Push",#selector(push))
        let bar = Theme.stack([Theme.label("Source Control",size:20,weight:.semibold),NSView(),refresh],spacing:12)
        let operations = Theme.stack([side,stage,unstage,open,NSView()],spacing:8)
        let network = Theme.stack([caption,NSView(),fetch,pull,push],spacing:8)
        let commitBar = Theme.stack([message,commit],spacing:12)
        changesControls = operations; commitControls = commitBar
        hunkAction = button("Stage Hunk",#selector(applySelectedHunk))
        hunkControls = Theme.stack([hunkPicker,hunkAction,NSView()],spacing:10); hunkControls.isHidden = true
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("changes")); column.width = 400; column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.autoresizingMask = [.width]
        table.headerView = nil; table.rowHeight = 58; table.intercellSpacing = .zero; table.dataSource = self; table.delegate = self
        table.backgroundColor = Theme.panel; table.style = .plain; table.target = self
        table.setAccessibilityLabel(L.text("Git changes and history"))
        let list = ResponsiveScrollView(); list.documentView = table; list.hasVerticalScroller = true; list.drawsBackground = false; list.scrollerStyle = .overlay
        diff.isEditable = false; diff.isRichText = false; diff.font = Theme.editorFont; diff.backgroundColor = Theme.canvas; diff.textColor = Theme.foreground
        diff.isHorizontallyResizable = true; diff.textContainer?.widthTracksTextView = false; diff.textContainer?.containerSize = NSSize(width:100000,height:CGFloat.greatestFiniteMagnitude)
        diff.frame = NSRect(x:0,y:0,width:600,height:400); diff.isVerticallyResizable = true; diff.textContainerInset = NSSize(width:16,height:16)
        diff.setAccessibilityLabel(L.text("Git diff"))
        diff.usesFindBar = true; diff.isIncrementalSearchingEnabled = true
        let preview = ResponsiveScrollView(); preview.documentView = diff; preview.hasVerticalScroller = true; preview.hasHorizontalScroller = true; preview.drawsBackground = false; preview.scrollerStyle = .overlay
        let split = ResizablePanes(); split.firstMinimum = 280; split.secondMinimum = 280
        detailTitle.maximumNumberOfLines = 1; detailTitle.lineBreakMode = .byTruncatingTail
        detailMetadata.maximumNumberOfLines = 1; detailMetadata.lineBreakMode = .byTruncatingMiddle
        let diffPage = Theme.stack([detailTitle,detailMetadata,preview],orientation:.vertical,spacing:10)
        split.position = 400; split.addArrangedSubview(list); split.addArrangedSubview(diffPage)
        let navigation = Surface(Theme.panel)
        let repoName = Theme.label(project.lastPathComponent,size:14,weight:.semibold); repoName.lineBreakMode = .byTruncatingMiddle
        let pending = button("Working Changes",#selector(showChanges)),graph = button("Commit Graph",#selector(showGraph)),modules = button("Submodules",#selector(showSubmodules))
        let branchColumn = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("branches")); branchColumn.width = 180; branchColumn.resizingMask = .autoresizingMask
        branchesTable.addTableColumn(branchColumn); branchesTable.headerView = nil; branchesTable.rowHeight = 30; branchesTable.dataSource = self; branchesTable.delegate = self
        branchesTable.backgroundColor = Theme.panel; branchesTable.autoresizingMask = [.width]
        branchesTable.target = self; branchesTable.doubleAction = #selector(checkoutSelectedBranch)
        let branchScroll = ResponsiveScrollView(); branchScroll.documentView = branchesTable; branchScroll.hasVerticalScroller = true; branchScroll.drawsBackground = false
        Theme.pin(Theme.stack([repoName,pending,graph,modules,Theme.label("BRANCHES",size:10,color:Theme.secondary,weight:.semibold),branchScroll,branches],orientation:.vertical,spacing:12),in:navigation,inset:14)
        mainPage = split; Theme.pin(split,in:pages)
        let details = Theme.stack([bar,mode,network,operations,hunkControls,commitBar,pages],orientation:.vertical,spacing:14)
        let root = ResizablePanes(); root.firstMinimum = 150; root.secondMinimum = 540; root.position = 190
        root.addArrangedSubview(navigation); root.addArrangedSubview(details)
        Theme.pin(root,in:self,inset:16)
        updateMode()
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        for list in [table,branchesTable] {
            if let width = list.enclosingScrollView?.contentView.bounds.width,width > 0 {
                list.tableColumns.first?.width = width
                list.setFrameSize(NSSize(width:width,height:list.frame.height))
                list.sizeLastColumnToFit()
            }
        }
    }
    func refreshTheme() {
        layer?.backgroundColor = Theme.canvas.cgColor; appearance = NSAppearance(named:Theme.profile.isDark ? .darkAqua : .aqua)
        table.backgroundColor = Theme.panel; diff.backgroundColor = Theme.canvas
        table.reloadData(); selectionChanged()
        actionsPage?.refreshTheme()
    }
    private func button(_ title: String,_ action: Selector) -> NSButton {
        let button = Theme.actionButton(title,target:self,action:action); actions.append(button); return button
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === branchesTable ? branchNames.count : mode.selectedSegment == 0 ? changes.count : mode.selectedSegment == 1 ? commits.count : 0 }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        if tableView === branchesTable {
            guard branchNames.indices.contains(row) else { return nil }
            let label = Theme.label("⑂  "+branchNames[row],size:12); label.maximumNumberOfLines = 1; label.usesSingleLineMode = true; label.lineBreakMode = .byTruncatingMiddle
            return label
        }
        if mode.selectedSegment == 0 {
            guard changes.indices.contains(row) else { return nil }
            let change = changes[row]
            return GitFileCell(change:change)
        } else {
            guard commits.indices.contains(row),graph.indices.contains(row) else { return nil }
            let commit = commits[row]
            return GitHistoryCell(commit:commit,row:graph[row],lanes:graph.map(\.width).max() ?? 1)
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === table { selectionChanged() }
    }
    @objc private func showChanges() { mode.selectedSegment = 0; modeChanged() }
    @objc func showSubmodules() { mode.selectedSegment = 2; modeChanged() }
    @objc func showOperations() { mode.selectedSegment = 3; modeChanged() }
    @objc private func showGraph() { mode.selectedSegment = 1; modeChanged() }
    @objc private func modeChanged() { updateMode(); table.reloadData(); if numberOfRows(in:table) > 0 { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); selectionChanged() } else { diff.string = "" } }
    private func updateMode() {
        changesControls.isHidden = mode.selectedSegment != 0; commitControls.isHidden = mode.selectedSegment != 0; hunkControls.isHidden = true
        pages.subviews.forEach { $0.removeFromSuperview() }
        if mode.selectedSegment == 3 {
            if let actionsPage,actionsPage.repository.directory != repository.directory,!actionsPage.running { self.actionsPage = nil }
            if actionsPage == nil {
                let page = GitActionsView(repository:repository); page.onChange = { [weak self] in self?.reload() }
                page.onBusyChange = { [weak self] value in
                    guard let self else { return }; self.busy = value
                    self.actions.forEach { $0.isEnabled = !value }; self.mode.isEnabled = !value; self.branchesTable.isEnabled = !value
                }
                actionsPage = page
            }
            Theme.pin(actionsPage!,in:pages)
        } else if mode.selectedSegment == 2 {
            if submodulePage == nil || submodulePage?.repository.directory != repository.directory {
                let page = GitSubmoduleView(repository:repository)
                page.onOpenRepository = { [weak self] in self?.onOpenRepository?($0) }
                page.onChange = { [weak self] in self?.reload() }
                page.onMore = { [weak self] path in
                    self?.showOperations(); self?.actionsPage?.selectOperation("Submodule — Initialize",path:path)
                }
                page.onBusyChange = { [weak self] value in
                    guard let self else { return }; self.busy = value
                    self.actions.forEach { $0.isEnabled = !value }; self.mode.isEnabled = !value; self.branchesTable.isEnabled = !value
                }
                submodulePage = page
            }
            Theme.pin(submodulePage!,in:pages)
        } else if let mainPage { Theme.pin(mainPage,in:pages) }
    }
    @objc private func checkoutSelectedBranch() {
        guard branchNames.indices.contains(branchesTable.selectedRow) else { return }
        let name = branchNames[branchesTable.selectedRow],repo = repository
        perform("Switching branch…") { _ = try repo.run(["switch",name]) }
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
            let result = Result { () throws -> ([GitChange],[GitCommit],String,[String],GitRepository) in
                let repo = try repo.resolvedWorkingTree()
                let changes = try repo.changes()
                let commits = (try? repo.history()) ?? []
                let branch = (try? repo.run(["branch","--show-current"]))?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
                let branches = (try? repo.run(["for-each-ref","--format=%(refname:short)","refs/heads/"]))?.components(separatedBy:.newlines).filter { !$0.isEmpty } ?? []
                return (changes,commits,branch,branches,repo)
            }
            DispatchQueue.main.async {
                guard let self,self.refreshGeneration == request else { return }
                switch result {
                case .success(let (changes,commits,branch,branches,repo)):
                    self.repository = repo
                    self.changes = changes; self.commits = commits; self.graph = GitGraph.layout(commits)
                    self.branchNames = branches; self.branchesTable.reloadData()
                    self.caption.stringValue = branch+" · "+L.format("%d changed files",changes.count)
                    self.table.reloadData(); self.diff.string = ""
                    if self.mode.selectedSegment >= 2 { self.updateMode() }
                    if self.numberOfRows(in:self.table) > 0 { self.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); self.selectionChanged() }
                case .failure(let error): self.caption.stringValue = error.localizedDescription; self.changes = []; self.commits = []; self.table.reloadData()
                }
            }
        }
    }
    @objc func selectionChanged() {
        guard mode.selectedSegment < 2 else { return }
        let row = table.selectedRow,history = mode.selectedSegment == 1
        guard row >= 0,row < (history ? commits.count : changes.count) else { return }
        let request = UUID(); generation = request; let repo = repository,staged = side.selectedSegment == 1
        let change = history ? nil : changes[row],hash = history ? commits[row].hash : nil
        if history {
            let commit = commits[row]
            detailTitle.stringValue = commit.subject
            detailMetadata.stringValue = String(commit.hash.prefix(12))+" · "+commit.author+" · "+String(commit.date.prefix(10))+" · "+commit.refs
        } else if let change {
            detailTitle.stringValue = URL(fileURLWithPath:change.path).lastPathComponent
            detailMetadata.stringValue = L.text(staged ? "Staged" : "Working Tree")+" · "+change.path
        }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let text: String
            do { text = try hash.map(repo.commitDiff) ?? repo.diff(change!,staged:staged) }
            catch { text = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self,self.generation == request else { return }
                self.hunks = !history && change?.index != "?" ? GitHunk.parse(text) : []
                self.hunkPicker.removeAllItems(); self.hunkPicker.addItems(withTitles:self.hunks.enumerated().map { L.format("Hunk %d",$0.offset+1)+" · "+$0.element.header })
                self.hunkControls.isHidden = self.hunks.isEmpty
                self.hunkAction.title = L.text(staged ? "Unstage Hunk" : "Stage Hunk")
                let rendered = NSMutableAttributedString(string:text,attributes:[.font:Theme.editorFont,.foregroundColor:Theme.foreground])
                (text as NSString).enumerateSubstrings(in:NSRange(location:0,length:text.utf16.count),options:.byLines) { line,range,_,_ in
                    guard let line else { return }
                    if line.hasPrefix("+") { rendered.addAttribute(.foregroundColor,value:Theme.color(Theme.profile.isDark ? 0x8BCB9B : 0x287A43),range:range) }
                    else if line.hasPrefix("-") { rendered.addAttribute(.foregroundColor,value:Theme.color(Theme.profile.isDark ? 0xE99B9B : 0xA43D3D),range:range) }
                    else if line.hasPrefix("@@") { rendered.addAttribute(.foregroundColor,value:Theme.accent,range:range) }
                }
                self.diff.textStorage?.setAttributedString(rendered)
                self.diff.minSize = self.diff.enclosingScrollView?.contentSize ?? .zero
                self.diff.sizeToFit(); self.diff.scrollRangeToVisible(NSRange(location:0,length:0))
            }
        }
    }
    private var selectedChange: GitChange? { mode.selectedSegment == 0 && changes.indices.contains(table.selectedRow) ? changes[table.selectedRow] : nil }
    @objc private func applySelectedHunk() {
        guard hunks.indices.contains(hunkPicker.indexOfSelectedItem) else { return }
        let hunk = hunks[hunkPicker.indexOfSelectedItem],repo = repository,unstage = side.selectedSegment == 1
        perform(unstage ? "Unstaging…" : "Staging…") { try repo.applyHunk(hunk,unstage:unstage) }
    }
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
