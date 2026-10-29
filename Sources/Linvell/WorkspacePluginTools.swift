import AppKit
import LinvellCore
import LinvellPluginKit

extension WorkspaceController {
    func pluginLanguage(path: String,remote: SSHRemote?,root: String) -> CodeLanguage? {
        for owner in pluginSessions.values where !owner.isStopped && owner.runtime.remote?.host == remote?.host && owner.runtime.root == root {
            if let server = owner.package.manifest.languageServers?.first(where:{ ($0.fileExtensions ?? []).contains(URL(fileURLWithPath:path).pathExtension) }),let id = server.languages.first {
                return CodeLanguage.supported.first { $0.id == id } ?? CodeLanguage.custom(id:id)
            }
        }; return nil
    }
    func refreshPluginProviders() {
        let owners = pluginSessions.values.filter { !$0.isStopped }
        let providers = owners.flatMap { owner in (owner.package.manifest.languageServers ?? []).flatMap { server in server.languages.map { ($0,(owner,server)) } } }
        resetLanguageServices()
        languageServices.queue.async { [services = languageServices] in services.pluginProviders = Dictionary(providers,uniquingKeysWith:{ first,_ in first }) }
        for document in documents { synchronizeLanguage(document) }
    }
    func pluginToolOptions(_ session: PluginSession) -> [PickerOption] {
        var values = [PickerOption(title:L.text("Plugin Logs"),detail:session.package.manifest.name,invoke:{ [weak self] in self?.showPluginLogs(session) }),PickerOption(title:L.text("Reconnect Plugin"),detail:session.package.manifest.name,invoke:{ [weak self] in self?.reconnectPlugin(session) })]
        guard !session.isStopped else { return values }
        values += (session.package.manifest.tasks ?? []).map { task in PickerOption(title:task.title,detail:L.text("Plugin Task")+" · "+session.package.manifest.name,invoke:{ [weak self] in self?.runPluginTask(task.id,session:session) }) }
        values += (session.package.manifest.debuggers ?? []).map { debugger in PickerOption(title:debugger.title,detail:L.text("Plugin Debugger")+" · "+session.package.manifest.name,invoke:{ [weak self] in self?.startPluginDebugger(debugger.id,session:session) }) }
        return values
    }
    func reconnectPlugin(_ session: PluginSession) {
        do { try installPlugin(PluginPackage(directory:session.package.directory),persistence:session.persistence) } catch { show(error) }
    }
    func showPluginLogs(_ session: PluginSession) {
        let key = session.sessionID.uuidString+"/tools/logs"
        let panel = (pluginWindows[key] as? PluginLogWindow) ?? PluginLogWindow(owner:self,title:session.package.manifest.name+" — "+L.text("Plugin Logs"),logs:session.logs)
        pluginWindows[key] = panel; panel.reload(); panel.showWindow(nil); panel.window?.makeKeyAndOrderFront(nil)
    }
    func runPluginTask(_ id: String,session: PluginSession) {
        guard let task = session.package.manifest.tasks?.first(where:{ $0.id == id }),!session.isStopped else { return }
        let key = session.sessionID.uuidString+"/tools/task/"+id
        if let existing = pluginWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        status.stringValue = L.text("Preparing plugin tool…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try session.runtime.command(task.program) }
            DispatchQueue.main.async {
                guard let self,self.pluginSessions[session.package.manifest.id] === session,!session.isStopped else { return }
                do {
                    let (path,args) = try result.get()
                    let panel = PluginTaskWindow(owner:self,title:task.title,directory:session.runtime.root,remote:session.runtime.remote)
                    panel.runView.command.stringValue = ([path]+args).map(SSHRemote.quote).joined(separator:" ")
                    self.pluginWindows[key] = panel; panel.showWindow(nil); panel.window?.makeKeyAndOrderFront(nil)
                    panel.runView.run(); self.status.stringValue = task.title
                } catch { session.logs.append(error.localizedDescription); self.show(error) }
            }
        }
    }
    func startPluginDebugger(_ id: String,session: PluginSession) {
        guard let debugger = session.package.manifest.debuggers?.first(where:{ $0.id == id }),!session.isStopped else { return }
        let key = session.sessionID.uuidString+"/tools/debug/"+id
        if let existing = pluginWindows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        var breakpoints: [String:[Int]] = [:]
        if let document = current,let editor = activePane?.textView,let path = document.remote?.path ?? document.fileURL?.path,document.remote?.connection.host == session.runtime.remote?.host {
            breakpoints[path] = [CodePosition(offset:editor.selectedRange().location,in:editor.string).line+1]
        }
        let panel = PluginDebugWindow(owner:self,title:debugger.title,logs:session.logs)
        pluginWindows[key] = panel; panel.showWindow(nil); panel.window?.makeKeyAndOrderFront(nil)
        panel.start(runtime:session.runtime,debugger:debugger,breakpoints:breakpoints)
    }
}

