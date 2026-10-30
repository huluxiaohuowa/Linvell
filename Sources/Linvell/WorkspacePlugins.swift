import AppKit
import LinvellCore
import LinvellPluginKit

extension WorkspaceController {
    @objc func loadDevelopmentPlugin() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = L.text("Choose a plugin folder containing plugin.json.")
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK,let self,let directory = panel.url else { return }
            do {
                let package = try PluginPackage(directory:directory)
                let alert = NSAlert(); alert.messageText = L.format("Load plugin: %@?",package.manifest.name)
                let remoteWarning = package.manifest.execution == "workspace" && self.remoteConnection != nil
                    ? L.text("Workspace programs will be copied to and executed on the connected SSH host.")+"\n\n" : ""
                let warning = L.text("Only load code you trust. Plugins run as your user account, outside a security sandbox. Declared permissions restrict editor APIs, not direct file, network or process access.")
                let permissions = package.manifest.permissions.isEmpty ? L.text("None") : package.manifest.permissions.joined(separator:", ")
                let permissionSummary = L.text("Editor permissions")+": "+permissions
                alert.informativeText = remoteWarning+[warning,permissionSummary,directory.path].joined(separator:"\n\n")
                alert.addButton(withTitle:L.text("Cancel")); alert.addButton(withTitle:L.text("Load Plugin"))
                alert.beginSheetModal(for:window) { [weak self] response in
                    guard response == .alertSecondButtonReturn,let self else { return }
                    do { try self.installPlugin(package) } catch { self.show(error) }
                }
            } catch { self.show(error) }
        }
    }
    @objc func stopPlugins() {
        managedPluginLoad = UUID()
        let sessions = Array(pluginSessions.values); pluginSessions.removeAll()
        sessions.forEach { $0.stop(); clearPluginUI($0) }; PluginMenus.refresh()
        refreshPluginProviders()
        NotificationCenter.default.post(name:PluginMenus.changed,object:self)
        status.stringValue = L.text("Plugins stopped. Load a plugin folder to start it again.")
    }
    func pluginCommandOptions() -> [PickerOption] {
        pluginSessions.values.sorted { $0.package.manifest.id < $1.package.manifest.id }.flatMap { session in
            if session.isStopped { return self.pluginToolOptions(session) }
            var options = session.package.manifest.commands.map { command in
                PickerOption(title:command.title,detail:session.package.manifest.name+" · "+command.id,invoke:{ [weak self] in
                    self?.executePlugin(session,command:command.id)
                })
            }
            options += (session.package.manifest.views ?? []).filter { $0.kind != .status }.map { view in
                PickerOption(title:view.title,detail:session.package.manifest.name,invoke:{ [weak self] in self?.showPluginView(view.id,session:session) })
            }
            options += (session.package.manifest.themes ?? []).map { theme in PickerOption(title:theme.title,detail:L.text("Plugin Theme")+" · "+session.package.manifest.name,invoke:{ [weak self] in self?.selectPluginTheme(theme.id,session:session) }) }
            options += (session.package.manifest.snippets ?? []).map { snippet in PickerOption(title:snippet.title,detail:L.text("Plugin Snippet")+" · "+session.package.manifest.name,invoke:{ [weak self] in self?.insertPluginSnippet(snippet.id,session:session) }) }
            if !(session.package.manifest.settings ?? []).isEmpty { options.append(PickerOption(title:session.package.manifest.name+" — "+L.text("Plugin Settings"),detail:"Linvell",invoke:{ [weak self] in self?.openPluginSettings(session) })) }
            options += self.pluginToolOptions(session)
            return options
        }
    }
    func executePlugin(_ session: PluginSession,command: String,uiEvent: PluginUIEvent? = nil) {
        guard pluginSessions[session.package.manifest.id] === session else { return }
        let document = current,pane = activePane
        let text = pane?.textView.string,revision = document?.buffer.revision
        let snapshot = text.flatMap { text in revision.map { PluginDocument(text:text,revision:$0,id:document?.buffer.id.uuidString) } }
        let workspace = pluginWorkspace
        status.stringValue = L.text("Running plugin command…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let outcome = Result { try session.execute(command:command,document:snapshot,workspace:workspace,uiEvent:uiEvent) }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.pluginSessions[session.package.manifest.id] === session else { return }
                do {
                    let result = try outcome.get()
                    if let edits = result.edits {
                        guard let document,let pane,let text,let revision,result.documentRevision == revision else { throw PluginError.staleDocument }
                        try self.applyPluginEdits(edits,document:document,pane:pane,revision:revision,original:text)
                    }
                    if let replacement = result.replacementText {
                        guard let document,let pane,let text,let revision else { throw PluginError.staleDocument }
                        try self.applyPluginReplacement(replacement,document:document,pane:pane,revision:revision,original:text)
                    }
                    self.status.stringValue = result.message ?? L.text("Plugin command completed.")
                } catch {
                    if session.isStopped { self.clearPluginUI(session); PluginMenus.refresh(); NotificationCenter.default.post(name:PluginMenus.changed,object:self) }
                    self.show(error); self.status.stringValue = L.existing(error.localizedDescription)
                }
            }
        }
    }
    func applyPluginReplacement(_ replacement: String,document: OpenDocument,pane: EditorPane,revision: Int,original: String) throws {
        try validatePluginDocument(document,pane:pane,revision:revision,original:original)
        guard replacement != original else { return }
        pane.textView.restoreMultiEdit(replacement,selections:[NSValue(range:NSRange(location:0,length:0))])
        pane.textView.undoManager?.setActionName(L.text("Plugin Edit"))
    }
    func validatePluginDocument(_ document: OpenDocument,pane: EditorPane,revision: Int,original: String) throws {
        guard current === document,activePane === pane,pane.document === document,
              document.buffer.revision == revision,pane.textView.string == original,!pane.textView.hasMarkedText() else { throw PluginError.staleDocument }
    }
    func applyPluginEdits(_ edits: [PluginTextEdit],document: OpenDocument,pane: EditorPane,revision: Int,original: String) throws {
        try validatePluginDocument(document,pane:pane,revision:revision,original:original)
        let result = try PluginEdits.apply(edits,to:original)
        guard result.text != original else { return }
        pane.textView.restoreMultiEdit(result.text,selections:result.selections.map(NSValue.init(range:)))
        pane.textView.undoManager?.setActionName(L.text("Plugin Edit"))
    }
    var pluginWorkspace: PluginWorkspace? {
        if let remoteConnection { return PluginWorkspace(root:remoteDirectory,remote:remoteConnection) }
        return root.map { PluginWorkspace(root:$0.url.path) }
    }
    func installPlugin(_ package: PluginPackage,persistence: PluginPersistence = PluginPersistence()) throws {
        let session = PluginSession(package:package,persistence:persistence,workspace:pluginWorkspace)
        let contributed = Set((package.manifest.languageServers ?? []).flatMap(\.languages))
        let existing = Set(pluginSessions.values.filter { $0.package.manifest.id != package.manifest.id }.flatMap { ($0.package.manifest.languageServers ?? []).flatMap(\.languages) })
        guard contributed.isDisjoint(with:existing) else { throw LanguageServiceError.message("Another loaded plugin already provides this language. Stop it before loading a replacement.") }
        try PluginMenus.validate(pluginSessions.values.filter { $0.package.manifest.id != package.manifest.id }+[session])
        synchronizePluginDocuments()
        if let previous = pluginSessions.removeValue(forKey:package.manifest.id) { previous.stop(); clearPluginUI(previous) }
        pluginSessions[package.manifest.id] = session
        session.eventFailure = { [weak self,weak session] error in
            DispatchQueue.main.async {
                guard let self,let session,self.pluginSessions[package.manifest.id] === session else { return }
                self.clearPluginUI(session); PluginMenus.refresh(); NotificationCenter.default.post(name:PluginMenus.changed,object:self)
                self.status.stringValue = L.existing(error.localizedDescription)
            }
        }
        session.uiUpdated = { [weak self,weak session] updates in
            guard !updates.isEmpty else { return }
            DispatchQueue.main.async { if let session { self?.receivePluginViews(updates,session:session) } }
        }
        refreshPluginProviders()
        renderPluginStatus()
        for document in documents where document.imageURL == nil { session.enqueue(pluginEvent(.open,document:document),workspace:pluginWorkspace) }
        PluginMenus.refresh(); NotificationCenter.default.post(name:PluginMenus.changed,object:self)
        status.stringValue = L.format("Plugin loaded: %@",package.manifest.name)
    }
    func pluginEvent(_ kind: PluginDocumentEvent.Kind,document: OpenDocument,revision: Int? = nil) -> PluginDocumentEvent {
        let version = revision ?? document.buffer.revision
        let text = document.buffer.text
        let snapshot = kind != .close && version == document.buffer.revision && text.utf8.count <= 2*1024*1024 ? PluginDocument(text:text,revision:version,id:document.buffer.id.uuidString) : nil
        return PluginDocumentEvent(kind:kind,documentID:document.buffer.id.uuidString,revision:version,document:snapshot)
    }
    func synchronizePluginDocuments() {
        let textDocuments = documents.filter { $0.imageURL == nil },ids = Set(textDocuments.map { $0.buffer.id })
        for id in Array(pluginDocumentVersions.keys) where !ids.contains(id) {
            let event = PluginDocumentEvent(kind:.close,documentID:id.uuidString,revision:pluginDocumentVersions.removeValue(forKey:id)!)
            pluginSessions.values.forEach { $0.enqueue(event,workspace:pluginWorkspace) }
        }
        for document in textDocuments {
            guard !panes.contains(where:{ $0.document === document && $0.textView.hasMarkedText() }) else { continue }
            let id = document.buffer.id,revision = document.buffer.revision,previous = pluginDocumentVersions[id]
            guard previous != revision else { continue }
            pluginDocumentVersions[id] = revision
            let event = pluginEvent(previous == nil ? .open : .change,document:document)
            pluginSessions.values.forEach { $0.enqueue(event,workspace:pluginWorkspace) }
        }
    }
    func pluginDocumentSaved(_ document: OpenDocument,revision: Int) {
        let event = pluginEvent(.save,document:document,revision:revision)
        pluginSessions.values.forEach { $0.enqueue(event,workspace:pluginWorkspace) }
    }
    func windowDidBecomeKey(_ notification: Notification) { PluginMenus.refresh() }
    func openPluginConfiguration(_ session: PluginSession,workspaceScope: Bool) {
        let workspace = pluginWorkspace
        if workspaceScope && workspace == nil { return }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                let file: URL
                if let workspace,workspaceScope {
                    var settings = try ProjectLanguageSettings.read(root:workspace.root,remote:workspace.remote)
                    let values = try JSONCSettings(settings.data).values
                    if (values["plugins"] as? [String:Any])?[session.package.manifest.id] == nil {
                        settings = try settings.writePlugin(session.package.manifest.id,configuration:[:])
                    }
                    file = URL(fileURLWithPath:workspace.root).appendingPathComponent(".linvell/settings.json")
                } else { file = try session.persistence.userConfiguration(package:session.package) }
                DispatchQueue.main.async {
                    guard let self,self.pluginSessions[session.package.manifest.id] === session else { return }
                    if workspaceScope,self.pluginWorkspace?.identityKey != workspace?.identityKey { return }
                    self.showWindow(nil); self.window?.makeKeyAndOrderFront(nil)
                    if workspaceScope,let connection = workspace?.remote { self.openRemote(file.path,connection:connection) }
                    else { self.open(file) }
                }
            } catch { DispatchQueue.main.async { self?.show(error) } }
        }
    }
}
