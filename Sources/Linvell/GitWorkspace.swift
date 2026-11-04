import AppKit
import LinvellCore

final class GitWorkspace: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private(set) var repository: GitRepository
    let workspaceDirectory: String
    let table = ResponsiveTableView(),diff = NSTextView()
    let mode = NSSegmentedControl(labels:[L.text("Changes"),L.text("Commit Graph"),L.text("Submodules"),L.text("Git Operations")],trackingMode:.selectOne,target:nil,action:nil)
    let side = NSSegmentedControl(labels:[L.text("Working Tree"),L.text("Staged")],trackingMode:.selectOne,target:nil,action:nil)
    let message = NSTextField(),caption = Theme.label("",size:12,color:Theme.secondary)
    var changes: [GitChange] = [],commits: [GitCommit] = []
    var graph: [GitGraphRow] = []
    var onOpen: ((URL) -> Void)?
    var onReview: ((ReviewComment) -> Void)?
    private var reviewChange: GitChange?
    private var reviewStaged = false
    var onOpenRepository: ((GitRepository) -> Void)?
    let pages = NSView()
    var mainPage: NSView?
    var submodulePage: GitSubmoduleView?
    var actionsPage: GitActionsView?
    var running: Bool { actionsPage?.running == true }
    func shutdown() { actionsPage?.terminate() }
    let branchesTable = ResponsiveTableView()
    private var branchNames: [String] = []
    private var currentBranch = ""
    private var visibleChanges: [GitChange] {
        side.selectedSegment == 1 ? changes.filter(\.staged) : changes.filter(\.unstaged)
    }
    private var stage: NSButton!
    private var unstage: NSButton!
    private var stageAll: NSButton!
    private var commit: NSButton!
    private var open: NSButton!
    private var review: NSButton!
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
        appearance = NSAppearance(named:Theme.isDark ? .darkAqua : .aqua)
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(modeChanged)
        side.selectedSegment = 0; side.target = self; side.action = #selector(changeSide)
        message.placeholderString = L.text("Commit message — staged changes only")
        message.font = .systemFont(ofSize:14)
        message.maximumNumberOfLines = 3; message.usesSingleLineMode = false; message.cell?.wraps = true
        message.heightAnchor.constraint(equalToConstant:62).isActive = true
        message.delegate = self
        let refresh = button("Refresh",#selector(reload))
        stage = button("Stage",#selector(stageSelected))
        unstage = button("Unstage",#selector(unstageSelected))
        stageAll = button("Stage All",#selector(stageAllChanges))
        commit = button("Commit",#selector(commitStaged))
        open = button("Open File",#selector(openSelected))
        review = button("Add Review Comment…",#selector(addReviewComment))
        let branches = button("Branches…",#selector(branches)),fetch = button("Fetch",#selector(fetch)),pull = button("Pull",#selector(pull)),push = button("Push",#selector(push))
        let bar = Theme.stack([Theme.label("Source Control",size:20,weight:.semibold),NSView(),refresh],spacing:12)
        let operations = Theme.stack([side,stage,unstage,stageAll,NSView()],spacing:8)
        let network = Theme.stack([caption,NSView(),fetch,pull,push],spacing:8)
        let commitBar = Theme.stack([message,commit],spacing:12)
        changesControls = operations; commitControls = commitBar
        hunkAction = button("Stage Hunk",#selector(applySelectedHunk))
        hunkControls = Theme.stack([hunkPicker,hunkAction,NSView()],spacing:10); hunkControls.isHidden = true
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("changes")); column.width = 360; column.resizingMask = .autoresizingMask; table.addTableColumn(column)
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
        let detailActions = Theme.stack([open,review,NSView()],spacing:8)
        let diffPage = Theme.stack([detailTitle,detailMetadata,detailActions,preview],orientation:.vertical,spacing:8)
        let diffPane = NSView()
        Theme.pin(diffPage,in:diffPane,inset:10)
        split.position = 360; split.addArrangedSubview(list); split.addArrangedSubview(diffPane)
        let navigation = Surface(Theme.panel)
        let repoName = Theme.label(project.lastPathComponent,size:14,weight:.semibold); repoName.lineBreakMode = .byTruncatingMiddle
        let branchColumn = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("branches")); branchColumn.width = 180; branchColumn.resizingMask = .autoresizingMask
        branchesTable.addTableColumn(branchColumn); branchesTable.headerView = nil; branchesTable.rowHeight = 30; branchesTable.dataSource = self; branchesTable.delegate = self
        branchesTable.backgroundColor = Theme.panel; branchesTable.autoresizingMask = [.width]
        branchesTable.target = self; branchesTable.doubleAction = #selector(checkoutSelectedBranch)
        let branchScroll = ResponsiveScrollView(); branchScroll.documentView = branchesTable; branchScroll.hasVerticalScroller = true; branchScroll.drawsBackground = false
        Theme.pin(Theme.stack([repoName,Theme.label("BRANCHES",size:10,color:Theme.secondary,weight:.semibold),branchScroll,branches],orientation:.vertical,spacing:12),in:navigation,inset:14)
        mainPage = split; Theme.pin(split,in:pages)
        let details = Theme.stack([bar,mode,network,operations,hunkControls,pages,commitBar],orientation:.vertical,spacing:10)
        let content = NSView()
        Theme.pin(details,in:content,inset:10)
        let root = ResizablePanes(); root.firstMinimum = 150; root.secondMinimum = 540; root.position = 190
        root.addArrangedSubview(navigation); root.addArrangedSubview(content)
        Theme.pin(root,in:self,inset:16)
        for scroll in [list,branchScroll] {
            scroll.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self,selector:#selector(resizeTable(_:)),name:NSView.frameDidChangeNotification,object:scroll)
        }
        updateMode()
        changeSide()
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func resizeTable(_ notification: Notification) {
        guard let scroll = notification.object as? NSScrollView,
              let list = scroll.documentView as? NSTableView,scroll.bounds.width > 0 else { return }
        let width = scroll.bounds.width
        list.setFrameSize(NSSize(width:width,height:list.frame.height))
        list.tableColumns.first?.width = width
    }
    func refreshTheme() {
        layer?.backgroundColor = Theme.canvas.cgColor; appearance = NSAppearance(named:Theme.isDark ? .darkAqua : .aqua)
        table.backgroundColor = Theme.panel; diff.backgroundColor = Theme.canvas
        table.reloadData(); selectionChanged()
        actionsPage?.refreshTheme()
    }
    private func button(_ title: String,_ action: Selector) -> NSButton {
        let button = Theme.actionButton(title,target:self,action:action); actions.append(button); return button
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === branchesTable ? branchNames.count : mode.selectedSegment == 0 ? visibleChanges.count : mode.selectedSegment == 1 ? commits.count : 0 }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        if tableView === branchesTable {
            guard branchNames.indices.contains(row) else { return nil }
            let active = branchNames[row] == currentBranch
            let label = Theme.label((active ? "✓  " : "⑂  ")+branchNames[row],size:12,color:active ? Theme.accent : Theme.foreground,weight:active ? .semibold : .regular); label.maximumNumberOfLines = 1; label.usesSingleLineMode = true; label.lineBreakMode = .byTruncatingMiddle
            return label
        }
        if mode.selectedSegment == 0 {
            let files = visibleChanges
            guard files.indices.contains(row) else { return nil }
            return GitFileCell(change:files[row],staged:side.selectedSegment == 1)
        } else {
            guard commits.indices.contains(row),graph.indices.contains(row) else { return nil }
            let commit = commits[row]
            return GitHistoryCell(commit:commit,row:graph[row],lanes:graph.map(\.width).max() ?? 1)
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === table { selectionChanged() }
    }
    @objc func showSubmodules() { mode.selectedSegment = 2; modeChanged() }
    @objc func showOperations() { mode.selectedSegment = 3; modeChanged() }
    @objc private func modeChanged() {
        updateMode()
        reloadRows()
    }
    @objc private func changeSide() {
        stage.isHidden = side.selectedSegment == 1
        stageAll.isHidden = stage.isHidden
        unstage.isHidden = !stage.isHidden
        reloadRows()
    }
    private func reloadRows(preferredRow: Int = 0) {
        table.reloadData()
        let count = numberOfRows(in:table)
        if count > 0 {
            table.selectRowIndexes(IndexSet(integer:min(max(0,preferredRow),count-1)),byExtendingSelection:false)
        } else {
            table.deselectAll(nil)
        }
        selectionChanged()
    }
    func controlTextDidChange(_ notification: Notification) { updateActionAvailability() }
    private func updateActionAvailability() {
        let working = mode.selectedSegment == 0
        let selected = working && selectedChange != nil
        stage.isEnabled = !busy && selected
        unstage.isEnabled = !busy && selected && selectedChange?.conflicted == false
        stageAll.isEnabled = !busy && working && changes.contains(where:\.unstaged) && !changes.contains(where:\.conflicted)
        open.isHidden = !working; review.isHidden = !working
        open.isEnabled = !busy && selected && selectedChange?.worktree != "D" && selectedChange?.index != "D"
        review.isEnabled = !busy && reviewChange != nil
        commit.isEnabled = !busy && working && changes.contains(where:\.staged) && !changes.contains(where:\.conflicted)
            && !message.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }
    private func updateMode() {
        changesControls.isHidden = mode.selectedSegment != 0; commitControls.isHidden = mode.selectedSegment != 0; hunkControls.isHidden = true
        pages.subviews.forEach { $0.removeFromSuperview() }
        if mode.selectedSegment == 3 {
            if let actionsPage,actionsPage.repository.directory != repository.directory,!actionsPage.running { self.actionsPage = nil }
            if actionsPage == nil {
                let page = GitActionsView(repository:repository); page.onChange = { [weak self] in self?.reload() }
                page.onBusyChange = { [weak self] value in
                    guard let self else { return }; self.busy = value
                    self.actions.forEach { $0.isEnabled = !value }; self.mode.isEnabled = !value; self.branchesTable.isEnabled = !value; self.updateActionAvailability()
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
                    self.actions.forEach { $0.isEnabled = !value }; self.mode.isEnabled = !value; self.branchesTable.isEnabled = !value; self.updateActionAvailability()
                }
                submodulePage = page
            }
            Theme.pin(submodulePage!,in:pages)
        } else if let mainPage { Theme.pin(mainPage,in:pages) }
    }
    @objc private func checkoutSelectedBranch() {
        guard branchNames.indices.contains(branchesTable.selectedRow),branchNames[branchesTable.selectedRow] != currentBranch else { return }
        let name = branchNames[branchesTable.selectedRow],repo = repository
        perform("Switching branch…") { _ = try repo.run(["switch",name]) }
    }
    private func perform(_ title: String,onSuccess: (() -> Void)? = nil,_ work: @escaping () throws -> Void) {
        guard !busy else { return }; busy = true; refreshGeneration = UUID(); caption.stringValue = L.text(title)
        actions.forEach { $0.isEnabled = false }; mode.isEnabled = false; side.isEnabled = false; branchesTable.isEnabled = false
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                self.actions.forEach { $0.isEnabled = true }; self.mode.isEnabled = true; self.side.isEnabled = true; self.branchesTable.isEnabled = true
                self.updateActionAvailability()
                if case .failure(let error) = result { self.caption.stringValue = error.localizedDescription }
                else { onSuccess?(); self.reload() }
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
                    let oldRow = self.table.selectedRow
                    let path = self.selectedChange?.path
                    let hash = self.mode.selectedSegment == 1 && self.commits.indices.contains(oldRow) ? self.commits[oldRow].hash : nil
                    self.repository = repo
                    self.changes = changes; self.commits = commits; self.graph = GitGraph.layout(commits)
                    self.currentBranch = branch
                    self.branchNames = branches; self.branchesTable.reloadData()
                    self.side.setLabel(L.text("Working Tree")+" (\(changes.filter(\.unstaged).count))",forSegment:0)
                    self.side.setLabel(L.text("Staged")+" (\(changes.filter(\.staged).count))",forSegment:1)
                    self.caption.stringValue = (branch.isEmpty ? L.text("Detached HEAD") : branch)+" · "+L.format("%d changed files",changes.count)
                    if self.mode.selectedSegment >= 2 { self.updateMode() }
                    let matchingRow = path.flatMap { path in self.visibleChanges.firstIndex { $0.path == path } }
                        ?? hash.flatMap { hash in commits.firstIndex { $0.hash == hash } }
                    self.reloadRows(preferredRow:matchingRow ?? oldRow)
                case .failure(let error):
                    self.caption.stringValue = error.localizedDescription
                    self.changes = []; self.commits = []; self.graph = []
                    self.branchNames = []; self.branchesTable.reloadData()
                    self.side.setLabel(L.text("Working Tree"),forSegment:0)
                    self.side.setLabel(L.text("Staged"),forSegment:1)
                    self.reloadRows()
                }
            }
        }
    }
    @objc func selectionChanged() {
        reviewChange = nil; hunks = []; hunkControls.isHidden = true
        let request = UUID(); generation = request
        updateActionAvailability()
        guard mode.selectedSegment < 2 else { return }
        let row = table.selectedRow,history = mode.selectedSegment == 1
        let change = selectedChange,hash = history && commits.indices.contains(row) ? commits[row].hash : nil
        diff.string = ""; detailMetadata.stringValue = ""
        guard change != nil || hash != nil else {
            detailTitle.stringValue = L.text(history ? "No commits yet" : side.selectedSegment == 1 ? "No staged changes" : "No working tree changes")
            return
        }
        let repo = repository,staged = side.selectedSegment == 1
        if history {
            let commit = commits[row]
            detailTitle.stringValue = commit.subject
            detailMetadata.stringValue = String(commit.hash.prefix(12))+" · "+commit.author+" · "+String(commit.date.prefix(10))+" · "+commit.refs
        } else if let change {
            detailTitle.stringValue = URL(fileURLWithPath:change.path).lastPathComponent
            detailMetadata.stringValue = L.text(staged ? "Staged" : "Working Tree")+" · "+change.path
        }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result {
                if let hash { return try repo.commitDiff(hash) }
                if let change { return try repo.diff(change,staged:staged) }
                return ""
            }
            let text: String
            switch result {
            case .success(let value): text = value
            case .failure(let error): text = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self,self.generation == request else { return }
                self.hunks = !history && change?.index != "?" && change?.conflicted == false ? GitHunk.parse(text) : []
                self.hunkPicker.removeAllItems(); self.hunkPicker.addItems(withTitles:self.hunks.enumerated().map { L.format("Hunk %d",$0.offset+1)+" · "+$0.element.header })
                self.hunkControls.isHidden = self.hunks.isEmpty
                self.hunkAction.title = L.text(staged ? "Unstage Hunk" : "Stage Hunk")
                let rendered = NSMutableAttributedString(string:text,attributes:[.font:Theme.editorFont,.foregroundColor:Theme.foreground])
                (text as NSString).enumerateSubstrings(in:NSRange(location:0,length:text.utf16.count),options:.byLines) { line,range,_,_ in
                    guard let line else { return }
                    if line.hasPrefix("+"),!line.hasPrefix("+++ ") {
                        let color = Theme.color(Theme.isDark ? 0x8BCB9B : 0x287A43)
                        rendered.addAttributes([.foregroundColor:color,.backgroundColor:color.withAlphaComponent(0.12)],range:range)
                    } else if line.hasPrefix("-"),!line.hasPrefix("--- ") {
                        let color = Theme.color(Theme.isDark ? 0xE99B9B : 0xA43D3D)
                        rendered.addAttributes([.foregroundColor:color,.backgroundColor:color.withAlphaComponent(0.12)],range:range)
                    } else if line.hasPrefix("@@") { rendered.addAttribute(.foregroundColor,value:Theme.accent,range:range) }
                }
                self.diff.textStorage?.setAttributedString(rendered)
                if case .success = result { self.reviewChange = change }
                self.reviewStaged = staged; self.updateActionAvailability()
                self.diff.minSize = self.diff.enclosingScrollView?.contentSize ?? .zero
                self.diff.sizeToFit(); self.diff.scrollRangeToVisible(NSRange(location:0,length:0))
            }
        }
    }
    private var selectedChange: GitChange? {
        guard mode.selectedSegment == 0 else { return nil }
        let files = visibleChanges
        return files.indices.contains(table.selectedRow) ? files[table.selectedRow] : nil
    }
    @objc func addReviewComment() {
        guard mode.selectedSegment == 0,let change = reviewChange else { return }
        do { onReview?(try ReviewComment.diff(path:change.path,originalPath:change.originalPath,text:diff.string,range:diff.selectedRange(),staged:reviewStaged,untracked:change.index == "?")) }
        catch { caption.stringValue = L.text(error.localizedDescription) }
    }
    @objc private func applySelectedHunk() {
        guard hunks.indices.contains(hunkPicker.indexOfSelectedItem) else { return }
        let hunk = hunks[hunkPicker.indexOfSelectedItem],repo = repository,unstage = side.selectedSegment == 1
        perform(unstage ? "Unstaging…" : "Staging…") { try repo.applyHunk(hunk,unstage:unstage) }
    }
    @objc private func stageSelected() { guard let change = selectedChange else { return }; let repo = repository; perform("Staging…") { try repo.stage(change) } }
    @objc private func unstageSelected() { guard let change = selectedChange else { return }; let repo = repository; perform("Unstaging…") { try repo.unstage(change) } }
    @objc private func openSelected() { if let change = selectedChange { onOpen?(repository.root.appendingPathComponent(change.path)) } }
    @objc private func stageAllChanges() {
        guard stageAll.isEnabled else { return }
        let repo = repository
        perform("Staging…") { _ = try repo.run(["add","--all"]) }
    }
    @objc private func commitStaged() {
        guard commit.isEnabled else { return }
        let text = message.stringValue,repo = repository
        perform("Committing…",onSuccess:{ [weak self] in
            guard let self,self.message.stringValue == text else { return }
            self.message.stringValue = ""
            self.updateActionAvailability()
        }) { try repo.commit(text) }
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