final class PluginTaskWindow: PluginOwnedWindow {
    let runView: RunWorkspace
    init(owner: WorkspaceController,title: String,directory: String,remote: SSHRemote?) {
        runView = RunWorkspace(directory:directory,remote:remote); super.init(owner:owner,title:title); Theme.pin(runView,in:window!.contentView!)
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { runView.shutdown() }
    override func close() { runView.shutdown(); super.close() }
}
class PluginLogWindow: PluginOwnedWindow {
    let logs: PluginLogBuffer
    let text = NSTextView(),content = NSStackView()
    init(owner: WorkspaceController,title: String,logs: PluginLogBuffer) {
        self.logs = logs; super.init(owner:owner,title:title)
        text.isEditable = false; text.isRichText = false; text.font = .monospacedSystemFont(ofSize:12,weight:.regular); text.backgroundColor = Theme.canvas; text.textColor = Theme.foreground
        text.isVerticallyResizable = true; text.autoresizingMask = .width; text.textContainer?.widthTracksTextView = true
        let scroll = ResponsiveScrollView(); scroll.documentView = text; scroll.hasVerticalScroller = true
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 8
        content.addArrangedSubview(Theme.actionButton("Refresh Plugin Logs",target:self,action:#selector(reload)))
        content.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true
        Theme.pin(content,in:window!.contentView!,inset:12); reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func reload() { text.string = logs.text }
}
final class PluginDebugWindow: PluginLogWindow {
    private let queue = DispatchQueue(label:"top.fuluwa.linvell.plugin-debug")
    private var session: PluginDebugSession?
    private var threadID: Int?,frameID: Int?
    private var closed = false
    private let expression = NSTextField()
    override init(owner: WorkspaceController,title: String,logs: PluginLogBuffer) {
        super.init(owner:owner,title:title,logs:logs)
        let buttons = [("Continue","continue"),("Pause","pause"),("Step Over","next"),("Step Into","stepIn"),("Step Out","stepOut"),("Stack & Variables","stackTrace"),("Stop Debugging","disconnect")].map { title,command -> NSButton in
            let button = Theme.actionButton(title,target:self,action:#selector(action(_:))); button.identifier = .init(command); return button
        }
        content.insertArrangedSubview(Theme.stack(buttons,spacing:6),at:0)
        expression.placeholderString = L.text("Debug expression"); expression.target = self; expression.action = #selector(evaluate)
        content.insertArrangedSubview(Theme.stack([expression,Theme.actionButton("Evaluate",target:self,action:#selector(evaluate))]),at:1)
    }
    required init?(coder: NSCoder) { fatalError() }
    func start(runtime: PluginRuntime,debugger: PluginDebugger,breakpoints: [String:[Int]]) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let session = try PluginDebugSession(runtime:runtime,debugger:debugger,logs:self.logs)
                let cancelled = DispatchQueue.main.sync { () -> Bool in
                    if self.closed { session.stop(); return true }; self.session = session; return false
                }
                if cancelled { return }
                session.event = { [weak self] event,params in
                    DispatchQueue.main.async {
                        guard let self,!self.closed else { return }
                        if ["stopped","continued","exited","terminated"].contains(event) { self.logs.append(L.text(event)) }
                        if event == "stopped" { self.threadID = params["threadId"] as? Int; self.inspect() }
                        self.reload()
                    }
                }
                try session.start(debugger,root:runtime.root,breakpoints:breakpoints)
                DispatchQueue.main.async { self.reload() }
            } catch { self.logs.append(error.localizedDescription); DispatchQueue.main.async { self.session?.stop(); self.reload() } }
        }
    }
    @objc private func action(_ button: NSButton) {
        guard let command = button.identifier?.rawValue else { return }
        if command == "stackTrace" { inspect(); return }
        if command == "disconnect" { shutdown(); return }
        guard let session else { return }; let thread = threadID
        queue.async { [weak self] in
            do {
                var id = thread
                if id == nil { let reply = try session.request("threads") as? [String:Any]; id = (reply?["threads"] as? [[String:Any]])?.first?["id"] as? Int }
                guard let id else { throw PluginError.unavailable }; _ = try session.request(command,arguments:["threadId":id])
            } catch { self?.logs.append(error.localizedDescription) }
            DispatchQueue.main.async { self?.reload() }
        }
    }
    private func inspect() {
        guard let session,let threadID else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let stack = try session.request("stackTrace",arguments:["threadId":threadID,"levels":30]) as? [String:Any]
                let frames = stack?["stackFrames"] as? [[String:Any]] ?? []; for frame in frames {
                    let source = frame["source"] as? [String:Any] ?? [:]
                    self.logs.append((frame["name"] as? String ?? "?")+" — "+(source["path"] as? String ?? "")+":"+String(frame["line"] as? Int ?? 0))
                }
                if let frame = frames.first,let id = frame["id"] as? Int {
                    DispatchQueue.main.async { self.frameID = id }
                    let scopes = try session.request("scopes",arguments:["frameId":id]) as? [String:Any]
                    for scope in (scopes?["scopes"] as? [[String:Any]] ?? []).prefix(8) {
                        if let ref = scope["variablesReference"] as? Int { let reply = try session.request("variables",arguments:["variablesReference":ref,"count":100]) as? [String:Any]
                            for variable in reply?["variables"] as? [[String:Any]] ?? [] { self.logs.append((variable["name"] as? String ?? "?")+": "+(variable["type"] as? String ?? "")+" = "+(variable["value"] as? String ?? "")) } }
                    }
                }
            } catch { self.logs.append(error.localizedDescription) }
            DispatchQueue.main.async { self.reload() }
        }
    }
    @objc private func evaluate() {
        guard let session else { return }; let value = expression.stringValue,id = frameID
        queue.async { [weak self] in
            do { var args: [String:Any] = ["expression":value,"context":"repl"]; if let id { args["frameId"] = id }; let reply = try session.request("evaluate",arguments:args) as? [String:Any]; self?.logs.append(reply?["result"] as? String ?? "") } catch { self?.logs.append(error.localizedDescription) }
            DispatchQueue.main.async { self?.reload() }
        }
    }
    private func shutdown() { closed = true; let current = session; session = nil; current?.stop(); reload() }
    override func close() { shutdown(); super.close() }
    func windowWillClose(_ notification: Notification) { shutdown() }
}
