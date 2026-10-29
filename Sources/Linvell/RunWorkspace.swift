import AppKit
import WebKit
import SwiftTerm
import LinvellCore
import Darwin

final class RunWorkspace: NSView, LocalProcessTerminalViewDelegate {
    let remote: SSHRemote?
    let directory: String
    let command = NSTextField(),url = NSTextField(),presets = NSPopUpButton()
    let output = NSView()
    let preview: WKWebView
    let status = Theme.label("",size:12,color:Theme.secondary)
    var terminal: LocalProcessTerminalView?
    var tasks: [RunTask] = []
    var forward: Process?
    var forwardLog: FileHandle?
    var forwardLogURL: URL?
    init(directory: String,remote: SSHRemote?) {
        self.directory = directory; self.remote = remote
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        preview = WKWebView(frame:.zero,configuration:configuration)
        super.init(frame:.zero)
        wantsLayer = true; layer?.backgroundColor = Theme.canvas.cgColor
        appearance = NSAppearance(named:Theme.isDark ? .darkAqua : .aqua)
        command.placeholderString = L.text("Command to run, for example npm run dev")
        command.font = .monospacedSystemFont(ofSize:13,weight:.regular)
        command.target = self; command.action = #selector(run)
        url.placeholderString = "http://127.0.0.1:3000"; url.stringValue = "http://127.0.0.1:3000"
        let run = Theme.actionButton("Run",target:self,action:#selector(run)),stop = Theme.actionButton("Stop",target:self,action:#selector(stop))
        let show = Theme.actionButton("Preview",target:self,action:#selector(showPreview)),reload = Theme.actionButton("Reload",target:self,action:#selector(reloadPreview))
        presets.target = self; presets.action = #selector(selectTask)
        status.stringValue = (remote.map { "SSH · "+$0.host } ?? L.text("Local"))+" · "+directory
        let panes = ResizablePanes(); panes.addArrangedSubview(output); panes.addArrangedSubview(preview)
        Theme.pin(Theme.stack([Theme.label("Run & Preview",size:24,weight:.semibold),status,Theme.stack([presets,command,run,stop],spacing:10),Theme.stack([url,show,reload],spacing:10),panes],orientation:.vertical,spacing:14),in:self,inset:20)
        loadTasks()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { terminate(); closeForward() }
    var running: Bool { terminal?.process.running == true }
    func mayClose() -> Bool {
        guard running else { return true }
        let alert = NSAlert(); alert.messageText = L.text("Stop the running task?")
        alert.addButton(withTitle:L.text("Stop")); alert.addButton(withTitle:L.text("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func loadTasks() {
        let directory = directory,remote = remote
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let tasks = remote.flatMap { try? $0.request("tasks",path:directory).tasks } ?? (remote == nil ? RunTasks.discover(at:URL(fileURLWithPath:directory)) : [])
            DispatchQueue.main.async {
                guard let self else { return }; self.tasks = tasks; self.presets.removeAllItems()
                self.presets.addItem(withTitle:L.text("Custom command")); self.presets.addItems(withTitles:tasks.map(\.label))
            }
        }
    }
    @objc private func selectTask() {
        if presets.indexOfSelectedItem > 0 { command.stringValue = tasks[presets.indexOfSelectedItem-1].command }
    }
    @objc func run() {
        guard !running,!command.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        terminal?.removeFromSuperview()
        let term = DisplayPacedTerminalView(frame:output.bounds); terminal = term; term.processDelegate = self
        term.font = .monospacedSystemFont(ofSize:Theme.fontSize,weight:.regular)
        term.nativeBackgroundColor = Theme.canvas; term.nativeForegroundColor = Theme.foreground; term.caretColor = Theme.accent
        Theme.pin(term,in:output)
        let args: [String],executable: String
        if let remote {
            executable = "/usr/bin/ssh"; args = ["-tt","--",remote.host,RunTasks.remoteCommand(directory:directory,command:command.stringValue)]
        } else { executable = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"; args = ["-lc",command.stringValue] }
        var env = ProcessInfo.processInfo.environment; env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        term.startProcess(executable:executable,args:args,environment:env.map { "\($0.key)=\($0.value)" },currentDirectory:remote == nil ? directory : FileManager.default.homeDirectoryForCurrentUser.path)
        status.stringValue = L.text("Running")+" · "+(remote?.host ?? L.text("Local"))+" · "+directory
        window?.makeFirstResponder(term)
    }
    @objc func stop() {
        guard let terminal,running else { return }
        terminal.send(data:[3][...])
        let process = terminal.process!
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self,weak terminal] in
            guard let terminal,terminal.process === process,process.running else { return }
            self?.terminate()
        }
    }
    func terminate() {
        guard let terminal,terminal.process.running else { return }
        let pid = terminal.process.shellPid
        if pid > 0,getpgid(pid) == pid,pid != getpgrp() { kill(-pid,SIGHUP) }
        terminal.terminate()
    }
    func shutdown() { terminate(); closeForward() }
    func refreshTheme() {
        layer?.backgroundColor = Theme.canvas.cgColor; appearance = NSAppearance(named:Theme.isDark ? .darkAqua : .aqua)
        terminal?.nativeBackgroundColor = Theme.canvas; terminal?.nativeForegroundColor = Theme.foreground
        terminal?.font = .monospacedSystemFont(ofSize:Theme.fontSize,weight:.regular)
    }
    func sizeChanged(source: LocalProcessTerminalView,newCols: Int,newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView,title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView,directory: String?) {}
    func processTerminated(source: TerminalView,exitCode: Int32?) { status.stringValue = L.format("Exited with status %d",Int(exitCode ?? -1)) }
    private func closeForward() {
        if forward?.isRunning == true { forward?.terminate() }; forward = nil
        try? forwardLog?.close(); forwardLog = nil
        if let forwardLogURL { try? FileManager.default.removeItem(at:forwardLogURL) }; forwardLogURL = nil
    }
    @objc private func reloadPreview() { preview.reload() }
    @objc func showPreview() {
        guard var parts = URLComponents(string:url.stringValue),["http","https"].contains(parts.scheme?.lowercased() ?? ""),parts.user == nil,parts.password == nil,let target = parts.url else { status.stringValue = L.text("Enter an HTTP or HTTPS URL."); return }
        guard let remote else { preview.load(URLRequest(url:target)); return }
        guard ["localhost","127.0.0.1","::1"].contains(parts.host ?? "") else { status.stringValue = L.text("For remote preview, use localhost and the remote service port."); return }
        do {
            closeForward()
            let port = try Self.availablePort(),remotePort = parts.port ?? (parts.scheme == "https" ? 443 : 80)
            let process = Process(),log = FileManager.default.temporaryDirectory.appendingPathComponent("linvell-forward-"+UUID().uuidString)
            FileManager.default.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600])
            let handle = try FileHandle(forUpdating:log); forwardLog = handle; forwardLogURL = log
            process.executableURL = URL(fileURLWithPath:"/usr/bin/ssh")
            process.arguments = ["-N","-T","-o","BatchMode=yes","-o","ExitOnForwardFailure=yes","-o","ConnectTimeout=10","-o","ServerAliveInterval=15","-o","ServerAliveCountMax=2","-L","127.0.0.1:\(port):127.0.0.1:\(remotePort)","--",remote.host]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = handle
            try process.run(); forward = process
            parts.host = "127.0.0.1"; parts.port = port
            guard let localURL = parts.url else { return }
            status.stringValue = L.text("Starting SSH port forwarding…")
            waitForForward(process,port:port,url:localURL,attempts:60)
        } catch { status.stringValue = error.localizedDescription }
    }
    private func waitForForward(_ process: Process,port: Int,url: URL,attempts: Int) {
        guard forward === process else { return }
        if !process.isRunning {
            try? forwardLog?.seek(toOffset:0)
            let data = (try? forwardLog?.read(upToCount:4096)) ?? Data()
            status.stringValue = String(decoding:data,as:UTF8.self); return
        }
        if Self.listening(port) { status.stringValue = L.text("SSH port forwarding active"); preview.load(URLRequest(url:url)); return }
        guard attempts > 0 else { status.stringValue = L.text("SSH port forwarding timed out."); closeForward(); return }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { [weak self] in self?.waitForForward(process,port:port,url:url,attempts:attempts-1) }
    }
    private static func address(_ port: Int) -> sockaddr_in {
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1"); return address
    }
    static func availablePort() throws -> Int {
        let fd = socket(AF_INET,SOCK_STREAM,0); guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }; defer { close(fd) }
        var addr = address(0),length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafePointer(to:&addr) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,length) } }
        guard result == 0 else { throw CocoaError(.fileReadUnknown) }
        _ = withUnsafeMutablePointer(to:&addr) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&length) } }
        return Int(UInt16(bigEndian:addr.sin_port))
    }
    private static func listening(_ port: Int) -> Bool {
        let fd = socket(AF_INET,SOCK_STREAM,0); guard fd >= 0 else { return false }; defer { close(fd) }
        var addr = address(port)
        return withUnsafePointer(to:&addr) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }
}
