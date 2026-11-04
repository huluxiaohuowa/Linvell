import AppKit
import LinvellCore

final class GitWorkspace: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private(set) var repository: GitRepository
    let workspaceDirectory: String
    let table = ResponsiveTableView(),diff = NSTextView()
    let mode = NSSegmentedControl(labels:[L.text("Changes"),L.text("Commit Graph"),L.text("Submodules"),L.text("Git Operations")],trackingMode:.selectOne,target:nil,action:nil)
    let side = NSSegmentedControl(labels:[L.text("Working Tree"),L.text("Staged")],trackingMode:.selectOne,target:nil,action:nil)
    let message = NSTextField(),caption = Theme.label("",size:12,color:Theme.secondary)
    var changes: [GitChange] = [],commits: [GitCommit] = []
    var graph: [GitGraphRow] = []
    private var graphWidth = 1
    var onOpen: ((URL) -> Void)?
    var onReview: ((ReviewComment) -> Void)?
    private var reviewChange: GitChange?
    private var reviewStaged = false
    var onOpenRepository: ((GitRepository) -> Void)?
    let pages = NSView()
    var mainPage: NSView?
    var submodulePage: GitSubmoduleView?
    var actionsPage: GitActionsView?
    var running: Bool { busy || actionsPage?.running == true }
    func shutdown() { autoFetchTimer?.invalidate(); actionsPage?.terminate() }
    let branchesTable = ResponsiveTableView()
    private let sidebarScope = NSSegmentedControl(labels:[L.text("Branches"),L.text("Worktrees")],trackingMode:.selectOne,target:nil,action:nil)
    private var showsWorktrees: Bool { sidebarScope.selectedSegment == 1 }
    private var branchNames: [String] = []
    private var currentBranch = ""
    var references: [GitReference] = []
    var worktrees: [GitWorktreeEntry] = []
    var gitPicker: QuickPicker?
    var onOpenMergeFile: ((GitRepository,String) -> Void)?
    var onOpenWorktree: ((String) -> Void)?
    var onNewTask: (() -> Void)?
    var onRepositories: (() -> Void)?
    var onCanRemoveWorktree: ((String) -> Bool)?
    var onOpenTerminal: (() -> Void)?
    private let historySearch = NSSearchField()
    private let historyScope = NSSegmentedControl(labels:[L.text("Current Branch"),L.text("All References")],trackingMode:.selectOne,target:nil,action:nil)
    private var historyControls: NSStackView!
    private var moreHistory: NSButton!
    private var historyLimit = 150
    private var searchResults: [GitCommit] = []
    private var searchOffset: Int?
    private var searchTask: Task<Void,Never>?
    private var searchGeneration = UUID()
    private var searchingHistory = false
    private var historyQuery: String { historySearch.stringValue.trimmingCharacters(in:.whitespacesAndNewlines) }
    private var displayedCommits: [GitCommit] { historyQuery.isEmpty ? commits : searchResults }
    private var fileRows: [GitChange?] = []
    private var fileGroups: [Int:String] = [:]
    private var collapsedFolders: Set<String> = []
    private var groupFiles: Bool { UserDefaults.standard.bool(forKey:"git.groupChangedFiles") }
    private let fileSearch = NSSearchField()
    private var autoFetchTimer: Timer?
    private var lastFetch = Date()
    private var autoFetchKey: String { "git.autoFetch."+(repository.remote?.host ?? "local")+":"+workspaceDirectory }
    private var autoFetch: Bool { UserDefaults.standard.bool(forKey:autoFetchKey) }
    private var visibleChanges: [GitChange] {
        side.selectedSegment == 1 ? changes.filter(\.staged) : changes.filter(\.unstaged)
    }
    private var stage: NSButton!
    private var unstage: NSButton!
    private var unstageAll: NSButton!
    private var stageAll: NSButton!
    private var commit: NSButton!
    private var open: NSButton!
    private var review: NSButton!
    private var changesControls: NSStackView!
    private var commitControls: NSStackView!
    let diffMode = NSSegmentedControl(labels:[L.text("Auto"),L.text("Unified"),L.text("Side by Side")],trackingMode:.selectOne,target:nil,action:nil)
    private let diffHost = NSView()
    private let splitDiff = GitSplitDiff()
    private var unifiedPreview: NSScrollView!
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
        unstageAll = button("Unstage All",#selector(unstageAllChanges))
        stageAll = button("Stage All",#selector(stageAllChanges))
        commit = button("Commit",#selector(commitStaged))
        open = button("Open File",#selector(openSelected))
        review = button("Add Review Comment…",#selector(addReviewComment))
        let branches = button("Branches and Tags",#selector(browseReferences)),fetch = button("Fetch",#selector(fetch)),pull = button("Pull",#selector(pull)),push = button("Push",#selector(push))
        let bar = Theme.stack([Theme.label("Source Control",size:20,weight:.semibold),NSView(),refresh],spacing:12)
        fileSearch.placeholderString = L.text("Filter changed files")
        fileSearch.delegate = self
        let operations = Theme.stack([side,stage,unstage,stageAll,unstageAll,fileSearch],spacing:8)
        historySearch.placeholderString = L.text("Search hash, author, email, message or reference")
        historySearch.delegate = self
        historyScope.selectedSegment = 1
        historyScope.target = self; historyScope.action = #selector(changeHistoryScope)
        moreHistory = button("Load More",#selector(loadMoreHistory))
        historyControls = Theme.stack([historyScope,historySearch,moreHistory],spacing:8)
        let tools = button("Git Tools…",#selector(browseTools))
        let network = Theme.stack([caption,NSView(),fetch,pull,push,tools],spacing:8)
        let menu = NSMenu(); menu.delegate = self; table.menu = menu
        let branchMenu = NSMenu(); branchMenu.delegate = self; branchesTable.menu = branchMenu
        let commitBar = Theme.stack([message,commit],spacing:12)
        changesControls = operations; commitControls = commitBar
        hunkAction = button("Stage Hunk",#selector(applySelectedHunk))
        hunkControls = Theme.stack([hunkPicker,hunkAction,NSView()],spacing:10); hunkControls.isHidden = true
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("changes")); column.width = 360; column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.autoresizingMask = [.width]
        table.headerView = nil; table.rowHeight = 58; table.intercellSpacing = .zero; table.dataSource = self; table.delegate = self
        table.backgroundColor = Theme.panel; table.style = .plain; table.target = self; table.doubleAction = #selector(activateRow)
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
        unifiedPreview = preview
        Theme.pin(preview,in:diffHost); Theme.pin(splitDiff,in:diffHost)
        splitDiff.isHidden = true
        diffMode.selectedSegment = UserDefaults.standard.object(forKey:"git.diffMode") as? Int ?? 1
        diffMode.target = self; diffMode.action = #selector(changeDiffMode)
        diffHost.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self,selector:#selector(updateDiffMode),name:NSView.frameDidChangeNotification,object:diffHost)
        let detailActions = Theme.stack([open,review,NSView()],spacing:8)
        let diffPage = Theme.stack([detailTitle,detailMetadata,diffMode,detailActions,diffHost],orientation:.vertical,spacing:8)
        let diffPane = NSView()
        Theme.pin(diffPage,in:diffPane,inset:10)
        split.position = 360; split.addArrangedSubview(list); split.addArrangedSubview(diffPane)
        let navigation = Surface(Theme.panel)
        let repoName = Theme.label(project.lastPathComponent,size:14,weight:.semibold); repoName.lineBreakMode = .byTruncatingMiddle
        let branchColumn = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("branches")); branchColumn.width = 180; branchColumn.resizingMask = .autoresizingMask
        branchesTable.addTableColumn(branchColumn); branchesTable.headerView = nil; branchesTable.rowHeight = 30; branchesTable.dataSource = self; branchesTable.delegate = self
        branchesTable.backgroundColor = Theme.panel; branchesTable.autoresizingMask = [.width]
        branchesTable.target = self; branchesTable.doubleAction = #selector(activateSidebarRow)
        sidebarScope.selectedSegment = 0
        sidebarScope.target = self; sidebarScope.action = #selector(changeSidebarScope)
        let branchScroll = ResponsiveScrollView(); branchScroll.documentView = branchesTable; branchScroll.hasVerticalScroller = true; branchScroll.drawsBackground = false
        Theme.pin(Theme.stack([repoName,button("Repositories…",#selector(browseRepositories)),sidebarScope,branchScroll,button("Manage Worktrees…",#selector(browseWorktrees)),branches],orientation:.vertical,spacing:12),in:navigation,inset:14)
        mainPage = split; Theme.pin(split,in:pages)
        let details = Theme.stack([bar,mode,network,operations,historyControls,hunkControls,pages,commitBar],orientation:.vertical,spacing:10)
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
        autoFetchTimer = Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in self?.fetchIfDue() }
    }
    deinit { autoFetchTimer?.invalidate(); searchTask?.cancel() }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func resizeTable(_ notification: Notification) {
        guard let scroll = notification.object as? NSScrollView,
              let list = scroll.documentView as? NSTableView,scroll.bounds.width > 0 else { return }
        let width = scroll.bounds.width
        list.setFrameSize(NSSize(width:width,height:list.frame.height))
        list.tableColumns.first?.width = width
    }
    @objc private func changeDiffMode() {
        UserDefaults.standard.set(diffMode.selectedSegment,forKey:"git.diffMode")
        updateDiffMode()
    }
    @objc private func updateDiffMode() {
        let split = diffMode.selectedSegment == 2 || (diffMode.selectedSegment == 0 && diffHost.bounds.width >= 740)
        if split && splitDiff.isHidden,let storage = diff.textStorage { splitDiff.render(storage) }
        splitDiff.isHidden = !split; unifiedPreview.isHidden = split
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
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === branchesTable ? (showsWorktrees ? worktrees.count : branchNames.count) : mode.selectedSegment == 0 ? fileRows.count : mode.selectedSegment == 1 ? displayedCommits.count : 0 }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        if tableView === branchesTable {
            let name: String,active: Bool,symbol: String,detail: String
            if showsWorktrees {
                guard worktrees.indices.contains(row) else { return nil }
                let entry = worktrees[row]
                name = entry.branch.isEmpty ? URL(fileURLWithPath:entry.path).lastPathComponent : entry.branch
                active = entry.path == repository.directory
                symbol = entry.locked ? "⌑  " : "▱  "
                detail = entry.path
            } else {
                guard branchNames.indices.contains(row) else { return nil }
                name = branchNames[row]; active = name == currentBranch; symbol = "⑂  "; detail = name
            }
            let label = Theme.label((active ? "✓  " : symbol)+name,size:12,color:active ? Theme.accent : Theme.foreground,weight:active ? .semibold : .regular)
            label.maximumNumberOfLines = 1; label.usesSingleLineMode = true; label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = detail
            return label
        }
        if mode.selectedSegment == 0 {
            let files = fileRows
            guard files.indices.contains(row) else { return nil }
            if let file = files[row] { return GitFileCell(change:file,staged:side.selectedSegment == 1) }
            guard let folder = fileGroups[row] else { return nil }
            let label = Theme.label((collapsedFolders.contains(folder) ? "▸  " : "▾  ")+folder,size:12,color:Theme.secondary,weight:.semibold)
            label.lineBreakMode = .byTruncatingMiddle
            return label
        } else {
            let rows = displayedCommits
            guard rows.indices.contains(row) else { return nil }
            return GitHistoryCell(commit:rows[row],row:historyQuery.isEmpty ? graph[row] : nil,lanes:graphWidth)
        }
    }
    func tableView(_ tableView: NSTableView,heightOfRow row: Int) -> CGFloat {
        if tableView === branchesTable { return 30 }
        return mode.selectedSegment == 0 && fileGroups[row] != nil ? 28 : 58
    }
    @objc private func activateRow() {
        let row = table.clickedRow
        if mode.selectedSegment == 0,let folder = fileGroups[row] {
            if collapsedFolders.contains(folder) { collapsedFolders.remove(folder) }
            else { collapsedFolders.insert(folder) }
            reloadRows(preferredRow:row)
        } else if open.isEnabled { openSelected() }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === table { selectionChanged() }
    }
    func focusHistorySearch() { showCommitGraph(); window?.makeFirstResponder(historySearch) }
    func showCommitGraph() { mode.selectedSegment = 1; modeChanged() }
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
        unstageAll.isHidden = unstage.isHidden
        reloadRows(path:selectedChange?.path)
    }
    private func reloadRows(preferredRow: Int = 0,path: String? = nil,hash: String? = nil) {
        let fileQuery = fileSearch.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let files = visibleChanges.filter { fileQuery.isEmpty || $0.path.localizedStandardContains(fileQuery) || $0.originalPath?.localizedStandardContains(fileQuery) == true }
        fileGroups = [:]
        if groupFiles {
            let groups = Dictionary(grouping:files) { ($0.path as NSString).deletingLastPathComponent }
            fileRows = (groups[""] ?? []).map(Optional.some)
            for folder in groups.keys.filter({ !$0.isEmpty }).sorted(by:{ $0.localizedStandardCompare($1) == .orderedAscending }) {
                fileGroups[fileRows.count] = folder
                fileRows.append(nil)
                if !collapsedFolders.contains(folder) || !fileQuery.isEmpty {
                    fileRows += (groups[folder] ?? []).map(Optional.some)
                }
            }
        } else {
            fileRows = files.map(Optional.some)
        }
        table.reloadData()
        table.noteHeightOfRows(withIndexesChanged:IndexSet(integersIn:0..<table.numberOfRows))
        let count = numberOfRows(in:table)
        if count > 0 {
            let matching = path.flatMap { path in fileRows.firstIndex { $0?.path == path } }
                ?? hash.flatMap { hash in displayedCommits.firstIndex { $0.hash == hash } }
            let fallback = preferredRow < 0 && mode.selectedSegment == 0 ? fileRows.firstIndex(where:{ $0 != nil }) ?? 0 : preferredRow
            table.selectRowIndexes(IndexSet(integer:min(max(0,matching ?? fallback),count-1)),byExtendingSelection:false)
        } else {
            table.deselectAll(nil)
        }
        selectionChanged()
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === historySearch {
            if (historySearch.currentEditor() as? NSTextView)?.hasMarkedText() != true { searchHistory(reset:true) }
        }
        else if notification.object as? NSSearchField === fileSearch { reloadRows() }
        else { updateActionAvailability() }
    }
    @objc private func changeHistoryScope() { historyLimit = 150; reload() }
    @objc private func loadMoreHistory() {
        if historyQuery.isEmpty { historyLimit += 150; reload() }
        else { searchHistory(reset:false) }
    }

    private func searchHistory(reset: Bool) {
        if reset {
            searchTask?.cancel()
            searchGeneration = UUID()
            searchResults = []; searchOffset = 0; searchingHistory = false
        }
        let query = historyQuery
        historyScope.isEnabled = query.isEmpty
        guard !query.isEmpty else {
            moreHistory.isEnabled = commits.count >= historyLimit
            reloadRows()
            return
        }
        guard let offset = searchOffset,!searchingHistory else { return }
        searchingHistory = true; moreHistory.isEnabled = false
        if reset { reloadRows() }
        let repo = repository,request = searchGeneration
        searchTask = Task { [weak self] in
            if reset { try? await Task.sleep(nanoseconds:220_000_000) }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority:.userInitiated) {
                Result { try repo.searchHistory(query,offset:offset,isCancelled:{ Task.isCancelled }) }
            }
            let result = await withTaskCancellationHandler(operation:{ await worker.value },onCancel:{ worker.cancel() })
            guard let self,!Task.isCancelled,self.searchGeneration == request else { return }
            self.searchingHistory = false
            switch result {
            case .success(let page):
                let hash = self.selectedCommit?.hash
                let known = Set(self.searchResults.map(\.hash))
                self.searchResults += page.commits.filter { !known.contains($0.hash) }
                self.searchOffset = page.nextOffset
                self.moreHistory.isEnabled = page.nextOffset != nil && !self.busy
                self.reloadRows(hash:hash)
            case .failure(let error):
                self.moreHistory.isEnabled = self.searchOffset != nil && !self.busy
                self.reloadRows()
                self.caption.stringValue = error.localizedDescription
            }
        }
    }
    private func updateActionAvailability() {
        let working = mode.selectedSegment == 0
        let selected = working && selectedChange != nil
        stage.isEnabled = !busy && selected
        unstage.isEnabled = !busy && selected && selectedChange?.conflicted == false
        unstageAll.isEnabled = !busy && working && changes.contains(where:\.staged) && !changes.contains(where:\.conflicted)
        stageAll.isEnabled = !busy && working && changes.contains(where:\.unstaged) && !changes.contains(where:\.conflicted)
        open.isHidden = !working; review.isHidden = !working
        open.isEnabled = !busy && selected && selectedChange?.worktree != "D" && selectedChange?.index != "D"
        review.isEnabled = !busy && reviewChange != nil
        commit.isEnabled = !busy && working && changes.contains(where:\.staged) && !changes.contains(where:\.conflicted)
            && !message.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
    }
    private func updateMode() {
        historyControls.isHidden = mode.selectedSegment != 1
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
    @objc private func changeSidebarScope() {
        branchesTable.deselectAll(nil)
        branchesTable.reloadData()
    }
    @objc private func activateSidebarRow() {
        guard !running else { return }
        let row = branchesTable.clickedRow
        if showsWorktrees {
            guard worktrees.indices.contains(row) else { return }
            let entry = worktrees[row]
            if !entry.prunable,entry.path != repository.directory { onOpenWorktree?(entry.path) }
        } else {
            guard branchNames.indices.contains(row),branchNames[row] != currentBranch else { return }
            let name = branchNames[row],repo = repository
            perform("Switching branch…") { _ = try repo.run(["switch",name]) }
        }
    }
    private func perform(_ title: String,onSuccess: (() -> Void)? = nil,_ work: @escaping () throws -> Void) {
        performResult(title,work) { _ in onSuccess?() }
    }
    private func performResult<T>(_ title: String,_ work: @escaping () throws -> T,completion: @escaping (T) -> Void) {
        guard !busy else { return }; busy = true; refreshGeneration = UUID(); caption.stringValue = L.text(title)
        actions.forEach { $0.isEnabled = false }; mode.isEnabled = false; side.isEnabled = false; branchesTable.isEnabled = false
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                self.actions.forEach { $0.isEnabled = true }; self.mode.isEnabled = true; self.side.isEnabled = true; self.branchesTable.isEnabled = true
                self.updateActionAvailability()
                switch result {
                case .failure(let error): self.caption.stringValue = L.text(error.localizedDescription)
                case .success(let value): completion(value); self.reload()
                }
            }
        }
    }
    @objc func reload() {
        guard !busy else { return }
        let request = UUID(); refreshGeneration = request; let repo = repository
        let allRefs = historyScope.selectedSegment == 1,limit = historyLimit
        caption.stringValue = L.text("Reading repository…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { () throws -> ([GitChange],[GitCommit],String,[GitReference],[GitWorktreeEntry],GitRepository) in
                let repo = try repo.resolvedWorkingTree()
                let changes = try repo.changes()
                let commits = (try? repo.history(allRefs:allRefs,limit:limit)) ?? []
                let branch = (try? repo.run(["branch","--show-current"]))?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
                let refOutput = (try? repo.run(["for-each-ref","--format=%(refname)","refs/heads/","refs/remotes/","refs/tags/"])) ?? ""
                let refs = refOutput.split(whereSeparator:\.isNewline).map { GitReference(fullName:String($0)) }
                let worktrees = (try? repo.worktrees()) ?? []
                return (changes,commits,branch,refs,worktrees,repo)
            }
            DispatchQueue.main.async {
                guard let self,self.refreshGeneration == request else { return }
                switch result {
                case .success(let (changes,commits,branch,refs,worktrees,repo)):
                    let oldRow = self.table.selectedRow
                    let path = self.selectedChange?.path
                    let hash = self.selectedCommit?.hash
                    self.repository = repo
                    self.changes = changes; self.commits = commits; self.graph = GitGraph.layout(commits)
                    self.graphWidth = self.graph.map(\.width).max() ?? 1
                    self.currentBranch = branch; self.references = refs; self.worktrees = worktrees
                    self.branchNames = refs.filter { $0.category == "Local Branches" }.map(\.name)
                    self.branchesTable.reloadData()
                    self.moreHistory.isEnabled = self.historyQuery.isEmpty && commits.count >= limit
                    self.side.setLabel(L.text("Working Tree")+" (\(changes.filter(\.unstaged).count))",forSegment:0)
                    self.side.setLabel(L.text("Staged")+" (\(changes.filter(\.staged).count))",forSegment:1)
                    self.caption.stringValue = (branch.isEmpty ? L.text("Detached HEAD") : branch)+" · "+L.format("%d changed files",changes.count)
                    if self.mode.selectedSegment >= 2 { self.updateMode() }
                    if self.historyQuery.isEmpty { self.reloadRows(preferredRow:oldRow,path:path,hash:hash) }
                    else { self.searchHistory(reset:true) }
                case .failure(let error):
                    self.caption.stringValue = error.localizedDescription
                    self.searchTask?.cancel(); self.searchGeneration = UUID()
                    self.searchResults = []; self.searchOffset = nil; self.searchingHistory = false
                    self.changes = []; self.commits = []; self.graph = []
                    self.branchNames = []; self.references = []; self.worktrees = []; self.branchesTable.reloadData()
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
        let history = mode.selectedSegment == 1
        let change = selectedChange,commit = selectedCommit,hash = commit?.hash
        diff.string = ""; detailMetadata.stringValue = ""
        if !splitDiff.isHidden { splitDiff.render(NSAttributedString()) }
        updateDiffMode()
        guard change != nil || hash != nil else {
            if !history,let folder = fileGroups[table.selectedRow] {
                detailTitle.stringValue = folder
                detailMetadata.stringValue = L.text("Double-click a folder to expand or collapse it")
            } else {
                let searching = history ? !historyQuery.isEmpty : !fileSearch.stringValue.isEmpty
                if history && searchingHistory { detailTitle.stringValue = L.text("Searching repository history…"); return }
                detailTitle.stringValue = L.text(searching ? "No matching results" : history ? "No commits yet" : side.selectedSegment == 1 ? "No staged changes" : "No working tree changes")
            }
            return
        }
        let repo = repository,staged = side.selectedSegment == 1
        if let commit {
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
                if !self.splitDiff.isHidden { self.splitDiff.render(rendered) }
                if case .success = result { self.reviewChange = change }
                self.reviewStaged = staged; self.updateActionAvailability()
                self.diff.minSize = self.diff.enclosingScrollView?.contentSize ?? .zero
                self.diff.sizeToFit(); self.diff.scrollRangeToVisible(NSRange(location:0,length:0))
            }
        }
    }
    private var selectedChange: GitChange? {
        guard mode.selectedSegment == 0 else { return nil }
        return fileRows.indices.contains(table.selectedRow) ? fileRows[table.selectedRow] : nil
    }
    private var selectedCommit: GitCommit? {
        let rows = displayedCommits
        guard mode.selectedSegment == 1,rows.indices.contains(table.selectedRow) else { return nil }
        return rows[table.selectedRow]
    }
    @objc func addReviewComment() {
        guard mode.selectedSegment == 0,let change = reviewChange else { return }
        guard let range = splitDiff.isHidden ? diff.selectedRange() : splitDiff.sourceSelection() else {
            caption.stringValue = L.text("Select adjacent lines in one column, or use Unified for a mixed selection.")
            return
        }
        do { onReview?(try ReviewComment.diff(path:change.path,originalPath:change.originalPath,text:diff.string,range:range,staged:reviewStaged,untracked:change.index == "?")) }
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
    @objc private func unstageAllChanges() {
        guard unstageAll.isEnabled else { return }
        let repo = repository
        perform("Unstaging…") { try repo.unstageAll() }
    }
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
    @objc private func fetch() { lastFetch = Date(); let repo = repository; perform("Fetching…") { _ = try repo.run(["fetch","--all"],timeout:120) } }
    @objc private func pull() { let repo = repository; perform("Pulling (fast-forward only)…") { _ = try repo.run(["pull","--ff-only"],timeout:120) } }
    @objc private func push() { let repo = repository; perform("Pushing…") { _ = try repo.run(["push"],timeout:120) } }
    @objc private func browseRepositories() { onRepositories?() }
    @objc func browseTools() {
        var options = ["Stash Changes","List Stashes","Create Tag","List Remotes"].map { operationOption($0) }
        options += [
            PickerOption(title:L.text("Amend Commit"),detail:L.text("Edit the last commit message and include staged changes")) { [weak self] in self?.amendLastCommit() },
            PickerOption(title:L.text("Insert Commit Template"),detail:L.text("Use the repository’s commit.template setting")) { [weak self] in self?.insertCommitTemplate() }
        ]
        options.insert(PickerOption(title:L.text("Browse Stashes"),detail:"") { [weak self] in self?.browseStashes() },at:1)
        options += [
            PickerOption(title:L.text(groupFiles ? "Show Flat File List" : "Group Files by Folder"),detail:"") { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(!self.groupFiles,forKey:"git.groupChangedFiles")
                self.reloadRows(path:self.selectedChange?.path)
            },
            PickerOption(title:L.text("Jump to HEAD"),detail:"") { [weak self] in self?.jumpToHead() },
            PickerOption(title:L.text(autoFetch ? "Disable Auto Fetch" : "Enable Auto Fetch"),detail:L.text("Fetch every five minutes while this repository is visible")) { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(!self.autoFetch,forKey:self.autoFetchKey)
                self.lastFetch = Date()
            },
            PickerOption(title:L.text("Open Terminal"),detail:repository.directory) { [weak self] in self?.onOpenTerminal?() },
            PickerOption(title:L.text("Git Operations"),detail:"") { [weak self] in self?.showOperations() }
        ]
        showGitPicker("Git Tools…",options)
    }
    private func amendLastCommit() {
        let repo = repository
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let message = try? repo.run(["log","-1","--format=%B","HEAD"]).trimmingCharacters(in:.newlines)
            DispatchQueue.main.async {
                guard let self,!self.running else { return }
                guard let message,!message.isEmpty else { self.caption.stringValue = L.text("No commits yet"); return }
                self.openOperation("Amend Commit",values:["Message":message])
            }
        }
    }
    private func insertCommitTemplate() {
        let repo = repository,existing = message.stringValue
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try repo.commitTemplate() }
            DispatchQueue.main.async {
                guard let self,!self.running else { return }
                switch result {
                case .success(let template):
                    guard self.message.stringValue == existing else { return }
                    self.mode.selectedSegment = 0; self.modeChanged()
                    self.message.stringValue = existing.isEmpty ? template : existing+"\n\n"+template
                    self.updateActionAvailability()
                    self.window?.makeFirstResponder(self.message)
                case .failure(let error): self.caption.stringValue = L.text(error.localizedDescription)
                }
            }
        }
    }
    func jumpToHead() {
        let repo = repository
        mode.selectedSegment = 1; historySearch.stringValue = ""; searchHistory(reset:true); modeChanged()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let head = (try? repo.run(["rev-parse","HEAD"]))?.trimmingCharacters(in:.whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard let self,self.mode.selectedSegment == 1,let head else { return }
                if let row = self.displayedCommits.firstIndex(where:{ $0.hash == head }) {
                    self.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
                    self.table.scrollRowToVisible(row)
                } else {
                    self.historyScope.selectedSegment = 0
                    self.changeHistoryScope()
                }
            }
        }
    }
    private func fetchIfDue() {
        guard autoFetch,!running,window?.isVisible == true,!isHiddenOrHasHiddenAncestor,
              Date().timeIntervalSince(lastFetch) >= 300 else { return }
        fetch()
    }
    private func browseStashes() {
        let repo = repository
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let stashes = (try? repo.run(["stash","list","--format=%gd%x09%gs"])) ?? ""
            DispatchQueue.main.async {
                guard let self,!self.running else { return }
                let options = stashes.split(whereSeparator:\.isNewline).map { line in
                    let fields = line.split(separator:"\t",maxSplits:1)
                    let ref = String(fields[0])
                    return PickerOption(title:ref,detail:fields.count > 1 ? String(fields[1]) : "") { [weak self] in
                        guard let self else { return }
                        self.showGitPicker(ref,["Show Stash","Apply Stash","Pop Stash","Drop Stash"].map {
                            self.operationOption($0,values:["Stash":ref])
                        })
                    }
                }
                self.showGitPicker("Browse Stashes",options)
            }
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard !running else { return }
        if menu === branchesTable.menu {
            let row = branchesTable.clickedRow
            if showsWorktrees {
                guard worktrees.indices.contains(row) else { return }
                addMenuOptions(worktreeOptions(worktrees[row]),to:menu)
                return
            }
            guard branchNames.indices.contains(row) else { return }
            let branch = branchNames[row]
            addMenuOptions(["Switch Branch","Rename Selected Branch","Delete Merged Branch"].map {
                operationOption($0,values:["Branch":branch])
            }+[operationOption("Merge",values:["Revision":"refs/heads/"+branch])],to:menu)
            return
        }
        let row = table.clickedRow
        guard row >= 0 else { return }
        table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        if let commit = selectedCommit {
            addMenuOptions([
                PickerOption(title:L.text("Copy Commit Hash"),detail:"") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.hash,forType:.string) },
                operationOption("Create Branch",values:["Revision":commit.hash]),
                operationOption("Create Tag",values:["Revision":commit.hash]),
                operationOption("Cherry Pick",values:["Revision":commit.hash]),
                operationOption("Revert Commit",values:["Revision":commit.hash])
            ],to:menu)
        } else if let change = selectedChange {
            if change.conflicted {
                addMenuOptions(["Use Current Side","Use Incoming Side","Mark Conflict Resolved"].map {
                    operationOption($0,path:change.path)
                },to:menu)
            } else if side.selectedSegment == 0 && change.index != "?" {
                addMenuOptions([operationOption("Restore File",path:change.path)],to:menu)
            }
        }
    }
    private func addMenuOptions(_ options: [PickerOption],to menu: NSMenu) {
        for option in options {
            let item = NSMenuItem(title:option.title,action:#selector(invokeMenuItem(_:)),keyEquivalent:"")
            item.target = self; item.representedObject = option
            menu.addItem(item)
        }
    }
    @objc private func invokeMenuItem(_ sender: NSMenuItem) { (sender.representedObject as? PickerOption)?.invoke() }

    func finishWorktree(_ entry: GitWorktreeEntry) {
        guard let window,onCanRemoveWorktree?(entry.path) != false else {
            caption.stringValue = L.text("Close the worktree window and stop its agents before finishing.")
            return
        }
        let repo = repository
        let branches = branchNames.filter { $0 != entry.branch }
        guard !branches.isEmpty else { return }
        let targets = Theme.choiceButton()
        targets.frame = NSRect(x:0,y:0,width:360,height:28)
        targets.addItems(withTitles:branches)
        if branches.contains(currentBranch) { targets.selectItem(withTitle:currentBranch) }
        let alert = NSAlert(); alert.messageText = L.text("Finish Worktree…")
        alert.informativeText = entry.branch+"\n"+L.text("Choose the target branch. Git will merge in its checked-out worktree or switch this clean worktree to that branch.")
        let remove = NSButton(checkboxWithTitle:L.text("Remove the source worktree after merging"),target:nil,action:nil)
        remove.state = .on
        let accessory = NSView(frame:NSRect(x:0,y:0,width:370,height:62))
        Theme.pin(Theme.stack([targets,remove],orientation:.vertical,spacing:8),in:accessory)
        alert.accessoryView = accessory
        alert.addButton(withTitle:L.text("Finish Worktree")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn,let self,let target = targets.titleOfSelectedItem,
                  self.onCanRemoveWorktree?(entry.path) != false else { return }
            let removeSource = remove.state == .on
            self.performResult("Finishing Worktree…",{
                try repo.finishWorktree(entry,into:target,removeSource:removeSource)
            }) { [weak self] merge in
                if let merge { self?.showWorktreeConflicts(merge) }
            }
        }
    }

    private func showWorktreeConflicts(_ merge: GitWorktreeMerge) {
        performResult("Reading merge conflicts…",{ try merge.conflicts() }) { [weak self] conflicts in
            guard let self else { return }
            var options = conflicts.map { change in
                PickerOption(title:change.path,detail:L.text("Resolve Merge Conflict")) { [weak self] in
                    self?.resolveWorktreeConflict(change.path,merge:merge)
                }
            }
            if conflicts.isEmpty {
                options.append(PickerOption(title:L.text("Continue Merge"),detail:merge.targetBranch) { [weak self] in
                    guard let self,self.onCanRemoveWorktree?(merge.source.path) != false else { return }
                    self.perform("Finishing Worktree…") { try merge.complete() }
                })
            }
            options.append(PickerOption(title:L.text("Abort Merge"),detail:L.text("Keep the source worktree and undo this merge")) { [weak self] in
                guard let self,let window = self.window else { return }
                let alert = NSAlert(); alert.messageText = L.text("Abort Merge?")
                alert.informativeText = L.text("Edits made while resolving this merge may be discarded.")
                alert.addButton(withTitle:L.text("Abort Merge")); alert.addButton(withTitle:L.text("Cancel"))
                alert.beginSheetModal(for:window) { [weak self] response in
                    if response == .alertFirstButtonReturn { self?.perform("Aborting Merge…") { try merge.abort() } }
                    else { self?.showWorktreeConflicts(merge) }
                }
            })
            self.showGitPicker("Resolve Merge Conflicts",options)
        }
    }

    private func resolveWorktreeConflict(_ path: String,merge: GitWorktreeMerge) {
        let options = [
            PickerOption(title:L.text("Compare Conflict Versions"),detail:path) { [weak self] in
                self?.compareWorktreeConflict(path,merge:merge)
            },
            PickerOption(title:L.text("Use Current Side"),detail:merge.targetBranch) { [weak self] in
                self?.perform("Resolving Conflict…",onSuccess:{ [weak self] in self?.showWorktreeConflicts(merge) }) { try merge.resolve(path,useIncoming:false) }
            },
            PickerOption(title:L.text("Use Incoming Side"),detail:merge.source.branch) { [weak self] in
                self?.perform("Resolving Conflict…",onSuccess:{ [weak self] in self?.showWorktreeConflicts(merge) }) { try merge.resolve(path,useIncoming:true) }
            },
            PickerOption(title:L.text("Edit Conflict in Linvell"),detail:path) { [weak self] in
                self?.onOpenMergeFile?(merge.destination,path)
            },
            PickerOption(title:L.text("Mark Conflict Resolved"),detail:path) { [weak self] in
                self?.perform("Resolving Conflict…",onSuccess:{ [weak self] in self?.showWorktreeConflicts(merge) }) { try merge.markResolved(path) }
            }
        ]
        showGitPicker(path,options)
    }
    private func compareWorktreeConflict(_ path: String,merge: GitWorktreeMerge) {
        performResult("Reading merge conflicts…",{ try merge.versions(path) }) { [weak self] versions in
            guard let self,let window = self.window else { return }
            func column(_ branch: String,_ contents: String?) -> NSView {
                let scroll = NSTextView.scrollableTextView()
                if let text = scroll.documentView as? NSTextView {
                    text.isEditable = false; text.isRichText = false
                    text.font = Theme.editorFont
                    text.string = contents ?? L.text("File deleted on this side")
                }
                return Theme.stack([Theme.label(branch,size:12,weight:.semibold),scroll],orientation:.vertical,spacing:8)
            }
            let panes = ResizablePanes()
            panes.addArrangedSubview(column(merge.targetBranch,versions.current))
            panes.addArrangedSubview(column(merge.source.branch,versions.incoming))
            let accessory = NSView(frame:NSRect(x:0,y:0,width:650,height:300))
            Theme.pin(panes,in:accessory)
            let alert = NSAlert(); alert.messageText = L.text("Compare Conflict Versions")
            alert.informativeText = path; alert.accessoryView = accessory
            alert.addButton(withTitle:L.text("Use Current Side"))
            alert.addButton(withTitle:L.text("Use Incoming Side"))
            alert.addButton(withTitle:L.text("Back"))
            alert.beginSheetModal(for:window) { [weak self] response in
                guard let self else { return }
                if response == .alertFirstButtonReturn || response == .alertSecondButtonReturn {
                    self.perform("Resolving Conflict…",onSuccess:{ [weak self] in self?.showWorktreeConflicts(merge) }) {
                        try merge.resolve(path,useIncoming:response == .alertSecondButtonReturn)
                    }
                } else { self.resolveWorktreeConflict(path,merge:merge) }
            }
        }
    }

}
