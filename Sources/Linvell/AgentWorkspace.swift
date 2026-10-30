import AppKit
import SwiftTerm
import LinvellCore
import Darwin

/// Native controls around the providers' own interactive CLIs. No model runtime.
final class AgentWorkspace: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, LocalProcessTerminalViewDelegate {
    let configurationView = NSView()
    var onStart: (() -> Void)?
    var onOpenFile: ((String, SSHRemote?, Int?) -> Void)?
    let openSessions = NSPopUpButton()
    let openFile = NSButton()
    let settingsToggle = NSButton()
    private let configurationDetails = NSStackView()
    private(set) var runtimes: [AgentRuntime] = []
    private(set) var activeRuntime: AgentRuntime?
    let project: String
    let remote: SSHRemote?
    let kindPicker = NSPopUpButton(),installationsPicker = NSPopUpButton()
    let location = NSSegmentedControl(labels:[L.text("This Mac"),L.text("SSH Host")],trackingMode:.selectOne,target:nil,action:nil)
    let path = NSTextField(),agentHome = NSTextField(),search = NSSearchField(),task = NSTextField()
    let table = ResponsiveTableView(),terminalHost = NSView()
    let historyStatus = Theme.label("",size:11,color:Theme.secondary)
    let status = Theme.label("",size:12,color:Theme.secondary)
    let scope = Theme.label("",size:12,color:Theme.secondary)
    let mappingLabel = Theme.label("",size:11,color:Theme.secondary)
    let mappingRow = NSStackView()
    let refresh = NSButton(),newSession = NSButton(),resume = NSButton(),stop = NSButton(),browse = NSButton(),mount = NSButton(),chooseMount = NSButton()
    var installations: [AgentInstallation] = []
    var sessions: [AgentSession] = []
    var filtered: [AgentSession] = []
    var mapping: AgentPathMapping?
    var terminal: LocalProcessTerminalView? { activeRuntime?.terminal }
    private(set) var generation = UUID()
    private var loading = false
    private var mounting = false
    private var selectionMessage: String?
    private struct Channel: Hashable { let kind: AgentKind; let host: String? }
    private var lastActive: [Channel:AgentRuntime] = [:]
    let mountGuide = AgentMountGuide()
    private let emptyState = NSView()
    private let emptyMessage = Theme.label("",size:14,color:Theme.secondary)
    private var selectedChannel: Channel { Channel(kind:kind,host:usesSSH ? remote?.host : nil) }
    private func channel(of runtime: AgentRuntime) -> Channel { Channel(kind:runtime.context.kind,host:runtime.context.host) }
    var kind: AgentKind { AgentKind.allCases[max(0,kindPicker.indexOfSelectedItem)] }
    var usesSSH: Bool { remote != nil && location.selectedSegment == 1 }
    var running: Bool { runtimes.contains { $0.terminal.process.running } }
    private var executionDirectory: String? { usesSSH || remote == nil ? project : mapping?.localRoot }
    private var settingsKey: String { "agentCLI."+(usesSSH ? remote!.host : "local")+"."+kind.rawValue }
    private var mappingKey: String { "agentMapping."+(remote?.host ?? "")+":"+project }

