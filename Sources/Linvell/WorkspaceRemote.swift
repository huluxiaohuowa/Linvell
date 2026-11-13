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
                        PickerOption(title:(entry.name as NSString).lastPathComponent,detail:entry.name,invoke:{ [weak self] in self?.openRemote(entry.path,connection:connection) })
                    }
                    self.picker = QuickPicker(title:L.text("Search remote files by name"),options:options,owner:window,compact:true)
                case .failure(let error): self.show(error)
                }
            }
        }
    }
    @objc func connectSSH() {
        let hosts = SSHConfig.hosts()
        var options = hosts.map { host in PickerOption(title:host,detail:L.text("SSH configuration"),invoke:{ [weak self] in self?.connectToSSH(host) }) }
        options.append(PickerOption(title:L.text("Enter SSH host…"),detail:L.text("Uses system SSH keys, agent and configuration"),invoke:{ [weak self] in
            let alert = ThemedAlert(); alert.messageText = L.text("SSH host or config alias")
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
            if remoteConnection?.host != host || remoteDirectory != folder { persistWorkspaceTabs() }
            latestOpenRequest = nil; tabRestoreGeneration = UUID(); stopPlugins(); resetLanguageServices()
            remoteConnection = connection; remoteDirectory = "~"; root = nil; fileIndex = []
            projectTitle.stringValue = "SSH · "+host; window?.title = "SSH · "+host
            sidebarKind = "files"; sidebar.subviews.forEach { $0.removeFromSuperview() }
            remoteDirectory = folder; setupRemoteSidebar(connection)
            sidebar.isHidden = false; body.adjustSubviews(); agentProjectDidChange()
        } catch { show(error) }
    }
    func setupRemoteSidebar(_ connection: SSHRemote) {
        sidebar.layer?.backgroundColor = NSColor.clear.cgColor
        let browser = RemoteExplorer(connection:connection,path:remoteDirectory); remoteBrowser = browser
        browser.onSearch = { [weak self] in self?.quickOpenRemote(connection) }
        browser.onOpen = { [weak self] in self?.openRemote($0,connection:connection) }
        browser.onMutation = { [weak self,weak browser] path,name in
            guard let self,self.remoteBrowser === browser else { return }
            self.mutateRemoteItem(path,newName:name)
        }
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
            if self.remoteDirectory != path { self.persistWorkspaceTabs() }
            self.tabRestoreGeneration = UUID(); self.stopPlugins(); self.resetLanguageServices()
            self.remoteDirectory = path; self.sidebar.subviews.forEach { $0.removeFromSuperview() }
            self.setupRemoteSidebar(connection); self.sidebar.isHidden = false; self.body.adjustSubviews(); self.selectActivity(0); self.agentProjectDidChange()
        }
        picker.onTerminal = { [weak self] in self?.toggleTerminal() }
    }
    private func containsRemotePath(_ path: String,under root: String) -> Bool {
        path == root || path.hasPrefix(root+"/")
    }

    func isMutatingRemote(_ path: String,host: String) -> Bool {
        guard let mutation = remoteMutation,mutation.host == host else { return false }
        return containsRemotePath(path,under:mutation.path)
    }

    func mutateRemoteItem(_ path: String,newName: String?,completion: ((Result<String,Error>) -> Void)? = nil) {
        guard let connection = remoteConnection,remoteMutation == nil else { return }
        let directory = remoteDirectory,trash = newName == nil
        guard containsRemotePath(path,under:directory),path != directory else { return }
        let affected = documents.filter { document in
            guard let remote = document.remote,remote.connection.host == connection.host else { return false }
            return containsRemotePath(remote.path,under:path)
        }
        let busy = remoteLoads.values.contains { $0.host == connection.host && containsRemotePath($0.path,under:path) }
            || affected.contains { autoSaving.contains($0.buffer.id) || (trash && $0.buffer.isModified) }
        guard !busy else {
            status.stringValue = L.text(trash ? "Save or close affected tabs before moving this item to the Trash." : "Finish opening or saving the file and try again.")
            return
        }
        remoteMutation = (connection.host,path,trash)
        for document in affected {
            autoSaveWork.removeValue(forKey:document.buffer.id)?.cancel()
        }
        if trash {
            for pane in panes where affected.contains(where:{ $0 === pane.document }) { pane.textView.isEditable = false }
        }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result {
                if let newName { return try connection.renameItem(at:path,to:newName,in:directory) }
                return try connection.trashItem(at:path,in:directory)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.remoteMutation = nil
                for pane in self.panes where affected.contains(where:{ $0 === pane.document }) && trash { pane.textView.isEditable = true }
                switch result {
                case .success(let destination):
                    if trash {
                        affected.filter { document in self.documents.contains { $0 === document } }.forEach { self.closeDocument($0) }
                        self.status.stringValue = L.format("Moved to remote Trash: %@",destination)
                    } else {
                        for document in affected {
                            guard let remote = document.remote else { continue }
                            if let snapshot = self.codeSnapshot(document,forClosing:true) { self.languageServices.close(snapshot) }
                            self.languageEdits.removeValue(forKey:document.buffer.id)?.cancel()
                            self.languageDiagnostics.removeValue(forKey:document.buffer.id)?.cancel()
                            let oldCache = remote.localURL
                            remote.path = destination+String(remote.path.dropFirst(path.count))
                            let newCache = remote.localURL
                            if oldCache != newCache,(try? FileManager.default.moveItem(at:oldCache,to:newCache)) != nil {
                                if document.previewURL != nil { document.previewURL = newCache }
                                else { document.buffer.relocate(from:oldCache,to:newCache) }
                            } else if oldCache != newCache { remote.retainCache(at:oldCache) }
                            document.syntax.invalidate()
                        }
                        if let current = self.current,affected.contains(where:{ $0 === current }) { self.activate(current) }
                        else { self.renderTabs() }
                        self.status.stringValue = L.text("Remote item renamed.")
                    }
                    if self.remoteConnection?.host == connection.host,self.remoteDirectory == directory {
                        self.remoteBrowser?.refreshDirectories([(path as NSString).deletingLastPathComponent])
                    }
                    if let search = self.sidebar.subviews.first(where:{ $0 is ToolSidebar }) as? ToolSidebar,
                       self.remoteConnection?.host == connection.host,self.remoteDirectory == directory { search.refresh() }
                    self.persistWorkspaceTabs()
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
                for document in affected where self.documents.contains(where:{ $0 === document }) { self.scheduleAutoSave(document) }
                completion?(result)
            }
        }
    }

    func openRemote(_ path: String,connection: SSHRemote,completion: (() -> Void)? = nil) {
        guard !isMutatingRemote(path,host:connection.host) else { return }
        if let existing = documents.first(where:{ $0.remote?.connection.host == connection.host && $0.remote?.path == path }) { activate(existing); completion?(); return }
        let request = UUID(); latestOpenRequest = request; remoteLoads[request] = (connection.host,path)
        status.stringValue = L.text("Opening remote file…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try Self.loadRemoteDocument(path,connection:connection) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.remoteLoads.removeValue(forKey:request)
                switch result {
                case .success(let document):
                    self.finishRemoteOpen(document,request:request,completion:completion)
                case .failure(let error): if self.latestOpenRequest == request { self.show(error) }
                }
            }
        }
    }
    static func loadRemoteDocument(_ path: String,connection: SSHRemote) throws -> OpenDocument {
        let reply = try connection.request("read",path:path)
        guard let content = reply.content,let data = Data(base64Encoded:content),let digest = reply.digest else {
            throw GitError.command("The remote response is incomplete.")
        }
        let remote = try RemoteDocument(connection:connection,path:reply.path ?? path,digest:digest,data:data)
        let document = try OpenDocument.load(remote.localURL)
        document.remote = remote
        return document
    }

    func finishRemoteOpen(_ document: OpenDocument,request: UUID,completion: (() -> Void)?) {
        let existing = documents.first { $0.remote?.connection.host == document.remote?.connection.host && $0.remote?.path == document.remote?.path }
        if latestOpenRequest == request { activate(existing ?? document); completion?() }
        else if existing == nil { documents.append(document); renderTabs() }
    }

}
