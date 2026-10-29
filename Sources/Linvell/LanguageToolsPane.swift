import AppKit
import LinvellCore

final class LanguageToolsPane: NSView {
    weak var owner: WorkspaceController?
    let languages = Theme.choiceButton(),runtime = NSComboBox(frame:.zero),server = NSTextField(),arguments = NSTextField()
    let enabled = NSButton(checkboxWithTitle:L.text("Enable language intelligence"),target:nil,action:nil)
    let state = NSTextField(wrappingLabelWithString:"")
    var tools: [String:String] = [:]
    var remote: SSHRemote?
    var root: String
    var remotePicker: RemoteToolPicker?
    var languageOptions = CodeLanguage.supported
    var language: CodeLanguage { languageOptions[max(0,min(languageOptions.count-1,languages.indexOfSelectedItem))] }
    init(owner: WorkspaceController?) {
        self.owner = owner
        if let document = owner?.current { remote = document.remote?.connection } else { remote = owner?.remoteConnection }
        root = remote == nil ? (owner?.root?.url.path ?? owner?.current?.fileURL?.deletingLastPathComponent().path ?? FileManager.default.homeDirectoryForCurrentUser.path) : (owner?.remoteDirectory ?? "~")
        super.init(frame:.zero)
        languages.addItems(withTitles:CodeLanguage.supported.map(\.title)); languages.target = self; languages.action = #selector(languageChanged)
        if let path = owner?.current?.remote?.path ?? owner?.current?.fileURL?.path,let selected = CodeLanguage.forPath(path),let index = CodeLanguage.supported.firstIndex(of:selected) { languages.selectItem(at:index) }
        runtime.font = .systemFont(ofSize:13); server.font = .systemFont(ofSize:13); arguments.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        for control in [runtime as NSView,server,arguments] { control.heightAnchor.constraint(equalToConstant:26).isActive = true }
        enabled.heightAnchor.constraint(equalToConstant:24).isActive = true
        runtime.placeholderString = L.text("Interpreter or compiler path"); server.placeholderString = L.text("Language server executable"); arguments.placeholderString = "[\"--stdio\"]"
        state.font = .systemFont(ofSize:12); state.textColor = Theme.secondary
        let detect = Theme.actionButton("Detect Tools",target:self,action:#selector(detectTools))
        let apply = Theme.actionButton("Apply Toolchain",target:self,action:#selector(applyToolchain))
        let scope = Theme.label(remote.map { "SSH · "+$0.host } ?? L.text("This Mac"),size:13,color:Theme.accent)
        let info = NSTextField(wrappingLabelWithString:L.text("Choose tools installed on this host. Definitions, references, diagnostics, completion and rename use the language server. Tool paths are saved in this project’s .linvell/settings.json; nothing is installed automatically.")); info.font = .systemFont(ofSize:13); info.textColor = Theme.secondary
        let location = NSTextField(wrappingLabelWithString:L.format("Project settings: %@",".linvell/settings.json")); location.font = .systemFont(ofSize:11); location.textColor = Theme.secondary
        let rows: [NSView] = [scope,location,info,languages,enabled,Theme.label("Interpreter / compiler",size:12),Theme.stack([runtime,Theme.actionButton("Browse…",target:self,action:#selector(browseRuntime))]),Theme.label("Language server",size:12),Theme.stack([server,Theme.actionButton("Browse…",target:self,action:#selector(browseServer))]),Theme.label("Arguments (JSON array)",size:12),arguments,Theme.stack([detect,apply,NSView()]),state]
        Theme.pin(Theme.stack(rows+[NSView()],orientation:.vertical,spacing:12),in:self)
        heightAnchor.constraint(greaterThanOrEqualToConstant:430).isActive = true
        load(); detectTools()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func languageChanged() { load(); displayDetected() }
    private func load() {
        let profile = LanguageTools.cached(language,remote:remote,root:root)
        runtime.stringValue = profile.runtime; server.stringValue = profile.server; enabled.state = profile.enabled ? .on : .off
        arguments.stringValue = String(data:(try? JSONEncoder().encode(profile.arguments)) ?? Data("[]".utf8),encoding:.utf8) ?? "[]"
    }
    private func displayDetected() {
        let selected = language.id
        languageOptions = LanguageTools.configuredLanguages(remote:remote,root:root)
        languages.removeAllItems(); languages.addItems(withTitles:languageOptions.map(\.title))
        languages.selectItem(at:languageOptions.firstIndex(where:{ $0.id == selected }) ?? 0)
        runtime.removeAllItems()
        let candidates = language.runtimes+(language.id == "python" ? [".venv/bin/python","venv/bin/python"] : [])
        runtime.addItems(withObjectValues:candidates.compactMap { tools[$0] })
        let resolved = LanguageTools.resolved(LanguageTools.cached(language,remote:remote,root:root),language:language,tools:tools,root:root)
        runtime.stringValue = resolved.runtime; server.stringValue = resolved.server
        arguments.stringValue = String(data:(try? JSONEncoder().encode(resolved.arguments)) ?? Data("[]".utf8),encoding:.utf8) ?? "[]"
        state.stringValue = resolved.server.isEmpty ? L.text("No language server found. Install one on this host or choose its executable.") : L.text("Tools detected. Apply to use this toolchain.")
    }
    @objc func detectTools() {
        guard owner?.root != nil || owner?.remoteConnection != nil else { state.stringValue = L.text("Open a project folder before configuring its language tools."); return }
        state.stringValue = L.text("Detecting tools…")
        let remote = remote,root = root,language = language
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { () throws -> [String:String] in
                let tools = try LanguageTools.discover(remote:remote,root:root)
                _ = try LanguageTools.load(language,remote:remote,root:tools["__root"] ?? root,force:true)
                return tools
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let tools): self.root = tools["__root"] ?? root; self.tools = tools; self.displayDetected()
                case .failure(let error): self.state.stringValue = error.localizedDescription
                }
            }
        }
    }
    @objc func applyToolchain() {
        do {
            var profile = LanguageToolchain()
            profile.runtime = runtime.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); profile.server = server.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            profile.arguments = try JSONDecoder().decode([String].self,from:Data(arguments.stringValue.utf8)); profile.enabled = enabled.state == .on
            guard !profile.enabled || profile.server.hasPrefix("/") || profile.server.hasPrefix("${workspaceFolder}/") || profile.server.hasPrefix("${userHome}/") || profile.server.hasPrefix("~/"),!profile.runtime.contains("\0"),!profile.server.contains("\0"),profile.arguments.allSatisfy({ !$0.contains("\0") }) else { throw LanguageServiceError.message(L.text("Choose an absolute executable path.")) }
            guard owner?.root != nil || owner?.remoteConnection != nil else { throw LanguageServiceError.message(L.text("Open a project folder before configuring its language tools.")) }
            let remote = remote,root = root,language = language
            state.stringValue = L.text("Saving project language settings…")
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                let result = Result { try LanguageTools.save(profile,language:language,remote:remote,root:root) }
                DispatchQueue.main.async {
                    switch result {
                    case .success: self?.state.stringValue = L.text("Saved to .linvell/settings.json. Language services will restart.")
                    case .failure(let error): self?.state.stringValue = error.localizedDescription
                    }
                }
            }
        } catch { state.stringValue = error.localizedDescription }
    }
    @objc func browseRuntime() { browse { [weak self] in self?.runtime.stringValue = $0 } }
    @objc func browseServer() { browse { [weak self] in self?.server.stringValue = $0 } }
    private func browse(_ chosen: @escaping (String) -> Void) {
        guard let window else { return }
        if let remote { remotePicker = RemoteToolPicker(remote:remote,root:root,owner:window,chosen:chosen) }
        else {
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.showsHiddenFiles = true
            panel.beginSheetModal(for:window) { result in if result == .OK,let path = panel.url?.path { chosen(path) } }
        }
    }
}

final class RemoteToolPicker: NSWindowController {
    let browser: RemoteBrowser
    weak var parentWindow: NSWindow?
    let chosen: (String) -> Void
    init(remote: SSHRemote,root: String,owner: NSWindow,chosen: @escaping (String) -> Void) {
        browser = RemoteBrowser(connection:remote,initialPath:root); self.parentWindow = owner; self.chosen = chosen
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:680,height:520),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        panel.title = L.text("Choose Remote Executable"); super.init(window:panel)
        let cancel = Theme.actionButton("Cancel",target:self,action:#selector(cancel)),choose = Theme.actionButton("Choose",target:self,action:#selector(chooseFile))
        Theme.pin(Theme.stack([browser,Theme.stack([NSView(),cancel,choose])],orientation:.vertical),in:panel.contentView!,inset:16)
        browser.onOpen = { [weak self] in self?.finish($0) }
        owner.beginSheet(panel)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func cancel() { if let window { parentWindow?.endSheet(window); window.orderOut(nil) } }
    @objc func chooseFile() {
        guard !browser.isLoading,browser.entries.indices.contains(browser.table.selectedRow) else { return }
        let entry = browser.entries[browser.table.selectedRow]; if !entry.directory { finish(entry.path) }
    }
    private func finish(_ path: String) { cancel(); chosen(path) }
}
