import AppKit
import LinvellCore

final class RemoteDocument {
    let connection: SSHRemote
    let path: String
    var digest: String
    let cache: URL
    init(connection: SSHRemote,path: String,digest: String,data: Data,cacheRoot: URL = FileManager.default.temporaryDirectory) throws {
        self.connection = connection; self.path = path; self.digest = digest
        cache = cacheRoot.appendingPathComponent("linvell-remote-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file = cache.appendingPathComponent(URL(fileURLWithPath:path).lastPathComponent)
        try data.write(to:file,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    var localURL: URL { cache.appendingPathComponent(URL(fileURLWithPath:path).lastPathComponent) }
    deinit { try? FileManager.default.removeItem(at:cache) }
    func save(_ data: Data) throws {
        let reply = try connection.request("write",path:path,content:data,digest:digest)
        guard let updated = reply.digest else { throw GitError.command("The remote save was not acknowledged.") }
        digest = updated
    }
}

/// Runs network work off-main while preserving synchronous save/close decisions.
enum RemoteProgress {
    static func perform<T>(_ title: String,work: @escaping () throws -> T) throws -> T {
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:380,height:105),styleMask:[.titled],backing:.buffered,defer:false)
        panel.title = L.text(title); panel.center(); panel.isReleasedWhenClosed = false
        let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.startAnimation(nil)
        Theme.pin(Theme.stack([spinner,Theme.label(title,size:14)],spacing:16),in:panel.contentView!,inset:26)
        var outcome: Result<T,Error>?
        DispatchQueue.global(qos:.userInitiated).async {
            let result = Result { try work() }
            DispatchQueue.main.async { outcome = result; NSApp.stopModal() }
        }
        NSApp.runModal(for:panel); panel.orderOut(nil)
        guard let outcome else { throw GitError.command("Remote operation interrupted.") }
        return try outcome.get()
    }
}

final class RemoteBrowser: NSView, NSTableViewDelegate, NSTableViewDataSource {
    let connection: SSHRemote
    let pathField = NSTextField(),table = ResponsiveTableView(),note = Theme.label("",size:12,color:Theme.secondary)
    var entries: [RemoteEntry] = []
    var directory = "~"
    var onOpen: ((String) -> Void)?
    var onDirectory: ((String) -> Void)?
    var onTerminal: (() -> Void)?
    private var generation = UUID()
    private let directoriesOnly: Bool
    private(set) var isLoading = false
    var onSelectionChanged: (() -> Void)?
    init(connection: SSHRemote,directoriesOnly: Bool = false,initialPath: String = "~",autoLoad: Bool = true) {
        self.directoriesOnly = directoriesOnly; directory = initialPath
        self.connection = connection; super.init(frame:.zero)
        let heading = Theme.label("SSH · "+connection.host,size:13,weight:.semibold)
        let up = Theme.button("arrow.up",help:"Parent Folder",target:self,action:#selector(parent))
        let refresh = Theme.actionButton("Refresh",target:self,action:#selector(refresh)); refresh.identifier = NSUserInterfaceItemIdentifier("Linvell.Remote.Refresh")
        let terminal = Theme.button("terminal",help:"SSH Terminal",target:self,action:#selector(shell))
        let create = Theme.button("doc.badge.plus",help:"New File",target:self,action:#selector(createFile))
        create.isHidden = directoriesOnly
        pathField.placeholderString = L.text("Remote folder path"); pathField.stringValue = initialPath; pathField.target = self; pathField.action = #selector(go)
        pathField.font = .systemFont(ofSize:13)
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("remote")); table.addTableColumn(column); table.headerView = nil
        table.rowHeight = 34; table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(selectionChanged); table.doubleAction = #selector(openSelected)
        table.backgroundColor = Theme.panel; table.setAccessibilityLabel(L.text("Remote files"))
        let scroll = ResponsiveScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        Theme.pin(Theme.stack([Theme.stack([heading,NSView(),create,terminal,up,refresh],spacing:6),pathField,note,scroll],orientation:.vertical,spacing:12),in:self,inset:14)
        if autoLoad { browse(initialPath) }
    }
    var selectedDirectory: String? {
        guard !isLoading else { return nil }
        if entries.indices.contains(table.selectedRow),entries[table.selectedRow].directory { return entries[table.selectedRow].path }
        return directory
    }
    @objc private func selectionChanged() { onSelectionChanged?() }
    func tableViewSelectionDidChange(_ notification: Notification) { onSelectionChanged?() }
    required init?(coder: NSCoder) { fatalError() }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let entry = entries[row]
        return RemoteEntryCell.make(in:tableView,name:entry.name,path:entry.path,directory:entry.directory)
    }
    @objc private func openSelected() {
        guard !isLoading,entries.indices.contains(table.selectedRow) else { return }; let entry = entries[table.selectedRow]
        if entry.directory { browse(entry.path) } else { onOpen?(entry.path) }
    }
    @objc private func go() { browse(pathField.stringValue) }
    @objc private func refresh() { browse(directory,force:true) }
    @objc private func parent() { browse((directory as NSString).deletingLastPathComponent) }
    @objc private func shell() { onTerminal?() }
    @objc func createFile() {
        let alert = NSAlert(); alert.messageText = L.text("New remote file")
        let input = NSTextField(frame:NSRect(x:0,y:0,width:320,height:28)); input.placeholderString = L.text("File name")
        alert.accessoryView = input; alert.window.initialFirstResponder = input
        alert.addButton(withTitle:L.text("Create")); alert.addButton(withTitle:L.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn,!input.stringValue.isEmpty else { return }
        let path = (directory as NSString).appendingPathComponent(input.stringValue),remote = connection
        note.stringValue = L.text("Creating remote file…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try remote.request("create",path:path) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let reply): self.browse(self.directory); self.onOpen?(reply.path ?? path)
                case .failure(let error): self.note.stringValue = error.localizedDescription
                }
            }
        }
    }
    func browse(_ path: String,force: Bool = false) {
        let request = UUID(); generation = request
        let cached = connection.cachedDirectory(path)
        if let cached { apply(cached,fallback:path) }
        isLoading = cached == nil
        if isLoading { table.deselectAll(nil); note.stringValue = L.text("Connecting…") }
        onSelectionChanged?()
        let remote = connection
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try remote.listDirectory(path,force:force) }
            DispatchQueue.main.async {
                guard let self,self.generation == request else { return }
                self.isLoading = false
                defer { self.onSelectionChanged?() }
                switch result {
                case .success(let reply): self.apply(reply,fallback:path)
                case .failure(let error): self.note.stringValue = error.localizedDescription
                }
            }
        }
    }
    private func apply(_ reply: RemoteReply,fallback: String) {
        let updated = (reply.entries ?? []).filter { !directoriesOnly || $0.directory }
        let path = reply.path ?? fallback
        let changed = directory != path || entries != updated
        let selected = directory == path && entries.indices.contains(table.selectedRow) ? entries[table.selectedRow].path : nil
        entries = updated; directory = path; pathField.stringValue = path
        note.stringValue = L.format("%d entries",entries.count)
        if changed {
            table.reloadData(); table.deselectAll(nil)
            if let selected,let index = entries.firstIndex(where:{ $0.path == selected }) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
        }
        onDirectory?(path)
    }
}