    init(project: String,remote: SSHRemote?,autoLoad: Bool = true) {
        self.project = project; self.remote = remote
        super.init(frame:NSRect(x:0,y:0,width:800,height:600))
        wantsLayer = true; layer?.backgroundColor = Theme.canvas.cgColor
        appearance = NSAppearance(named:Theme.isDark ? .darkAqua : .aqua)
        kindPicker.addItems(withTitles:AgentKind.allCases.map(\.title)); kindPicker.target = self; kindPicker.action = #selector(selectionChanged)
        kindPicker.widthAnchor.constraint(equalToConstant:170).isActive = true
        kindPicker.setAccessibilityLabel(L.text("Agent"))
        location.selectedSegment = remote == nil ? 0 : 1; location.isHidden = remote == nil
        location.target = self; location.action = #selector(selectionChanged)
        location.setAccessibilityLabel(L.text("Agent execution location"))
        installationsPicker.target = self; installationsPicker.action = #selector(installationChanged)
        installationsPicker.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        path.placeholderString = L.text("Agent CLI executable path"); path.delegate = self; path.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        path.setAccessibilityLabel(L.text("Agent CLI executable path"))
        agentHome.placeholderString = L.text("Agent home (optional)"); agentHome.delegate = self
        scope.lineBreakMode = .byTruncatingMiddle; mappingLabel.lineBreakMode = .byTruncatingMiddle
        agentHome.toolTip = L.text("Use the same agent home as your CLI or desktop app. Leave empty for the default.")
        search.placeholderString = L.text("Search sessions"); search.delegate = self
        historyStatus.maximumNumberOfLines = 3; historyStatus.lineBreakMode = .byWordWrapping; historyStatus.isHidden = true
        task.placeholderString = L.text("DSH task — each run continues the selected session for one task"); task.delegate = self
        func button(_ button: NSButton,_ title: String,_ action: Selector) { button.title = L.text(title); button.target = self; button.action = action; button.bezelStyle = .rounded }
        button(refresh,"Refresh",#selector(reload)); button(newSession,"New Session",#selector(startNew)); button(resume,"Resume Session",#selector(resumeSelected)); button(stop,"Stop",#selector(stopAgent))
        button(browse,"Choose CLI…",#selector(chooseCLI)); button(mount,"Mount SSH Folder…",#selector(mountProject)); button(chooseMount,"Choose Mount…",#selector(selectMount))
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("agentSessions")); table.addTableColumn(column); table.headerView = nil
        table.delegate = self; table.dataSource = self; table.rowHeight = 54; table.backgroundColor = Theme.panel
        table.target = self; table.doubleAction = #selector(resumeSelected); table.setAccessibilityLabel(L.text("Project agent sessions"))
        let scroll = ResponsiveScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:180).isActive = true
        mappingRow.orientation = .vertical; mappingRow.alignment = .leading; mappingRow.spacing = 8
        [mappingLabel,mount,chooseMount].forEach { mappingRow.addArrangedSubview($0) }
        path.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        path.lineBreakMode = .byTruncatingMiddle
        let heading = Theme.stack([Theme.label("AGENTS",size:11,weight:.semibold),NSView(),refresh],spacing:8)
        settingsToggle.title = L.text("Agent Settings"); settingsToggle.bezelStyle = .rounded
        settingsToggle.setButtonType(.pushOnPushOff); settingsToggle.target = self; settingsToggle.action = #selector(toggleSettings)
        configurationDetails.orientation = .vertical; configurationDetails.alignment = .leading; configurationDetails.spacing = 8
        [installationsPicker,Theme.stack([path,browse],spacing:6),agentHome].forEach { configurationDetails.addArrangedSubview($0) }
        configurationDetails.isHidden = true
        let rows: [NSView] = [heading,location,kindPicker,newSession,task,mappingRow,search,historyStatus,scroll,resume,settingsToggle,configurationDetails]
        let configuration = Theme.stack(rows,orientation:.vertical,spacing:10)
        let outer = ResponsiveScrollView(); outer.hasVerticalScroller = true; outer.drawsBackground = false
        let document = AgentConfigurationDocument(); document.translatesAutoresizingMaskIntoConstraints = false; outer.documentView = document
        Theme.pin(outer,in:configurationView); Theme.pin(configuration,in:document,inset:16)
        document.widthAnchor.constraint(equalTo:outer.contentView.widthAnchor).isActive = true
        document.heightAnchor.constraint(greaterThanOrEqualTo:outer.contentView.heightAnchor).isActive = true
        scope.lineBreakMode = .byTruncatingMiddle; status.lineBreakMode = .byTruncatingMiddle
        button(openFile,"Open Selected File",#selector(openSelectedFile))
        openFile.toolTip = L.text("Select a file path in the terminal to open it in this workspace. Command-click terminal links to open them directly.")
        openSessions.target = self; openSessions.action = #selector(selectOpenSession)
        openSessions.setAccessibilityLabel(L.text("Open agent sessions"))
        openSessions.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let mainHeading = Theme.stack([openSessions,NSView(),openFile,stop])
        Theme.pin(Theme.stack([mainHeading,scope,status,terminalHost],orientation:.vertical,spacing:12),in:self,inset:20)
        emptyMessage.maximumNumberOfLines = 0; emptyMessage.lineBreakMode = .byWordWrapping
        let emptyContent = Theme.stack([emptyMessage,mountGuide],orientation:.vertical,spacing:20)
        emptyContent.translatesAutoresizingMaskIntoConstraints = false; emptyState.addSubview(emptyContent)
        NSLayoutConstraint.activate([emptyContent.topAnchor.constraint(equalTo:emptyState.topAnchor,constant:24),emptyContent.leadingAnchor.constraint(equalTo:emptyState.leadingAnchor,constant:24),emptyContent.trailingAnchor.constraint(equalTo:emptyState.trailingAnchor,constant:-24)])
        mountGuide.onConnect = { [weak self] in self?.mountProject() }
        mountGuide.onRecheck = { [weak self] in self?.selectionMessage = nil; self?.reload(); self?.updateControls() }
        terminalHost.heightAnchor.constraint(greaterThanOrEqualToConstant:160).isActive = true
        restoreSettings(); display(nil); if autoLoad { reload() } else { updateControls() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { shutdown() }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let session = filtered[row]
        let title = Theme.label(session.title == session.id || session.title == "Untitled session" ? L.text("Untitled session") : session.title,size:13); title.lineBreakMode = .byTruncatingTail
        title.toolTip = session.title
        let date = Date(timeIntervalSince1970:session.updated).formatted(date:.abbreviated,time:.shortened)
        let detail = Theme.label(date+" · "+String(session.id.prefix(8))+(session.cwd == project ? "" : " · "+URL(fileURLWithPath:session.cwd).lastPathComponent),size:10,color:Theme.secondary); detail.lineBreakMode = .byTruncatingMiddle; detail.toolTip = session.cwd+"\n"+session.id
        let stack = NSStackView(views:[title,detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top:6,left:10,bottom:6,right:10)
        return stack
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === task { selectionMessage = nil; updateRuntimeControls() }
        else if notification.object as? NSSearchField === search { filterSessions() }
        else { generation = UUID(); loading = false; selectionMessage = nil; sessions = []; filterSessions() }
    }
    func controlTextDidEndEditing(_ notification: Notification) { if notification.object as? NSSearchField !== search,notification.object as? NSTextField !== task { saveSettings(); reload() } }
    @objc private func toggleSettings() { configurationDetails.isHidden = settingsToggle.state != .on }
    private func restoreSettings() {
        if mapping == nil,let data = UserDefaults.standard.data(forKey:mappingKey) { mapping = try? JSONDecoder().decode(AgentPathMapping.self,from:data) }
        path.stringValue = UserDefaults.standard.string(forKey:settingsKey+".path") ?? ""
        agentHome.stringValue = UserDefaults.standard.string(forKey:settingsKey+".home") ?? ""
        agentHome.isHidden = kind.homeVariable == nil
        task.isHidden = kind != .dsh
    }
    private func saveSettings() {
        UserDefaults.standard.set(path.stringValue,forKey:settingsKey+".path")
        UserDefaults.standard.set(agentHome.stringValue,forKey:settingsKey+".home")
    }
    @objc func selectionChanged() {
        generation = UUID(); loading = false; sessions = []; selectionMessage = nil
        restoreSettings()
        let channel = selectedChannel
        let selected = lastActive[channel] ?? runtimes.last(where:{ self.channel(of:$0) == channel })
        if let selected { path.stringValue = selected.context.executable; agentHome.stringValue = selected.context.home }
        display(selected)
        reload(); onStart?()
    }
    private func showSettings() { settingsToggle.state = .on; configurationDetails.isHidden = false }
    private var launchHint: String {
        if kind == .dsh,task.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return L.text("Enter a DSH task, then create or resume a session.") }
        if remote != nil,!usesSSH,mapping == nil { return L.text("Connect this SSH project before starting a local agent.") }
        if path.stringValue.isEmpty { return L.text("Choose an agent CLI in Agent Settings, then create a session.") }
        return L.text("No open session for this agent and location. Create a session or select one from the list.")
    }
    @objc private func installationChanged() {
        guard installations.indices.contains(installationsPicker.indexOfSelectedItem) else { return }
        path.stringValue = installations[installationsPicker.indexOfSelectedItem].path; saveSettings(); generation = UUID(); loading = false; reload()
    }
    private func updateControls() {
        [kindPicker,installationsPicker,location,path,agentHome,task,browse,mount,chooseMount].forEach { $0.isEnabled = true }
        mount.isEnabled = !mounting; chooseMount.isEnabled = !mounting; mountGuide.connect.isEnabled = !mounting
        refresh.isEnabled = !loading
        newSession.isEnabled = !(mounting && !usesSSH); newSession.toolTip = launchHint
        resume.isEnabled = !(mounting && !usesSSH) && filtered.indices.contains(table.selectedRow); stop.isEnabled = terminal?.process.running == true; openFile.isEnabled = terminal != nil
        browse.isHidden = usesSSH; mount.isHidden = remote == nil || usesSSH; chooseMount.isHidden = mount.isHidden
        mappingRow.isHidden = remote == nil || usesSSH
        mountGuide.isHidden = remote == nil || usesSSH
        scope.stringValue = activeRuntime.map { ($0.remote?.host ?? L.text("This Mac"))+" · "+$0.directory } ?? ((usesSSH ? remote!.host : L.text("This Mac"))+" · "+(executionDirectory ?? (L.text("Mount required")+" · "+project)))
        mappingLabel.stringValue = remote != nil && !usesSSH ? (mapping?.localRoot ?? L.text("Mount the SSH project to use a local agent.")) : ""
        emptyMessage.stringValue = mounting && !usesSSH ? L.text("Connecting project mount…") : (selectionMessage ?? launchHint)
        if mounting && !usesSSH { status.stringValue = L.text("Connecting project mount…") }
    }
    @objc func reload() {
        // Reopening the same window shares its pending CLI/session discovery.
        guard !loading else { return }
        let selectedID = filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow].id : nil
        let request = UUID(); generation = request; loading = true
        sessions = []; historyStatus.stringValue = L.text("Loading agent sessions…"); historyStatus.isHidden = false
        if activeRuntime == nil { status.stringValue = selectionMessage ?? L.text("Loading agent sessions…") }; filterSessions()
        let remote = usesSSH ? self.remote : nil,kind = kind,path = path.stringValue,home = agentHome.stringValue
        let project = executionDirectory,expectedMapping = self.remote != nil && !usesSSH ? mapping : nil
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { () throws -> ([AgentInstallation],[AgentSession]) in
                if let remote {
                    let snapshot = try remote.agentSnapshot(project:project ?? "~",kind:kind,executable:path.isEmpty ? nil : path,agentHome:home.isEmpty ? nil : home)
                    return (snapshot.installations.filter { $0.kind == kind },snapshot.sessions)
                }
                let found = AgentCLI.discover().filter { $0.kind == kind }
                guard let project else { return (found,[]) }
                try expectedMapping?.validate()
                var env = AgentCLI.environment
                if let variable = kind.homeVariable,!home.isEmpty { env[variable] = (home as NSString).expandingTildeInPath }
                let executable = path.isEmpty ? found.first?.path : (path as NSString).expandingTildeInPath
                let storage = AgentCLI.defaultStorage(kind,environment:env)
                return (found,try AgentCLI.sessions(kind:kind,project:project,storage:storage,executable:executable,environment:env))
            }
            DispatchQueue.main.async {
                guard let self,self.generation == request else { return }
                self.loading = false
                switch result {
                case .success(let (found,sessions)):
                    self.installations = found; self.installationsPicker.removeAllItems()
                    self.installationsPicker.addItems(withTitles:found.map { $0.source+" · "+$0.path })
                    if self.path.stringValue.isEmpty,let first = found.first { self.path.stringValue = first.path; self.saveSettings() }
                    if let index = found.firstIndex(where:{ $0.path == self.path.stringValue }) { self.installationsPicker.selectItem(at:index) }
                    self.sessions = sessions; self.filterSessions(select:selectedID)
                    self.historyStatus.stringValue = L.format("%d project sessions",sessions.count)
                    if self.activeRuntime == nil { self.status.stringValue = self.selectionMessage ?? self.historyStatus.stringValue }
                case .failure(let error):
                    self.historyStatus.stringValue = String(error.localizedDescription.prefix(240)); self.historyStatus.toolTip = error.localizedDescription
                    if self.activeRuntime == nil { self.status.stringValue = self.selectionMessage ?? error.localizedDescription }
                }
                self.updateControls()
            }
        }
    }
    private func filterSessions(select id: String? = nil) {
        let selectedID = id ?? (filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow].id : nil)
        let query = search.stringValue
        filtered = sessions.filter { query.isEmpty || ($0.title+" "+$0.id).localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if let selectedID,let index = filtered.firstIndex(where:{ $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
        else { table.deselectAll(nil) }
        updateControls()
    }
    @objc private func chooseCLI() {
        let panel = NSOpenPanel(); panel.message = L.text("Choose the agent executable or its desktop application.")
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        guard panel.runModal() == .OK,let url = panel.url else { return }
        if url.pathExtension == "app" {
            let found = AgentCLI.discover(applicationDirectories:[url.deletingLastPathComponent()]).filter { $0.kind == kind && $0.path.hasPrefix(url.path+"/") }
            guard let first = found.first else { status.stringValue = L.text("No supported CLI was found in this app. Choose its CLI executable directly."); return }
            path.stringValue = first.path
        } else {
            guard FileManager.default.isExecutableFile(atPath:url.path) else { status.stringValue = L.text("Choose an executable CLI file."); return }
            path.stringValue = url.path
        }
        saveSettings(); generation = UUID(); loading = false; reload()
    }
    @objc private func selectMount() {
        guard let remote else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.message = L.text("Choose the SSHFS mount of this remote project.")
        guard panel.runModal() == .OK,let url = panel.url else { return }
        let mapping = AgentPathMapping(host:remote.host,remoteRoot:project,localRoot:url.path)
        performMapping { try mapping.validate(); return mapping }
    }
    @objc private func mountProject() {
        guard let remote else { return }; let project = project
        performMapping { try AgentPathMapping.mount(remote:remote,directory:project) }
    }
    private func performMapping(_ work: @escaping () throws -> AgentPathMapping,completion: (() -> Void)? = nil) {
        guard !mounting else { return }; mounting = true
        let origin = selectedChannel
        status.stringValue = L.text("Connecting project mount…"); updateControls()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async {
                guard let self else { return }; self.mounting = false
                switch result {
                case .success(let mapping): self.mapping = mapping; UserDefaults.standard.set(try? JSONEncoder().encode(mapping),forKey:self.mappingKey); self.selectionMessage = nil; self.generation = UUID(); self.loading = false; self.reload(); completion?()
                case .failure(let error):
                    if self.selectedChannel == origin { self.selectionMessage = error.localizedDescription; self.status.stringValue = error.localizedDescription }; self.updateControls()
                }
            }
        }
    }
    @objc func startNew() { start(session:nil) }
    @objc func resumeSelected() { guard filtered.indices.contains(table.selectedRow) else { return }; start(session:filtered[table.selectedRow]) }
    private func matchingRuntime(_ session: AgentSession) -> AgentRuntime? {
        let executable = usesSSH ? path.stringValue : (path.stringValue as NSString).expandingTildeInPath
        let home = usesSSH ? agentHome.stringValue : (agentHome.stringValue as NSString).expandingTildeInPath
        let context = AgentRuntime.Context(kind:kind,host:usesSSH ? remote?.host : nil,executable:executable,home:home)
        return runtimes.first { $0.context == context && $0.sessionID == session.id && $0.terminal.process.running }
    }
    func start(session: AgentSession?) {
        if let session,let existing = matchingRuntime(session) { activate(existing); return }
        selectionMessage = nil
        if kind == .dsh,task.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            selectionMessage = L.text("Enter a DSH task, then create or resume a session.")
            status.stringValue = selectionMessage!; updateControls(); onStart?(); window?.makeFirstResponder(task); return
        }
        guard !path.stringValue.isEmpty else {
            selectionMessage = L.text("Choose an agent CLI in Agent Settings, then create a session.")
            showSettings(); status.stringValue = selectionMessage!; updateControls(); onStart?(); window?.makeFirstResponder(path); return
        }
        if let remote,!usesSSH,mapping == nil {
            let expectedKind = kind,expectedPath = path.stringValue,expectedHome = agentHome.stringValue,expectedTask = task.stringValue
            performMapping({ try AgentPathMapping.mount(remote:remote,directory:self.project) }) { [weak self] in
                guard let self,!self.usesSSH,self.kind == expectedKind,self.path.stringValue == expectedPath,
                      self.agentHome.stringValue == expectedHome,self.task.stringValue == expectedTask,
                      self.window != nil,self.configurationView.window != nil else { return }
                self.start(session:session)
            }
            onStart?(); return
        }
        guard let projectDirectory = executionDirectory else { return }
        let directory = session?.cwd ?? projectDirectory
        let task = kind == .dsh ? task.stringValue.trimmingCharacters(in:.whitespacesAndNewlines) : nil
        do {
            if remote != nil && !usesSSH { try mapping?.validate() }
            let executable = usesSSH ? path.stringValue : (path.stringValue as NSString).expandingTildeInPath
            guard executable.hasPrefix("/"),!executable.contains("\0") else { throw GitError.command("Choose an absolute agent CLI path.") }
            if !usesSSH,!FileManager.default.isExecutableFile(atPath:executable) { throw GitError.command("The agent CLI is unavailable.") }
            let home = usesSSH ? agentHome.stringValue : (agentHome.stringValue as NSString).expandingTildeInPath
            guard home.isEmpty || home.hasPrefix("/") else { throw GitError.command("Use an absolute agent home path.") }
            saveSettings()
            let context = AgentRuntime.Context(kind:kind,host:usesSSH ? remote?.host : nil,executable:executable,home:home)
            let term = DisplayPacedTerminalView(frame:terminalHost.bounds); term.processDelegate = self
            let runtime = AgentRuntime(context:context,session:session,directory:directory,remote:usesSSH ? remote : nil,mapping:usesSSH ? nil : mapping,terminal:term)
            register(runtime)
            term.font = .monospacedSystemFont(ofSize:Theme.fontSize,weight:.regular)
            term.nativeBackgroundColor = Theme.canvas; term.nativeForegroundColor = Theme.foreground; term.caretColor = Theme.accent
            activate(runtime,focus:false)
            var env = AgentCLI.environment; env["PATH"] = (executable as NSString).deletingLastPathComponent+":"+(env["PATH"] ?? "")
            if let variable = kind.homeVariable,!home.isEmpty { env[variable] = home }
            if usesSSH,let remote {
                var command = "PATH="+SSHRemote.quote((executable as NSString).deletingLastPathComponent)+":\"$PATH\"; export PATH; "
                if let variable = kind.homeVariable,!home.isEmpty { command += "export "+variable+"="+SSHRemote.quote(home)+"; " }
                command += "exec "+AgentCLI.command(executable:executable,kind:kind,session:session,task:task)
                term.startProcess(executable:"/usr/bin/ssh",args:["-tt","--",remote.host,RunTasks.remoteCommand(directory:directory,command:"/bin/sh -c "+SSHRemote.quote(command))],environment:env.map { "\($0.key)=\($0.value)" },currentDirectory:FileManager.default.homeDirectoryForCurrentUser.path)
            } else {
                term.startProcess(executable:executable,args:kind.arguments(session:session,task:task),environment:env.map { "\($0.key)=\($0.value)" },currentDirectory:directory)
            }
            updateRuntimeControls(); onStart?(); window?.makeFirstResponder(term)
        } catch { status.stringValue = error.localizedDescription }
    }
    func register(_ runtime: AgentRuntime) {
        guard !runtimes.contains(where:{ $0 === runtime }) else { return }
        runtime.terminal.processDelegate = self
        runtime.links.onOpen = { [weak self,weak runtime] link in if let runtime { self?.openLink(link,in:runtime) } }
        runtimes.append(runtime)
    }
    @objc func selectOpenSession() {
        guard runtimes.indices.contains(openSessions.indexOfSelectedItem) else { return }
        activate(runtimes[openSessions.indexOfSelectedItem])
    }
    func activate(_ runtime: AgentRuntime,focus: Bool = true) {
        guard runtimes.contains(where:{ $0 === runtime }) else { return }
        let changed = selectedChannel != channel(of:runtime) || path.stringValue != runtime.context.executable || agentHome.stringValue != runtime.context.home
        if changed {
            generation = UUID(); loading = false; sessions = []; selectionMessage = nil
            kindPicker.selectItem(at:AgentKind.allCases.firstIndex(of:runtime.context.kind)!)
            location.selectedSegment = runtime.context.host == nil ? 0 : 1
            restoreSettings(); path.stringValue = runtime.context.executable; agentHome.stringValue = runtime.context.home
        }
        display(runtime)
        if changed { reload() }
        if focus { onStart?(); window?.makeFirstResponder(runtime.terminal) }
    }
    private func display(_ runtime: AgentRuntime?) {
        terminal?.removeFromSuperview(); emptyState.removeFromSuperview(); activeRuntime = runtime
        if let runtime {
            lastActive[channel(of:runtime)] = runtime; Theme.pin(runtime.terminal,in:terminalHost)
        } else {
            Theme.pin(emptyState,in:terminalHost)
        }
        layoutSubtreeIfNeeded(); updateRuntimeControls()
    }
    private func updateRuntimeControls() {
        var titles = runtimes.enumerated().map { index,runtime in
            "\(runtime.context.kind.title) · \(runtime.context.host ?? L.text("This Mac")) · \(runtime.title) · \(L.text(runtime.terminal.process.running ? "Running" : "Stopped")) · \(index+1)"
        }
        if titles.isEmpty { titles = [L.text("No open sessions")] }
        else if activeRuntime == nil { titles.append(L.text("No open session for this agent and location")) }
        if openSessions.numberOfItems != titles.count {
            openSessions.removeAllItems(); openSessions.addItems(withTitles:titles)
        } else {
            for (index,title) in titles.enumerated() where openSessions.item(at:index)?.title != title { openSessions.item(at:index)?.title = title }
        }
        openSessions.isEnabled = !runtimes.isEmpty
        if let activeRuntime,let index = runtimes.firstIndex(where:{ $0 === activeRuntime }) {
            if openSessions.indexOfSelectedItem != index { openSessions.selectItem(at:index) }
            status.stringValue = activeRuntime.exitCode.map { L.format("Exited with status %d",Int($0)) } ?? L.text(activeRuntime.terminal.process.running ? "Running" : "Stopped")
        } else {
            openSessions.selectItem(at:openSessions.numberOfItems-1)
            status.stringValue = selectionMessage ?? L.text("No open session for this agent and location")
        }
        updateControls()
    }
    @objc func openSelectedFile() {
        guard let runtime = activeRuntime,let selection = runtime.terminal.getSelection() else { return }
        openLink(selection,in:runtime)
    }
    func openLink(_ link: String,in runtime: AgentRuntime) {
        if let url = URL(string:link),["http","https"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url); return }
        guard let file = AgentFileLink.resolve(link,directory:runtime.directory) else { status.stringValue = L.text("Unsupported file link."); return }
        let mapped = runtime.mapping?.remotePath(for:file.path)
        onOpenFile?(mapped ?? file.path,runtime.remote ?? (mapped == nil ? nil : remote),file.line)
    }
    func refreshTheme() {
        layer?.backgroundColor = Theme.canvas.cgColor; appearance = NSAppearance(named:Theme.isDark ? .darkAqua : .aqua)
        table.backgroundColor = Theme.panel
        for runtime in runtimes {
            let terminal = runtime.terminal
            terminal.nativeBackgroundColor = Theme.canvas; terminal.nativeForegroundColor = Theme.foreground
            terminal.caretColor = Theme.accent; terminal.font = .monospacedSystemFont(ofSize:Theme.fontSize,weight:.regular)
        }
    }
    @objc func stopAgent() {
        guard let terminal,terminal.process.running else { return }; terminal.send(data:[3][...])
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self,weak terminal] in
            guard let terminal,terminal.process.running else { return }
            Self.terminate(terminal); self?.updateRuntimeControls()
        }
    }
    func mayClose() -> Bool {
        guard running else { return true }
        let alert = NSAlert(); alert.messageText = L.text("Stop running agent sessions?")
        alert.informativeText = L.text("The running CLIs will stop. Saved sessions remain in the agent’s own storage.")
        alert.addButton(withTitle:L.text("Stop")); alert.addButton(withTitle:L.text("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    private static func terminate(_ terminal: LocalProcessTerminalView) {
        guard terminal.process.running else { return }
        let pid = terminal.process.shellPid
        if pid > 0,getpgid(pid) == pid,pid != getpgrp() { kill(-pid,SIGHUP) }; terminal.terminate()
    }
    func shutdown() { for runtime in runtimes { Self.terminate(runtime.terminal) } }
    func sizeChanged(source: LocalProcessTerminalView,newCols: Int,newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView,title: String) {
        guard let runtime = runtimes.first(where:{ $0.terminal === source }),!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,runtime.title != String(title.prefix(160)) else { return }
        runtime.title = String(title.prefix(160)); updateRuntimeControls()
    }
    func hostCurrentDirectoryUpdate(source: TerminalView,directory: String?) {
        guard let runtime = runtimes.first(where:{ $0.terminal === source }),let directory,
              let file = AgentFileLink.resolve(directory,directory:runtime.directory),file.path != runtime.directory else { return }
        runtime.directory = file.path; updateControls()
    }
    func processTerminated(source: TerminalView,exitCode: Int32?) {
        guard let runtime = runtimes.first(where:{ $0.terminal === source }) else { return }
        runtime.exitCode = exitCode ?? -1; updateRuntimeControls()
    }
}

private final class AgentConfigurationDocument: NSView { override var isFlipped: Bool { true } }
