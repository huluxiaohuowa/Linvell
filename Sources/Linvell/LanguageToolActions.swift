import AppKit
import LinvellCore

extension LanguageToolsPane {
    @objc func toggleAdvanced() { advancedBox.isHidden = advanced.state != .on }
    @objc func storageChanged() {
        let project = selectedStorage == .project
        autoIgnore.isHidden = !project; ignoreButton?.isHidden = !project
        ignoreNotice.stringValue = L.text(project ? "Project services live in .linvell/tools. Add /.linvell/tools/ to the project’s root .gitignore; settings.json remains available to Git." : "Services are stored on this host under ~/.linvell/language-services and can be reused by its projects. No Git ignore rule is needed.")
        let supported = ManagedLanguageRecipe.forLanguage(language.id) != nil
        installButton?.isEnabled = supported && installTask == nil; clearButton?.isEnabled = supported && installTask == nil
    }
    func setInstalling(_ value: Bool,cancellable: Bool = false) {
        actionControls.forEach { $0.isEnabled = !value }; cancelButton.isHidden = !value || !cancellable
        if !value { storageChanged() }
    }
    @objc func cancelInstallation() { installTask?.cancel(); installationCancellation?.cancel(); state.stringValue = L.text("Cancelling language tool installation…") }
    @objc func installService() {
        guard installTask == nil,let window,ManagedLanguageRecipe.forLanguage(language.id) != nil else { return }
        let language = language,remote = remote,root = root,storage = selectedStorage,addIgnore = autoIgnore.state == .on
        var profile = LanguageTools.cached(language,remote:remote,root:root)
        profile.runtime = runtime.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); profile.storage = storage; profile.addGitIgnore = addIgnore
        let alert = NSAlert(); alert.messageText = L.text("Install project code intelligence?")
        alert.informativeText = language.title+"\n"+(remote.map { "SSH · "+$0.host } ?? L.text("This Mac"))+"\n"+root+"\n\n"+L.text(storage == .project ? "Installs only inside this project’s .linvell/tools folder. This Mac retains no relay package after remote installation." : "Installs under the target host user’s ~/.linvell/language-services folder. Shared files are removed only when no other project uses them.")
        alert.addButton(withTitle:L.text("Download and Install")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self,response == .alertFirstButtonReturn else { return }
            self.setInstalling(true,cancellable:true); let cancel = LanguageInstallCancellation(); self.installationCancellation = cancel
            self.installTask = Task.detached(priority:.utility) { [weak self,profile] in
                do {
                    let result = try await ManagedLanguageTools.install(language:language.id,remote:remote,root:root,storage:storage,addGitIgnore:addIgnore,cancel:cancel) { [weak self] text in DispatchQueue.main.async { [weak self] in self?.state.stringValue = L.text(text) } }
                    var installed = profile; installed.server = result.server; installed.arguments = result.arguments; installed.enabled = true
                    try LanguageTools.save(installed,language:language,remote:remote,root:result.root)
                    await MainActor.run { [weak self] in
                        self?.root = result.root; self?.onRootResolved?(result.root); self?.server.stringValue = result.server; self?.enabled.state = .on
                        self?.arguments.stringValue = "[\"--stdio\"]"; self?.state.stringValue = L.text("Installed and configured for this project. Temporary downloads were removed.")
                    }
                } catch {
                    await MainActor.run { [weak self] in self?.state.stringValue = error is CancellationError ? L.text("Installation cancelled. Temporary downloads were removed.") : L.existing(error.localizedDescription) }
                }
                await MainActor.run { [weak self] in self?.installTask = nil; self?.installationCancellation = nil; self?.setInstalling(false) }
            }
        }
    }
    @objc func clearService() {
        guard installTask == nil,let window else { return }
        let language = language,remote = remote,root = root,storage = selectedStorage
        let alert = NSAlert(); alert.messageText = L.text("Clear this language service?")
        alert.informativeText = L.text("Only Linvell-managed files at the selected location are eligible for removal. Shared user-folder services remain if another project uses them. The interpreter, project source and other language services are preserved. JavaScript and TypeScript share one service.")
        alert.addButton(withTitle:L.text("Clear")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self,response == .alertFirstButtonReturn else { return }
            self.owner?.resetLanguageServices(); self.setInstalling(true)
            self.installTask = Task.detached(priority:.utility) { [weak self] in
                do {
                    try ManagedLanguageTools.remove(language:language.id,remote:remote,root:root,storage:storage)
                    let affected = ["javascript","typescript"].contains(language.id) ? CodeLanguage.supported.filter { ["javascript","typescript"].contains($0.id) } : [language]
                    for item in affected {
                        var value = try LanguageTools.load(item,remote:remote,root:root,force:true)
                        if value.storage == storage && (value.server.contains(".linvell/tools/") || value.server.contains(".linvell/language-services/")) {
                            value.server = ""; value.arguments = []; value.enabled = false
                            try LanguageTools.save(value,language:item,remote:remote,root:root)
                        }
                    }
                    let current = try LanguageTools.load(language,remote:remote,root:root,force:true)
                    await MainActor.run { [weak self] in self?.server.stringValue = current.server; self?.enabled.state = current.enabled ? .on : .off; self?.arguments.stringValue = String(decoding:(try? JSONEncoder().encode(current.arguments)) ?? Data("[]".utf8),as:UTF8.self); self?.state.stringValue = L.text("Current project service cleared. Other projects and languages were preserved.") }
                } catch { await MainActor.run { [weak self] in self?.state.stringValue = L.existing(error.localizedDescription) } }
                await MainActor.run { [weak self] in self?.installTask = nil; self?.setInstalling(false) }
            }
        }
    }
    @objc func addIgnoreRule() {
        guard installTask == nil else { return }; let remote = remote,root = root
        setInstalling(true)
        installTask = Task.detached(priority:.utility) { [weak self] in
            do {
                try ManagedLanguageTools.addIgnore(remote:remote,root:root)
                await MainActor.run { [weak self] in self?.state.stringValue = L.text("Git ignore rule is present. Existing entries were not duplicated.") }
            } catch { await MainActor.run { [weak self] in self?.state.stringValue = L.existing(error.localizedDescription) } }
            await MainActor.run { [weak self] in self?.installTask = nil; self?.setInstalling(false) }
        }
    }
}
