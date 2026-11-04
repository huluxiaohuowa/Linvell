import AppKit
import LinvellCore

final class GitWorkspace: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private(set) var repository: GitRepository
    let workspaceDirectory: String
    let table = ResponsiveTableView(),diff = GitPatchTextView()
    let mode = NSSegmentedControl(labels:[L.text("Changes"),L.text("Commit Graph"),L.text("Submodules"),L.text("Git Operations")],trackingMode:.selectOne,target:nil,action:nil)
    let side = NSSegmentedControl(labels:[L.text("Working Tree"),L.text("Staged")],trackingMode:.selectOne,target:nil,action:nil)
    let message = NSTextField(),caption = Theme.label("",size:12,color:Theme.secondary)
    var changes: [GitChange] = [],commits: [GitCommit] = []
    var graph: [GitGraphRow] = []
    private var lastTimeRefresh = Date()
    private var pullControl: NSButton?,pushControl: NSButton?,manageWorktreesControl: NSButton?
    private var graphWidth = 1
    private var incomingCommits: Set<String> = [],outgoingCommits: Set<String> = []
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
    func shutdown() { autoFetchTimer?.invalidate(); repositoryRefresh?.invalidate(); repositoryRefresh = nil; actionsPage?.terminate() }
    let branchesTable = ResponsiveTableView()
    private let sidebarScope = NSSegmentedControl(labels:[L.text("Branches"),L.text("Worktrees")],trackingMode:.selectOne,target:nil,action:nil)
    private var location: WorkspaceSession {
        repository.remote.map { .ssh(host:$0.host,path:repository.directory) } ?? .local(path:repository.directory)
    }
    private var worktreesEnabled: Bool { GitRepositoryOrganization.showsWorktrees(location) }
    private var showsWorktrees: Bool { worktreesEnabled && sidebarScope.selectedSegment == 1 }
    private var branchNames: [String] = []
    private var currentBranch = ""
    var references: [GitReference] = []
    var worktrees: [GitWorktreeEntry] = []
    var gitPicker: QuickPicker?
    private var reviewPanel: GitReviewPanel?
    var onOpenMergeFile: ((GitRepository,String) -> Void)?
    var onOpenWorktree: ((String) -> Void)?
    var onNewTask: (() -> Void)?
    var onRepositories: (() -> Void)?
    var onWorktreeRelocated: ((String,String?) -> Void)?
    var onCanRemoveWorktree: ((String) -> Bool)?
    var onOpenTerminal: (() -> Void)?
    private let historySearch = NSSearchField()
    private let historyScope = NSSegmentedControl(labels:[L.text("Current Branch"),L.text("All References")],trackingMode:.selectOne,target:nil,action:nil)
    private var historyControls: NSStackView!
    private var moreHistory: NSButton!
    private var historyLimit = 150
    private var refreshingWorktreeStates = false
    private var preferencesObserver: NSObjectProtocol?
    private var repositoryRefresh: GitWorkspaceRefresh?
    private var isReloading = false
    private var reloadRequested = false
    private var worktreeDetails: [String:String] = [:]
    private var worktreeStates: [String:String] = [:]
    private var fetchFailure: String?
    private var failedOperation: UUID?
    private var fetchOperation: UUID?
    private var failureButton: NSButton!
    private var fetchMinutes: Int { max(1,UserDefaults.standard.object(forKey:autoFetchKey+".minutes") as? Int ?? UserDefaults.standard.object(forKey:"git.defaultFetchMinutes") as? Int ?? 5) }
    private var lastSuccessfulFetch: Date? {
        get { UserDefaults.standard.object(forKey:autoFetchKey+".lastSuccess") as? Date }
        set { UserDefaults.standard.set(newValue,forKey:autoFetchKey+".lastSuccess") }
    }
    let otherChanges = ResponsiveTableView()
    private let otherHeading = Theme.label("",size:11,weight:.semibold)
    private let changeLists = ResizablePanes()
    private var otherPane: NSView!
    private var landing: (paths: Set<String>,staged: Bool,until: Date)?
    private var oppositeChanges: [GitChange] {
        side.selectedSegment == 0 ? changes.filter(\.staged) : changes.filter(\.unstaged)
    }
    private var historyIndex = GitHistoryIndex()
    private let swapComparison = NSButton(title:L.text("Swap Commits"),target:nil,action:nil)
    private let inspectComparison = NSButton(title:L.text("Review Comparison…"),target:nil,action:nil)
    private let commitSummary = GitCommitSummaryView(frame:.zero)
    private var commitNavigation: [String] = []
    private var navigatedCommit: GitCommit?
    private var historySelectionOrder: [String] = []
    private var suppressHistorySelection = false
    private var showsWorkingHistoryEntry: Bool { mode.selectedSegment == 1 && historyQuery.isEmpty && !changes.isEmpty }
    private var historyOffset: Int { showsWorkingHistoryEntry ? 1 : 0 }
    private func historyKey(at row: Int) -> String? {
        if showsWorkingHistoryEntry && row == 0 { return ":working" }
        let index = row-historyOffset
        return displayedCommits.indices.contains(index) ? displayedCommits[index].hash : nil
    }
    private func historyRow(for key: String) -> Int? {
        if key == ":working" { return showsWorkingHistoryEntry ? 0 : nil }
        return displayedCommits.firstIndex(where:{ $0.hash == key }).map { $0+historyOffset }
    }
    private func selectedHistoryEndpoints() -> [GitReviewRevision] {
        historySelectionOrder.map { $0 == ":working" ? .workingTree : .commit($0) }
    }
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
    private var autoFetchKey: String { "git.autoFetch."+(repository.remote?.host ?? "local")+":"+workspaceDirectory }
    private var autoFetch: Bool { UserDefaults.standard.object(forKey:autoFetchKey) as? Bool ?? UserDefaults.standard.bool(forKey:"git.defaultAutoFetch") }
    private var visibleChanges: [GitChange] {
        side.selectedSegment == 1 ? changes.filter(\.staged) : changes.filter(\.unstaged)
    }
    private var stage: NSButton!
    private var unstage: NSButton!
    private var unstageAll: NSButton!
    private var stageAll: NSButton!
    private var commit: NSButton!
    private let favoriteSnippets = NSStackView()
    let stagedSummary = Theme.label("",size:12,color:Theme.secondary)
    private var cleanupPanel: GitWorktreeCleanupPanel?
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
    private var lineAction: NSButton!
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
        failureButton = button("Failed Command…",#selector(showFailedCommand))
        failureButton.isHidden = true
        pullControl = pull; pushControl = push
        let network = Theme.stack([caption,failureButton,NSView(),fetch,pull,push,tools],spacing:8)
        let menu = NSMenu(); menu.delegate = self; table.menu = menu
        let branchMenu = NSMenu(); branchMenu.delegate = self; branchesTable.menu = branchMenu
        favoriteSnippets.spacing = 6
        let snippetScroll = NSScrollView(); snippetScroll.hasHorizontalScroller = true; snippetScroll.drawsBackground = false
        snippetScroll.documentView = favoriteSnippets
        reloadQuickSnippets()
        let manage = button("Commit Snippets…",#selector(showCommitSnippets))
        let footer = Theme.stack([snippetScroll,manage,stagedSummary,commit],spacing:8)
        footer.heightAnchor.constraint(equalToConstant:36).isActive = true
        let commitBar = Theme.stack([message,footer],orientation:.vertical,spacing:6)
        changesControls = operations; commitControls = commitBar
        hunkAction = button("Stage Hunk",#selector(applySelectedHunk))
        lineAction = button("Stage Selected Lines",#selector(applySelectedLines))
        hunkControls = Theme.stack([hunkPicker,hunkAction,lineAction,NSView()],spacing:10); hunkControls.isHidden = true
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
        preview.verticalRulerView = GitDiffLineRuler(scroll:preview,editor:diff)
        preview.hasVerticalRuler = true; preview.rulersVisible = true
        unifiedPreview = preview
        Theme.pin(preview,in:diffHost); Theme.pin(splitDiff,in:diffHost)
        splitDiff.isHidden = true
        diffMode.selectedSegment = UserDefaults.standard.object(forKey:"git.diffMode") as? Int ?? 1
        diffMode.target = self; diffMode.action = #selector(changeDiffMode)
        diffHost.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self,selector:#selector(updateDiffMode),name:NSView.frameDidChangeNotification,object:diffHost)
        let wrap = button("Wrap Lines",#selector(toggleDiffWrapping))
        swapComparison.target = self; swapComparison.action = #selector(swapSelectedComparison); swapComparison.isHidden = true
        inspectComparison.target = self; inspectComparison.action = #selector(compareSelectedCommits); inspectComparison.isHidden = true
        let detailActions = Theme.stack([open,review,wrap,swapComparison,inspectComparison,NSView()],spacing:8)
        commitSummary.onNavigate = { [weak self] hash in self?.navigateToCommit(hash) }
        commitSummary.onBack = { [weak self] in self?.navigateBack() }
        let diffPage = Theme.stack([detailTitle,detailMetadata,commitSummary,diffMode,detailActions,diffHost],orientation:.vertical,spacing:8)
        let diffPane = NSView()
        Theme.pin(diffPage,in:diffPane,inset:10)
        let otherColumn = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("otherChanges"))
        otherChanges.addTableColumn(otherColumn); otherChanges.headerView = nil
        otherChanges.rowHeight = 58; otherChanges.dataSource = self; otherChanges.delegate = self
        otherChanges.target = self; otherChanges.action = #selector(activateOppositeChange)
        let otherScroll = ResponsiveScrollView(); otherScroll.documentView = otherChanges; otherScroll.hasVerticalScroller = true
        otherPane = NSView()
        Theme.pin(Theme.stack([otherHeading,otherScroll],orientation:.vertical,spacing:4),in:otherPane,inset:4)
        changeLists.isVertical = false; changeLists.firstMinimum = 85; changeLists.secondMinimum = 85
        changeLists.addArrangedSubview(list); changeLists.addArrangedSubview(otherPane)
        otherPane.isHidden = true
        split.position = 360; split.addArrangedSubview(changeLists); split.addArrangedSubview(diffPane)
        let navigation = Surface(Theme.panel)
        let repoName = Theme.label(project.lastPathComponent,size:14,weight:.semibold); repoName.lineBreakMode = .byTruncatingMiddle
        let branchColumn = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("branches")); branchColumn.width = 180; branchColumn.resizingMask = .autoresizingMask
        branchesTable.addTableColumn(branchColumn); branchesTable.headerView = nil; branchesTable.rowHeight = 30; branchesTable.dataSource = self; branchesTable.delegate = self
        branchesTable.backgroundColor = Theme.panel; branchesTable.autoresizingMask = [.width]
        branchesTable.target = self; branchesTable.doubleAction = #selector(activateSidebarRow)
        sidebarScope.selectedSegment = 0
        sidebarScope.target = self; sidebarScope.action = #selector(changeSidebarScope)
        let branchScroll = ResponsiveScrollView(); branchScroll.documentView = branchesTable; branchScroll.hasVerticalScroller = true; branchScroll.drawsBackground = false
        let manageWorktrees = button("Manage Worktrees…",#selector(browseWorktrees)); manageWorktreesControl = manageWorktrees; manageWorktrees.isHidden = !worktreesEnabled
        Theme.pin(Theme.stack([repoName,button("Repositories…",#selector(browseRepositories)),sidebarScope,branchScroll,manageWorktrees,branches],orientation:.vertical,spacing:12),in:navigation,inset:14)
        mainPage = split; Theme.pin(split,in:pages)
        let details = Theme.stack([bar,mode,network,operations,historyControls,hunkControls,pages,commitBar],orientation:.vertical,spacing:10)
        let content = NSView()
        Theme.pin(details,in:content,inset:10)
        let root = ResizablePanes(); root.firstMinimum = 150; root.secondMinimum = 540; root.position = 190
        root.addArrangedSubview(navigation); root.addArrangedSubview(content)
        Theme.pin(root,in:self,inset:16)
        for scroll in [list,branchScroll,otherScroll] {
            scroll.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self,selector:#selector(resizeTable(_:)),name:NSView.frameDidChangeNotification,object:scroll)
        }
        NotificationCenter.default.addObserver(self,selector:#selector(autoFetchFinished(_:)),name:GitAutoFetchScheduler.finished,object:nil)
        preferencesObserver = NotificationCenter.default.addObserver(forName:UserDefaults.didChangeNotification,object:nil,queue:.main) { [weak self] _ in
            guard let self else { return }
            self.sidebarScope.setEnabled(self.worktreesEnabled,forSegment:1)
            self.manageWorktreesControl?.isHidden = !self.worktreesEnabled
            if !self.worktreesEnabled { self.sidebarScope.selectedSegment = 0 }
            let mode = UserDefaults.standard.object(forKey:"git.diffMode") as? Int ?? 1
            let rerender = self.diff.font != Theme.editorFont
            self.diffMode.selectedSegment = mode
            self.updateDiffMode(); self.commitControls.isHidden = self.mode.selectedSegment != 0 || UserDefaults.standard.object(forKey:"git.showCommitMessageArea") as? Bool == false
            self.table.reloadData(); self.branchesTable.reloadData()
            if rerender { self.selectionChanged() }
        }
        sidebarScope.setEnabled(worktreesEnabled,forSegment:1)
        updateMode()
        changeSide()
        reload()
        autoFetchTimer = Timer.scheduledTimer(withTimeInterval:15,repeats:true) { [weak self] _ in
            guard let self,NSApp.isActive,self.window?.isVisible == true,!self.isHiddenOrHasHiddenAncestor else { return }
            self.refreshWorktreeStates()
            if self.mode.selectedSegment == 1,GitCommitTimeMode.current != .absolute,Date().timeIntervalSince(self.lastTimeRefresh) >= 60 {
                self.lastTimeRefresh = Date(); self.table.reloadData()
            }
        }
    }
    deinit { if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }; autoFetchTimer?.invalidate(); repositoryRefresh?.invalidate(); searchTask?.cancel() }
    func refreshExternalState() { repositoryRefresh?.check(force:true) }
    private func installRepositoryRefresh() {
        guard repositoryRefresh == nil else { return }
        repositoryRefresh = GitWorkspaceRefresh(repository:repository,isVisible:{ [weak self] in
            guard let self else { return false }
            return NSApp.isActive && self.window?.isVisible == true && !self.isHiddenOrHasHiddenAncestor && !self.running
        },changed:{ [weak self] in self?.reload() })
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func resizeTable(_ notification: Notification) {
        guard let scroll = notification.object as? NSScrollView,
              let list = scroll.documentView as? NSTableView,scroll.bounds.width > 0 else { return }
        let width = scroll.bounds.width
        list.setFrameSize(NSSize(width:width,height:list.frame.height))
        list.tableColumns.first?.width = width
    }
    @objc private func toggleDiffWrapping() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey:"git.wrapDiff"),forKey:"git.wrapDiff")
        updateDiffMode()
    }
    @objc private func changeDiffMode() {
        UserDefaults.standard.set(diffMode.selectedSegment,forKey:"git.diffMode")
        updateDiffMode()
    }
    @objc private func updateDiffMode() {
        let wrap = UserDefaults.standard.bool(forKey:"git.wrapDiff")
        diff.isHorizontallyResizable = !wrap
        diff.autoresizingMask = wrap ? .width : []
        diff.textContainer?.widthTracksTextView = wrap
        diff.textContainer?.containerSize = NSSize(width:wrap ? max(1,unifiedPreview.contentSize.width-32) : 100000,height:CGFloat.greatestFiniteMagnitude)
        if wrap { diff.setFrameSize(NSSize(width:unifiedPreview.contentSize.width,height:diff.frame.height)) }
        unifiedPreview.hasHorizontalScroller = !wrap
        splitDiff.setWrap(wrap)
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
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === otherChanges ? oppositeChanges.count : tableView === branchesTable ? (showsWorktrees ? worktrees.count : branchNames.count) : mode.selectedSegment == 0 ? fileRows.count : mode.selectedSegment == 1 ? displayedCommits.count+historyOffset : 0 }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        if tableView === otherChanges {
            guard oppositeChanges.indices.contains(row) else { return nil }
            return GitFileCell(change:oppositeChanges[row],staged:side.selectedSegment == 0)
        }
        if tableView === branchesTable {
            let name: String,active: Bool,symbol: String,detail: String
            if showsWorktrees {
                guard worktrees.indices.contains(row) else { return nil }
                let entry = worktrees[row]
                name = entry.branch.isEmpty ? URL(fileURLWithPath:entry.path).lastPathComponent : entry.branch
                active = entry.path == repository.directory
                let state = worktreeStates[entry.path]
                symbol = state == "Conflicts" ? "⚠  " : state == "In Progress" ? "↻  " : state == "Uncommitted Changes" ? "●  " : state == "Merged" ? "✓  " : entry.locked ? "⌑  " : "▱  "
                detail = [entry.path,state.map(L.text),worktreeDetails[entry.path]].compactMap { $0 }.joined(separator:" · ")
            } else {
                guard branchNames.indices.contains(row) else { return nil }
                name = branchNames[row]; active = name == currentBranch; symbol = "⑂  "; detail = name
            }
            let label = Theme.label((active && !showsWorktrees ? "✓  " : symbol)+name,size:12,color:active ? Theme.accent : Theme.foreground,weight:active ? .semibold : .regular)
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
            if showsWorkingHistoryEntry,row == 0 {
                return Theme.stack([Theme.label("Uncommitted Changes",size:13,weight:.semibold),Theme.label(L.format("%d changed files",changes.count),size:11,color:Theme.secondary)],orientation:.vertical,spacing:3)
            }
            let rows = displayedCommits,index = row-historyOffset
            guard rows.indices.contains(index) else { return nil }
            return GitHistoryCell(commit:rows[index],row:historyQuery.isEmpty && !UserDefaults.standard.bool(forKey:"git.hideCommitGraph") ? graph[index] : nil,lanes:graphWidth,incoming:incomingCommits.contains(rows[index].hash),outgoing:outgoingCommits.contains(rows[index].hash))
        }
    }
    func tableView(_ tableView: NSTableView,heightOfRow row: Int) -> CGFloat {
        if tableView === branchesTable { return 30 }
        if tableView === otherChanges { return 58 }
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
        if notification.object as? NSTableView === table {
            guard !suppressHistorySelection else { return }
            navigatedCommit = nil; commitNavigation = []
            if mode.selectedSegment == 1 {
                let keys = table.selectedRowIndexes.compactMap { historyKey(at:$0) }
                historySelectionOrder = historySelectionOrder.filter(keys.contains)+keys.filter { !historySelectionOrder.contains($0) }
                if historySelectionOrder.count > 2 {
                    historySelectionOrder = [historySelectionOrder[0],historySelectionOrder.last!]
                    suppressHistorySelection = true
                    table.selectRowIndexes(IndexSet(historySelectionOrder.compactMap(historyRow)),byExtendingSelection:false)
                    suppressHistorySelection = false
                }
            } else { historySelectionOrder = [] }
            selectionChanged()
        }
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
    @objc private func activateOppositeChange() {
        let row = otherChanges.clickedRow
        guard !busy,oppositeChanges.indices.contains(row) else { return }
        let path = oppositeChanges[row].path
        side.selectedSegment = 1-side.selectedSegment
        changeSide()
        reloadRows(path:path)
    }

    private func reloadRows(preferredRow: Int = 0,path: String? = nil,hash: String? = nil) {
        let fileQuery = fileSearch.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let files = visibleChanges.filter { fileQuery.isEmpty || $0.path.localizedStandardContains(fileQuery) || $0.originalPath?.localizedStandardContains(fileQuery) == true }
        fileGroups = [:]
        if groupFiles {
            let groups = Dictionary(grouping:files) { ($0.path as NSString).deletingLastPathComponent }
            var children: [String:Set<String>] = [:]
            for folder in groups.keys {
                var path = folder
                while !path.isEmpty {
                    let parent = (path as NSString).deletingLastPathComponent
                    children[parent,default:[]].insert(path)
                    path = parent
                }
            }
            fileRows = []
            func appendFolder(_ path: String) {
                if !path.isEmpty {
                    fileGroups[fileRows.count] = path
                    fileRows.append(nil)
                    if collapsedFolders.contains(path),fileQuery.isEmpty { return }
                }
                for child in (children[path] ?? []).sorted(by:{ $0.localizedStandardCompare($1) == .orderedAscending }) {
                    appendFolder(child)
                }
                fileRows += (groups[path] ?? []).map(Optional.some)
            }
            appendFolder("")
        } else {
            fileRows = files.map(Optional.some)
        }
        otherHeading.stringValue = L.text(side.selectedSegment == 0 ? "Staged" : "Working Tree")
        otherPane.isHidden = mode.selectedSegment != 0 || oppositeChanges.isEmpty
        otherChanges.reloadData(); otherChanges.deselectAll(nil)
        if let landing,landing.until > Date(),landing.staged == (side.selectedSegment == 0) {
            let indices = IndexSet(oppositeChanges.enumerated().filter { landing.paths.contains($0.element.path) }.map(\.offset))
            otherChanges.selectRowIndexes(indices,byExtendingSelection:false)
            if let first = indices.first { otherChanges.scrollRowToVisible(first) }
        }
        changeLists.needsLayout = true
        let historySelection = historySelectionOrder
        suppressHistorySelection = true
        defer { suppressHistorySelection = false }
        table.reloadData()
        table.noteHeightOfRows(withIndexesChanged:IndexSet(integersIn:0..<table.numberOfRows))
        let count = numberOfRows(in:table)
        if count > 0 {
            let matching = path.flatMap { path in fileRows.firstIndex { $0?.path == path } }
                ?? hash.flatMap { historyRow(for:$0) }
            let fallback = preferredRow < 0 && mode.selectedSegment == 0 ? fileRows.firstIndex(where:{ $0 != nil }) ?? 0 : preferredRow
            let retained = mode.selectedSegment == 1 ? historySelection.compactMap(historyRow) : []
            if !retained.isEmpty { table.selectRowIndexes(IndexSet(retained),byExtendingSelection:false) }
            else { table.selectRowIndexes(IndexSet(integer:min(max(0,matching ?? fallback),count-1)),byExtendingSelection:false) }
            if mode.selectedSegment == 1 {
                historySelectionOrder = historySelection.filter { historyRow(for:$0) != nil }
                if historySelectionOrder.isEmpty,let key = historyKey(at:table.selectedRow) { historySelectionOrder = [key] }
            }
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
        let repo = repository,request = searchGeneration,index = historyIndex
        searchTask = Task { [weak self] in
            if reset { try? await Task.sleep(nanoseconds:220_000_000) }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority:.userInitiated) {
                Result { try repo.searchHistory(query,offset:offset,index:index,isCancelled:{ Task.isCancelled }) }
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
        changesControls.isHidden = mode.selectedSegment != 0; commitControls.isHidden = mode.selectedSegment != 0 || UserDefaults.standard.object(forKey:"git.showCommitMessageArea") as? Bool == false; hunkControls.isHidden = true
        pages.subviews.forEach { $0.removeFromSuperview() }
        if mode.selectedSegment == 3 {
            if let actionsPage,actionsPage.repository.directory != repository.directory,!actionsPage.running { self.actionsPage = nil }
            if actionsPage == nil {
                let page = GitActionsView(repository:repository); page.onChange = { [weak self] in self?.reload() }
                page.onWorktreeManagement = { [weak self] in self?.browseWorktrees() }
                page.onFetchSuccess = { [weak self] in guard let self else { return }; GitAutoFetchScheduler.shared.recordSuccess(self.location) }
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
        refreshWorktreeStates()
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
            if worktreesEnabled,let tree = worktrees.first(where:{ $0.branch == name && $0.path != repo.directory && !$0.prunable }) {
                onOpenWorktree?(tree.path); return
            }
            perform("Switching branch…") { _ = try repo.run(["switch",name]) }
        }
    }
    private func perform(_ title: String,onSuccess: (() -> Void)? = nil,_ work: @escaping () throws -> Void) {
        performResult(title,work) { _ in onSuccess?() }
    }
    func performResult<T>(_ title: String,operation: UUID = UUID(),_ work: @escaping () throws -> T,completion: @escaping (T) -> Void) {
        guard !busy else { return }; busy = true; refreshGeneration = UUID(); caption.stringValue = L.text(title)
        failedOperation = nil
        failureButton.isHidden = true
        actions.forEach { $0.isEnabled = false }; mode.isEnabled = false; side.isEnabled = false; branchesTable.isEnabled = false
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try GitCommandJournal.$operation.withValue(operation,operation:work) }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false
                self.actions.forEach { $0.isEnabled = true }; self.mode.isEnabled = true; self.side.isEnabled = true; self.branchesTable.isEnabled = true
                self.updateActionAvailability()
                switch result {
                case .failure(let error):
                    self.caption.stringValue = L.text(error.localizedDescription)
                    self.failedOperation = operation
                    self.failureButton.isHidden = false
                case .success(let value): completion(value); self.reload()
                }
            }
        }
    }
    @objc func reload() {
        guard !busy else { reloadRequested = true; return }
        guard !isReloading else { reloadRequested = true; return }
        isReloading = true
        let request = UUID(); refreshGeneration = request; let repo = repository
        let allRefs = historyScope.selectedSegment == 1,limit = historyLimit
        caption.stringValue = L.text("Reading repository…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { () throws -> ([GitChange],[GitCommit],String,[GitReference],[GitWorktreeEntry],GitRepository,Set<String>,Set<String>,[Int],GitDiffStat) in
                let repo = try repo.resolvedWorkingTree()
                let changes = try repo.changes()
                let commits = (try? repo.history(allRefs:allRefs,limit:limit,includeMessage:true)) ?? []
                let branch = (try? repo.run(["branch","--show-current"]))?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
                let refOutput = (try? repo.run(["for-each-ref","--format=%(refname)","refs/heads/","refs/remotes/","refs/tags/"])) ?? ""
                let refs = refOutput.split(whereSeparator:\.isNewline).map { GitReference(fullName:String($0)) }
                let worktrees = (try? repo.worktrees()) ?? []
                let incoming = Set(((try? repo.run(["rev-list","--max-count=10000","HEAD..@{upstream}","--"])) ?? "").split(whereSeparator:\.isNewline).map(String.init))
                let outgoing = Set(((try? repo.run(["rev-list","--max-count=10000","@{upstream}..HEAD","--"])) ?? "").split(whereSeparator:\.isNewline).map(String.init))
                let counts = ((try? repo.run(["rev-list","--left-right","--count","HEAD...@{upstream}","--"])) ?? "").split(whereSeparator:\.isWhitespace).compactMap { Int($0) }
                return (changes,commits,branch,refs,worktrees,repo,incoming,outgoing,counts,try repo.stagedStat())
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReloading = false
                defer {
                    if self.reloadRequested && !self.busy { self.reloadRequested = false; self.reload() }
                }
                guard self.refreshGeneration == request else { return }
                switch result {
                case .success(let (changes,commits,branch,refs,worktrees,repo,incoming,outgoing,counts,stat)):
                    let oldRow = self.table.selectedRow
                    let path = self.selectedChange?.path
                    let hash = self.selectedCommit?.hash
                    self.repository = repo
                    self.installRepositoryRefresh()
                    self.stagedSummary.stringValue = L.format("%d files · +%d · −%d",stat.files,stat.insertions,stat.deletions)+(stat.binaryFiles > 0 ? " · "+L.format("%d binary",stat.binaryFiles) : "")
                    self.incomingCommits = incoming; self.outgoingCommits = outgoing
                    self.pullControl?.title = L.text("Pull")+(counts.count == 2 ? " ↓"+String(counts[1]) : "")
                    self.pushControl?.title = L.text("Push")+(counts.count == 2 ? " ↑"+String(counts[0]) : "")
                    self.historyIndex = GitHistoryIndex()
                    self.changes = changes; self.commits = commits; self.graph = GitGraph.layout(commits)
                    self.graphWidth = self.graph.map(\.width).max() ?? 1
                    self.currentBranch = branch; self.references = refs; self.worktrees = worktrees
                    GitRepositoryOrganization.registerWorktreeFamily(worktrees,location:self.location)
                    self.branchNames = refs.filter { $0.category == "Local Branches" }.map(\.name)
                    self.refreshWorktreeStates()
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
        table.allowsMultipleSelection = history
        let change = selectedChange,commit = selectedCommit,hash = commit?.hash
        diff.string = ""; detailMetadata.stringValue = ""; commitSummary.isHidden = true
        if !splitDiff.isHidden { splitDiff.render(NSAttributedString()) }
        updateDiffMode()
        let endpoints = history ? selectedHistoryEndpoints() : []
        swapComparison.isHidden = endpoints.count != 2; inspectComparison.isHidden = endpoints.count != 2
        let workingSelected = history && endpoints.count == 1 && historySelectionOrder.first == ":working"
        if history,endpoints.count == 2 {
            renderSelectedComparison(endpoints[0],endpoints[1]); return
        }
        guard change != nil || hash != nil || workingSelected else {
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
        if workingSelected { detailTitle.stringValue = L.text("Uncommitted Changes") }
        else if let commit {
            commitSummary.render(commit,mergedIn:nil,canGoBack:!commitNavigation.isEmpty)
            DispatchQueue.global(qos:.utility).async { [weak self] in
                let merged = try? repo.introducingMerge(commit.hash)
                DispatchQueue.main.async {
                    guard let self,self.generation == request else { return }
                    self.commitSummary.render(commit,mergedIn:merged,canGoBack:!self.commitNavigation.isEmpty)
                }
            }
            detailTitle.stringValue = commit.subject
            detailMetadata.stringValue = String(commit.hash.prefix(12))+" · "+commit.author+" · "+String(commit.date.prefix(10))+" · "+commit.refs
        } else if let change {
            detailTitle.stringValue = URL(fileURLWithPath:change.path).lastPathComponent
            detailMetadata.stringValue = L.text(staged ? "Staged" : "Working Tree")+" · "+change.path
        }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result {
                if workingSelected { return try repo.uncommittedPatch() }
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
                self.hunks = !history && change?.conflicted == false ? GitHunk.parse(text) : []
                self.hunkPicker.removeAllItems(); self.hunkPicker.addItems(withTitles:self.hunks.enumerated().map { L.format("Hunk %d",$0.offset+1)+" · "+$0.element.header })
                self.hunkControls.isHidden = self.hunks.isEmpty
                self.hunkAction.title = L.text(staged ? "Unstage Hunk" : "Stage Hunk")
                self.lineAction.title = L.text(staged ? "Unstage Selected Lines" : "Stage Selected Lines")
                let rendered = GitDiffRendering.styled(text,path:change?.path)
                self.diff.textStorage?.setAttributedString(rendered)
                self.unifiedPreview.verticalRulerView?.needsDisplay = true
                if !self.splitDiff.isHidden { self.splitDiff.render(rendered) }
                if case .success = result { self.reviewChange = change }
                self.diff.apply = self.hunks.isEmpty ? nil : { [weak self] patch in
                    guard let self,let change else { return }
                    self.perform(staged ? "Unstaging…" : "Staging…",onSuccess:{ [weak self] in self?.markLanding([change.path],staged:!staged) }) {
                        if let patch { try repo.applyHunk(patch,unstage:false) }
                        else if staged { try repo.unstage(change) } else { try repo.stage(change) }
                    }
                }
                self.diff.unstaging = staged
                self.reviewStaged = staged; self.updateActionAvailability()
                self.diff.minSize = self.diff.enclosingScrollView?.contentSize ?? .zero
                self.diff.sizeToFit(); self.diff.scrollRangeToVisible(NSRange(location:0,length:0))
            }
        }
    }
    func navigateToCommit(_ hash: String,remember: Bool = true) {
        let repo = repository,request = UUID(); generation = request
        let previous = selectedCommit?.hash
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try repo.commitDetails(hash) }
            DispatchQueue.main.async {
                guard let self,self.generation == request else { return }
                switch result {
                case .success(let commit):
                    if remember,let previous,previous != commit.hash { self.commitNavigation.append(previous) }
                    self.navigatedCommit = commit; self.historySelectionOrder = [commit.hash]
                    self.mode.selectedSegment = 1; self.updateMode(); self.selectionChanged()
                case .failure(let error): self.caption.stringValue = error.localizedDescription
                }
            }
        }
    }
    private func navigateBack() {
        guard let hash = commitNavigation.popLast() else { return }
        navigateToCommit(hash,remember:false)
    }
    private func endpointName(_ value: GitReviewRevision) -> String {
        switch value { case .workingTree: return L.text("Working Tree"); case .commit(let hash): return String(hash.prefix(12)) }
    }
    private func renderSelectedComparison(_ base: GitReviewRevision,_ target: GitReviewRevision) {
        let request = generation,repo = repository
        detailTitle.stringValue = endpointName(base)+" → "+endpointName(target)
        commitSummary.isHidden = true
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { () throws -> (String,GitDiffStat) in
                let paths = try repo.comparisonPaths(base:base,target:target)
                return (try paths.map { try repo.comparisonPatch(base:base,target:target,path:$0) }.joined(separator:"\n"),try repo.comparisonStat(base:base,target:target))
            }
            DispatchQueue.main.async {
                guard let self,self.generation == request else { return }
                switch result {
                case .success(let (patch,stat)):
                    self.detailMetadata.stringValue = L.format("%d files · +%d · −%d",stat.files,stat.insertions,stat.deletions)
                    let value = GitDiffRendering.styled(patch)
                    self.diff.textStorage?.setAttributedString(value); self.splitDiff.render(value)
                    self.diff.enclosingScrollView?.verticalRulerView?.needsDisplay = true
                case .failure(let error): self.diff.string = error.localizedDescription
                }
            }
        }
    }

    private var selectedChange: GitChange? {
        guard mode.selectedSegment == 0 else { return nil }
        return fileRows.indices.contains(table.selectedRow) ? fileRows[table.selectedRow] : nil
    }
    private var selectedCommit: GitCommit? {
        if let navigatedCommit { return navigatedCommit }
        let rows = displayedCommits,index = table.selectedRow-historyOffset
        guard mode.selectedSegment == 1,rows.indices.contains(index) else { return nil }
        return rows[index]
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
    @objc private func applySelectedLines() {
        let range: NSRange? = splitDiff.isHidden ? diff.selectedRange() : splitDiff.sourceSelection()
        guard let range else { return }
        do {
            let patch = try GitHunk.selection(in:diff.string,range:range,unstage:side.selectedSegment == 1)
            let repo = repository
            perform("Updating index…",onSuccess:{ [weak self] in if let path = self?.selectedChange?.path { self?.markLanding([path],staged:self?.side.selectedSegment == 0) } }) { try repo.applyHunk(patch,unstage:false) }
        } catch { if let window { NSAlert(error:error).beginSheetModal(for:window) } }
    }

    @objc private func applySelectedHunk() {
        guard hunks.indices.contains(hunkPicker.indexOfSelectedItem) else { return }
        let hunk = hunks[hunkPicker.indexOfSelectedItem],repo = repository,unstage = side.selectedSegment == 1
        perform(unstage ? "Unstaging…" : "Staging…",onSuccess:{ [weak self] in if let path = self?.selectedChange?.path { self?.markLanding([path],staged:!unstage) } }) { try repo.applyHunk(hunk,unstage:unstage) }
    }
    private func markLanding(_ paths: [String],staged: Bool) {
        landing = (Set(paths),staged,Date().addingTimeInterval(2))
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { [weak self] in
            guard let self,let landing = self.landing,landing.until <= Date() else { return }
            self.landing = nil; self.otherChanges.deselectAll(nil)
        }
    }
    @objc private func stageSelected() {
        guard let change = selectedChange else { return }; let repo = repository
        perform("Staging…",onSuccess:{ [weak self] in self?.markLanding([change.path],staged:true) }) { try repo.stage(change) }
    }
    @objc private func unstageSelected() {
        guard let change = selectedChange else { return }; let repo = repository
        perform("Unstaging…",onSuccess:{ [weak self] in self?.markLanding([change.path],staged:false) }) { try repo.unstage(change) }
    }
    @objc private func openSelected() { if let change = selectedChange { onOpen?(repository.root.appendingPathComponent(change.path)) } }
    @objc private func unstageAllChanges() {
        guard unstageAll.isEnabled else { return }
        let repo = repository
        perform("Unstaging…",onSuccess:{ [weak self] in guard let self else { return }; self.markLanding(self.changes.filter(\.staged).map(\.path),staged:false) }) { try repo.unstageAll() }
    }
    @objc private func stageAllChanges() {
        guard stageAll.isEnabled else { return }
        let repo = repository
        perform("Staging…",onSuccess:{ [weak self] in guard let self else { return }; self.markLanding(self.changes.filter(\.unstaged).map(\.path),staged:true) }) { _ = try repo.run(["add","--all"]) }
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
    @objc private func showFailedCommand() { showGitLog(failuresOnly:true,operation:failedOperation) }

    @objc private func swapSelectedComparison() {
        guard historySelectionOrder.count == 2 else { return }
        historySelectionOrder.reverse(); selectionChanged()
    }
    @objc func compareSelectedCommits() {
        let endpoints = selectedHistoryEndpoints()
        guard endpoints.count == 2 else { return }
        openComparison(endpoints[0],endpoints[1])
    }

    func openComparison(_ base: String,_ target: String) {
        openComparison(.commit(base),.commit(target))
    }
    func openComparison(_ base: GitReviewRevision,_ target: GitReviewRevision) {
        let repo = repository
        performResult("Reading repository…",{
            func pinned(_ value: GitReviewRevision) throws -> GitReviewRevision {
                switch value { case .commit(let ref): return .commit(try repo.resolvedRevision(ref)); case .workingTree: return .workingTree }
            }
            let base = try pinned(base),target = try pinned(target)
            return (base,target,try repo.comparisonPaths(base:base,target:target),try repo.comparisonStat(base:base,target:target))
        }) { [weak self] base,target,paths,stat in
            guard let self else { return }
            let files = paths.map { path in
                GitReviewPanel.File(path:path,patch:{ try repo.comparisonPatch(base:base,target:target,path:path) },images:{ try repo.comparisonImages(base:base,target:target,path:path) })
            }
            let context = GitReviewPanel.Context(title:L.text("Compare Revisions"),base:self.endpointName(base),target:self.endpointName(target),statistics:L.format("%d files · +%d · −%d",stat.files,stat.insertions,stat.deletions),statisticsProvider:{
                let latest = try repo.comparisonStat(base:base,target:target)
                return L.format("%d files · +%d · −%d",latest.files,latest.insertions,latest.deletions)
            },onSwap:{ [weak self] in self?.openComparison(target,base) })
            let loader: (() throws -> [GitReviewPanel.File])? = base == .workingTree || target == .workingTree ? {
                try repo.comparisonPaths(base:base,target:target).map { path in
                    GitReviewPanel.File(path:path,patch:{ try repo.comparisonPatch(base:base,target:target,path:path) },images:{ try repo.comparisonImages(base:base,target:target,path:path) })
                }
            } : nil
            self.openReview(files,context:context,reloadFiles:loader)
        }
    }

    func canPerformMenuAction(_ action: String) -> Bool {
        switch action {
        case "commitGitChanges": return commit.isEnabled
        case "stageGitChanges": return stageAll.isEnabled
        case "unstageGitChanges": return unstageAll.isEnabled
        case "stageGitFile": return stage.isEnabled
        case "unstageGitFile": return unstage.isEnabled
        case "checkoutGitCommit","revertGitCommit","copyGitCommit": return mode.selectedSegment == 1 && selectedHistoryEndpoints().count == 1 && selectedCommit != nil
        case "compareGitCommits": return mode.selectedSegment == 1 && selectedHistoryEndpoints().count == 2
        case "createGitWorktree","finishGitWorktree": return worktreesEnabled && !worktrees.isEmpty
        case "showGitInFinder": return repository.remote == nil
        case "expandGitDirectories","collapseGitDirectories": return mode.selectedSegment == 0 && groupFiles
        case "renameGitBranch": return !currentBranch.isEmpty
        case "amendGitCommit": return !commits.isEmpty
        default: return !running
        }
    }
    func showChangesFromMenu() { mode.selectedSegment = 0; modeChanged() }
    func openTerminalFromMenu() { onOpenTerminal?() }
    func showInFinderFromMenu() { guard repository.remote == nil else { return }; NSWorkspace.shared.activateFileViewerSelecting([repository.root]) }
    func expandDirectoriesFromMenu(_ expanded: Bool) {
        guard mode.selectedSegment == 0,groupFiles else { return }
        let path = selectedChange?.path
        if expanded { collapsedFolders.removeAll() }
        else {
            for change in visibleChanges {
                var folder = (change.path as NSString).deletingLastPathComponent
                while !folder.isEmpty { collapsedFolders.insert(folder); folder = (folder as NSString).deletingLastPathComponent }
            }
        }
        reloadRows(path:path)
    }
    func newBranchFromMenu() { openOperation("Create Branch") }
    func newTagFromMenu() { openOperation("Create Tag") }
    func stashFromMenu() { openOperation("Stash Changes") }
    func stashesFromMenu() { browseStashes() }
    func renameBranchFromMenu() { openOperation("Rename Selected Branch",values:["Branch":currentBranch]) }
    func mergeBranchFromMenu() { openOperation("Merge") }
    func amendFromMenu() { amendLastCommit() }
    func checkoutCommitFromMenu() { if let commit = selectedCommit { openOperation("Checkout Commit",values:["Revision":commit.hash]) } }
    func revertCommitFromMenu() { if let commit = selectedCommit { openOperation("Revert Commit",values:["Revision":commit.hash]) } }
    func copyCommitFromMenu() {
        guard let commit = selectedCommit else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.hash,forType:.string)
    }
    func newWorktreeFromMenu() {
        guard worktreesEnabled,let window else { return }
        GitWorktreePanels.create(repository:repository,owner:window) { [weak self] path in self?.reload(); self?.onOpenWorktree?(path) }
    }
    func finishWorktreeFromMenu() {
        guard worktreesEnabled else { return }
        if let current = worktrees.dropFirst().first(where:{ $0.path == repository.directory && !$0.prunable && !$0.branch.isEmpty }) { finishWorktree(current); return }
        showGitPicker("Finish Worktree…",worktrees.dropFirst().filter { !$0.prunable && !$0.branch.isEmpty }.map { entry in
            PickerOption(title:entry.branch,detail:entry.path) { [weak self] in self?.finishWorktree(entry) }
        })
    }
    func shortcutsFromMenu() {
        let menu = NSApp.mainMenu?.items.first { $0.title == L.text("Git") }?.submenu
        let lines = (menu?.items ?? []).filter { !$0.keyEquivalent.isEmpty }.map { item in
            let mask = item.keyEquivalentModifierMask
            let symbols = (mask.contains(.control) ? "⌃" : "")+(mask.contains(.option) ? "⌥" : "")+(mask.contains(.shift) ? "⇧" : "")+(mask.contains(.command) ? "⌘" : "")
            let key = ["\r":"↩","\u{f703}":"→","\u{f702}":"←"][item.keyEquivalent] ?? item.keyEquivalent.uppercased()
            return symbols+key+"   "+item.title
        }
        showGitText("Git Keyboard Shortcuts",text:(lines+["⌘F   "+L.text("Search repository history"),"⌥→ / ⌥←   "+L.text("Expand / collapse review diffs")]).joined(separator:"\n"))
    }
    func commitFromMenu() { commitStaged() }
    func stageAllFromMenu() { stageAllChanges() }
    func unstageAllFromMenu() { unstageAllChanges() }
    func stageFromMenu() { stageSelected() }
    func unstageFromMenu() { unstageSelected() }
    func pullFromMenu() { pull() }
    func pushFromMenu() { push() }
    func showBranchesFromMenu() { browseReferences() }

    func openRepositoryReview() { browseTrackedFiles() }
    func openChangesReview() { browseWorkingChanges() }
    func openGitJournal() { showGitLog() }
    func fetchRepository() { fetch() }

    @objc private func showDiffSettings() { if let window { _ = GitDiffSettingsPanel(owner:window.attachedSheet ?? window) } }
    @objc func showRepositorySettings() { if let window { GitRepositorySettingsPanel.show(owner:window.attachedSheet ?? window) } }
    @objc func showGitSettings() {
        guard let window else { return }
        let defaults = UserDefaults.standard
        let repositorySettings = Theme.actionButton("Repository Settings…",target:self,action:#selector(showRepositorySettings))
        let diffSettings = Theme.actionButton("Diff Appearance…",target:self,action:#selector(showDiffSettings))
        let showMessage = NSButton(checkboxWithTitle:L.text("Show Commit Message Area"),target:nil,action:nil)
        showMessage.state = defaults.object(forKey:"git.showCommitMessageArea") as? Bool == false ? .off : .on
        let defaultFetch = NSButton(checkboxWithTitle:L.text("Auto Fetch by Default"),target:nil,action:nil)
        defaultFetch.state = defaults.bool(forKey:"git.defaultAutoFetch") ? .on : .off
        let worktreeStatus = NSButton(checkboxWithTitle:L.text("Show Worktree Status in Sidebar"),target:nil,action:nil)
        worktreeStatus.state = defaults.object(forKey:"git.showWorktreeStatus") as? Bool == false ? .off : .on
        let defaultMinutes = NSTextField(string:String(defaults.object(forKey:"git.defaultFetchMinutes") as? Int ?? 5))
        let graph = NSButton(checkboxWithTitle:L.text("Show Commit Graph"),target:nil,action:nil)
        let relative = Theme.choiceButton()
        relative.addItems(withTitles:GitCommitTimeMode.allCases.map { L.text($0.rawValue.capitalized) })
        relative.selectItem(at:GitCommitTimeMode.allCases.firstIndex(of:GitCommitTimeMode.current) ?? 2)
        let expand = NSButton(checkboxWithTitle:L.text("Expand Review Diffs by Default"),target:nil,action:nil)
        let fetch = Theme.choiceButton()
        fetch.addItems(withTitles:[L.text("Use Default"),L.text("Off"),L.text("On")])
        fetch.selectItem(at:defaults.object(forKey:autoFetchKey) == nil ? 0 : autoFetch ? 2 : 1)
        let defaultInterval = NSButton(checkboxWithTitle:L.text("Use Default Interval"),target:nil,action:nil)
        defaultInterval.state = defaults.object(forKey:autoFetchKey+".minutes") == nil ? .on : .off
        graph.state = defaults.bool(forKey:"git.hideCommitGraph") ? .off : .on
        expand.state = defaults.bool(forKey:"git.expandReviewDiffs") ? .on : .off
        let minutes = NSTextField(string:String(fetchMinutes))
        let last = lastSuccessfulFetch.map { DateFormatter.localizedString(from:$0,dateStyle:.medium,timeStyle:.short) } ?? L.text("Never")
        let editor = NSTextField(string:defaults.string(forKey:"git.externalEditor") ?? "")
        let terminal = NSTextField(string:defaults.string(forKey:"git.externalTerminal") ?? "")
        editor.placeholderString = "/Applications/Editor.app"
        terminal.placeholderString = "/Applications/Terminal.app"
        let accessory = NSView(frame:NSRect(x:0,y:0,width:470,height:440))
        Theme.pin(Theme.stack([Theme.stack([repositorySettings,diffSettings]),graph,showMessage,worktreeStatus,Theme.stack([Theme.label("Commit Time"),relative]),expand,Theme.stack([Theme.label("Auto Fetch"),fetch]),defaultFetch,
                              Theme.stack([Theme.label("Fetch interval in minutes"),minutes,defaultInterval]),
                              Theme.stack([Theme.label("Default fetch interval in minutes"),defaultMinutes]),
                              Theme.label(L.text("Last successful Fetch")+" · "+last),
                              Theme.stack([Theme.label("External editor"),editor]),
                              Theme.stack([Theme.label("External terminal"),terminal])],
                             orientation:.vertical,spacing:6),in:accessory)
        let alert = NSAlert(); alert.window.appearance = NSAppearance(named:Theme.isDark ? .darkAqua : .aqua); alert.messageText = L.text("Git Settings…"); alert.accessoryView = accessory
        alert.addButton(withTitle:L.text("Save")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn,let self else { return }
            defaults.set(showMessage.state == .on,forKey:"git.showCommitMessageArea")
            self.commitControls.isHidden = self.mode.selectedSegment != 0 || showMessage.state == .off
            defaults.set(defaultFetch.state == .on,forKey:"git.defaultAutoFetch")
            defaults.set(worktreeStatus.state == .on,forKey:"git.showWorktreeStatus")
            defaults.set(min(1440,max(1,defaultMinutes.integerValue)),forKey:"git.defaultFetchMinutes")
            defaults.set(graph.state == .off,forKey:"git.hideCommitGraph")
            defaults.set(GitCommitTimeMode.allCases[max(0,relative.indexOfSelectedItem)].rawValue,forKey:"git.commitTimeMode")
            defaults.set(expand.state == .on,forKey:"git.expandReviewDiffs")
            if fetch.indexOfSelectedItem == 0 { defaults.removeObject(forKey:self.autoFetchKey) }
            else { defaults.set(fetch.indexOfSelectedItem == 2,forKey:self.autoFetchKey) }
            if defaultInterval.state == .on { defaults.removeObject(forKey:self.autoFetchKey+".minutes") }
            else { defaults.set(min(1440,max(1,minutes.integerValue)),forKey:self.autoFetchKey+".minutes") }
            defaults.set(editor.stringValue,forKey:"git.externalEditor")
            defaults.set(terminal.stringValue,forKey:"git.externalTerminal")
            self.table.reloadData()
        }
    }

    private func openExternal(key: String) {
        guard repository.remote == nil else {
            caption.stringValue = L.text("External applications require a local checkout.")
            return
        }
        guard let path = UserDefaults.standard.string(forKey:key),!path.isEmpty else { showGitSettings(); return }
        let target = key == "git.externalEditor" ? selectedChange.map { repository.root.appendingPathComponent($0.path) } ?? repository.root : repository.root
        NSWorkspace.shared.open([target],withApplicationAt:URL(fileURLWithPath:path),configuration:NSWorkspace.OpenConfiguration()) { [weak self] _,error in
            if let error { DispatchQueue.main.async { self?.caption.stringValue = error.localizedDescription } }
        }
    }

    @objc private func autoFetchFinished(_ notification: Notification) {
        guard let event = notification.object as? GitAutoFetchScheduler.Event,event.key == autoFetchKey else { return }
        fetchFailure = event.error; fetchOperation = event.error == nil ? nil : event.operation
        if let error = event.error { caption.stringValue = L.text("Fetch Failure Details…")+" · "+error }
        else if !running { reload() }
    }

    @objc private func fetch() {
        let repo = repository,operation = UUID()
        performResult("Fetching…",operation:operation,{ Result { try repo.fetch() } }) { [weak self] result in
            switch result {
            case .success:
                self?.fetchFailure = nil
                self?.fetchOperation = nil
                self?.lastSuccessfulFetch = Date()
                if let self { GitAutoFetchScheduler.shared.recordSuccess(self.location) }
            case .failure(let error):
                self?.fetchFailure = error.localizedDescription
                self?.fetchOperation = operation
                self?.failedOperation = operation
                self?.failureButton.isHidden = false
            }
        }
    }
    @objc private func pull() {
        let repo = repository
        perform("Pulling (fast-forward only)…",onSuccess:{ [weak self] in
            guard let self else { return }; GitAutoFetchScheduler.shared.recordSuccess(self.location)
        }) { _ = try repo.fetch(); _ = try repo.run(["pull","--ff-only"],timeout:120) }
    }
    @objc private func push() { let repo = repository; perform("Pushing…") { _ = try repo.pushTrackingBranch() } }
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
            PickerOption(title:L.text("Git Command Log…"),detail:"") { [weak self] in self?.showGitLog() },
            PickerOption(title:L.text("Commit Snippets…"),detail:"") { [weak self] in self?.browseSnippets() },
            PickerOption(title:L.text("Repository Review…"),detail:"") { [weak self] in self?.browseTrackedFiles() },
            PickerOption(title:L.text("Review Changed Files…"),detail:"") { [weak self] in self?.browseWorkingChanges() },
            PickerOption(title:L.text("Clean Up Merged Worktrees…"),detail:"") { [weak self] in self?.browseMergedWorktrees() },
            PickerOption(title:L.text("Toggle Diff Line Wrapping"),detail:"") { [weak self] in
                self?.toggleDiffWrapping()
            },
            PickerOption(title:L.text("Jump to HEAD"),detail:"") { [weak self] in self?.jumpToHead() },
            PickerOption(title:L.text("Git Settings…"),detail:"") { [weak self] in self?.showGitSettings() },
            PickerOption(title:L.text("Open in…"),detail:"") { [weak self] in self?.browseExternalApplications() },
            PickerOption(title:L.text("Open in External Editor"),detail:"") { [weak self] in self?.openExternal(key:"git.externalEditor") },
            PickerOption(title:L.text("Open in External Terminal"),detail:"") { [weak self] in self?.openExternal(key:"git.externalTerminal") },
            PickerOption(title:L.text("Open Terminal"),detail:repository.directory) { [weak self] in self?.onOpenTerminal?() },
            PickerOption(title:L.text("Git Operations"),detail:"") { [weak self] in self?.showOperations() }
        ]
        if let fetchFailure {
            options.insert(PickerOption(title:L.text("Fetch Failure Details…"),detail:"") { [weak self] in self?.showFetchFailure(fetchFailure) },at:0)
        }
        if !worktreesEnabled { options.removeAll { $0.title == L.text("Clean Up Merged Worktrees…") } }
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
                if let row = self.historyRow(for:head) {
                    self.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
                    self.table.scrollRowToVisible(row)
                } else {
                    self.historyScope.selectedSegment = 0
                    self.changeHistoryScope()
                }
            }
        }
    }
    func reviewStash(_ ref: String) {
        let repo = repository
        performResult("Reading repository…",{
            let hash = try repo.resolvedRevision(ref)
            let parents = try repo.run(["rev-list","--parents","-1",hash,"--"]).split(whereSeparator:\.isWhitespace).dropFirst().map(String.init)
            guard let base = parents.first else { throw GitError.command("Invalid stash commit.") }
            var files = try repo.comparePaths(base,hash).map { path in
                GitReviewPanel.File(path:path,patch:{ try repo.comparisonPatch(base,hash,path:path) },images:{ try repo.revisionImages(base,hash,path:path) })
            }
            if parents.count > 2 {
                let untracked = parents[2]
                files += try repo.changedPaths(in:untracked).map { path in
                    GitReviewPanel.File(path:path,patch:{ try repo.commitDiff(untracked,path:path) },images:{ (nil,try repo.blobData(untracked,path:path)) })
                }
            }
            return (hash,files)
        }) { [weak self] hash,files in
            self?.openReview(files,context:.init(title:ref,primaryActionTitle:L.text("Apply Stash"),primaryAction:{ [weak self] in
                self?.perform("Applying stash…") { _ = try repo.run(["stash","apply",hash],timeout:120) }
            }))
        }
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
                            if $0 == "Show Stash" { return PickerOption(title:L.text("Show Stash"),detail:ref) { [weak self] in self?.reviewStash(ref) } }
                            return self.operationOption($0,values:["Stash":ref])
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
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
        if let commit = selectedCommit {
            addMenuOptions([
                PickerOption(title:L.text("Copy Commit Hash"),detail:"") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.hash,forType:.string) },
                PickerOption(title:L.text("Merged Commits…"),detail:"") { [weak self] in self?.browseMergedCommits(commit) },
                PickerOption(title:L.text("Commit Details…"),detail:"") { [weak self] in
                    self?.navigateToCommit(commit.hash)
                },
                PickerOption(title:L.text("Compare with HEAD"),detail:"") { [weak self] in self?.openComparison(commit.hash,"HEAD") },
                PickerOption(title:L.text("Compare Selected Commits"),detail:"") { [weak self] in self?.compareSelectedCommits() },
                PickerOption(title:L.text("Changed Files in Commit…"),detail:commit.subject) { [weak self] in self?.browseCommitFiles(commit) },
                operationOption("Create Branch",values:["Revision":commit.hash]),
                operationOption("Create Tag",values:["Revision":commit.hash]),
                operationOption("Cherry Pick",values:["Revision":commit.hash]),
                operationOption("Revert Commit",values:["Revision":commit.hash])
            ],to:menu)
        } else if let folder = fileGroups[row],mode.selectedSegment == 0 {
            let stage = side.selectedSegment == 0,repo = repository
            addMenuOptions([PickerOption(title:L.text(stage ? "Stage Folder" : "Unstage Folder"),detail:folder) { [weak self] in
                self?.perform(stage ? "Staging…" : "Unstaging…",onSuccess:{ [weak self] in guard let self else { return }; self.markLanding(self.changes.filter { $0.path.hasPrefix(folder+"/") }.map(\.path),staged:stage) }) { try repo.setFolderStaged(folder,staged:stage) }
            }],to:menu)
        } else if let change = selectedChange {
            addMenuOptions([PickerOption(title:L.text("File History…"),detail:change.path) { [weak self] in
                self?.browseFileHistory(change.path)
            }],to:menu)
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
        guard worktreesEnabled,let window else { return }
        GitWorktreePanels.finish(entry:entry,repository:repository,owner:window,
            canRemove:{ [weak self] in self?.onCanRemoveWorktree?($0) != false },
            onOpen:{ [weak self] in self?.onOpenWorktree?($0) },
            onOpenFile:{ [weak self] repo,path in self?.onOpenMergeFile?(repo,path) },
            onChanged:{ [weak self] in self?.reload() },onRelocated:{ [weak self] in self?.onWorktreeRelocated?($0,$1) })
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
            PickerOption(title:L.text("Delete Conflicted File…"),detail:path) { [weak self] in
                guard let self,let window = self.window else { return }
                let alert = NSAlert(); alert.messageText = L.text("Delete Conflicted File…"); alert.informativeText = path
                alert.addButton(withTitle:L.text("Delete")); alert.addButton(withTitle:L.text("Cancel"))
                alert.beginSheetModal(for:window) { [weak self] result in
                    guard result == .alertFirstButtonReturn else { return }
                    self?.perform("Resolving Conflict…",onSuccess:{ [weak self] in self?.showWorktreeConflicts(merge) }) { try merge.deleteConflict(path) }
                }
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

extension GitWorkspace {
    func showGitText(_ title: String,text: String,export: Bool = false) {
        guard let window else { return }
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x:0,y:0,width:660,height:340)
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false; view.font = Theme.editorFont; view.string = text
        }
        let alert = NSAlert(); alert.messageText = L.text(title); alert.accessoryView = scroll
        alert.addButton(withTitle:L.text("Close"))
        alert.addButton(withTitle:L.text("Copy"))
        if export { alert.addButton(withTitle:L.text("Export Log…")) }
        alert.beginSheetModal(for:window) { response in
            if response == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string); return
            }
            guard export,response == .alertThirdButtonReturn else { return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "linvell-git.log"
            panel.beginSheetModal(for:window) { response in
                guard response == .OK,let url = panel.url else { return }
                do { try text.write(to:url,atomically:true,encoding:.utf8) }
                catch { NSAlert(error:error).beginSheetModal(for:window) }
            }
        }
    }

}

private extension GitWorkspace {
    func logText(_ entry: GitCommandJournal.Entry) -> String {
        let date = ISO8601DateFormatter().string(from:entry.date)
        let result = L.text(entry.succeeded ? "Succeeded" : "Failed")
        let duration = String(format:"%.3fs",entry.elapsed)
        return "\(date)  \(entry.displayCommand)  \(result)  \(duration)"
    }

    func showGitLog(failuresOnly: Bool = false,operation: UUID? = nil,includeReads: Bool = true) {
        let entries = GitCommandJournal.shared.entries(for:repository.journalScope).filter {
            (!failuresOnly || !$0.succeeded) && (operation == nil || $0.operation == operation) && (includeReads || !$0.readOnly)
        }
        var options = [
            PickerOption(title:L.text(failuresOnly ? "Show All Commands" : "Show Failed Commands"),detail:"") { [weak self] in
                self?.showGitLog(failuresOnly:!failuresOnly,operation:operation,includeReads:includeReads)
            },
            PickerOption(title:L.text(includeReads ? "Hide Read Commands" : "Include Read Commands"),detail:"") { [weak self] in
                self?.showGitLog(failuresOnly:failuresOnly,operation:operation,includeReads:!includeReads)
            },
            PickerOption(title:L.text("Clear Log"),detail:"") { [weak self] in
                guard let self else { return }
                GitCommandJournal.shared.clear(scope:self.repository.journalScope)
                self.showGitLog(failuresOnly:failuresOnly,includeReads:includeReads)
            },
            PickerOption(title:L.text("Copy Log"),detail:"") { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entries.map(self.logText).joined(separator:"\n"),forType:.string)
            },
            PickerOption(title:L.text("Export Log…"),detail:"") { [weak self] in
                guard let self else { return }
                self.showGitText("Git Command Log…",text:entries.map(self.logText).joined(separator:"\n"),export:true)
            }
        ]
        options += entries.map { entry in
            PickerOption(title:entry.displayCommand,detail:logText(entry)) { [weak self] in
                guard let self else { return }
                self.showGitPicker("Git Command Log…",[
                    PickerOption(title:L.text("Copy Command"),detail:entry.displayCommand) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.displayCommand,forType:.string)
                    },
                    PickerOption(title:L.text("Copy Log"),detail:"") { [weak self] in
                        guard let self else { return }
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(self.logText(entry),forType:.string)
                    },
                    PickerOption(title:L.text("Details…"),detail:"") { [weak self] in self?.showGitText("Git Command Log…",text:entry.details) }
                ])
            }
        }
        showGitPicker("Git Command Log…",options)
    }

    func showFetchFailure(_ error: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L.text("Fetch Failure Details…")
        alert.informativeText = error
        alert.addButton(withTitle:L.text("Close"))
        alert.addButton(withTitle:L.text("Failed Command…"))
        alert.beginSheetModal(for:window) { [weak self] result in
            guard result == .alertSecondButtonReturn,let self else { return }
            self.showGitLog(failuresOnly:true,operation:self.fetchOperation)
        }
    }

    private func insertSnippet(_ value: String) {
        UserDefaults.standard.set(true,forKey:"git.showCommitMessageArea")
        mode.selectedSegment = 0; modeChanged()
        message.stringValue += (message.stringValue.isEmpty ? "" : "\n")+value
        updateActionAvailability()
        window?.makeFirstResponder(message)
    }

    @objc private func showCommitSnippets() { browseSnippets() }
    private func reloadQuickSnippets() {
        favoriteSnippets.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for snippet in GitCommitSnippet.load().filter(\.favorite) {
            let button = NSButton(title:String(snippet.text.prefix(40)).replacingOccurrences(of:"\n",with:" · "),target:self,action:#selector(insertFavoriteSnippet(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(snippet.text)
            button.toolTip = snippet.text
            button.setAccessibilityLabel(snippet.text)
            favoriteSnippets.addArrangedSubview(button)
        }
        favoriteSnippets.frame = NSRect(origin:.zero,size:NSSize(width:max(1,favoriteSnippets.fittingSize.width),height:30))
    }
    @objc private func insertFavoriteSnippet(_ sender: NSButton) {
        if let value = sender.identifier?.rawValue { insertSnippet(value) }
    }

    private func editSnippet(_ snippet: GitCommitSnippet?) {
        guard let window else { return }
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x:0,y:0,width:430,height:150)
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.isRichText = false; editor.string = snippet?.text ?? ""
        let favorite = NSButton(checkboxWithTitle:L.text("Show in Quick Input"),target:nil,action:nil)
        favorite.state = snippet?.favorite == false ? .off : .on
        let accessory = NSView(frame:NSRect(x:0,y:0,width:430,height:185))
        Theme.pin(Theme.stack([scroll,favorite],orientation:.vertical,spacing:6),in:accessory)
        let alert = NSAlert(); alert.messageText = L.text(snippet == nil ? "Add Snippet…" : "Edit Snippet…"); alert.accessoryView = accessory
        alert.addButton(withTitle:L.text("Save")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn,!editor.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
            var values = GitCommitSnippet.load()
            var updated = snippet ?? GitCommitSnippet(text:"")
            updated.text = editor.string; updated.favorite = favorite.state == .on
            if let index = values.firstIndex(where:{ $0.id == updated.id }) { values[index] = updated }
            else { values.append(updated) }
            GitCommitSnippet.save(values); self?.reloadQuickSnippets()
        }
    }

    func browseSnippets() {
        let snippets = GitCommitSnippet.load()
        let add = PickerOption(title:L.text("Add Snippet…"),detail:"") { [weak self] in self?.editSnippet(nil) }
        showGitPicker("Commit Snippets…",[add]+snippets.map { snippet in
            PickerOption(title:snippet.text,detail:snippet.favorite ? L.text("Quick Input") : "") { [weak self] in
                guard let self else { return }
                self.showGitPicker("Commit Snippets…",[
                    PickerOption(title:L.text("Insert Snippet"),detail:snippet.text) { [weak self] in self?.insertSnippet(snippet.text) },
                    PickerOption(title:L.text("Edit Snippet…"),detail:"") { [weak self] in self?.editSnippet(snippet) },
                    PickerOption(title:L.text(snippet.favorite ? "Remove from Quick Input" : "Show in Quick Input"),detail:"") { [weak self] in
                        GitCommitSnippet.save(GitCommitSnippet.load().map { value in
                            var value = value; if value.id == snippet.id { value.favorite.toggle() }; return value
                        }); self?.reloadQuickSnippets()
                    },
                    PickerOption(title:L.text("Delete Snippet"),detail:"") { [weak self] in
                        GitCommitSnippet.save(GitCommitSnippet.load().filter { $0.id != snippet.id }); self?.reloadQuickSnippets()
                    }
                ])
            }
        })
    }

    func openReview(_ files: [GitReviewPanel.File],context: GitReviewPanel.Context = .init(),reloadFiles: (() throws -> [GitReviewPanel.File])? = nil) {
        guard let window else { return }
        reviewPanel = GitReviewPanel(repository:repository,files:files,owner:window,onOpen:onOpen,context:context,reloadFiles:reloadFiles)
    }

    func browseMergedCommits(_ commit: GitCommit) {
        guard commit.parents.count >= 2 else { return }
        let repo = repository
        performResult("Reading repository…",{ try repo.run(["log","--format=%H%x00%an%x00%ad%x00%s%x00%b%x00","--date=short",commit.parents[0]+".."+commit.hash+"^@","--"]) }) { [weak self] output in
            let fields = output.components(separatedBy:"\0")
            let options: [PickerOption] = stride(from:0,to:fields.count-1,by:5).compactMap { index in
                guard index+4 < fields.count else { return nil }
                let hash = fields[index].trimmingCharacters(in:.newlines)
                let detail = fields[index+1]+" · "+fields[index+2]+" · "+String(hash.prefix(12))+" · "+String(fields[index+4].trimmingCharacters(in:.whitespacesAndNewlines).prefix(300))
                return PickerOption(title:fields[index+3],detail:detail) { [weak self] in self?.navigateToCommit(hash) }
            }
            self?.showGitPicker("Merged Commits…",options)
        }
    }

    func browseCommitFiles(_ commit: GitCommit) { browseCommitFiles(commit.hash) }
    private func browseCommitFiles(_ hash: String) {
        let repo = repository
        performResult("Reading repository…",{ try repo.changedPaths(in:hash) }) { [weak self] paths in
            self?.openReview(paths.map { path in
                GitReviewPanel.File(path:path,patch:{ try repo.commitDiff(hash,path:path) },images:{
                    try repo.commitImages(hash,path:path)
                })
            })
        }
    }

    func browseTrackedFiles() {
        let repo = repository
        performResult("Reading repository…",{ try repo.reviewFiles() }) { [weak self] paths in
            self?.openReview(paths.map { GitReviewPanel.File(path:$0,patch:nil) },reloadFiles:{ try repo.reviewFiles().map { GitReviewPanel.File(path:$0,patch:nil) } })
        }
    }

    func browseWorkingChanges() {
        let repo = repository,staged = side.selectedSegment == 1
        let loader: () throws -> [GitReviewPanel.File] = {
            try repo.changes().filter { staged ? $0.staged : $0.unstaged }.map { change in
                GitReviewPanel.File(path:change.path,patch:{ try repo.diff(change,staged:staged) },indexSide:change.conflicted ? nil : staged,images:{
                    let head = try? repo.resolvedRevision("HEAD")
                    let before = staged ? head.flatMap { try? repo.blobData($0,path:change.originalPath ?? change.path) } : try? repo.blobData(":",path:change.path)
                    let after = staged ? try? repo.blobData(":",path:change.path) : try? repo.workingFileData(change.path,largeFile:true)
                    return (before,after)
                })
            }
        }
        performResult("Reading repository…",loader) { [weak self] files in self?.openReview(files,reloadFiles:loader) }
    }

    func browseFileHistory(_ path: String,offset: Int = 0,revision: String? = nil) {
        let repo = repository,pageSize = 60
        performResult("Reading repository…",{
            let tip = try repo.resolvedRevision(revision ?? "HEAD")
            return (tip,try repo.fileHistoryEntries(path,revision:tip,limit:pageSize+1,offset:offset))
        }) { [weak self] tip,entries in
            var options = entries.prefix(pageSize).map { entry in
                PickerOption(title:entry.commit.subject,detail:entry.commit.author+" · "+entry.commit.date+" · "+String(entry.commit.hash.prefix(12))) { [weak self] in
                    self?.openReview([GitReviewPanel.File(path:entry.newPath ?? entry.oldPath ?? path,patch:{ try repo.fileHistoryDiff(entry) },images:{ try repo.fileHistoryImages(entry) })],context:.init(title:entry.commit.subject,statistics:entry.commit.author+" · "+entry.commit.date+" · "+entry.commit.hash,message:entry.commit.message))
                }
            }
            if entries.count > pageSize {
                options.insert(PickerOption(title:L.text("Load More"),detail:path) { [weak self] in self?.browseFileHistory(path,offset:offset+pageSize,revision:tip) },at:0)
            }
            self?.showGitPicker("File History…",options)
        }
    }

    func showHistoricalDiff(_ commit: GitCommit,path: String) {
        let repo = repository
        performResult("Reading repository…",{ try repo.commitDiff(commit.hash,path:path) }) { [weak self] patch in
            self?.showGitText(path,text:patch)
        }
    }

    func refreshWorktreeStates() {
        guard UserDefaults.standard.object(forKey:"git.showWorktreeStatus") as? Bool != false else {
            worktreeDetails = [:]; worktreeStates = [:]; branchesTable.reloadData(); return
        }
        guard showsWorktrees,!refreshingWorktreeStates,!running else { return }
        refreshingWorktreeStates = true
        let repo = repository,entries = worktrees
        let target = ""
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let latest = (try? repo.worktrees()) ?? entries
            let merged = Set(((try? repo.cleanupCandidates(into:target)) ?? []).map { $0.entry.path })
            var states: [String:String] = [:],details: [String:String] = [:]
            for entry in latest where !entry.prunable {
                if let state = try? repo.worktreeState(entry) {
                    states[entry.path] = state == "Clean" && merged.contains(entry.path) ? "Merged" : state
                    details[entry.path] = (try? repo.worktreeDetail(entry,against:target)).map(GitWorktreeStatusText.localized)
                }
            }
            let result = states,tooltip = details
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshingWorktreeStates = false
                guard self.repository.journalScope == repo.journalScope,self.worktrees.map(\.path) == entries.map(\.path) else { return }
                self.worktrees = latest
                self.worktreeStates = result
                self.worktreeDetails = tooltip
                self.branchesTable.reloadData()
            }
        }
    }

    func browseMergedWorktrees() {
        guard worktreesEnabled else { return }
        showGitPicker("Select Cleanup Target",[PickerOption(title:L.text("Automatic Trunk"),detail:L.text("Use the remote default branch and its upstream")) { [weak self] in self?.previewMergedWorktrees(into:"") }]+branchNames.map { target in
            PickerOption(title:target,detail:"") { [weak self] in self?.previewMergedWorktrees(into:target) }
        })
    }

    func previewMergedWorktrees(into target: String) {
        guard let window else { return }
        cleanupPanel = GitWorktreeCleanupPanel(repository:repository,target:target,owner:window,canRemove:{ [weak self] path in
            self?.onCanRemoveWorktree?(path) != false
        },onRemoved:{ [weak self] in self?.reload() },onWorktreeRemoved:{ [weak self] in self?.onWorktreeRelocated?($0,nil) })
    }
}
