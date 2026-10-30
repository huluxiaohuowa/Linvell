import AppKit
import LinvellCore

/// Watches the files the editor actually displays. Metadata probes stay off-main;
/// a hidden agent window and its PTY have independent lifetimes.
final class AgentFileMonitor {
    private weak var workspace: WorkspaceController?
    private var timer: Timer?
    private var busy = false,stopped = false
    private var generation = UUID()
    private var lastRemotePoll = Date.distantPast
    private let queue = DispatchQueue(label:"top.fuluwa.linvell.agent-file-watch",qos:.utility)
    private var states: [String:String] = [:]
    private struct Target {
        let document: OpenDocument
        let id: UUID
        let revision: Int
        let url: URL
        let remote: SSHRemote?
        let path: String
        let wantsReload: Bool
        var key: String { (remote.map { "ssh:"+$0.host+":" } ?? "local:")+path+":"+id.uuidString }
    }
    init(workspace: WorkspaceController) {
        self.workspace = workspace
        let timer = Timer(timeInterval:1,repeats:true) { [weak self] _ in self?.poll() }
        self.timer = timer; RunLoop.main.add(timer,forMode:.common); poll()
    }
    deinit { timer?.invalidate() }
    func stop() { stopped = true; generation = UUID(); timer?.invalidate(); timer = nil }
    func poll() {
        guard !busy,!stopped,let workspace else { return }
        let pollRemote = Date().timeIntervalSince(lastRemotePoll) >= 2
        if pollRemote { lastRemotePoll = Date() }
        let targets = workspace.documents.compactMap { document -> Target? in
            guard document.imageURL == nil,let url = document.buffer.url,document.remote == nil || pollRemote else { return nil }
            return Target(document:document,id:document.buffer.id,revision:document.buffer.revision,url:url,remote:document.remote?.connection,path:document.remote?.path ?? url.path,wantsReload:document.externalChange && !document.buffer.isModified)
        }
        let root = workspace.root
        var directories: [FileNode] = root.map { [$0] } ?? []
        if workspace.sidebarKind == "files" {
            directories += (0..<workspace.outline.numberOfRows).compactMap { row in
                guard let node = workspace.outline.item(atRow:row) as? FileNode,node.isDirectory,workspace.outline.isItemExpanded(node) else { return nil }; return node
            }
        }
        let remote = pollRemote ? workspace.remoteConnection : nil
        let remotePaths = remote == nil ? [] : workspace.remoteBrowser?.visibleDirectories ?? []
        let remoteRoot = workspace.remoteDirectory,request = generation
        busy = true
        queue.async { [weak self,weak workspace] in
            guard let self else { return }
            var replacements: [(Target,DocumentBuffer,String?)] = [],missing: [Target] = []
            var trees: [(FileNode,[FileNode])] = [],changedRemoteDirectories = Set<String>()
            var remoteStates: [String:[String:String]] = [:]
            var hosts: [String:SSHRemote] = [:],pathsByHost: [String:Set<String>] = [:]
            for target in targets { if let remote = target.remote { hosts[remote.host] = remote; pathsByHost[remote.host,default:[]].insert(target.path) } }
            if let remote { hosts[remote.host] = remote; pathsByHost[remote.host,default:[]].formUnion(remotePaths) }
            for (host,connection) in hosts {
                let paths = Array(pathsByHost[host] ?? [])
                if let data = try? JSONSerialization.data(withJSONObject:paths),let reply = try? connection.request("editor-file-states",path:remoteRoot,content:data) { remoteStates[host] = reply.fileStates }
            }
            for target in targets {
                let state: String?
                if let remote = target.remote { state = remoteStates[remote.host]?[target.path] }
                else { state = Self.signature(target.path) }
                guard let state,self.states[target.key] != state || target.wantsReload else { continue }
                if state == "missing" { missing.append(target); self.states[target.key] = state; continue }
                do {
                    let buffer: DocumentBuffer,digest: String?
                    if let remote = target.remote {
                        let reply = try remote.request("read",path:target.path)
                        guard let content = reply.content,let data = Data(base64Encoded:content),let checksum = reply.digest else { continue }
                        buffer = try DocumentBuffer(data:data,url:target.url); digest = checksum
                    } else { buffer = try DocumentBuffer(url:target.url); digest = nil }
                    replacements.append((target,buffer,digest)); self.states[target.key] = state
                } catch { /* Retry a partial write or transient SSH failure on the next tick. */ }
            }
            for node in directories {
                let key = "directory:"+node.url.path,state = Self.signature(node.url.path)
                guard self.states[key] != state,state != "missing",let urls = try? FileManager.default.contentsOfDirectory(at:node.url,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles]) else { continue }
                let children = urls.map(FileNode.init).sorted { a,b in a.isDirectory != b.isDirectory ? a.isDirectory : a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending }
                trees.append((node,children)); self.states[key] = state
            }
            if let remote {
                for path in remotePaths {
                    let key = "ssh-directory:"+remote.host+":"+path
                    if let state = remoteStates[remote.host]?[path],self.states[key] != state { changedRemoteDirectories.insert(path); self.states[key] = state }
                }
            }
            // Bound metadata to currently open documents and visible directories.
            let activeKeys = Set(targets.map(\.key)+directories.map { "directory:"+$0.url.path }+remotePaths.map { "ssh-directory:"+(remote?.host ?? "")+":"+$0 })
            if pollRemote { self.states = self.states.filter { activeKeys.contains($0.key) } }
            DispatchQueue.main.async { [weak self,weak workspace] in
                guard let self else { return }; self.busy = false
                guard let workspace,!self.stopped,self.generation == request else { return }
                for (target,buffer,digest) in replacements {
                    if workspace.documents.contains(where:{ $0 === target.document }) { workspace.applyExternalFile(buffer,to:target.document,revision:target.revision,remoteDigest:digest) }
                }
                for target in missing where workspace.documents.contains(where:{ $0 === target.document }) { workspace.markExternalChange(target.document) }
                if workspace.root === root { for (node,children) in trees { workspace.updateExternalDirectory(node,children:children) } }
                if workspace.remoteConnection?.host == remote?.host,workspace.remoteDirectory == remoteRoot { workspace.remoteBrowser?.refreshDirectories(changedRemoteDirectories) }
            }
        }
    }
    private static func signature(_ path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath:path) else { return "missing" }
        return String((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)+":"+String(describing:attrs[.size])+":"+String(describing:attrs[.systemFileNumber])
    }
    func retry(_ id: UUID) { queue.async { [weak self] in self?.states = self?.states.filter { !$0.key.hasSuffix(":"+id.uuidString) } ?? [:] } }
}

