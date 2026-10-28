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
    func connectToSSH(_ host: String) {
        do {
            let connection = try SSHRemote(host:host)
            if terminal != nil {
                guard mayCloseTerminal() else { return }; terminateTerminal(); terminalHost?.removeFromSuperview(); terminalHost = nil; terminal = nil
            }
            remoteConnection = connection; remoteDirectory = "~"; root = nil; fileIndex = []
            projectTitle.stringValue = "SSH · "+host; window?.title = "SSH · "+host
            sidebarKind = "files"; sidebar.subviews.forEach { $0.removeFromSuperview() }; setupRemoteSidebar(connection)
            sidebar.isHidden = false; body.adjustSubviews()
        } catch { show(error) }
    }
    func setupRemoteSidebar(_ connection: SSHRemote) {
        let browser = RemoteBrowser(connection:connection); remoteBrowser = browser
        browser.onOpen = { [weak self] in self?.openRemote($0,connection:connection) }
        browser.onDirectory = { [weak self] in self?.remoteDirectory = $0 }
        browser.onTerminal = { [weak self] in self?.toggleTerminal() }
        Theme.pin(browser,in:sidebar)
    }
    func openRemote(_ path: String,connection: SSHRemote) {
        if let existing = documents.first(where:{ $0.remote?.connection.host == connection.host && $0.remote?.path == path }) { activate(existing); return }
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
                    if let existing = self.documents.first(where:{ $0.remote?.connection.host == connection.host && $0.remote?.path == document.remote?.path }) { self.activate(existing) }
                    else { self.activate(document) }
                case .failure(let error): self.show(error)
                }
            }
        }
    }
}
