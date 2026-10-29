import AppKit
import LinvellCore
import LinvellPluginKit

extension WorkspaceController {
    @objc func loadDevelopmentPlugin() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = L.text("Choose a plugin folder containing plugin.json and its executable.")
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK,let self,let directory = panel.url else { return }
            do {
                let package = try PluginPackage(directory:directory)
                let alert = NSAlert(); alert.messageText = L.format("Load plugin: %@?",package.manifest.name)
                alert.informativeText = L.text("Only load code you trust. Plugins run as your user account, outside a security sandbox. Declared permissions restrict editor APIs, not direct file, network or process access.")+"\n\n"+L.text("Editor permissions")+": "+(package.manifest.permissions.isEmpty ? L.text("None") : package.manifest.permissions.joined(separator:", "))+"\n\n"+directory.path
                alert.addButton(withTitle:L.text("Cancel")); alert.addButton(withTitle:L.text("Load Plugin"))
                alert.beginSheetModal(for:window) { [weak self] response in
                    guard response == .alertSecondButtonReturn,let self else { return }
                    do { try self.installPlugin(package) } catch { self.show(error) }
                }
            } catch { self.show(error) }
        }
    }
    @objc func stopPlugins() {
        pluginSessions.values.forEach { $0.stop() }; pluginSessions.removeAll(); PluginMenus.refresh()
        status.stringValue = L.text("Plugins stopped. Load a plugin folder to start it again.")
    }
    func pluginCommandOptions() -> [PickerOption] {
        pluginSessions.values.sorted { $0.package.manifest.id < $1.package.manifest.id }.flatMap { session in
            session.package.manifest.commands.map { command in
                PickerOption(title:command.title,detail:session.package.manifest.name+" · "+command.id,invoke:{ [weak self] in
                    self?.executePlugin(session,command:command.id)
                })
            }
        }
    }
    func executePlugin(_ session: PluginSession,command: String) {
        guard pluginSessions[session.package.manifest.id] === session else { return }
        let document = current,pane = activePane
        let text = pane?.textView.string,revision = document?.buffer.revision
        let snapshot = text.flatMap { text in revision.map { PluginDocument(text:text,revision:$0,id:document?.buffer.id.uuidString) } }
        let workspace = pluginWorkspace
        status.stringValue = L.text("Running plugin command…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let outcome = Result { try session.execute(command:command,document:snapshot,workspace:workspace) }
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
                } catch { self.show(error); self.status.stringValue = L.existing(error.localizedDescription) }
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
        let session = PluginSession(package:package,persistence:persistence)
        try PluginMenus.validate(pluginSessions.values.filter { $0.package.manifest.id != package.manifest.id }+[session])
        synchronizePluginDocuments()
        pluginSessions.removeValue(forKey:package.manifest.id)?.stop()
        pluginSessions[package.manifest.id] = session
        session.eventFailure = { [weak self,weak session] error in
            DispatchQueue.main.async {
                guard let self,let session,self.pluginSessions[package.manifest.id] === session else { return }
                self.status.stringValue = L.existing(error.localizedDescription)
            }
        }
        for document in documents where document.imageURL == nil { session.enqueue(pluginEvent(.open,document:document),workspace:pluginWorkspace) }
        PluginMenus.refresh(); status.stringValue = L.format("Plugin loaded: %@",package.manifest.name)
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
                    if workspaceScope,let connection = workspace?.remote { self.openRemote(file.path,connection:connection) }
                    else { self.open(file) }
                }
            } catch { DispatchQueue.main.async { self?.show(error) } }
        }
    }
}
