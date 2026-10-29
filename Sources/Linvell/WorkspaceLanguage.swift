import AppKit
import LinvellCore

final class LanguageQueryTicket {
    private let lock = NSLock()
    let cancellation = LanguageRequestCancellation()
    private var value = false
    private var action: (() -> Void)?
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; action = nil; lock.unlock(); cancellation.cancel() }
    func schedule(_ work: @escaping () -> Void) { lock.lock(); if !value { action = work }; lock.unlock() }
    func run() { lock.lock(); let work = value ? nil : action; action = nil; lock.unlock(); work?() }
}
struct EditorCodeSnapshot {
    let id: UUID,uri: String,path: String,text: String,version: Int,language: CodeLanguage,root: String,remote: SSHRemote?
}
struct CodeNavigationPoint { let path: String,remote: SSHRemote?,offset: Int }

extension WorkspaceController {
    func resetLanguageServices() {
        picker?.dismiss(); picker = nil
        languageQueries.values.forEach { $0.cancel() }; languageQueries.removeAll()
        languageSyncs.values.forEach { $0.cancel() }; languageSyncs.removeAll()
        languageEdits.values.forEach { $0.cancel() }; languageEdits.removeAll()
        completionPanel?.dismiss(); hoverPopover?.close(); workspaceDiagnostics.removeAll(); languageCompletionTriggers.removeAll(); languageSignatureTriggers.removeAll(); workspaceDiagnosticCount = 0; languageStatus.stringValue = ""; languageServices.stop()
    }
    @objc func languageToolsChanged(_ notification: Notification) {
        if let scope = notification.object as? String,let current,let snapshot = codeSnapshot(current),scope != LanguageTools.scope(remote:snapshot.remote,root:snapshot.root) { return }
        resetLanguageServices()
        if let current { synchronizeLanguage(current) }
    }
    func codeDocumentSaved(_ document: OpenDocument,savedVersion: Int? = nil) {
        pluginDocumentSaved(document,revision:savedVersion ?? document.buffer.revision)
        if let metadata = codeSnapshot(document,forClosing:true) {
            let directory = metadata.path.hasSuffix("/.linvell/settings.json") ? URL(fileURLWithPath:metadata.path).deletingLastPathComponent().deletingLastPathComponent().path : metadata.root
            languageServices.queue.async { [services = languageServices] in services.filesChanged([metadata.path],root:directory,remote:metadata.remote) }
        }
        if let savedVersion,savedVersion != document.buffer.revision { return }
        if let snapshot = codeSnapshot(document) { languageServices.saved(snapshot) }
    }
    func codeSnapshot(_ document: OpenDocument,forClosing: Bool = false) -> EditorCodeSnapshot? {
        guard document.imageURL == nil,let path = document.remote?.path ?? document.fileURL?.path,forClosing || document.storage.length <= 2*1024*1024 else { return nil }
        let remote = document.remote?.connection
        let directory: String
        if let remote,remoteConnection?.host == remote.host,remoteDirectory.hasPrefix("/"),path.hasPrefix(remoteDirectory+"/") { directory = remoteDirectory }
        else if remote == nil,let project = root?.url.path,path.hasPrefix(project+"/") { directory = project }
        else { directory = URL(fileURLWithPath:path).deletingLastPathComponent().path }
        guard let language = LanguageTools.language(path:path,remote:remote,root:directory) else { return nil }
        return EditorCodeSnapshot(id:document.buffer.id,uri:URL(fileURLWithPath:path).absoluteString,path:path,text:forClosing ? "" : document.buffer.text,version:document.buffer.revision,language:language,root:directory,remote:remote)
    }
    func configureLanguageEditor(_ pane: EditorPane) {
        pane.textView.codeAction = { [weak self,weak pane] action,offset in
            guard let self,let pane,self.current === pane.document else { return }
            if action != "hover" { self.activePane = pane; self.window?.makeFirstResponder(pane.textView) }
            switch action {
            case "back": self.goBack()
            case "forward": self.goForward()
            case "definition": self.goToDefinition(at:offset)
            case "hover": self.showCodeHover(at:offset,editor:pane.textView)
            case "references": self.findReferences()
            case "rename": self.renameSymbol()
            case "completion": self.codeSuggestions()
            default: break
            }
        }
        pane.textView.codeHoverDismiss = { [weak self] in self?.hoverPopover?.close(); self?.hoverPopover = nil; self?.languageQueries["textDocument/hover"]?.cancel() }
        pane.textView.codeDismiss = { [weak self] in self?.completionPanel?.dismiss(); self?.hoverPopover?.close(); self?.languageQueries["textDocument/hover"]?.cancel(); self?.languageQueries["textDocument/completion"]?.cancel() }
        pane.textView.completionKey = { [weak self] event in
            guard let panel = self?.completionPanel,panel.isVisible else { return false }; return panel.handle(event)
        }
        if codeSnapshot(pane.document) == nil,let path = pane.document.remote?.path ?? pane.document.fileURL?.path,pane.document.storage.length <= 2*1024*1024 {
            let remote = pane.document.remote?.connection
            let root = remote == nil ? (self.root?.url.path ?? URL(fileURLWithPath:path).deletingLastPathComponent().path) : remoteDirectory
            languageServices.queue.async { [weak self,weak pane] in
                _ = try? LanguageTools.load(CodeLanguage.supported[0],remote:remote,root:root)
                DispatchQueue.main.async { if let self,let pane,self.current === pane.document { self.synchronizeLanguage(pane.document) } }
            }
        } else { synchronizeLanguage(pane.document) }
    }
    func languageDocumentChanged(_ document: OpenDocument) {
        completionPanel?.dismiss(); hoverPopover?.close()
        languageEdits.removeValue(forKey:document.buffer.id)?.cancel()
        let work = DispatchWorkItem { [weak self,weak document] in
            guard let self,let document else { return }; self.synchronizeLanguage(document)
            guard self.current === document,let editor = self.activePane?.textView,!editor.hasMarkedText(),(!editor.vimEnabled || document.vim.mode == .insert) else { return }
            let at = editor.selectedRange().location,word = EditorTextView.codeWord(in:editor.string,at:at)
            let trigger = at > 0 ? (editor.string as NSString).substring(with:NSRange(location:at-1,length:1)) : ""
            let key = self.codeSnapshot(document).map { LanguageTools.scope(remote:$0.remote,root:$0.root)+"|"+$0.language.id } ?? ""
            if at-word.location >= 2 || (self.languageCompletionTriggers[key] ?? [".",":"]).contains(trigger) { self.codeSuggestions(automatic:true) }
            if (self.languageSignatureTriggers[key] ?? ["(",","]).contains(trigger) { self.signatureHelp() }
        }
        languageEdits[document.buffer.id] = work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:work)
    }
    func synchronizeLanguage(_ document: OpenDocument) {
        guard !panes.contains(where:{ $0.document === document && $0.textView.hasMarkedText() }),let snapshot = codeSnapshot(document),LanguageTools.cached(snapshot.language,remote:snapshot.remote,root:snapshot.root).enabled else { return }
        let services = languageServices
        let ticket = LanguageQueryTicket(); languageSyncs.removeValue(forKey:snapshot.id)?.cancel(); languageSyncs[snapshot.id] = ticket
        ticket.schedule { [weak self] in
            guard !ticket.cancelled else { return }
            do {
                let session = try services.session(language:snapshot.language,root:snapshot.root,remote:snapshot.remote)
                guard !ticket.cancelled else { return }
                self?.observeDiagnostics(session,snapshot:snapshot)
                DispatchQueue.main.async { [weak self] in
                    guard self?.current?.buffer.id == snapshot.id else { return }
                    self?.languageStatus.stringValue = snapshot.language.title+" · "+L.text("Connected")
                    let key = LanguageTools.scope(remote:snapshot.remote,root:snapshot.root)+"|"+snapshot.language.id
                    self?.languageCompletionTriggers[key] = Set((session.capabilities["completionProvider"] as? [String:Any])?["triggerCharacters"] as? [String] ?? [])
                    let signature = session.capabilities["signatureHelpProvider"] as? [String:Any]
                    self?.languageSignatureTriggers[key] = Set((signature?["triggerCharacters"] as? [String] ?? [])+(signature?["retriggerCharacters"] as? [String] ?? []))
                }
                session.synchronize(uri:snapshot.uri,language:snapshot.language.documentID(path:snapshot.path),text:snapshot.text,version:snapshot.version)
                if let report = try session.pullDiagnostics(uri:snapshot.uri,cancellation:ticket.cancellation),report["kind"] as? String != "unchanged",let items = report["items"] as? [[String:Any]] {
                    self?.receiveCodeDiagnostics(uri:snapshot.uri,values:items,version:snapshot.version,snapshot:snapshot)
                    if let related = report["relatedDocuments"] as? [String:[String:Any]] {
                        for (uri,report) in related where report["kind"] as? String != "unchanged" {
                            self?.receiveCodeDiagnostics(uri:uri,values:report["items"] as? [[String:Any]] ?? [],version:report["version"] as? Int,snapshot:snapshot)
                        }
                    }
                }
            } catch is CancellationError { return }
            catch {
                DispatchQueue.main.async { [weak self] in
                    guard !ticket.cancelled,self?.current?.buffer.id == snapshot.id else { return }
                    self?.languageStatus.stringValue = snapshot.language.title+" · "+L.text("Service unavailable")
                    self?.languageStatus.toolTip = L.existing(error.localizedDescription)
                }
            }
        }
        services.queue.async { ticket.run() }
    }
    func observeDiagnostics(_ session: LanguageSession,snapshot: EditorCodeSnapshot) {
        session.rpc.notification = { [weak self,weak session] method,params in
            if method == "$/progress",let progress = params["value"] as? [String:Any] {
                let text = progress["kind"] as? String == "end" ? L.text("Connected") : String((progress["title"] as? String ?? progress["message"] as? String ?? L.text("Analyzing…")).prefix(90))
                let percentage = (progress["percentage"] as? Int).map { " \(max(0,min(100,$0)))%" } ?? ""
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let active = self.current.flatMap { self.codeSnapshot($0) },root = self.remoteConnection == nil ? self.root?.url.path : self.remoteDirectory
                    guard (active?.root == snapshot.root && active?.remote?.host == snapshot.remote?.host) || (root == snapshot.root && self.remoteConnection?.host == snapshot.remote?.host) else { return }
                    self.languageStatus.stringValue = (active?.language.title ?? snapshot.language.title)+" · "+text+percentage
                }
                return
            }
            if method == "workspace/diagnostic/refresh" { DispatchQueue.main.async { [weak self] in if let current = self?.current { self?.synchronizeLanguage(current) } }; return }
            guard method == "textDocument/publishDiagnostics",let uri = params["uri"] as? String,let values = params["diagnostics"] as? [[String:Any]] else { return }
            self?.receiveCodeDiagnostics(uri:uri,values:values,version:params["version"] as? Int ?? session?.synchronizedVersion(uri:uri),snapshot:snapshot)
        }
    }
    func languageRequest(_ method: String,at offset: Int? = nil,extra: [String:Any] = [:],quiet: Bool = false,completion: @escaping (Any,EditorCodeSnapshot) -> Void) {
        guard let document = current,let editor = activePane?.textView,let snapshot = codeSnapshot(document) else {
            if !quiet { status.stringValue = L.text("Choose a supported source file. Language services pause for files larger than 2 MiB.") }; return
        }
        guard LanguageTools.cached(snapshot.language,remote:snapshot.remote,root:snapshot.root).enabled else { if !quiet { showLanguageTools() }; return }
        let at = min((snapshot.text as NSString).length,max(0,offset ?? editor.selectedRange().location))
        let caretAtRequest = editor.selectedRange().location
        let row = document.lines.line(at:at),position = CodePosition(line:row,character:at-document.lines.starts[row])
        let snapshots = documents.compactMap { codeSnapshot($0) }.filter { $0.root == snapshot.root && $0.remote?.host == snapshot.remote?.host && $0.language.id == snapshot.language.id }
        let ticket = LanguageQueryTicket(); languageQueries.removeValue(forKey:method)?.cancel(); languageQueries[method] = ticket
        if !quiet { status.stringValue = L.text("Querying language service…") }
        let services = languageServices
        ticket.schedule { [weak self] in
            guard !ticket.cancelled else { return }
            let result = Result { () throws -> Any in
                let session = try services.session(language:snapshot.language,root:snapshot.root,remote:snapshot.remote)
                let providerKeys = ["textDocument/hover":"hoverProvider","textDocument/definition":"definitionProvider","textDocument/typeDefinition":"typeDefinitionProvider","textDocument/implementation":"implementationProvider","textDocument/declaration":"declarationProvider","textDocument/references":"referencesProvider","textDocument/rename":"renameProvider","textDocument/documentSymbol":"documentSymbolProvider","textDocument/signatureHelp":"signatureHelpProvider","textDocument/formatting":"documentFormattingProvider","textDocument/completion":"completionProvider"]
                if let key = providerKeys[method],session.capabilities[key] == nil || session.capabilities[key] as? Bool == false { throw LanguageServiceError.message("The language service does not support this action.") }
                self?.observeDiagnostics(session,snapshot:snapshot)
                for file in snapshots { session.synchronize(uri:file.uri,language:file.language.documentID(path:file.path),text:file.text,version:file.version) }
                if method == "textDocument/rename",snapshot.language.id == "swift" {
                    _ = try session.rpc.request("workspace/synchronize",params:["index":true],timeout:60)
                }
                let timeout: TimeInterval = method == "textDocument/hover" ? 3 : method == "textDocument/completion" ? 4 : method == "textDocument/rename" ? 30 : 15
                var params: [String:Any] = ["textDocument":["uri":snapshot.uri],"position":position.json]; extra.forEach { params[$0] = $1 }
                if method == "workspace/symbol" { return try services.workspaceSymbols(query:extra["query"] as? String ?? "",root:snapshot.root,remote:snapshot.remote,cancellation:ticket.cancellation) }
                if method == "textDocument/rename",let rename = session.capabilities["renameProvider"] as? [String:Any],rename["prepareProvider"] as? Bool == true {
                    let preparation = try session.rpc.request("textDocument/prepareRename",params:["textDocument":["uri":snapshot.uri],"position":position.json],timeout:8,cancellation:ticket.cancellation)
                    guard !(preparation is NSNull) else { throw LanguageServiceError.message("This symbol cannot be renamed.") }
                }
                if method.hasPrefix("workspace/") { params = extra }
                return try session.rpc.request(method,params:params,timeout:timeout,cancellation:ticket.cancellation)
            }
            DispatchQueue.main.async {
                guard let self,!ticket.cancelled,self.current?.buffer.id == snapshot.id,self.current?.buffer.revision == snapshot.version else { return }
                if ["textDocument/definition","textDocument/typeDefinition","textDocument/implementation","textDocument/declaration"].contains(method),self.activePane?.textView.selectedRange().location != caretAtRequest { return }
                switch result {
                case .success(let value): completion(value,snapshot)
                case .failure(let error): if !quiet { self.status.stringValue = L.text(error.localizedDescription)+" · "+L.text("Project → Project Settings") }
                }
            }
        }
        services.queue.async { ticket.run() }
    }
    @objc func showLanguageTools() {
        showProjectSettings()
    }
    @objc func definitionCommand() { goToDefinition() }
    func goToDefinition(at offset: Int? = nil) {
        if let offset,let editor = activePane?.textView { editor.setSelectedRange(NSRange(location:min(max(0,offset),(editor.string as NSString).length),length:0)); editor.synchronizeNativeSelection() }
        completionPanel?.dismiss(); hoverPopover?.close()
        languageRequest("textDocument/definition",at:offset) { [weak self] value,snapshot in
            guard let self else { return }
            do {
                let locations = try CodeLocation.locations(value)
                if locations.count == 1 { self.navigateCode(locations[0],remote:snapshot.remote) }
                else { self.showCodeLocations(locations,remote:snapshot.remote,title:"Definitions") }
            } catch { self.show(error) }
        }
    }
    @objc func findReferences() {
        languageRequest("textDocument/references",extra:["context":["includeDeclaration":true]]) { [weak self] value,snapshot in
            do { self?.showCodeLocations(try CodeLocation.locations(value),remote:snapshot.remote,title:"References") } catch { self?.show(error) }
        }
    }
    func showCodeLocations(_ locations: [CodeLocation],remote: SSHRemote?,title: String) {
        guard let window else { return }
        guard !locations.isEmpty else { status.stringValue = L.text("No symbol locations found."); return }
        let options = locations.prefix(2000).compactMap { location -> PickerOption? in
            guard let url = URL(string:location.uri),url.isFileURL else { return nil }
            return PickerOption(title:"\(url.lastPathComponent):\(location.range.start.line+1):\(location.range.start.character+1)",detail:url.path,invoke:{ [weak self] in self?.navigateCode(location,remote:remote) })
        }
        picker = QuickPicker(title:L.text(title),options:options,owner:window)
    }
    func codePoint() -> CodeNavigationPoint? {
        guard let document = current,let path = document.remote?.path ?? document.fileURL?.path else { return nil }
        return CodeNavigationPoint(path:path,remote:document.remote?.connection,offset:activePane?.textView.selectedRange().location ?? 0)
    }
    func navigateCode(_ location: CodeLocation,remote: SSHRemote?) {
        guard let url = URL(string:location.uri),url.isFileURL else { return }
        if let previous = codePoint() { navigationBack.append(previous); navigationBack = Array(navigationBack.suffix(100)); navigationForward.removeAll() }
        openCodeFile(url.path,remote:remote) { [weak self] in
            guard let self,let document = self.current,let editor = self.activePane?.textView,let range = try? location.range.range(in:document.buffer.text) else { return }
            editor.setSelectedRange(range); editor.synchronizeNativeSelection(); editor.scrollRangeToVisible(range); self.updateStatus()
        }
    }
    func openCodeFile(_ path: String,remote: SSHRemote?,completion: @escaping () -> Void) {
        let finish = { [weak self] in
            guard let document = self?.current,(document.remote?.path ?? document.fileURL?.path) == path,document.remote?.connection.host == remote?.host else { return }
            completion()
        }
        if let remote { openRemote(path,connection:remote,completion:finish) } else { open(URL(fileURLWithPath:path),completion:finish) }
    }
    @objc func goBack() { navigateHistory(back:true) }
    @objc func goForward() { navigateHistory(back:false) }
    private func navigateHistory(back: Bool) {
        guard let point = back ? navigationBack.popLast() : navigationForward.popLast() else { return }
        if let current = codePoint() { if back { navigationForward.append(current) } else { navigationBack.append(current) } }
        openCodeFile(point.path,remote:point.remote) { [weak self] in
            guard let editor = self?.activePane?.textView else { return }
            let range = NSRange(location:min(point.offset,(editor.string as NSString).length),length:0)
            editor.setSelectedRange(range); editor.synchronizeNativeSelection(); editor.scrollRangeToVisible(range)
        }
    }
    @objc func hoverCommand() { activePane?.textView.hoverOffset = nil; showCodeHover() }
    func showCodeHover(at offset: Int? = nil,editor chosen: EditorTextView? = nil) {
        let editor = chosen ?? activePane?.textView,at = offset ?? editor?.selectedRange().location ?? 0
        let generation = editor?.hoverGeneration
        let mouseTriggered = chosen != nil
        languageRequest("textDocument/hover",at:at,quiet:true) { [weak self,weak editor] value,_ in
            guard let self,let editor,editor.window?.isVisible == true,editor.hoverGeneration == generation,(!mouseTriggered || editor.hoverOffset == at),let result = value as? [String:Any] else { return }
            func plain(_ value: Any) -> String {
                if let text = value as? String { return text }
                if let values = value as? [Any] { return values.map(plain).joined(separator:"\n\n") }
                return (value as? [String:Any])?["value"] as? String ?? ""
            }
            let text = String(plain(result["contents"] ?? "").prefix(20_000))
            guard !text.isEmpty else { return }
            self.hoverPopover?.close()
            let popover = CodeHoverPanel()
            popover.contentViewController = CodeHoverContent(text:text) { [weak self] in self?.goToDefinition(at:at) }
            let screen = editor.firstRect(forCharacterRange:NSRange(location:at,length:0),actualRange:nil)
            let rect = mouseTriggered ? NSRect(x:editor.hoverAnchor.x,y:editor.hoverAnchor.y,width:1,height:1) : editor.convert(editor.window?.convertFromScreen(screen) ?? .zero,from:nil)
            self.hoverPopover = popover; popover.show(relativeTo:rect,of:editor,preferredEdge:.maxY)
        }
    }
    @objc func completionCommand() { codeSuggestions() }
    func codeSuggestions(automatic: Bool = false) {
        guard let editor = activePane?.textView,!editor.hasMarkedText() else { return }
        let cursor = editor.selectedRange().location
        languageRequest("textDocument/completion",quiet:automatic) { [weak self,weak editor] value,snapshot in
            guard let self,let editor,editor.window?.isVisible == true,editor.selectedRange().location == cursor else { return }
            let items = CodeCompletion.items(value)
            guard !items.isEmpty else { if !automatic { self.status.stringValue = L.text("No code suggestions.") }; return }
            self.completionPanel?.dismiss()
            self.completionPanel = CodeCompletionPanel(items:items,editor:editor) { [weak self,weak editor] item in
                guard let self,let editor,self.current?.buffer.id == snapshot.id,self.current?.buffer.revision == snapshot.version,editor.selectedRange().location == cursor else { return }
                do {
                    let range = try item.range?.range(in:editor.string) ?? EditorTextView.codeWord(in:editor.string,at:cursor)
                    let extra = try item.additional.map { (try $0.range.range(in:editor.string),$0.newText) }
                    let edits = [(range,item.text)]+extra
                    let sorted = edits.sorted { $0.0.location < $1.0.location }
                    for pair in zip(sorted,sorted.dropFirst()) where NSMaxRange(pair.0.0) > pair.1.0.location { throw DocumentError.invalidRange }
                    editor.performMultiEdit(edits.map(\.0),replacements:edits.map(\.1))
                    let shift = extra.filter { $0.0.location < range.location }.reduce(0) { $0+$1.1.utf16.count-$1.0.length }
                    editor.applySelections([NSRange(location:range.location+shift+item.text.utf16.count,length:0)])
                } catch { self.show(error) }
            }
        }
    }
}
