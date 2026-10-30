import AppKit
import SwiftTerm
import LinvellCore
import Darwin

/// Native controls around the providers' own interactive CLIs. No model runtime.
final class AgentWorkspace: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, LocalProcessTerminalViewDelegate {
    let configurationView = NSView()
    var onStart: (() -> Void)?
    let project: String
    let remote: SSHRemote?
    let kindPicker = NSPopUpButton(),installationsPicker = NSPopUpButton()
    let location = NSSegmentedControl(labels:[L.text("This Mac"),L.text("SSH Host")],trackingMode:.selectOne,target:nil,action:nil)
    let path = NSTextField(),agentHome = NSTextField(),search = NSSearchField(),task = NSTextField()
    let table = ResponsiveTableView(),terminalHost = NSView()
    let status = Theme.label("",size:12,color:Theme.secondary)
    let scope = Theme.label("",size:12,color:Theme.secondary)
    let mappingLabel = Theme.label("",size:11,color:Theme.secondary)
    let mappingRow = NSStackView()
    let refresh = NSButton(),newSession = NSButton(),resume = NSButton(),stop = NSButton(),browse = NSButton(),mount = NSButton(),chooseMount = NSButton()
    var installations: [AgentInstallation] = []
    var sessions: [AgentSession] = []
    var filtered: [AgentSession] = []
    var mapping: AgentPathMapping?
    var terminal: LocalProcessTerminalView?
    private(set) var generation = UUID()
    private var loading = false
    var kind: AgentKind { AgentKind.allCases[max(0,kindPicker.indexOfSelectedItem)] }
    var usesSSH: Bool { remote != nil && location.selectedSegment == 1 }
    var running: Bool { terminal?.process.running == true }
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
        installationsPicker.target = self; installationsPicker.action = #selector(installationChanged)
        installationsPicker.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        path.placeholderString = L.text("Agent CLI executable path"); path.delegate = self; path.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        path.setAccessibilityLabel(L.text("Agent CLI executable path"))
        agentHome.placeholderString = L.text("Agent home (optional)"); agentHome.delegate = self
        scope.lineBreakMode = .byTruncatingMiddle; mappingLabel.lineBreakMode = .byTruncatingMiddle
        agentHome.toolTip = L.text("Use the same agent home as your CLI or desktop app. Leave empty for the default.")
        search.placeholderString = L.text("Search sessions"); search.delegate = self
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
        let rows: [NSView] = [heading,location,kindPicker,installationsPicker,Theme.stack([path,browse],spacing:6),agentHome,mappingRow,task,search,scroll,newSession,resume]
        let configuration = Theme.stack(rows,orientation:.vertical,spacing:10)
        let outer = ResponsiveScrollView(); outer.hasVerticalScroller = true; outer.drawsBackground = false
        let document = AgentConfigurationDocument(); document.translatesAutoresizingMaskIntoConstraints = false; outer.documentView = document
        Theme.pin(outer,in:configurationView); Theme.pin(configuration,in:document,inset:16)
        document.widthAnchor.constraint(equalTo:outer.contentView.widthAnchor).isActive = true
        document.heightAnchor.constraint(greaterThanOrEqualTo:outer.contentView.heightAnchor).isActive = true
        scope.lineBreakMode = .byTruncatingMiddle; status.lineBreakMode = .byTruncatingMiddle
        let mainHeading = Theme.stack([Theme.label("Agents",size:20,weight:.semibold),NSView(),stop])
        Theme.pin(Theme.stack([mainHeading,scope,status,terminalHost],orientation:.vertical,spacing:12),in:self,inset:20)
        terminalHost.heightAnchor.constraint(greaterThanOrEqualToConstant:160).isActive = true
        restoreSettings(); if autoLoad { reload() } else { updateControls() }
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
        if notification.object as? NSTextField === task { updateControls() }
        else if notification.object as? NSSearchField === search { filterSessions() }
        else { generation = UUID(); sessions = []; filterSessions() }
    }
    func controlTextDidEndEditing(_ notification: Notification) { if notification.object as? NSSearchField !== search,notification.object as? NSTextField !== task { saveSettings(); reload() } }
    private func restoreSettings() {
        path.stringValue = UserDefaults.standard.string(forKey:settingsKey+".path") ?? ""
        agentHome.stringValue = UserDefaults.standard.string(forKey:settingsKey+".home") ?? ""
        agentHome.isHidden = kind.homeVariable == nil
        task.isHidden = kind != .dsh
    }
    private func saveSettings() {
        UserDefaults.standard.set(path.stringValue,forKey:settingsKey+".path")
        UserDefaults.standard.set(agentHome.stringValue,forKey:settingsKey+".home")
    }
    @objc func selectionChanged() { guard !running else { return }; restoreSettings(); reload() }
    @objc private func installationChanged() {
        guard installations.indices.contains(installationsPicker.indexOfSelectedItem) else { return }
        path.stringValue = installations[installationsPicker.indexOfSelectedItem].path; saveSettings(); reload()
    }
    private func updateControls() {
        let enabled = !running && !loading
        [kindPicker,installationsPicker,location,path,agentHome,task,browse,mount,chooseMount].forEach { $0.isEnabled = enabled }
        refresh.isEnabled = !loading && !running
        let available = enabled && executionDirectory != nil && !path.stringValue.isEmpty && (kind != .dsh || !task.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
        newSession.isEnabled = available; resume.isEnabled = available && filtered.indices.contains(table.selectedRow); stop.isEnabled = running
        browse.isHidden = usesSSH; mount.isHidden = remote == nil || usesSSH; chooseMount.isHidden = mount.isHidden
        mappingRow.isHidden = remote == nil || usesSSH
        scope.stringValue = (usesSSH ? remote!.host : L.text("This Mac"))+" · "+(executionDirectory ?? project)
        mappingLabel.stringValue = remote != nil && !usesSSH ? (mapping?.localRoot ?? L.text("Mount the SSH project to use a local agent.")) : ""
    }
    @objc func reload() {
        // Reopening the same window shares its pending CLI/session discovery.
        guard !running,!loading else { return }
        let selectedID = filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow].id : nil
        let request = UUID(); generation = request; loading = true
        sessions = []; status.stringValue = L.text("Loading agent sessions…"); filterSessions()
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
                    self.sessions = sessions; self.filterSessions(select:selectedID); self.status.stringValue = L.format("%d project sessions",sessions.count)
                case .failure(let error): self.status.stringValue = error.localizedDescription
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
        saveSettings(); reload()
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
    private func performMapping(_ work: @escaping () throws -> AgentPathMapping) {
        generation = UUID(); loading = true; status.stringValue = L.text("Connecting project mount…"); updateControls()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async {
                guard let self else { return }; self.loading = false
                switch result {
                case .success(let mapping): self.mapping = mapping; UserDefaults.standard.set(try? JSONEncoder().encode(mapping),forKey:self.mappingKey); self.reload()
                case .failure(let error): self.status.stringValue = error.localizedDescription; self.updateControls()
                }
            }
        }
    }
    @objc func startNew() { start(session:nil) }
    @objc func resumeSelected() { guard filtered.indices.contains(table.selectedRow) else { return }; start(session:filtered[table.selectedRow]) }
    func start(session: AgentSession?) {
        guard !running,!loading,let projectDirectory = executionDirectory,!path.stringValue.isEmpty else { return }
        let directory = session?.cwd ?? projectDirectory
        let task = kind == .dsh ? task.stringValue.trimmingCharacters(in:.whitespacesAndNewlines) : nil
        guard task == nil || task?.isEmpty == false else { return }
        do {
            if remote != nil && !usesSSH { try mapping?.validate() }
            let executable = usesSSH ? path.stringValue : (path.stringValue as NSString).expandingTildeInPath
            guard executable.hasPrefix("/"),!executable.contains("\0") else { throw GitError.command("Choose an absolute agent CLI path.") }
            if !usesSSH,!FileManager.default.isExecutableFile(atPath:executable) { throw GitError.command("The agent CLI is unavailable.") }
            let home = usesSSH ? agentHome.stringValue : (agentHome.stringValue as NSString).expandingTildeInPath
            guard home.isEmpty || home.hasPrefix("/") else { throw GitError.command("Use an absolute agent home path.") }
            saveSettings(); terminal?.removeFromSuperview(); layoutSubtreeIfNeeded()
            let term = DisplayPacedTerminalView(frame:terminalHost.bounds); terminal = term; term.processDelegate = self
            term.font = .monospacedSystemFont(ofSize:Theme.fontSize,weight:.regular)
            term.nativeBackgroundColor = Theme.canvas; term.nativeForegroundColor = Theme.foreground; term.caretColor = Theme.accent
            Theme.pin(term,in:terminalHost)
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
            status.stringValue = L.text("Running")+" · "+kind.title+" · "+directory; updateControls(); onStart?(); window?.makeFirstResponder(term)
        } catch { status.stringValue = error.localizedDescription }
    }
    func refreshTheme() {
        layer?.backgroundColor = Theme.canvas.cgColor; appearance = NSAppearance(named:Theme.isDark ? .darkAqua : .aqua)
        table.backgroundColor = Theme.panel
        terminal?.nativeBackgroundColor = Theme.canvas; terminal?.nativeForegroundColor = Theme.foreground
        terminal?.caretColor = Theme.accent; terminal?.font = .monospacedSystemFont(ofSize:Theme.fontSize,weight:.regular)
    }
    @objc func stopAgent() {
        guard let terminal,running else { return }; terminal.send(data:[3][...])
        let process = terminal.process
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self,weak terminal] in
            guard let self,let terminal,terminal.process === process,terminal.process.running else { return }; self.shutdown(); self.updateControls()
        }
    }
    func mayClose() -> Bool {
        guard running else { return true }
        let alert = NSAlert(); alert.messageText = L.text("Stop this agent session?")
        alert.informativeText = L.text("The running CLI will stop. Saved sessions remain in the agent’s own storage.")
        alert.addButton(withTitle:L.text("Stop")); alert.addButton(withTitle:L.text("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    func shutdown() {
        guard let terminal,terminal.process.running else { return }
        let pid = terminal.process.shellPid
        if pid > 0,getpgid(pid) == pid,pid != getpgrp() { kill(-pid,SIGHUP) }; terminal.terminate()
    }
    func sizeChanged(source: LocalProcessTerminalView,newCols: Int,newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView,title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView,directory: String?) {}
    func processTerminated(source: TerminalView,exitCode: Int32?) {
        guard source === terminal else { return }; status.stringValue = L.format("Exited with status %d",Int(exitCode ?? -1)); updateControls()
    }
}

private final class AgentConfigurationDocument: NSView { override var isFlipped: Bool { true } }
