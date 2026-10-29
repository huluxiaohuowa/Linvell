import AppKit
import LinvellCore

extension WorkspaceController {
    @objc func indexedDocumentSymbols() {
        languageRequest("textDocument/documentSymbol") { [weak self] value,snapshot in
            self?.presentCodeSymbols(value,snapshot:snapshot,document:true)
        }
    }
    func presentCodeSymbols(_ value: Any,snapshot: EditorCodeSnapshot,document: Bool) {
        guard let window,let symbols = try? CodeSymbol.parse(value,documentURI:document ? snapshot.uri : nil) else { return }
        let options = symbols.map { symbol in
            PickerOption(title:symbol.name,detail:(symbol.container.isEmpty ? "" : symbol.container+" · ")+(URL(string:symbol.location.uri)?.lastPathComponent ?? "")+":\(symbol.location.range.start.line+1)",invoke:{ [weak self] in self?.navigateCode(symbol.location,remote:snapshot.remote) })
        }
        picker = QuickPicker(title:L.text(document ? "Document Symbols" : "Workspace Symbols"),options:options,owner:window)
    }
    @objc func workspaceSymbols() {
        guard let window else { return }
        let active = current.flatMap { codeSnapshot($0) },remote = remoteConnection ?? active?.remote
        guard let directory = remote != nil ? (remoteConnection != nil ? remoteDirectory : active?.root) : (root?.url.path ?? active?.root) else { status.stringValue = L.text("Open a project folder before configuring its language tools."); return }
        let panel = QuickPicker(title:L.text("Workspace Symbols"),options:[],owner:window); picker = panel
        let services = languageServices,localPaths = fileIndex.map(\.path)
        let snapshots = documents.compactMap { codeSnapshot($0) }.filter { $0.root == directory && $0.remote?.host == remote?.host }
        let state = WorkspaceSymbolSearchState(directory:directory)
        panel.onQuery = { [weak self] query,deliver in
            guard let self else { return }
            let ticket = LanguageQueryTicket(); self.languageQueries.removeValue(forKey:"workspace/symbol")?.cancel(); self.languageQueries["workspace/symbol"] = ticket
            ticket.schedule { [weak self] in
                do {
                    if state.languages == nil {
                        if let remote,!state.directory.hasPrefix("/"),let path = try remote.listDirectory(state.directory).path { state.directory = path }
                        _ = try LanguageTools.load(CodeLanguage.supported[0],remote:remote,root:state.directory)
                        let paths = try remote.map { try $0.request("files",path:state.directory).entries?.map(\.path) ?? [] } ?? (localPaths.isEmpty ? ProjectFiles.list(URL(fileURLWithPath:state.directory)).map(\.path) : localPaths)
                        var ids = Set(snapshots.map { $0.language.id })
                        for path in paths {
                            if ticket.cancelled { throw CancellationError() }
                            if let language = LanguageTools.language(path:path,remote:remote,root:state.directory) { ids.insert(language.id) }
                        }
                        state.languages = ids.sorted().map { id in CodeLanguage.supported.first { $0.id == id } ?? CodeLanguage.custom(id:id) }
                    }
                    for language in state.languages ?? [] {
                        if ticket.cancelled { throw CancellationError() }
                        guard let session = try? services.session(language:language,root:state.directory,remote:remote) else { continue }
                        for document in snapshots where document.language.id == language.id { session.synchronize(uri:document.uri,language:document.language.documentID(path:document.path),text:document.text,version:document.version) }
                    }
                    let symbols = try CodeSymbol.parse(services.workspaceSymbols(query:query,root:state.directory,remote:remote,cancellation:ticket.cancellation))
                    let options = symbols.map { symbol in
                        PickerOption(title:symbol.name,detail:symbol.container+" · "+(URL(string:symbol.location.uri)?.lastPathComponent ?? ""),invoke:{ [weak self] in self?.navigateCode(symbol.location,remote:remote) })
                    }
                    DispatchQueue.main.async { if !ticket.cancelled { deliver(options) } }
                } catch { DispatchQueue.main.async { if !ticket.cancelled { deliver([]); self?.status.stringValue = L.existing(error.localizedDescription) } } }
            }
            services.queue.async { ticket.run() }
        }
        panel.onDismiss = { [weak self] in
            self?.languageQueries.removeValue(forKey:"workspace/symbol")?.cancel()
            services.queue.asyncAfter(deadline:.now()+2) { services.releaseUnusedBackends(root:state.directory,remote:remote) }
        }
    }
    @objc func typeDefinition() { navigateLanguageLocations("textDocument/typeDefinition",title:"Type Definitions") }
    @objc func implementation() { navigateLanguageLocations("textDocument/implementation",title:"Implementations") }
    @objc func declaration() { navigateLanguageLocations("textDocument/declaration",title:"Declarations") }
    func navigateLanguageLocations(_ method: String,title: String) {
        languageRequest(method) { [weak self] value,snapshot in
            guard let self,let locations = try? CodeLocation.locations(value) else { return }
            if locations.count == 1,let location = locations.first { self.navigateCode(location,remote:snapshot.remote) }
            else { self.showCodeLocations(locations,remote:snapshot.remote,title:title) }
        }
    }
    @objc func signatureHelp() {
        let caret = activePane?.textView.selectedRange(),generation = activePane?.textView.hoverGeneration
        languageRequest("textDocument/signatureHelp",extra:["context":["triggerKind":1,"isRetrigger":false]],quiet:true) { [weak self] value,_ in
            guard let self,let editor = self.activePane?.textView,editor.selectedRange() == caret,editor.hoverGeneration == generation,let result = value as? [String:Any],let signatures = result["signatures"] as? [[String:Any]],!signatures.isEmpty else { return }
            let active = max(0,min(signatures.count-1,result["activeSignature"] as? Int ?? 0))
            guard let label = signatures[active]["label"] as? String else { return }
            self.hoverPopover?.close()
            let popover = CodeHoverPanel()
            var range: NSRange?
            let parameter = signatures[active]["activeParameter"] as? Int ?? result["activeParameter"] as? Int ?? 0
            if let parameters = signatures[active]["parameters"] as? [[String:Any]],parameters.indices.contains(parameter) {
                if let offsets = parameters[parameter]["label"] as? [Int],offsets.count == 2,offsets[0] >= 0,offsets[1] >= offsets[0],offsets[1] <= (label as NSString).length { range = NSRange(location:offsets[0],length:offsets[1]-offsets[0]) }
                else if let text = parameters[parameter]["label"] as? String { let found = (label as NSString).range(of:text); if found.location != NSNotFound { range = found } }
            }
            popover.contentViewController = CodeHoverContent(text:label,highlight:range,navigate:{})
            let screen = editor.firstRect(forCharacterRange:editor.selectedRange(),actualRange:nil)
            self.hoverPopover = popover; popover.show(relativeTo:editor.convert(editor.window?.convertFromScreen(screen) ?? .zero,from:nil),of:editor,preferredEdge:.maxY)
        }
    }
    @objc func formatDocument() {
        let width = Int(PreferencesSync.value("tabWidth")) ?? 4
        languageRequest("textDocument/formatting",extra:["options":["tabSize":width,"insertSpaces":PreferencesSync.value("useSpaces") != "false"]]) { [weak self] value,snapshot in
            guard let self,let data = try? JSONSerialization.data(withJSONObject:value),let edits = try? JSONDecoder().decode([CodeTextEdit].self,from:data),let document = self.current,document.buffer.id == snapshot.id else { return }
            do {
                let text = try CodeTextEdit.applying(edits,to:document.buffer.text)
                guard text != document.buffer.text else { return }
                self.applyLanguageText(text,document:document)
            } catch { self.status.stringValue = error.localizedDescription }
        }
    }
    func applyLanguageText(_ text: String,document: OpenDocument) {
        let prior = document.buffer.text
        window?.undoManager?.registerUndo(withTarget:self) { target in target.applyLanguageText(prior,document:document) }
        document.storage.replaceCharacters(in:NSRange(location:0,length:document.storage.length),with:text)
        document.buffer.update(text); document.vim.sync(text:text,cursor:min(document.vim.cursor,(text as NSString).length))
        panes.filter { $0.document === document }.forEach { $0.refreshCodePresentation() }
        synchronizeLanguage(document); scheduleAutoSave(document); renderTabs()
    }
}