extension WorkspaceController {
    func markExternalChange(_ document: OpenDocument) {
        document.externalChange = true; autoSaveWork.removeValue(forKey:document.buffer.id)?.cancel()
        if current === document { updateStatus() }
    }
    func applyExternalFile(_ buffer: DocumentBuffer,to document: OpenDocument,revision: Int,remoteDigest: String? = nil) {
        guard !document.buffer.matchesDisk(buffer) else {
            if document.externalChange { document.externalChange = false; if current === document { updateStatus() } }; return
        }
        guard document.buffer.revision == revision else { agentFileMonitor?.retry(document.buffer.id); return }
        guard !document.buffer.isModified,!panes.contains(where:{ $0.document === document && $0.textView.hasMarkedText() }) else { markExternalChange(document); return }
        let visible = panes.filter { $0.document === document }
        let positions = visible.map { ($0,$0.textView.editingSelections,$0.scrollAnchor) }
        guard document.buffer.adoptExternal(buffer) else { return }
        document.storage.replaceCharacters(in:NSRange(location:0,length:document.storage.length),with:buffer.text)
        document.externalChange = false
        if let remote = document.remote,let remoteDigest {
            remote.digest = remoteDigest; try? buffer.dataForSaving().write(to:remote.localURL,options:.atomic)
        }
        document.vim.sync(text:buffer.text,cursor:min(document.vim.cursor,(buffer.text as NSString).length))
        for (pane,selections,anchor) in positions {
            pane.textView.undoManager?.removeAllActions(withTarget:pane.textView)
            pane.textView.applySelections(selections.map { NSRange(location:min($0.location,document.storage.length),length:min($0.length,max(0,document.storage.length-$0.location))) })
            pane.refreshCodePresentation(); pane.scrollFromPreview(anchor)
        }
        if current === document { markdownView?.render(buffer.text); updateStatus() }
        synchronizeLanguage(document); synchronizePluginDocuments(); updateTabTitles()
    }
    func updateExternalDirectory(_ node: FileNode,children: [FileNode]) {
        let old = node.children
        guard old.count != children.count || zip(old,children).contains(where:{ $0.url != $1.url || $0.isDirectory != $1.isDirectory }) else { return }
        let retained = Dictionary(old.map { ($0.url.path,$0) },uniquingKeysWith:{ a,_ in a })
        let expanded = (0..<outline.numberOfRows).compactMap { row -> FileNode? in
            guard let item = outline.item(atRow:row) as? FileNode,outline.isItemExpanded(item) else { return nil }; return item
        }
        let selected = outline.item(atRow:outline.selectedRow) as? FileNode
        node.children = children.map { child in if let prior = retained[child.url.path],prior.isDirectory == child.isDirectory { return prior }; return child }
        if node === root { outline.reloadData() } else { outline.reloadItem(node,reloadChildren:true) }
        for item in expanded { outline.expandItem(item) }
        if let selected { let row = outline.row(forItem:selected); if row >= 0 { outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) } }
        if let root {
            let url = root.url
            DispatchQueue.global(qos:.utility).async { [weak self] in
                let files = ProjectFiles.list(url)
                DispatchQueue.main.async { if self?.root === root { self?.fileIndex = files } }
            }
        }
    }
}
