import AppKit
import LinvellCore
import LinvellPluginKit
import SwiftTerm

final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    lazy var children: [FileNode] = {
        guard isDirectory else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles])) ?? []
        return urls.map(FileNode.init).sorted { a,b in a.isDirectory != b.isDirectory ? a.isDirectory : a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending }
    }()
    init(_ url: URL) {
        self.url = url
        isDirectory = (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true && FilePreview.kind(for:url) == nil
    }
    init(_ url: URL, isDirectory: Bool) { self.url = url; self.isDirectory = isDirectory }
    static func filteredTree(_ urls: [URL],under root: URL) -> [FileNode] {
        var folders: [String:FileNode] = [:]
        let top = FileNode(root,isDirectory:true)
        top.children = []
        folders[root.path] = top
        func parent(at url: URL) -> FileNode {
            if let existing = folders[url.path] { return existing }
            let node = FileNode(url,isDirectory:true)
            node.children = []
            folders[url.path] = node
            parent(at:url.deletingLastPathComponent()).children.append(node)
            return node
        }
        for url in urls where ExplorerActions.relative(url.path,under:root.path) != nil {
            parent(at:url.deletingLastPathComponent()).children.append(FileNode(url,isDirectory:false))
        }
        for folder in folders.values {
            folder.children.sort {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
        }
        return top.children
    }

}

final class WorkspaceController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    var documents: [OpenDocument] = []
    var recentQuickFiles: [WorkspaceSession] = []
    var quickFileIndex: [URL] = []
    var pluginSessions: [String:PluginSession] = [:]
    let installedPluginStore: PluginStore
    let managedPluginAutoload: Bool
    var managedPluginIDs = Set<String>()
    var managedPluginLoad = UUID()
    var pluginDocumentVersions: [UUID:Int] = [:]
    var pluginViewValues: [String:PluginViewUpdate] = [:]
    var pluginDataViews: [String:PluginDataView] = [:]
    var pluginImages: [String:NSImage] = [:]
    var pluginWindows: [String:PluginOwnedWindow] = [:]
    let pluginStatusBar = NSStackView()
    let languageServices = WorkspaceLanguageServices()
    var languageEdits: [UUID:DispatchWorkItem] = [:]
    var languageDiagnostics: [UUID:DispatchWorkItem] = [:]
    var tabRows: [UUID:NSStackView] = [:]
    var tabIconURLs: [UUID:URL] = [:]
    var languageSyncs: [UUID:LanguageQueryTicket] = [:]
    var languageQueries: [String:LanguageQueryTicket] = [:]
    var navigationBack: [CodeNavigationPoint] = [],navigationForward: [CodeNavigationPoint] = []
    var completionPanel: CodeCompletionPanel?
    var hoverPopover: CodeHoverPanel?
    var languageCompletionTriggers: [String:Set<String>] = [:]
    var languageSignatureTriggers: [String:Set<String>] = [:]
    var workspaceDiagnosticCount = 0
    var workspaceDiagnostics: [String:WorkspaceDiagnosticReport] = [:]
    var autoSaveWork: [UUID:DispatchWorkItem] = [:]
    var autoSaving: Set<UUID> = []
    let saveQueue = DispatchQueue(label:"top.fuluwa.linvell.autosave",qos:.utility)
    var current: OpenDocument?
    var activePane: EditorPane?
    var panes: [EditorPane] = []
    var root: FileNode?
    let outline = HierarchyOutlineView()
    let body = ResizablePanes()
    let content = ResizablePanes()
    let editors = ResizablePanes()
    let sidebar = Surface(Theme.panel)
    let activity = Surface(Theme.canvas)
    let workspaceArea = NSView()
    let center = Surface(Theme.canvas)
    let tabs = NSStackView()
    let tabScroll = TabScrollView()
    let editorHost = NSView()
    private var editorCard: NSView?
    let status = Theme.label("Ready",size:11,color:Theme.secondary)
    let languageStatus = Theme.label("",size:11,color:Theme.secondary)
    let modeLabel = Theme.label("TEXT",size:11,color:Theme.accent,weight:.semibold)
    let breadcrumb = Theme.label("",size:11,color:Theme.secondary)
    let previewButton = NSButton()
    var markdownView: MarkdownPreview?
    let projectTitle = Theme.label("Linvell",size:13,weight:.semibold)
    let search = Theme.searchField()
    var vimEnabled = UserDefaults.standard.bool(forKey:"vimEnabled")
    var terminal: LocalProcessTerminalView?
    var terminalHost: NSView?
    var agentWorkspace: AgentWorkspace?
    var agentWorkspaces: [AgentWorkspace] = []
    var agentFileMonitor: AgentFileMonitor?
    var reviewPanel: ReviewCommentsPanel?
    var recoveryTimer: Timer?
    var commandPanel: NSPanel?
    let recovery: RecoveryStore
    var recoveryErrorShown = false
    var fileIndex: [URL] = [] {
        didSet { if !search.stringValue.isEmpty { filterChanged() } }
    }
    var ignoredFiles: Set<String> = []
    private var fileMatches: [FileNode] = []
    var picker: QuickPicker?
    var sidebarKind = "files"
    var activityButtons: [NSButton] = []
    var activeActivity = 0
    var gitRepositoryFactory: (SSHRemote,String) -> GitRepository = { GitRepository(remote:$0,directory:$1) }
    var preferences: PreferencesController?
    var projectSettings: ProjectSettingsController?
    var restoringLayout = true
    var loading: [URL:UUID] = [:]
    var latestOpenRequest: UUID?
    var tabRestoreGeneration = UUID()
    var remoteConnection: SSHRemote?
    var remoteDirectory = "~"
    var remoteBrowser: RemoteExplorer?
    var remoteMutation: (host: String,path: String,trash: Bool)?
    var remoteLoads: [UUID:(host: String,path: String)] = [:]
    var remoteFolderPicker: RemoteFolderPicker?
    var runWorkspaceView: RunWorkspace?
    var gitWorkspaceView: GitWorkspace?

    init(pluginStore: PluginStore = .shared,managedAutoload: Bool = false) {
        self.installedPluginStore = pluginStore;self.managedPluginAutoload = managedAutoload
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!.appendingPathComponent("Linvell/Recovery",isDirectory:true)
        recovery = RecoveryStore(directory:support)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1320,height:860),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init(window:window)
        window.contentView = WorkspaceRootView(frame:NSRect(x:0,y:0,width:1320,height:860))
        window.title = "Linvell"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.appearance = Theme.appearance
        window.minSize = NSSize(width:800,height:540); window.delegate = self
        window.setFrameAutosaveName("Linvell.Workspace"); window.center()
        buildUI(); showWelcome()
        NotificationCenter.default.addObserver(self,selector:#selector(managedPluginsChanged(_:)),name:PluginStore.changed,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(pauseManagedPlugin(_:)),name:PluginStore.willChange,object:nil)
        DispatchQueue.main.async { [weak self] in self?.syncManagedPlugins() }
        languageServices.didCreateSession = { [weak self] session,language,root,remote in
            self?.observeDiagnostics(session,snapshot:EditorCodeSnapshot(id:UUID(),uri:"",path:"",text:"",version:0,language:language,root:root,remote:remote))
        }
        NotificationCenter.default.addObserver(self,selector:#selector(languageToolsChanged(_:)),name:LanguageTools.changed,object:nil)
        recoveryTimer = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in self?.persistRecovery() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { recoveryTimer?.invalidate(); NotificationCenter.default.removeObserver(self) }

    func buildUI() {
        guard let rootView = window?.contentView else { return }
        rootView.clipsToBounds = true
        let shell = NSStackView(); shell.orientation = .vertical; shell.spacing = 0; shell.alignment = .leading; shell.distribution = .fill
        Theme.pin(shell,in:rootView)
        if let window { WorkspaceGlass.installWindowBackdrop(in:window,root:rootView) }
        let header = NSView()
        header.heightAnchor.constraint(equalToConstant:38).isActive = true
        let command = NSButton(title:L.text("Quick Open…   ⌘P"),target:self,action:#selector(quickOpen))
        command.image = NSImage(systemSymbolName:"magnifyingglass",accessibilityDescription:nil)?
            .withSymbolConfiguration(.init(pointSize:12,weight:.medium))
        command.imagePosition = .imageLeading
        command.bezelStyle = .inline; command.isBordered = false; command.font = .systemFont(ofSize:12)
        command.contentTintColor = Theme.liveSecondary
        let searchPill = WorkspaceGlass.surface(containing:command,radius:13)
        searchPill.widthAnchor.constraint(equalToConstant:144).isActive = true
        searchPill.heightAnchor.constraint(equalToConstant:26).isActive = true
        projectTitle.lineBreakMode = .byTruncatingMiddle
        projectTitle.widthAnchor.constraint(lessThanOrEqualToConstant:160).isActive = true
        projectTitle.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let heading = Theme.stack([
            projectTitle,WorkspaceGlass.icon("slider.horizontal.3",help:"Project Settings",target:self,action:#selector(showProjectSettings)),
            tabScroll,previewButton,searchPill,
            WorkspaceGlass.icon("sidebar.left",help:"Toggle Sidebar",target:self,action:#selector(toggleSidebar)),
            WorkspaceGlass.icon("folder.badge.plus",help:"Open Folder…",target:self,action:#selector(openFolder)),
            WorkspaceGlass.icon("rectangle.split.2x1",help:"Split Editor",target:self,action:#selector(toggleSplit)),
            WorkspaceGlass.icon("terminal",help:"Toggle Terminal",target:self,action:#selector(toggleTerminal)),
            WorkspaceGlass.icon("sparkles",help:"Agents",target:self,action:#selector(showAgents)),
            WorkspaceGlass.icon("square.stack.3d.up",help:"Task Workspaces…",target:self,action:#selector(showAgentTasks))
        ],spacing:5)
        heading.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:12),
            heading.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-10),
            heading.centerYAnchor.constraint(equalTo:header.centerYAnchor)
        ])
        shell.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo:shell.widthAnchor).isActive = true
        body.isVertical = true; body.firstMinimum = 180; body.secondMinimum = 400
        body.addArrangedSubview(sidebar); body.addArrangedSubview(center)
        body.onResize = { [weak self] width in if self?.restoringLayout == false { UserDefaults.standard.set(width,forKey:"sidebarWidth") } }
        content.onResize = { [weak self] height in
            if let self,self.terminalHost?.isHidden == false { UserDefaults.standard.set(self.content.bounds.height-height-1,forKey:"terminalHeight") }
        }
        let area = Theme.stack([activity,body],spacing:0); area.alignment = .top
        activity.widthAnchor.constraint(equalToConstant:42).isActive = true
        activity.heightAnchor.constraint(equalTo:area.heightAnchor).isActive = true
        body.heightAnchor.constraint(equalTo:area.heightAnchor).isActive = true
        shell.addArrangedSubview(area)
        area.widthAnchor.constraint(equalTo:shell.widthAnchor).isActive = true
        area.heightAnchor.constraint(equalTo:rootView.heightAnchor,constant:-62).isActive = true
        breadcrumb.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let footer = Theme.stack([modeLabel,languageStatus,breadcrumb,NSView(),pluginStatusBar,status]); footer.edgeInsets = NSEdgeInsets(top:0,left:16,bottom:0,right:20)
        footer.heightAnchor.constraint(equalToConstant:24).isActive = true; shell.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo:shell.widthAnchor).isActive = true
        setupActivity()
        setupSidebar(); setupCenter()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.contentView?.layoutSubtreeIfNeeded()
            let defaults = UserDefaults.standard
            let width = defaults.integer(forKey:"layoutVersion") >= 2 ? defaults.double(forKey:"sidebarWidth") : 260
            self.body.setPosition(width > 0 ? width : 260,ofDividerAt:0)
            self.outline.reloadData(); self.outline.needsDisplay = true
            self.restoringLayout = false; defaults.set(2,forKey:"layoutVersion")
        }
    }

    private func setupSidebar() {
        sidebar.layer?.backgroundColor = NSColor.clear.cgColor
        let label = Theme.label("EXPLORER",size:11,color:Theme.secondary,weight:.semibold)
        let row = Theme.stack([label,NSView(),WorkspaceGlass.icon("plus",help:"New File",target:self,action:#selector(newFile)),WorkspaceGlass.icon("arrow.clockwise",help:"Refresh Files",target:self,action:#selector(refreshFiles))],spacing:4)
        row.heightAnchor.constraint(equalToConstant:28).isActive = true
        search.placeholderString = L.text("Filter files"); search.font = .systemFont(ofSize:12); search.delegate = self; search.sendsSearchStringImmediately = true
        search.target = self; search.action = #selector(filterChanged)
        while outline.tableColumns.count > 1 { outline.removeTableColumn(outline.tableColumns.last!) }
        let column = outline.tableColumns.first ?? NSTableColumn(identifier:NSUserInterfaceItemIdentifier("files"))
        if outline.tableColumns.isEmpty { outline.addTableColumn(column) }
        column.width = max(180,sidebar.bounds.width-32); column.resizingMask = .autoresizingMask
        outline.outlineTableColumn = column; outline.headerView = nil
        outline.indentationPerLevel = 15; outline.indentationMarkerFollowsCell = true; outline.autoresizesOutlineColumn = true
        outline.dataSource = self; outline.delegate = self; outline.rowHeight = 23
        outline.backgroundColor = .clear; outline.style = .sourceList; outline.intercellSpacing = NSSize(width:0,height:2)
        outline.target = self; outline.action = #selector(fileClicked)
        outline.openSelected = { [weak self] in
            guard let self,let node = self.outline.item(atRow:self.outline.selectedRow) as? FileNode else { return false }
            if node.isDirectory {
                if self.outline.isItemExpanded(node) { self.outline.collapseItem(node) } else { self.outline.expandItem(node) }
            } else { self.open(node.url) }
            return true
        }
        outline.renameSelected = { [weak self] in self?.renameSelectedExplorerItem() ?? false }
        outline.trashSelected = { [weak self] in self?.trashSelectedExplorerItem() ?? false }
        outline.setAccessibilityLabel("Workspace files")
        let fileMenu = NSMenu(); fileMenu.delegate = self; outline.menu = fileMenu
        let scroll = ExplorerScrollView()
        scroll.folder = { item in
            guard let node = item as? FileNode,node.isDirectory else { return nil }
            return (node.url.path,node.url.lastPathComponent)
        }
        scroll.canPin = { [weak self] in self?.isFilteringFiles == false }
        scroll.documentView = outline; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        let stack = Theme.stack([row,search,scroll],orientation:.vertical,spacing:6)
        Theme.pin(stack,in:sidebar,inset:10)
    }

    private func setupActivity() {
        activity.layer?.backgroundColor = NSColor.clear.cgColor
        var controls: [NSView] = []
        for (index,entry) in [("doc.on.doc","Explorer"),("magnifyingglass","Search Project"),("arrow.triangle.branch","Source Control"),("list.bullet.rectangle","Document Symbols"),("square.grid.2x2","Project Tools"),("sparkles","Agents")].enumerated() {
            let button = Theme.activityButton(entry.0,help:entry.1,target:self,action:#selector(activityClicked(_:)))
            button.tag = index; button.image?.isTemplate = true
            if index == 5 { button.identifier = .init("Linvell.AgentsActivity") }
            button.state = index == activeActivity ? .on : .off
            button.contentTintColor = index == activeActivity ? Theme.accent : Theme.secondary
            activityButtons.append(button); controls.append(button)
        }
        let settings = Theme.button("gearshape",help:"Settings",target:self,action:#selector(showSettings))
        let settingsRow = NSView()
        settingsRow.heightAnchor.constraint(equalToConstant:32).isActive = true
        settings.translatesAutoresizingMaskIntoConstraints = false
        settingsRow.addSubview(settings)
        NSLayoutConstraint.activate([
            settings.centerXAnchor.constraint(equalTo:settingsRow.centerXAnchor),
            settings.centerYAnchor.constraint(equalTo:settingsRow.centerYAnchor)
        ])
        controls.append(NSView()); controls.append(settingsRow)
        let stack = Theme.stack(controls,orientation:.vertical,spacing:5); Theme.pin(stack,in:activity,inset:4)
    }
    @objc private func activityClicked(_ sender: NSButton) {
        selectActivity(sender.tag)
        switch sender.tag { case 0: showSidebar("files"); case 1: projectSearch(); case 2: gitWorkspace(); case 3: showSymbols(); case 4: projectTools(); default: showAgents() }
    }
    func showSidebar(_ kind: String) {
        sidebar.refreshTheme()
        if kind == "agents",let agentWorkspace {
            sidebarKind = kind; sidebar.isHidden = false
            sidebar.subviews.forEach { $0.removeFromSuperview() }
            Theme.pin(agentWorkspace.configurationView,in:sidebar); selectActivity(5); body.adjustSubviews(); return
        }
        if kind.hasPrefix("plugin:"),restorePluginSidebar(String(kind.dropFirst(7))) { return }
        sidebarKind = kind; sidebar.isHidden = false
        sidebar.subviews.forEach { $0.removeFromSuperview() }
        if kind == "files",let connection = remoteConnection { setupRemoteSidebar(connection) }
        else if kind == "files" { setupSidebar() }
        else if kind == "search",let connection = remoteConnection {
            let directory = remoteDirectory
            let tool = ToolSidebar(project:URL(fileURLWithPath:directory),remote:(connection,directory))
            tool.unsavedTexts = { [weak self] in self?.searchOverrides(root:directory,host:connection.host) ?? [:] }
            tool.onSelect = { [weak self] match in
                guard let self,self.remoteConnection?.host == connection.host,self.remoteDirectory == directory else { return }
                self.openRemote(match.url.path,connection:connection) { [weak self] in self?.selectSearchMatch(match) }
            }
            Theme.pin(tool,in:sidebar)
        } else if kind == "search",let project = root?.url {
            let tool = ToolSidebar(project:project)
            tool.unsavedTexts = { [weak self] in self?.searchOverrides(root:project.path,host:nil) ?? [:] }
            tool.onSelect = { [weak self] match in
                self?.open(match.url) { [weak self] in self?.selectSearchMatch(match) }
            }
            Theme.pin(tool,in:sidebar)
        } else {
            let label = Theme.label("Open a folder to get started.",size:13,color:Theme.secondary)
            label.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:18),label.topAnchor.constraint(equalTo:sidebar.topAnchor,constant:24)])
        }
        selectActivity(kind == "files" ? 0 : kind == "search" ? 1 : 2)
        body.adjustSubviews()
    }
    func selectActivity(_ index: Int) {
        activeActivity = index
        for button in activityButtons { button.state = button.tag == index ? .on : .off; button.contentTintColor = button.tag == index ? Theme.accent : Theme.secondary; button.needsDisplay = true }
    }
    func goToLine(_ line: Int) {
        guard let pane = activePane else { return }
        let view = pane.textView, starts = pane.document.lines.starts
        let offset = starts[min(starts.count,max(1,line))-1]
        view.setSelectedRange(NSRange(location:offset,length:0)); view.scrollRangeToVisible(view.selectedRange()); window?.makeFirstResponder(view)
    }
    private func showSymbols() {
        if let current,codeSnapshot(current) != nil { indexedDocumentSymbols(); return }
        showTextSymbols()
    }
    private func showTextSymbols() {
        guard let current else { return }
        let lines = current.buffer.text.components(separatedBy:"\n")
        let expression = try? NSRegularExpression(pattern:#"^\s*(?:(?:public|private|fileprivate|internal|open|final|static|export|async)\s+)*(?:struct|class|enum|protocol|func|function|def|interface|type)\s+([^\s({:]+)"#)
        let options = lines.enumerated().compactMap { index,line -> PickerOption? in
            guard let match = expression?.firstMatch(in:line,range:NSRange(location:0,length:line.utf16.count)) else { return nil }
            let name = (line as NSString).substring(with:match.range(at:1))
            return PickerOption(title:name,detail:"Line \(index+1) · text-based symbol",invoke:{ [weak self] in self?.goToLine(index+1) })
        }
        picker = QuickPicker(title:L.text("Document symbols (text-based)"),options:options,owner:window!)
    }
    @objc func showSettings() {
        if preferences == nil { preferences = PreferencesController(owner:self) }
        preferences?.showWindow(nil); preferences?.window?.makeKeyAndOrderFront(nil)
    }
    var projectToolsReportLoader: ((Int) throws -> ProjectTools.Reports)?
    @objc func projectTools() {
        guard let project = remoteConnection != nil ? URL(fileURLWithPath:remoteDirectory) : root?.url else { openFolder(); return }
        preserveEditorPosition()
        current = nil; activePane = nil; panes = []; markdownView = nil
        editors.arrangedSubviews.forEach { $0.removeFromSuperview() }
        editors.addArrangedSubview(ProjectTools(project:project,remote:remoteConnection,directory:remoteConnection == nil ? nil : remoteDirectory,owner:self,reportLoader:projectToolsReportLoader))
        renderTabs(); previewButton.isHidden = true; breadcrumb.stringValue = L.text("Project Tools")
        status.stringValue = L.text("Project-scoped tools"); modeLabel.stringValue = L.text("TOOLS")
        selectActivity(4)
    }
    @objc func gitWorkspace() {
        let repository: GitRepository
        if let remoteConnection { repository = gitRepositoryFactory(remoteConnection,remoteDirectory) }
        else if let project = root?.url { repository = GitRepository(root:project) }
        else { openFolder(); return }
        if let previous = gitWorkspaceView,previous.workspaceDirectory != repository.directory || previous.repository.remote?.host != repository.remote?.host {
            guard !previous.running else { status.stringValue = L.text("Finish the current Git operation first."); return }
            previous.shutdown(); gitWorkspaceView = nil
        }
        preserveEditorPosition()
        current = nil; activePane = nil; panes = []; markdownView = nil
        editors.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let existing = gitWorkspaceView
        let git = existing ?? GitWorkspace(repository:repository); gitWorkspaceView = git
        if existing != nil { git.refreshExternalState() }
        git.onOpen = { [weak self] url in
            if let remote = repository.remote { self?.openRemote(url.path,connection:remote) }
            else { self?.open(url) }
        }
        git.onRepositories = { [weak self] in self?.browseGitRepositories() }
        git.onNewTask = { [weak self] in self?.newAgentTask() }
        git.onOpenTerminal = { [weak self] in
            guard let self else { return }
            if self.terminalHost?.isHidden != false { self.toggleTerminal() }
            else if let terminal = self.terminal { self.window?.makeFirstResponder(terminal) }
        }
        git.onOpenWorktree = { [weak self] path in
            guard let self else { return }
            if let remote = repository.remote {
                let target = (NSApp.delegate as? AppDelegate)?.newWorkspace() ?? self
                target.connectToSSH(remote.host,folder:path)
                if target.remoteConnection?.host == remote.host,target.remoteDirectory == path { target.gitWorkspace() }
            } else {
                self.openTaskWorkspace(path)?.gitWorkspace()
            }
        }
        git.onOpenMergeFile = { [weak self] destination,path in
            guard let self else { return }
            let file = destination.root.appendingPathComponent(path)
            if let remote = destination.remote {
                if self.remoteConnection?.host == remote.host,self.remoteDirectory == destination.directory {
                    self.openRemote(file.path,connection:remote)
                } else if let target = (NSApp.delegate as? AppDelegate)?.newWorkspace() {
                    target.connectToSSH(remote.host,folder:destination.directory)
                    if target.remoteConnection?.host == remote.host,target.remoteDirectory == destination.directory {
                        target.openRemote(file.path,connection:remote)
                    }
                }
            } else if self.root?.url.path == destination.directory {
                self.open(file)
            } else {
                self.openTaskWorkspace(destination.directory)?.open(file)
            }
        }
        git.onCanRemoveWorktree = { path in
            let open = (NSApp.delegate as? AppDelegate)?.workspaces.contains { workspace in
                if let host = repository.remote?.host {
                    guard workspace.remoteConnection?.host == host,workspace.remoteDirectory == path else { return false }
                } else {
                    guard workspace.remoteConnection == nil,workspace.root?.url.path == path else { return false }
                }
                return workspace.window?.isVisible == true || workspace.agentsRunning || workspace.documents.contains { $0.buffer.isModified }
            } ?? false
            return !open
        }
        git.onWorktreeRelocated = { old,new in
            for workspace in (NSApp.delegate as? AppDelegate)?.workspaces ?? [] {
                workspace.worktreeDidRelocate(host:repository.remote?.host,from:old,to:new)
            }
        }
        git.onReview = { [weak self] comment in self?.composeReview(comment) }
        git.onOpenRepository = { [weak self] repo in
            guard let self else { return }
            if let remote = repo.remote {
                self.connectToSSH(remote.host,folder:repo.directory)
                guard self.remoteConnection?.host == remote.host,self.remoteDirectory == repo.directory else { return }
            } else { self.setProject(repo.root); guard self.root?.url == repo.root else { return } }
            self.gitWorkspace()
        }
        editors.addArrangedSubview(git); editors.adjustSubviews(); renderTabs()
        previewButton.isHidden = true; breadcrumb.stringValue = L.text("Source Control")
        status.stringValue = L.text("Git repository"); modeLabel.stringValue = "GIT"
        sidebar.isHidden = true; body.adjustSubviews(); selectActivity(2)
    }
    @objc func runWorkspace() {
        let directory = remoteConnection == nil ? (root?.url.path ?? current?.fileURL?.deletingLastPathComponent().path) : remoteDirectory
        guard let directory else { openFolder(); return }
        if let existing = runWorkspaceView,existing.directory != directory || existing.remote?.host != remoteConnection?.host {
            guard existing.mayClose() else { return }; existing.terminate(); runWorkspaceView = nil
        }
        if runWorkspaceView == nil { runWorkspaceView = RunWorkspace(directory:directory,remote:remoteConnection) }
        preserveEditorPosition()
        current = nil; activePane = nil; panes = []; markdownView = nil
        editors.arrangedSubviews.forEach { $0.removeFromSuperview() }
        editors.addArrangedSubview(runWorkspaceView!); editors.adjustSubviews(); renderTabs()
        previewButton.isHidden = true; breadcrumb.stringValue = L.text("Run & Preview"); modeLabel.stringValue = "RUN"
    }

    private func setupCenter() {
        center.layer?.backgroundColor = NSColor.clear.cgColor
        tabs.orientation = .horizontal; tabs.spacing = 5; tabs.alignment = .centerY
        tabs.edgeInsets = NSEdgeInsets(top:0,left:6,bottom:0,right:6)
        tabScroll.owner = self
        tabScroll.documentView = tabs; tabScroll.hasHorizontalScroller = true; tabScroll.autohidesScrollers = true
        tabScroll.drawsBackground = false; tabScroll.heightAnchor.constraint(equalToConstant:30).isActive = true
        tabScroll.setContentHuggingPriority(.defaultLow,for:.horizontal)
        tabScroll.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.heightAnchor.constraint(equalTo:tabScroll.contentView.heightAnchor).isActive = true
        previewButton.title = ""; previewButton.image = NSImage(systemSymbolName:"eye",accessibilityDescription:nil)
        previewButton.widthAnchor.constraint(equalToConstant:26).isActive = true
        previewButton.imagePosition = .imageOnly; previewButton.isBordered = false; previewButton.contentTintColor = Theme.liveAccent
        previewButton.target = self; previewButton.action = #selector(toggleMarkdownPreview); previewButton.isHidden = true
        previewButton.setAccessibilityLabel(L.text("Toggle Preview")); previewButton.toolTip = L.text("Preview · ⇧⌘V")
        breadcrumb.lineBreakMode = .byTruncatingMiddle
        editors.isVertical = true
        Theme.pin(editors,in:editorHost)
        editorHost.translatesAutoresizingMaskIntoConstraints = false
        content.isVertical = false; content.addArrangedSubview(editorHost)
        let card = WorkspaceGlass.surface(containing:content,radius:12)
        WorkspaceGlass.tintEditor(card)
        editorCard = card
        Theme.pin(card,in:center,inset:6)
    }

    private func showWelcome() {
        editors.arrangedSubviews.forEach { $0.removeFromSuperview() }; panes = []; activePane = nil
        markdownView = nil; editors.addArrangedSubview(WelcomeView(owner:self))
    }

    @objc func newFile() {
        latestOpenRequest = nil; activate(OpenDocument(DocumentBuffer()))
    }
    @objc func openFile() {
        let p = Theme.openPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = true
        p.beginSheetModal(for:window!) { [weak self] result in
            guard result == .OK else { return }
            if let app = NSApp.delegate as? AppDelegate { app.openExternal(p.urls,preferred:self) }
            else { p.urls.forEach { self?.open($0) } }
        }
    }
    @objc func openFolder() {
        if remoteConnection != nil { openRemoteFolder(); return }
        openLocalFolder()
    }
    @objc func openLocalFolder() {
        let p = Theme.openPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.beginSheetModal(for:window!) { [weak self] result in if result == .OK, let url = p.url { self?.setProject(url) } }
    }
    func setProject(_ url: URL) {
        if root?.url.path != url.resolvingSymlinksInPath().path,gitWorkspaceView?.running == true {
            status.stringValue = L.text("Finish the current Git operation first."); return
        }
        if root?.url.path != url.resolvingSymlinksInPath().path { persistWorkspaceTabs() }
        resetLanguageServices()
        let wasRemote = remoteConnection != nil
        if wasRemote {
            guard mayCloseTerminal() else { return }; terminateTerminal()
            terminalHost?.removeFromSuperview(); terminalHost = nil; terminal = nil
        }
        latestOpenRequest = nil
        tabRestoreGeneration = UUID()
        remoteConnection = nil; remoteBrowser = nil
        if pluginWorkspace?.identityKey != PluginWorkspace(root:url.path).identityKey { stopPlugins(); resetLanguageServices() }
        search.stringValue = ""; fileMatches = []; fileIndex = []; quickFileIndex = []; ignoredFiles = []
        let project = FileNode(url.resolvingSymlinksInPath())
        root = project; updateIgnoredFiles(for:project); syncManagedPlugins(); projectTitle.stringValue = url.lastPathComponent
        if let task = AgentTaskStore().task(at:root!.url.path) { projectTitle.stringValue = task.title }
        outline.reloadData(); UserDefaults.standard.set(url.path,forKey:"lastProject")
        WorkspaceSession.save(.local(path:project.url.path))
        indexProjectFiles(project)
        if wasRemote || sidebarKind != "files" { showSidebar(wasRemote ? "files" : sidebarKind) }
        agentProjectDidChange()
    }
    func open(_ url: URL,completion: (() -> Void)? = nil) {
        if (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true,FilePreview.kind(for:url) == nil { setProject(url); return }
        if let existing = documents.first(where: { $0.fileURL == url.resolvingSymlinksInPath() }) { activate(existing); completion?(); return }
        let resolved = url.resolvingSymlinksInPath()
        if FilePreview.kind(for:resolved) != nil { latestOpenRequest = nil; activate(OpenDocument(previewURL:resolved)); completion?(); return }
        guard loading[resolved] == nil else { return }
        let request = UUID(); loading[resolved] = request; latestOpenRequest = request
        status.stringValue = L.format("Opening %@…",url.lastPathComponent)
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                let doc = try OpenDocument.load(resolved)
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.loading[resolved] == request else { return }
                    self.loading.removeValue(forKey:resolved)
                    guard self.window?.isVisible == true else { return }
                    if self.latestOpenRequest == request { self.activate(doc); completion?() }
                    else { self.documents.append(doc); self.renderTabs() }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.loading.removeValue(forKey:resolved); self?.show(error) }
            }
        }
    }
    func activate(_ document: OpenDocument) {
        latestOpenRequest = nil
        preserveEditorPosition()
        if !documents.contains(where: { $0 === document }) { documents.append(document) }
        current = document
        if let location = quickFileLocation(document) {
            recentQuickFiles.removeAll { $0 == location }
            recentQuickFiles.insert(location,at:0)
            if recentQuickFiles.count > 30 { recentQuickFiles.removeLast() }
        }
        editors.arrangedSubviews.forEach { $0.removeFromSuperview() }
        panes = []; activePane = nil; markdownView = nil
        if let url = document.previewURL { editors.addArrangedSubview(FilePreview(url:url)) }
        else {
            let pane = makePane(document); editors.addArrangedSubview(pane); activePane = pane
            if document.supportsPreview && document.markdownPreview {
                let preview = MarkdownPreview(root:document.fileURL!.deletingLastPathComponent(),html:document.isHTML)
                pane.onScroll = { [weak preview] in preview?.scrollFromSource($0) }
                preview.onScroll = { [weak pane] in pane?.scrollFromPreview($0) }
                preview.openFile = { [weak self] in self?.open($0) }; preview.render(document.buffer.text)
                markdownView = preview; editors.addArrangedSubview(preview); editors.setPosition(editors.bounds.width/2,ofDividerAt:0)
            }
        }
        editors.adjustSubviews(); renderTabs(); updateStatus(); window?.makeFirstResponder(activePane?.textView)
        if let selections = document.lastSelections { activePane?.textView.setSelections(selections) }
        if let anchor = document.lastScroll { activePane?.scrollFromPreview(anchor); markdownView?.scrollFromSource(anchor) }
        window?.title = "\(document.displayName) — Linvell"
    }
    func preserveEditorPosition() {
        completionPanel?.dismiss(); hoverPopover?.close(); languageQueries["textDocument/completion"]?.cancel(); languageQueries["textDocument/hover"]?.cancel()
        if let pane = activePane {
            pane.document.lastScroll = pane.scrollAnchor
            pane.document.lastSelections = pane.textView.editingSelections
        }
    }
    private func makePane(_ document: OpenDocument) -> EditorPane {
        let pane = EditorPane(document:document,vim:vimEnabled)
        if let remote = document.remote,remoteMutation?.trash == true,isMutatingRemote(remote.path,host:remote.connection.host) {
            pane.textView.isEditable = false
        }
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.onFocus = { [weak self,weak pane] in self?.activePane = pane }
        pane.onChange = { [weak self] in self?.updateStatus(); self?.updateTabTitles() }
        pane.onTextChanged = { [weak self] in
            self?.markdownView?.render(document.buffer.text)
            self?.scheduleAutoSave(document)
            self?.languageDocumentChanged(document)
            self?.synchronizePluginDocuments()
            (self?.sidebar.subviews.first as? ToolSidebar)?.refresh()
        }
        pane.textView.exCommand = { [weak self] prefix in self?.showEx(prefix) }
        pane.textView.reviewAction = { [weak self,weak pane] in if let pane { self?.addEditorReview(pane) } }
        configureLanguageEditor(pane)
        panes.append(pane); return pane
    }
    func renderTabs() {
        synchronizePluginDocuments()
        let ids = Set(documents.map { $0.buffer.id })
        for id in Array(tabRows.keys) where !ids.contains(id) {
            tabRows.removeValue(forKey:id)?.removeFromSuperview(); tabIconURLs.removeValue(forKey:id)
        }
        for (index,doc) in documents.enumerated() {
            let id = doc.buffer.id
            let row: NSStackView
            if let existing = tabRows[id] { row = existing }
            else {
                let button = TabTitleButton(title:doc.displayName,target:self,action:#selector(tabClicked(_:)))
                button.bezelStyle = .inline; button.isBordered = false
                button.menu = tabMenu(for:doc)
                let close = TabCloseButton(); close.target = self; close.action = #selector(closeTab(_:))
                let tab = DraggableTabRow(views:[FileIcon.view(for:doc.fileURL),button,close])
                tab.owner = self
                tab.documentID = id
                tab.orientation = .horizontal; tab.alignment = .centerY; tab.spacing = 5
                row = tab
                row.edgeInsets = NSEdgeInsets(top:0,left:8,bottom:0,right:4)
                row.heightAnchor.constraint(equalToConstant:26).isActive = true; row.wantsLayer = true
                row.layer?.cornerRadius = 7
                row.menu = button.menu
                tabRows[id] = row; tabIconURLs[id] = doc.fileURL
            }
            if tabIconURLs[id] != doc.fileURL,let icon = row.arrangedSubviews.first {
                icon.removeFromSuperview(); row.insertArrangedSubview(FileIcon.view(for:doc.fileURL),at:0)
                tabIconURLs[id] = doc.fileURL
            }
            if index >= tabs.arrangedSubviews.count || tabs.arrangedSubviews[index] !== row {
                row.removeFromSuperview(); tabs.insertArrangedSubview(row,at:index)
            }
            if let icon = row.arrangedSubviews.first as? NSImageView { icon.contentTintColor = icon.image?.isTemplate == true ? Theme.secondary : nil }
            let selected = doc === current
            let button = row.arrangedSubviews[1] as! NSButton,close = row.arrangedSubviews[2] as! TabCloseButton
            button.tag = index; close.tag = index
            button.font = .systemFont(ofSize:12,weight:selected ? .semibold : .regular)
            button.contentTintColor = selected ? Theme.foreground : Theme.secondary
            close.toolTip = L.format("Close %@",doc.displayName); close.setAccessibilityLabel(close.toolTip)
            row.layer?.backgroundColor = selected ? Theme.foreground.withAlphaComponent(0.11).cgColor : NSColor.clear.cgColor
        }
        tabs.setAccessibilityChildren(tabs.arrangedSubviews)
        updateTabTitles()
        if let current,let row = tabRows[current.buffer.id] {
            tabs.layoutSubtreeIfNeeded()
            tabs.scrollToVisible(row.frame)
        }
    }
    func updateTabTitles() {
        for (i,row) in tabs.arrangedSubviews.enumerated() {
            guard i < documents.count,let b = (row as? NSStackView)?.arrangedSubviews.compactMap({ $0 as? NSButton }).first else { continue }
            if b.title != documents[i].displayName { b.title = documents[i].displayName }
            ((row as? NSStackView)?.arrangedSubviews.last as? TabCloseButton)?.modified = documents[i].buffer.isModified
        }
        window?.isDocumentEdited = documents.contains { $0.buffer.isModified }
    }
    @objc private func tabClicked(_ sender: NSButton) { if documents.indices.contains(sender.tag) { activate(documents[sender.tag]) } }
    @objc private func closeTab(_ sender: NSButton) { closeDocument(documents[sender.tag]) }
    @objc func closeWorkspaceWindow() { window?.performClose(nil) }
    @objc func openWelcomeWindow() { (NSApp.delegate as? AppDelegate)?.newWorkspace() }
    @objc func closeCurrent() { if let current { closeDocument(current) } }
    func closeDocument(_ doc: OpenDocument) {
        autoSaveWork.removeValue(forKey:doc.buffer.id)?.cancel()
        guard mayClose(doc) else { return }
        do { try recovery.remove(doc.buffer.id) } catch { show(error); return }
        if let snapshot = codeSnapshot(doc,forClosing:true) { languageServices.close(snapshot) }
        languageEdits.removeValue(forKey:doc.buffer.id)?.cancel()
        languageDiagnostics.removeValue(forKey:doc.buffer.id)?.cancel()
        documents.removeAll { $0 === doc }
        if current === doc {
            if let next = documents.last { activate(next) } else { current = nil; renderTabs(); showWelcome(); updateStatus() }
        } else { renderTabs() }
    }

    @objc func save() { if let current { _ = saveDocument(current) } }
    @objc func saveAs() { if let current { _ = saveDocument(current,asCopy:true) } }
    @discardableResult func saveDocument(_ doc: OpenDocument, asCopy: Bool = false) -> Bool {
        guard doc.previewURL == nil else { return true }
        autoSaveWork.removeValue(forKey:doc.buffer.id)?.cancel()
        guard !autoSaving.contains(doc.buffer.id) else { status.stringValue = L.text("Saving changes…"); return false }
        if let remote = doc.remote,!asCopy {
            guard !isMutatingRemote(remote.path,host:remote.connection.host) else { return false }
            do {
                let data = try doc.buffer.dataForSaving()
                try RemoteProgress.perform("Saving remote file…") { try remote.save(data) }
                try doc.buffer.save(); try recovery.remove(doc.buffer.id)
                codeDocumentSaved(doc); renderTabs(); updateStatus(); return true
            } catch { show(error); return false }
        }
        var destination: URL?
        if doc.buffer.url == nil || asCopy {
            let p = Theme.savePanel(); p.nameFieldStringValue = doc.displayName
            guard p.runModal() == .OK, let url = p.url else { return false }; destination = url
        }
        do {
            try doc.buffer.save(to:destination); try recovery.remove(doc.buffer.id)
            if asCopy { doc.remote = nil }
            codeDocumentSaved(doc); renderTabs(); updateStatus(); return true
        } catch { show(error); return false }
    }
    func mayClose(_ doc: OpenDocument) -> Bool {
        guard !autoSaving.contains(doc.buffer.id) else { status.stringValue = L.text("Saving changes…"); return false }
        guard doc.buffer.isModified else { return true }
        let a = ThemedAlert(); a.messageText = L.format("Save changes to %@?",doc.buffer.displayName); a.informativeText = L.text("Your changes will be lost if you discard them.")
        a.addButton(withTitle:L.text("Save")); a.addButton(withTitle:L.text("Cancel")); a.addButton(withTitle:L.text("Discard"))
        switch a.runModal() { case .alertFirstButtonReturn: return saveDocument(doc); case .alertThirdButtonReturn: return true; default: return false }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { autoSaveWork.values.forEach { $0.cancel() }; autoSaveWork.removeAll(); return documents.allSatisfy(mayClose) && mayCloseTerminal() && mayCloseAgents() }
    func mayCloseTerminal() -> Bool {
        if gitWorkspaceView?.running == true {
            let alert = ThemedAlert(); alert.messageText = L.text("Finish the current Git operation first.")
            alert.informativeText = L.text("Close the interactive Git console with Stop Console, or wait for the operation to finish.")
            alert.runModal(); return false
        }
        if let runWorkspaceView,!runWorkspaceView.mayClose() { return false }
        guard terminal?.process.running == true else { return true }
        let alert = ThemedAlert(); alert.messageText = L.text("Close this terminal session?"); alert.informativeText = L.text("The shell and its running processes will be stopped.")
        alert.addButton(withTitle:L.text("Close Session")); alert.addButton(withTitle:L.text("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    func terminateTerminal() {
        gitWorkspaceView?.shutdown()
        runWorkspaceView?.shutdown()
        guard let terminal else { return }
        let process = terminal.process!
        if process.running {
            let foreground = tcgetpgrp(process.childfd)
            if foreground > 0 && foreground != getpgrp() { kill(-foreground,SIGHUP) }
            let shell = process.shellPid
            if shell > 0 && shell != getpgrp() { kill(-shell,SIGHUP) }
        }
        terminal.terminate()
    }
    func windowWillClose(_ notification: Notification) {
        persistWorkspaceTabs()
        shutdownAgent(); agentWorkspace = nil; agentWorkspaces.removeAll()
        stopPlugins(); managedPluginLoad = UUID()
        pluginWindows.removeValue(forKey:"manager")?.close()
        picker?.dismiss(); picker = nil
        window?.undoManager?.removeAllActions(withTarget:self)
        completionPanel?.dismiss(); hoverPopover?.close(); languageServices.stop()
        languageQueries.values.forEach { $0.cancel() }; languageSyncs.values.forEach { $0.cancel() }; languageEdits.values.forEach { $0.cancel() }; languageDiagnostics.values.forEach { $0.cancel() }; autoSaveWork.values.forEach { $0.cancel() }
        terminateTerminal(); recoveryTimer?.invalidate()
        for d in documents { try? recovery.remove(d.buffer.id) }
    }
    func persistWorkspaceTabs() {
        let workspace: WorkspaceSession
        if let remoteConnection { workspace = .ssh(host:remoteConnection.host,path:remoteDirectory) }
        else if let root { workspace = .local(path:root.url.path) }
        else { return }
        func path(_ document: OpenDocument) -> String? {
            switch workspace {
            case .local:
                guard document.remote == nil,let path = document.fileURL?.path,path.hasPrefix(workspace.path+"/") else { return nil }
                return path
            case .ssh(let host,_):
                guard let remote = document.remote,remote.connection.host == host,remote.path.hasPrefix(workspace.path+"/") else { return nil }
                return remote.path
            }
        }
        let paths = documents.compactMap(path)
        let active = current.flatMap(path)
        var retained = Array(paths.prefix(WorkspaceTabs.limit))
        if let active,!retained.contains(active),!retained.isEmpty { retained.removeLast(); retained.append(active) }
        WorkspaceTabs(workspace:workspace,paths:retained,active:active).save()
    }

    func restoreTabs(_ snapshot: WorkspaceTabs) {
        let project = root, connection = remoteConnection
        let token = latestOpenRequest
        let previous = current
        let generation = tabRestoreGeneration
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            var seen = Set<String>()
            let restored: [(String,OpenDocument)] = snapshot.paths.prefix(WorkspaceTabs.limit).compactMap { path in
                guard path.hasPrefix("/"),seen.insert(path).inserted else { return nil }
                let document: OpenDocument?
                if let connection { document = try? Self.loadRemoteDocument(path,connection:connection) }
                else {
                    let url = URL(fileURLWithPath:path)
                    guard (try? url.resourceValues(forKeys:[.isRegularFileKey,.isPackageKey])).map({ $0.isRegularFile == true || $0.isPackage == true }) == true else { return nil }
                    document = try? OpenDocument.load(url)
                }
                return document.map { (path,$0) }
            }
            DispatchQueue.main.async {
                guard let self,self.window?.isVisible == true,self.root === project,self.tabRestoreGeneration == generation,
                      self.remoteConnection?.host == connection?.host,
                      connection == nil || self.remoteDirectory == snapshot.workspace.path else { return }
                let opened = Set(self.documents.compactMap { $0.remote?.path ?? $0.fileURL?.path })
                let additions = restored.filter { !opened.contains($0.0) }
                self.documents.append(contentsOf:additions.map(\.1))
                let preferred = self.documents.first { document in
                    guard let active = snapshot.active else { return false }
                    if let connection { return document.remote?.connection.host == connection.host && document.remote?.path == active }
                    return document.remote == nil && document.fileURL?.path == active
                }
                if self.current === previous,self.latestOpenRequest == token,
                   let selected = preferred ?? additions.last?.1 {
                    self.activate(selected)
                } else { self.renderTabs() }
            }
        }
    }

    func persistRecovery() {
        do { for d in documents where d.buffer.isModified { try recovery.write(d.buffer) } }
        catch { if !recoveryErrorShown { recoveryErrorShown = true; show(error) } }
    }
    func restore(recoverDrafts: Bool = true) {
        guard WorkspaceSession.shouldRestore else { return }
        if let location = WorkspaceSession.load() { openRecentProject(location,restoreSavedTabs:recoverDrafts) }
        guard recoverDrafts else { return }
        do {
            for entry in try recovery.entries() {
                // Recovered content stays an untitled copy so a changed disk file cannot be overwritten.
                activate(OpenDocument(DocumentBuffer(text:entry.text,id:entry.id)))
            }
        } catch { show(error) }
    }

    func updateStatus() {
        guard let current else { status.stringValue = L.text("Development preview"); breadcrumb.stringValue = ""; previewButton.isHidden = true; markdownView = nil; return }
        breadcrumb.stringValue = current.remote.map { $0.connection.host+":"+$0.path } ?? current.displayName; previewButton.isHidden = !current.supportsPreview
        let previewHelp = L.text(current.markdownPreview ? "Hide Preview" : "Preview")
        previewButton.image = NSImage(systemSymbolName:current.markdownPreview ? "doc.plaintext" : "eye",accessibilityDescription:nil)
        previewButton.setAccessibilityLabel(previewHelp)
        previewButton.toolTip = previewHelp + " · ⇧⌘V"
        if let url = current.previewURL {
            status.stringValue = L.text(FilePreview.kind(for:url) == .image ? "Image preview · Read only" : "File preview · Read only")
            modeLabel.stringValue = L.text(FilePreview.kind(for:url) == .pdf ? "PDF" : FilePreview.kind(for:url) == .image ? "IMAGE" : "PREVIEW"); return
        }
        let p = min(activePane?.textView.selectedRange().location ?? 0,current.buffer.text.utf16.count)
        let row = current.lines.line(at:p),start = current.lines.starts[row]
        let line = row+1,column = (current.buffer.text as NSString).substring(with:NSRange(location:start,length:p-start)).count+1
        status.stringValue = L.format("Ln %d, Col %d     %@     %d pt",line,column,current.buffer.formatLabel,Int(Theme.fontSize))
        if current.externalChange { status.stringValue += " · "+L.text("Changed on disk · unsaved edits kept") }
        modeLabel.stringValue = vimEnabled ? L.text(current.vim.mode.rawValue) + (current.vim.pending.isEmpty ? "" : "  \(current.vim.pending)") : L.text("TEXT")
        if vimEnabled,let recording = current.vim.recordingRegister { modeLabel.stringValue += "  ● @"+recording }
    }
    @objc func toggleVim() {
        vimEnabled.toggle(); UserDefaults.standard.set(vimEnabled,forKey:"vimEnabled")
        panes.forEach { $0.textView.vimEnabled = vimEnabled; $0.document.vim.escape(); $0.textView.needsDisplay = true }; updateStatus()
        PreferencesSync.shared.changed()
    }
    @objc func toggleSidebar() { sidebar.isHidden.toggle(); body.adjustSubviews() }
    @objc func toggleSplit() {
        guard let current,current.previewURL == nil else { return }
        if current.markdownPreview { current.markdownPreview = false; activate(current); return }
        if panes.count > 1 { let last = panes.removeLast(); last.removeFromSuperview(); activePane = panes.first }
        else { editors.addArrangedSubview(makePane(current)); editors.setPosition(editors.bounds.width/2,ofDividerAt:0) }
        editors.adjustSubviews()
    }
    @objc func toggleMarkdownPreview() {
        guard let current,current.supportsPreview else { return }
        current.markdownPreview.toggle(); activate(current)
    }
    @objc func increaseFont() { Theme.fontSize += 1; PreferencesSync.shared.changed() }
    @objc func decreaseFont() { Theme.fontSize -= 1; PreferencesSync.shared.changed() }
    @objc func resetFont() { Theme.fontSize = Theme.defaultFontSize; PreferencesSync.shared.changed() }
    @objc func toggleWordWrap() { toggleEditorPreference("wordWrap") }
    @objc func toggleMinimap() { toggleEditorPreference("showMinimap") }
    private func toggleEditorPreference(_ key: String) {
        UserDefaults.standard.set(PreferencesSync.value(key) != "true",forKey:key)
        PreferencesSync.shared.changed()
    }
    @objc func promptGoToLine() {
        guard let pane = activePane, let window else { return }
        let alert = ThemedAlert()
        alert.messageText = L.text("Go to Line…")
        let field = NSTextField(string:String(pane.document.lines.line(at:pane.textView.selectedRange().location)+1))
        field.frame.size = NSSize(width:180,height:24)
        field.setAccessibilityLabel(L.text("Line number"))
        alert.accessoryView = field
        alert.addButton(withTitle:L.text("Go"))
        alert.addButton(withTitle:L.text("Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let line = Int(field.stringValue.trimmingCharacters(in:.whitespaces)),
                  line > 0 else { return }
            self?.goToLine(line)
        }
    }
    func applyTheme() {
        let selectedActivity = activeActivity
        window?.appearance = Theme.appearance
        if let view = window?.contentView { Theme.refreshViews(view) }
        if let editorCard { WorkspaceGlass.tintEditor(editorCard) }
        activity.layer?.backgroundColor = NSColor.clear.cgColor
        center.layer?.backgroundColor = NSColor.clear.cgColor
        if sidebarKind == "files" { sidebar.layer?.backgroundColor = NSColor.clear.cgColor }
        gitWorkspaceView?.refreshTheme()
        allAgentWorkspaces.forEach { $0.refreshTheme() }; runWorkspaceView?.refreshTheme(); remoteBrowser?.table.reloadData()
        panes.forEach { $0.updateTheme() }; outline.reloadData(); renderTabs()
        for (index,row) in tabs.arrangedSubviews.enumerated() where documents.indices.contains(index) {
            if let icon = (row as? NSStackView)?.arrangedSubviews.first as? NSImageView { icon.image = FileIcon.image(for:documents[index].fileURL); icon.contentTintColor = icon.image?.isTemplate == true ? Theme.secondary : nil }
        }
        pluginDataViews.values.forEach { $0.refreshAppearance() }; pluginWindows.values.forEach { $0.refreshAppearance() }; renderPluginStatus()
        if let terminal { configureTerminal(terminal) }
        if let current,let markdownView { markdownView.render(current.buffer.text) }
        if let search = sidebar.subviews.first as? ToolSidebar { search.table.reloadData() }
        else if sidebarKind != "files" { showSidebar(sidebarKind) }
        selectActivity(selectedActivity)
    }
    func relocalize() {
        if let view = window?.contentView { L.apply(to:view) }
        if editors.arrangedSubviews.first is WelcomeView { showWelcome() }
        outline.reloadData(); renderTabs()
        if current != nil { updateStatus() }
    }
    @objc func toggleTerminal() {
        if let host = terminalHost { host.isHidden.toggle(); content.adjustSubviews(); if !host.isHidden,let terminal { window?.makeFirstResponder(terminal) }; return }
        let host = Surface(Theme.canvas)
        host.translatesAutoresizingMaskIntoConstraints = false
        let title = Theme.label("TERMINAL",size:11,color:Theme.secondary,weight:.semibold)
        let bar = Theme.stack([title,NSView(),Theme.button("xmark",help:"Hide Terminal",target:self,action:#selector(toggleTerminal))]); bar.heightAnchor.constraint(equalToConstant:32).isActive = true
        let term = DisplayPacedTerminalView(frame:NSRect(x:0,y:0,width:900,height:220))
        configureTerminal(term)
        let stack = Theme.stack([bar,term],orientation:.vertical,spacing:4)
        Theme.pin(stack,in:host,inset:12)
        terminal = term; terminalHost = host; content.addArrangedSubview(host)
        let savedHeight = UserDefaults.standard.double(forKey:"terminalHeight")
        content.setPosition(max(120,content.bounds.height-(savedHeight > 100 ? savedHeight : 270)),ofDividerAt:0)
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"; env["TERM_PROGRAM"] = "Linvell"
        let shell = env["SHELL"] ?? "/bin/zsh"
        if let remote = remoteConnection {
            let command = RunTasks.remoteShell(directory:remoteDirectory)
            term.startProcess(executable:"/usr/bin/ssh",args:["-tt","--",remote.host,command],environment:env.map { "\($0.key)=\($0.value)" },currentDirectory:FileManager.default.homeDirectoryForCurrentUser.path)
        } else {
            term.startProcess(executable:shell,args:["-l"],environment:env.map { "\($0.key)=\($0.value)" },currentDirectory:root?.url.path ?? FileManager.default.homeDirectoryForCurrentUser.path)
        }
        window?.makeFirstResponder(term)
    }
    private func configureTerminal(_ terminal: LocalProcessTerminalView) {
        let editorFont = Theme.editorFont
        terminal.font = editorFont.isFixedPitch ? editorFont : .monospacedSystemFont(ofSize:Theme.fontSize,weight:.regular)
        terminal.nativeBackgroundColor = Theme.canvas; terminal.nativeForegroundColor = Theme.foreground
        terminal.clipsToBounds = true; terminal.caretColor = Theme.accent; terminal.caretTextColor = Theme.canvas; terminal.caretViewTracksFocus = true
        let colors: [UInt32] = Theme.isDark
            ? [0x27323B,0xED8796,0x8BD5A2,0xEED49F,0x8AADF4,0xC6A0F6,0x8BD5CA,0xCAD3F5,0x6E7B8A,0xF5A2AF,0xA6DA95,0xF5D8A6,0xA5C3FF,0xD5B2FF,0x9EE4DB,0xEFF4FF]
            : [0x35443F,0xB33245,0x247A4F,0x946300,0x245BC5,0x8251A3,0x187583,0xCBD5D0,0x657C71,0xCF3B50,0x34824D,0x956919,0x326BD4,0x985AB3,0x1B8791,0xFCFDFD]
        terminal.installColors(colors.map { value in SwiftTerm.Color(red:UInt16((value>>16)&255)*257,green:UInt16((value>>8)&255)*257,blue:UInt16(value&255)*257) })
    }

    @objc func find() {
        if let git = gitWorkspaceView,editors.arrangedSubviews.first === git { git.focusHistorySearch() }
        else { activePane?.textView.performFindPanelAction(menuItem(tag:Int(NSFindPanelAction.showFindPanel.rawValue))) }
    }
    private func menuItem(tag: Int) -> NSMenuItem { let item = NSMenuItem(); item.tag = tag; return item }
    @objc func selectNextOccurrence() {
        guard let v = activePane?.textView else { return }
        if v.selectedRange().length == 0 { v.selectWord(nil); return }
        let ns = v.string as NSString, selected = v.selectedRange(), word = ns.substring(with:selected)
        let end = v.editingSelections.map { NSMaxRange($0) }.max() ?? NSMaxRange(selected)
        var range = ns.range(of:word,range:NSRange(location:end,length:ns.length-end))
        if range.location == NSNotFound { range = ns.range(of:word,range:NSRange(location:0,length:selected.location)) }
        if range.location != NSNotFound && !v.editingSelections.contains(range) {
            v.setSelections(v.editingSelections+[range]); v.scrollRangeToVisible(range)
        }
    }
    @objc func skipOccurrence() {
        guard let v = activePane?.textView,v.selectedRange().length > 0 else { return }
        var ranges = v.editingSelections
        guard let skipped = ranges.popLast() else { return }
        let ns = v.string as NSString,word = ns.substring(with:skipped),end = NSMaxRange(skipped)
        var next = ns.range(of:word,range:NSRange(location:end,length:ns.length-end))
        if next.location == NSNotFound { next = ns.range(of:word,range:NSRange(location:0,length:skipped.location)) }
        if next.location != NSNotFound,!ranges.contains(next) { v.setSelections(ranges+[next]); v.scrollRangeToVisible(next) }
    }
    @objc func selectAllOccurrences() {
        guard let v = activePane?.textView else { return }
        if v.selectedRange().length == 0 { v.selectWord(nil) }
        let ns = v.string as NSString,selection = v.selectedRange()
        guard selection.length > 0 else { return }
        let word = ns.substring(with:selection); var matches: [NSRange] = [],offset = 0
        while offset < ns.length {
            let r = ns.range(of:word,range:NSRange(location:offset,length:ns.length-offset))
            if r.location == NSNotFound { break }; matches.append(r); offset = NSMaxRange(r)
        }
        v.setSelections(matches)
    }
    @objc func undoSelections() { activePane?.textView.undoSelection() }
    @objc func addCursorAbove() { addCursors(direction:-1) }
    @objc func addCursorBelow() { addCursors(direction:1) }
    private func addCursors(direction: Int) {
        guard let v = activePane?.textView,let current else { return }
        let ns = v.string as NSString,index = current.lines
        var ranges = v.editingSelections
        for selection in ranges {
            let cursor = NSMaxRange(selection),row = index.line(at:cursor),targetRow = row+direction
            guard targetRow >= 0,targetRow < index.starts.count else { continue }
            let end = targetRow+1 < index.starts.count ? index.starts[targetRow+1]-1 : ns.length
            var target = min(end,index.starts[targetRow]+cursor-index.starts[row])
            if target < ns.length { target = ns.rangeOfComposedCharacterSequence(at:target).location }
            ranges.append(NSRange(location:target,length:0))
        }
        v.setSelections(ranges)
    }
    @objc func splitSelectionIntoLines() {
        guard let v = activePane?.textView,let current else { return }
        let index = current.lines,ns = v.string as NSString
        var carets: [NSRange] = []
        for selection in v.editingSelections {
            let first = index.line(at:selection.location),last = index.line(at:max(selection.location,NSMaxRange(selection)-1))
            for line in first...last {
                let end = line+1 < index.starts.count ? index.starts[line+1]-1 : ns.length
                carets.append(NSRange(location:min(end,NSMaxRange(selection)),length:0))
            }
        }
        v.setSelections(carets)
    }
    @objc func selectCurrentLine() {
        guard let v = activePane?.textView,let current else { return }
        let row = current.lines.line(at:v.selectedRange().location),start = current.lines.starts[row]
        let end = row+1 < current.lines.starts.count ? current.lines.starts[row+1] : current.storage.length
        v.setSelections([NSRange(location:start,length:end-start)])
    }
    private func searchOverrides(root: String,host: String?) -> [URL:String] {
        var overrides: [URL:String] = [:]
        for doc in documents where doc.buffer.isModified && doc.remote?.connection.host == host {
            guard let path = doc.remote?.path ?? doc.fileURL?.path,ExplorerActions.relative(path,under:root) != nil else { continue }
            overrides[URL(fileURLWithPath:path)] = doc.buffer.text
        }
        return overrides
    }

    private func selectSearchMatch(_ match: ToolSidebar.Match) {
        goToLine(match.line)
        guard let pane = activePane,pane.document.lines.starts.indices.contains(match.line-1) else { return }
        let start = pane.document.lines.starts[match.line-1]
        let next = match.line < pane.document.lines.starts.count ? pane.document.lines.starts[match.line] : pane.document.storage.length
        let source = pane.document.storage.string as NSString
        guard next >= start,NSMaxRange(match.range) <= next-start else { return }
        if let original = match.originalLine,
           source.substring(with:NSRange(location:start,length:next-start)).trimmingCharacters(in:.newlines) != original { return }
        let range = NSRange(location:start+match.range.location,length:match.range.length)
        pane.textView.setSelectedRange(range)
        pane.textView.scrollRangeToVisible(range)
    }

    @objc func projectSearch() {
        if sidebarKind != "search" || sidebar.isHidden { showSidebar("search") }
        if let search = sidebar.subviews.first(where:{ $0 is ToolSidebar }) as? ToolSidebar { window?.makeFirstResponder(search.query) }
    }
    @objc func documentSymbols() { showSymbols() }
    @objc func replaceInFile() { activePane?.textView.performFindPanelAction(menuItem(tag:Int(NSTextFinder.Action.showReplaceInterface.rawValue))) }
    @objc func showExplorer() { if sidebarKind != "files" || sidebar.isHidden { showSidebar("files") } }

    func indexProjectFiles(_ project: FileNode) {
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let files = ProjectFiles.list(project.url),quick = ProjectFiles.searchable(project.url)
            DispatchQueue.main.async {
                guard let self,self.root === project else { return }
                self.fileIndex = files; self.quickFileIndex = quick
                if self.isFilteringFiles { self.filterChanged() }
            }
        }
    }
    @objc func refreshFiles() {
        if let remoteBrowser { remoteBrowser.reload(); return }
        guard let project = root else { return }
        updateExternalDirectory(project,children:FileNode(project.url).children)
        updateIgnoredFiles(for:project)
        indexProjectFiles(project)
    }
    @objc func focusFileFilter() {
        if remoteConnection != nil {
            showExplorer()
            if let field = remoteBrowser?.filter { window?.makeFirstResponder(field) }
            return
        }
        guard root != nil else { return }
        if sidebarKind != "files" || sidebar.isHidden { showSidebar("files") }
        window?.makeFirstResponder(search)
    }
    @objc private func filterChanged() {
        let query = search.stringValue.trimmingCharacters(in:.whitespaces)
        if let root, !query.isEmpty {
            let urls = fileIndex.lazy.filter {
                ProjectFiles.relative($0,root:root.url).localizedCaseInsensitiveContains(query)
            }.prefix(500)
            fileMatches = FileNode.filteredTree(Array(urls),under:root.url)
        } else {
            fileMatches = []
        }
        outline.reloadData()
        if !query.isEmpty { outline.expandItem(nil,expandChildren:true) }
    }
    private var isFilteringFiles: Bool { !search.stringValue.trimmingCharacters(in:.whitespaces).isEmpty }
    private var filtered: [FileNode] { isFilteringFiles ? fileMatches : (root?.children ?? []) }
    func outlineView(_ outlineView: NSOutlineView,numberOfChildrenOfItem item: Any?) -> Int { (item as? FileNode)?.children.count ?? filtered.count }
    func outlineView(_ outlineView: NSOutlineView,child index: Int,ofItem item: Any?) -> Any { (item as? FileNode)?.children[index] ?? filtered[index] }
    func outlineView(_ outlineView: NSOutlineView,isItemExpandable item: Any) -> Bool { (item as? FileNode)?.isDirectory == true }
    func outlineView(_ outlineView: NSOutlineView,viewFor tableColumn: NSTableColumn?,item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let title = node.url.lastPathComponent
        let label = Theme.label(title,size:12,color:Theme.foreground)
        label.lineBreakMode = .byTruncatingMiddle
        if isFilteringFiles,let match = title.range(of:search.stringValue.trimmingCharacters(in:.whitespaces),options:[.caseInsensitive,.diacriticInsensitive]) {
            let styled = NSMutableAttributedString(string:title,attributes:[.font:label.font ?? NSFont.systemFont(ofSize:12),.foregroundColor:Theme.liveForeground])
            styled.addAttribute(.foregroundColor,value:Theme.liveAccent,range:NSRange(match,in:title))
            label.attributedStringValue = styled
        }
        let image = FileIcon.view(for:node.url,folder:node.isDirectory,expanded:outlineView.isItemExpanded(node))
        let row = Theme.stack([image,label],spacing:8)
        row.alphaValue = isIgnored(node) ? 0.55 : 1
        return row
    }
    @objc private func fileClicked() {
        guard outline.clickedRow >= 0,let node = outline.item(atRow:outline.clickedRow) as? FileNode else { return }
        if node.isDirectory { if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) } }
        else { open(node.url) }
    }
    func show(_ error: Error) { let alert = Theme.errorAlert(error); alert.messageText = L.text(alert.messageText); alert.informativeText = L.text(alert.informativeText); if let window { alert.beginSheetModal(for:window) } }

    func quickFileLocation(_ document: OpenDocument) -> WorkspaceSession? {
        if let remote = document.remote { return .ssh(host:remote.connection.host,path:remote.path) }
        return document.fileURL.map { .local(path:$0.path) }
    }
    @objc func quickOpen() {
        if let connection = remoteConnection { quickOpenRemote(connection); return }
        guard let root else { openFile(); return }
        let recent = recentQuickFiles.compactMap { location -> URL? in
            guard case .local(let path) = location,FileManager.default.fileExists(atPath:path),
                  ExplorerActions.relative(path,under:root.url.path) != nil else { return nil }
            return URL(fileURLWithPath:path)
        }
        var seen = Set<URL>()
        let urls = (recent+quickFileIndex.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }).filter { seen.insert($0).inserted }
        let options = urls.map { url in
            var option = PickerOption(title:url.lastPathComponent,detail:ProjectFiles.relative(url,root:root.url),fileURL:url,invoke:{ [weak self] in self?.openFromFilePicker(url,line:nil) })
            option.openAtLine = { [weak self] line in self?.openFromFilePicker(url,line:line) }
            return option
        }
        presentQuickFiles(options)
    }

    func revealLocalFile(_ url: URL) {
        guard let root,let relative = ExplorerActions.relative(url.path,under:root.url.path),!isFilteringFiles else { return }
        let components = relative.split(separator:"/")
        var node = root
        for (index,name) in components.enumerated() {
            guard let child = node.children.first(where:{ $0.url.lastPathComponent == name }) else { return }
            node = child
            if index < components.count-1 { outline.expandItem(node) }
        }
        let row = outline.row(forItem:node)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        outline.scrollRowToVisible(row)
    }

    private func openFromFilePicker(_ url: URL,line: Int?) {
        open(url) { [weak self] in
            self?.revealLocalFile(url)
            if let line { self?.goToLine(line) }
        }
    }

    func presentQuickFiles(_ options: [PickerOption]) {
        if let picker,picker.window?.sheetParent != nil,picker.goToCurrentLine != nil {
            picker.dismiss(); self.picker = nil; return
        }
        guard let window else { return }
        let panel = QuickPicker(title:L.text("Search files by name or file:line"),options:options,owner:window,compact:true)
        panel.goToCurrentLine = { [weak self] in self?.goToLine($0) }
        picker = panel
    }
    @objc func commandPalette() {
        var options: [PickerOption] = []
        for (title,selector) in [("New File",#selector(newFile)),("Open Folder…",#selector(openFolder)),("Connect to SSH Host…",#selector(connectSSH)),("Go to Definition",#selector(definitionCommand)),("Find All References",#selector(findReferences)),("Rename Symbol…",#selector(renameSymbol)),("Language Tools…",#selector(showLanguageTools)),("Go Back",#selector(goBack)),("Go Forward",#selector(goForward)),("Source Control",#selector(gitWorkspace)),("Git Commit Graph",#selector(showGitCommitGraph)),("Run & Preview",#selector(runWorkspace)),("Find in File",#selector(find)),("Toggle Vim Mode",#selector(toggleVim)),("Split Editor",#selector(toggleSplit)),("Toggle Terminal",#selector(toggleTerminal)),("Agents",#selector(showAgents)),("Increase Font Size",#selector(increaseFont)),("Decrease Font Size",#selector(decreaseFont))] {
            options.append(PickerOption(title:title,detail:"Linvell command",invoke:{ [weak self] in self?.perform(selector) }))
        }
        for (title,action) in [("New Task Workspace…",#selector(newAgentTask)),("Task Workspaces…",#selector(showAgentTasks)),("Add Review Comment…",#selector(addCurrentReview)),("Review Comments…",#selector(showReviewComments))] {
            options.append(PickerOption(title:L.text(title),detail:"Linvell",invoke:{ [weak self] in self?.perform(action) }))
        }
        options.append(PickerOption(title:L.text("Preferences: Theme and Font"),detail:"Appearance",invoke:{ [weak self] in self?.showSettings() }))
        options.append(PickerOption(title:L.text("Load Development Plugin…"),detail:"Linvell",invoke:{ [weak self] in self?.loadDevelopmentPlugin() }))
        options.append(PickerOption(title:L.text("Stop Plugins"),detail:"Linvell",invoke:{ [weak self] in self?.stopPlugins() }))
        options += pluginCommandOptions()
        picker = QuickPicker(title:L.text("Search commands"),options:options,owner:window!)
    }
    private func showEx(_ prefix: String = ":") {
        let alert = ThemedAlert(); alert.messageText = L.text("Vim command"); alert.informativeText = L.text("Search with / or ?, substitute with :s or :%s, or use :w, :q, :wq and :set number.")
        let field = NSTextField(string:prefix); field.frame = NSRect(x:0,y:0,width:340,height:28); field.font = .monospacedSystemFont(ofSize:15,weight:.regular)
        alert.accessoryView = field; alert.addButton(withTitle:L.text("Run")); alert.addButton(withTitle:L.text("Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for:window!) { [weak self] response in
            guard response == .alertFirstButtonReturn,let self else { self?.current?.vim.cancelPendingCommand(); return }
            switch field.stringValue.trimmingCharacters(in:.whitespaces).trimmingCharacters(in:CharacterSet(charactersIn:":")) {
            case "w": self.save()
            case "q": self.closeCurrent()
            case "wq": if let doc = self.current,self.saveDocument(doc) { self.closeCurrent() }
            case "set number", "set nu": self.panes.forEach { $0.setLineNumbersVisible(true) }
            case "set nonumber", "set nonu": self.panes.forEach { $0.setLineNumbersVisible(false) }
            default:
                guard let pane = self.activePane else { return }
                let vim = pane.document.vim,view = pane.textView,command = field.stringValue
                vim.sync(text:view.string,cursor:view.selectedRange().location)
                do {
                    if command.hasPrefix("/") || command.hasPrefix("?") {
                        let found = try vim.search(String(command.dropFirst()),backwards:command.hasPrefix("?"))
                        if !found { throw VimCommandError.invalid("Pattern not found.") }
                    } else { try vim.executeEx(command) }
                    let at = vim.cursor
                    if vim.changed,view.shouldChangeText(in:NSRange(location:0,length:view.string.utf16.count),replacementString:vim.text) {
                        view.applyingVim = true
                        view.textStorage?.replaceCharacters(in:NSRange(location:0,length:view.string.utf16.count),with:vim.text)
                        view.didChangeText(); view.applyingVim = false
                    }
                    view.setSelectedRange(NSRange(location:min(at,view.string.utf16.count),length:0)); view.scrollRangeToVisible(view.selectedRange()); self.updateStatus()
                } catch { self.show(error) }
            }
        }
    }
}
