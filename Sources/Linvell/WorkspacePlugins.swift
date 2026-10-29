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
                    self.pluginSessions.removeValue(forKey:package.manifest.id)?.stop()
                    self.pluginSessions[package.manifest.id] = PluginSession(package:package)
                    self.status.stringValue = L.format("Plugin loaded: %@",package.manifest.name)
                }
            } catch { self.show(error) }
        }
    }
    @objc func stopPlugins() {
        pluginSessions.values.forEach { $0.stop() }; pluginSessions.removeAll()
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
        let snapshot = text.flatMap { text in revision.map { PluginDocument(text:text,revision:$0) } }
        status.stringValue = L.text("Running plugin command…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let outcome = Result { try session.execute(command:command,document:snapshot) }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.pluginSessions[session.package.manifest.id] === session else { return }
                do {
                    let result = try outcome.get()
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
        guard current === document,activePane === pane,pane.document === document,
              document.buffer.revision == revision,pane.textView.string == original,!pane.textView.hasMarkedText() else { throw PluginError.staleDocument }
        guard replacement != original else { return }
        pane.textView.restoreMultiEdit(replacement,selections:[NSValue(range:NSRange(location:0,length:0))])
        pane.textView.undoManager?.setActionName(L.text("Plugin Edit"))
    }
}
