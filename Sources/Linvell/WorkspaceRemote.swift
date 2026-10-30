import AppKit
import LinvellCore

extension WorkspaceController {
    func quickOpenRemote(_ connection: SSHRemote) {
        let directory = remoteDirectory
        status.stringValue = L.text("Indexing remote files…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try connection.request("files",path:directory) }
            DispatchQueue.main.async {
                guard let self,let window = self.window else { return }
                switch result {
                case .success(let reply):
                    let options = (reply.entries ?? []).map { entry in
                        PickerOption(title:entry.name,detail:L.text("Remote file"),invoke:{ [weak self] in self?.openRemote(entry.path,connection:connection) })
                    }
                    self.picker = QuickPicker(title:L.text("Search remote files by name"),options:options,owner:window)
                case .failure(let error): self.show(error)
                }
            }
        }
    }
    @objc func connectSSH() {
        let hosts = SSHConfig.hosts()
        var options = hosts.map { host in PickerOption(title:host,detail:L.text("SSH configuration"),invoke:{ [weak self] in self?.connectToSSH(host) }) }
        options.append(PickerOption(title:L.text("Enter SSH host…"),detail:L.text("Uses system SSH keys, agent and configuration"),invoke:{ [weak self] in
            let alert = NSAlert(); alert.messageText = L.text("SSH host or config alias")
            let input = NSTextField(frame:NSRect(x:0,y:0,width:340,height:28)); alert.accessoryView = input
            alert.addButton(withTitle:L.text("Connect")); alert.addButton(withTitle:L.text("Cancel")); alert.window.initialFirstResponder = input
            if alert.runModal() == .alertFirstButtonReturn { self?.connectToSSH(input.stringValue) }
        }))
        picker = QuickPicker(title:L.text("Connect to SSH Host"),options:options,owner:window!)
    }
    func connectToSSH(_ host: String,folder: String? = nil) {
        do {
            let connection = try SSHRemote(host:host)
            guard let folder else {
                guard let window else { return }
                let picker = RemoteFolderPicker(connection:connection,path:"~",owner:window)
                remoteFolderPicker = picker
                picker.onChoose = { [weak self] path in self?.connectToSSH(host,folder:path) }
                picker.onTerminal = { [weak self] in self?.connectToSSH(host,folder:"~"); self?.toggleTerminal() }
                return
            }
            if terminal != nil {
                guard mayCloseTerminal() else { return }; terminateTerminal(); terminalHost?.removeFromSuperview(); terminalHost = nil; terminal = nil
            }
            latestOpenRequest = nil; stopPlugins(); resetLanguageServices()
            remoteConnection = connection; remoteDirectory = "~"; root = nil; fileIndex = []
            projectTitle.stringValue = "SSH · "+host; window?.title = "SSH · "+host
            sidebarKind = "files"; sidebar.subviews.forEach { $0.removeFromSuperview() }
            remoteDirectory = folder; setupRemoteSidebar(connection)
            sidebar.isHidden = false; body.adjustSubviews(); agentProjectDidChange()
        } catch { show(error) }
    }
    func setupRemoteSidebar(_ connection: SSHRemote) {
        let browser = RemoteExplorer(connection:connection,path:remoteDirectory); remoteBrowser = browser
        browser.onOpen = { [weak self] in self?.openRemote($0,connection:connection) }
        browser.onRootLoaded = { [weak self,weak browser] path in
            guard let self,self.remoteBrowser === browser else { return }
            self.remoteDirectory = path; self.syncManagedPlugins(); self.agentProjectDidChange()
            self.projectTitle.stringValue = URL(fileURLWithPath:path).lastPathComponent+" · SSH"
            WorkspaceSession.save(.ssh(host:connection.host,path:path))
        }
        browser.onTerminal = { [weak self] in self?.toggleTerminal() }
        browser.onChooseFolder = { [weak self] in self?.openRemoteFolder() }
        Theme.pin(browser,in:sidebar)
    }
    @objc func openRemoteFolder() {
        guard let connection = remoteConnection,let window else { connectSSH(); return }
        let picker = RemoteFolderPicker(connection:connection,path:remoteDirectory,owner:window); remoteFolderPicker = picker
        picker.onChoose = { [weak self] path in
            guard let self,self.remoteConnection?.host == connection.host else { return }
            self.stopPlugins(); self.resetLanguageServices()
            self.remoteDirectory = path; self.sidebar.subviews.forEach { $0.removeFromSuperview() }
            self.setupRemoteSidebar(connection); self.sidebar.isHidden = false; self.body.adjustSubviews(); self.selectActivity(0); self.agentProjectDidChange()
        }
        picker.onTerminal = { [weak self] in self?.toggleTerminal() }
    }
    func openRemote(_ path: String,connection: SSHRemote,completion: (() -> Void)? = nil) {
        if let existing = documents.first(where:{ $0.remote?.connection.host == connection.host && $0.remote?.path == path }) { activate(existing); completion?(); return }
        let request = UUID(); latestOpenRequest = request
        status.stringValue = L.text("Opening remote file…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { () throws -> (OpenDocument,RemoteDocument) in
                let reply = try connection.request("read",path:path)
                guard let content = reply.content,let data = Data(base64Encoded:content),let digest = reply.digest else { throw GitError.command("The remote response is incomplete.") }
                let remote = try RemoteDocument(connection:connection,path:reply.path ?? path,digest:digest,data:data)
                let document = ImagePreview.supports(remote.localURL) ? OpenDocument(imageURL:remote.localURL) : OpenDocument(try DocumentBuffer(url:remote.localURL))
                document.remote = remote
                return (document,remote)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let (document,_)):
                    self.finishRemoteOpen(document,request:request,completion:completion)
                case .failure(let error): if self.latestOpenRequest == request { self.show(error) }
                }
            }
        }
    }
    func finishRemoteOpen(_ document: OpenDocument,request: UUID,completion: (() -> Void)?) {
        let existing = documents.first { $0.remote?.connection.host == document.remote?.connection.host && $0.remote?.path == document.remote?.path }
        if latestOpenRequest == request { activate(existing ?? document); completion?() }
        else if existing == nil { documents.append(document); renderTabs() }
    }

}