struct WorkspaceDiagnosticReport {
    let uri: String,root: String,remote: SSHRemote?,diagnostics: [CodeDiagnostic]
}
extension WorkspaceController {
    func receiveCodeDiagnostics(uri: String,values: [[String:Any]],version: Int?,snapshot: EditorCodeSnapshot) {
        guard let data = try? JSONSerialization.data(withJSONObject:Array(values.prefix(500))),let diagnostics = try? JSONDecoder().decode([CodeDiagnostic].self,from:data),let url = URL(string:uri),url.isFileURL else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A previous workspace's late notification must not repopulate its diagnostics.
            let root = self.remoteConnection == nil ? self.root?.url.path : self.remoteDirectory
            let active = self.current.flatMap { self.codeSnapshot($0) }
            guard (root == snapshot.root && self.remoteConnection?.host == snapshot.remote?.host) || (active?.root == snapshot.root && active?.remote?.host == snapshot.remote?.host) else { return }
            let document = self.documents.first { ($0.remote?.path ?? $0.fileURL?.path) == url.path && $0.remote?.connection.host == snapshot.remote?.host }
            if let version,let document,version != document.buffer.revision { return }
            let key = (snapshot.remote?.host ?? "local")+"|"+uri
            self.workspaceDiagnosticCount -= self.workspaceDiagnostics[key]?.diagnostics.count ?? 0
            self.workspaceDiagnostics[key] = WorkspaceDiagnosticReport(uri:uri,root:snapshot.root,remote:snapshot.remote,diagnostics:diagnostics)
            self.workspaceDiagnosticCount += diagnostics.count
            while self.workspaceDiagnosticCount > 10_000,let first = self.workspaceDiagnostics.keys.first {
                self.workspaceDiagnosticCount -= self.workspaceDiagnostics.removeValue(forKey:first)?.diagnostics.count ?? 0
            }
            guard let document else { return }
            document.codeDiagnostics = diagnostics
            self.panes.filter { $0.document === document }.forEach { $0.applyCodeDiagnostics() }
        }
    }
    @objc func showProblems() {
        guard let window else { return }
        let reports = workspaceDiagnostics.values.sorted { $0.uri < $1.uri }
        let options = reports.flatMap { report in report.diagnostics.map { diagnostic in
            PickerOption(title:diagnostic.message,detail:(URL(string:report.uri)?.lastPathComponent ?? "")+":\(diagnostic.range.start.line+1) · "+L.text([1:"Error",2:"Warning",3:"Information",4:"Hint"][diagnostic.severity ?? 0] ?? "Diagnostic"),invoke:{ [weak self] in
                self?.navigateCode(CodeLocation(uri:report.uri,range:diagnostic.range),remote:report.remote)
            })
        } }
        picker = QuickPicker(title:L.text("Problems"),options:options,owner:window)
    }
    @objc func restartLanguageServices() {
        resetLanguageServices()
        for document in documents { synchronizeLanguage(document) }
    }
}

private final class WorkspaceSymbolSearchState {
    var directory: String
    var languages: [CodeLanguage]?
    init(directory: String) { self.directory = directory }
}
