import AppKit
import LinvellCore

final class RemoteTreeNode: NSObject {
    var name: String,path: String
    let isDirectory: Bool
    let isIgnored: Bool
    var children: [RemoteTreeNode]?
    var loading = false
    var wantsExpanded = false
    init(name: String,path: String,directory: Bool,ignored: Bool = false) { self.name = name; self.path = path; isDirectory = directory; isIgnored = ignored }
}

final class RemoteExplorer: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let connection: SSHRemote
    let table = ResponsiveOutlineView()
    private let note = NSTextField(wrappingLabelWithString:"")
    private(set) var rootNode: RemoteTreeNode
    var directory: String { rootNode.path }
    var onOpen: ((String) -> Void)?
    var onRootLoaded: ((String) -> Void)?
    var onTerminal: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onSearch: (() -> Void)?
    var onMutation: ((String,String?) -> Void)?
    private var pendingRefresh = Set<String>()
    init(connection: SSHRemote,path: String) {
        self.connection = connection
        rootNode = RemoteTreeNode(name:URL(fileURLWithPath:path).lastPathComponent,path:path,directory:true)
        super.init(frame:.zero)
        let title = Theme.label("SSH · "+connection.host,size:12,weight:.semibold); title.lineBreakMode = .byTruncatingMiddle
        let open = WorkspaceGlass.icon("folder.badge.plus",help:"Open Remote Folder…",target:self,action:#selector(chooseFolder))
        let create = WorkspaceGlass.icon("doc.badge.plus",help:"New File",target:self,action:#selector(createFile))
        let shell = WorkspaceGlass.icon("terminal",help:"SSH Terminal",target:self,action:#selector(terminal))
        let refresh = WorkspaceGlass.icon("arrow.clockwise",help:"Refresh Files",target:self,action:#selector(reload))
        let search = WorkspaceGlass.icon("magnifyingglass",help:"Search remote files by name",target:self,action:#selector(searchFiles))
        note.font = .systemFont(ofSize:11); note.textColor = Theme.liveSecondary; note.maximumNumberOfLines = 3
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("remote-tree")); column.width = 300; column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.outlineTableColumn = column; table.headerView = nil
        table.dataSource = self; table.delegate = self; table.rowHeight = 23; table.indentationPerLevel = 15
        table.style = .sourceList
        table.backgroundColor = .clear; table.autoresizingMask = [.width]; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.autoresizesOutlineColumn = true
        table.target = self; table.action = #selector(selected); table.doubleAction = #selector(toggled)
        let menu = NSMenu(); menu.delegate = self; table.menu = menu
        table.setAccessibilityLabel(L.text("Remote project files"))
        let scroll = ResponsiveScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        Theme.pin(Theme.stack([title,Theme.stack([open,create,shell,search,NSView(),refresh],spacing:4),note,scroll],orientation:.vertical,spacing:6),in:self,inset:10)
        rootNode.wantsExpanded = true; load(rootNode)
    }
    required init?(coder: NSCoder) { fatalError() }
    func outlineView(_ outlineView: NSOutlineView,numberOfChildrenOfItem item: Any?) -> Int { item == nil ? 1 : (item as? RemoteTreeNode)?.children?.count ?? 0 }
    func outlineView(_ outlineView: NSOutlineView,child index: Int,ofItem item: Any?) -> Any { item == nil ? rootNode : (item as! RemoteTreeNode).children![index] }
    func outlineView(_ outlineView: NSOutlineView,isItemExpandable item: Any) -> Bool { (item as? RemoteTreeNode)?.isDirectory == true }
    func outlineView(_ outlineView: NSOutlineView,shouldExpandItem item: Any) -> Bool {
        guard let node = item as? RemoteTreeNode else { return false }; node.wantsExpanded = true
        if node.children == nil { load(node) }; return true
    }
    func outlineView(_ outlineView: NSOutlineView,shouldCollapseItem item: Any) -> Bool { (item as? RemoteTreeNode)?.wantsExpanded = false; return true }
    func outlineView(_ outlineView: NSOutlineView,viewFor tableColumn: NSTableColumn?,item: Any) -> NSView? {
        guard let node = item as? RemoteTreeNode else { return nil }
        return RemoteEntryCell.make(in:outlineView,name:node.name,path:node.path,directory:node.isDirectory,ignored:node.isIgnored)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = table.item(atRow:table.clickedRow) as? RemoteTreeNode,node !== rootNode else { return }
        for (title,action) in [("Rename…",#selector(renameItem(_:))),("Move to Trash…",#selector(trashItem(_:)))] {
            let item = NSMenuItem(title:L.text(title),action:action,keyEquivalent:"")
            item.target = self; item.representedObject = node; menu.addItem(item)
        }
    }
    @objc private func renameItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? RemoteTreeNode,let window else { return }
        let alert = ThemedAlert(); alert.messageText = L.text("Rename…")
        let field = NSTextField(string:node.name)
        field.frame.size = NSSize(width:310,height:26)
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        alert.addButton(withTitle:L.text("Rename")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn,field.stringValue != node.name else { return }
            self?.onMutation?(node.path,field.stringValue)
        }
    }
    @objc private func trashItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? RemoteTreeNode,let window else { return }
        let alert = ThemedAlert()
        alert.messageText = L.format("Move “%@” to the Trash?",node.name)
        alert.informativeText = L.text("The item will be moved to the Trash on the SSH host.")
        alert.addButton(withTitle:L.text("Move to Trash")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.onMutation?(node.path,nil) }
        }
    }
    @objc private func selected() {
        guard let node = table.item(atRow:table.selectedRow) as? RemoteTreeNode,!node.isDirectory else { return }
        onOpen?(node.path)
    }
    @objc private func toggled() {
        guard let node = table.item(atRow:table.clickedRow) as? RemoteTreeNode,node.isDirectory else { return }
        if table.isItemExpanded(node) { table.collapseItem(node) } else { table.expandItem(node) }
    }
    @objc private func searchFiles() { onSearch?() }
    @objc private func chooseFolder() { onChooseFolder?() }
    @objc private func terminal() { onTerminal?() }
    @objc func reload() { rootNode.wantsExpanded = true; refreshDirectories(Set(visibleDirectories)) }
    var visibleDirectories: [String] {
        [rootNode.path]+(0..<table.numberOfRows).compactMap { row in
            guard let node = table.item(atRow:row) as? RemoteTreeNode,node !== rootNode,node.isDirectory,table.isItemExpanded(node) else { return nil }; return node.path
        }
    }
    func refreshDirectories(_ paths: Set<String>) {
        let nodes = [rootNode]+(0..<table.numberOfRows).compactMap { table.item(atRow:$0) as? RemoteTreeNode }
        var visited = Set<String>()
        for node in nodes where node.isDirectory && paths.contains(node.path) && visited.insert(node.path).inserted { load(node,force:true) }
    }
    private func apply(_ reply: RemoteReply,to node: RemoteTreeNode) {
        if node === rootNode,let path = reply.path { node.path = path; node.name = URL(fileURLWithPath:path).lastPathComponent }
        let entries = (reply.entries ?? []).filter { $0.name != ".git" }
        let existing = node.children ?? []
        let unchanged = node.children != nil && existing.count == entries.count && zip(existing,entries).allSatisfy { $0.name == $1.name && $0.path == $1.path && $0.isDirectory == $1.directory && $0.isIgnored == $1.isIgnored }
        guard !unchanged else { return }
        let retained = Dictionary(existing.map { ($0.path,$0) },uniquingKeysWith:{ first,_ in first })
        node.children = entries.map { entry in
            if let old = retained[entry.path],old.isDirectory == entry.directory,old.name == entry.name,old.isIgnored == entry.isIgnored { return old }
            let child = RemoteTreeNode(name:entry.name,path:entry.path,directory:entry.directory,ignored:entry.isIgnored)
            if let old = retained[entry.path],old.isDirectory == entry.directory {
                child.children = old.children; child.wantsExpanded = old.wantsExpanded
            }
            return child
        }
        func expandedNodes(_ nodes: [RemoteTreeNode]) -> [RemoteTreeNode] {
            nodes.flatMap { child in table.isItemExpanded(child) ? [child]+expandedNodes(child.children ?? []) : [] }
        }
        let expanded = expandedNodes(existing)
        table.reloadItem(node,reloadChildren:true)
        if node.wantsExpanded { table.expandItem(node) }
        for child in expanded where table.row(forItem:child) >= 0 { table.expandItem(child) }
        for child in node.children ?? [] where child.wantsExpanded { table.expandItem(child) }
    }
    private func load(_ node: RemoteTreeNode,force: Bool = false) {
        if node.loading { if force { pendingRefresh.insert(node.path) }; return }; node.loading = true
        if let cached = connection.cachedDirectory(node.path) { apply(cached,to:node) }
        if node.children == nil { note.stringValue = L.text("Loading remote folder…") }
        let root = rootNode,remote = connection,path = node.path
        DispatchQueue.global(qos:.userInitiated).async { [weak self,weak node] in
            guard let node else { return }
            let result = Result { try remote.listDirectory(path,force:force) }
            DispatchQueue.main.async {
                guard let self,self.rootNode === root else { return }; node.loading = false
                switch result {
                case .success(let reply):
                    self.apply(reply,to:node); self.note.stringValue = ""
                    if node === root { self.onRootLoaded?(reply.path ?? node.path) }
                case .failure(let error): self.note.stringValue = error.localizedDescription
                }
                if self.pendingRefresh.remove(path) != nil { self.load(node,force:true) }
            }
        }
    }
    @objc func createFile() {
        let alert = ThemedAlert(); alert.messageText = L.text("New remote file")
        let name = NSTextField(frame:NSRect(x:0,y:0,width:340,height:28)); name.placeholderString = L.text("File name")
        alert.accessoryView = name; alert.window.initialFirstResponder = name
        alert.addButton(withTitle:L.text("Create")); alert.addButton(withTitle:L.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn,!name.stringValue.isEmpty else { return }
        let selected = table.item(atRow:table.selectedRow) as? RemoteTreeNode
        let nameValue = name.stringValue
        guard nameValue != ".",nameValue != "..",!nameValue.contains("/"),!nameValue.utf8.contains(0),
              !nameValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            note.stringValue = L.text("Enter a single file name.")
            return
        }
        let target = selected?.isDirectory == true ? selected! : rootNode
        let base = target.path
        let path = (base as NSString).appendingPathComponent(nameValue),remote = connection
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try remote.request("create",path:path) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let reply): self.load(target,force:true); self.onOpen?(reply.path ?? path)
                case .failure(let error): self.note.stringValue = error.localizedDescription
                }
            }
        }
    }
}

final class RemoteEntryCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("Linvell.RemoteEntry")
    private let icon = NSImageView(),label = Theme.label("",size:12)
    init(name: String,path: String,directory: Bool,ignored: Bool = false) {
        super.init(frame:.zero); identifier = Self.reuseID; clipsToBounds = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.maximumNumberOfLines = 1; label.usesSingleLineMode = true; label.lineBreakMode = .byTruncatingMiddle
        for view in [icon,label] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant:16),icon.heightAnchor.constraint(equalToConstant:16),icon.leadingAnchor.constraint(equalTo:leadingAnchor,constant:3),icon.centerYAnchor.constraint(equalTo:centerYAnchor),label.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:7),label.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-6),label.centerYAnchor.constraint(equalTo:centerYAnchor),label.heightAnchor.constraint(equalToConstant:20)])
        configure(name:name,path:path,directory:directory,ignored:ignored)
    }
    func configure(name: String,path: String,directory: Bool,ignored: Bool) {
        let image = FileIcon.image(for:URL(fileURLWithPath:path),folder:directory)
        icon.image = image; icon.contentTintColor = directory ? Theme.accent : image.isTemplate ? Theme.secondary : nil
        label.stringValue = name; label.textColor = ignored ? Theme.liveSecondary : Theme.liveForeground; alphaValue = ignored ? 0.62 : 1; toolTip = path
    }
    static func make(in table: NSTableView,name: String,path: String,directory: Bool,ignored: Bool = false) -> RemoteEntryCell {
        if let cell = table.makeView(withIdentifier:reuseID,owner:nil) as? RemoteEntryCell { cell.configure(name:name,path:path,directory:directory,ignored:ignored); return cell }
        return RemoteEntryCell(name:name,path:path,directory:directory,ignored:ignored)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class RemoteFolderPicker: NSWindowController {
    private let browser: RemoteBrowser
    private var openButton: NSButton?
    weak var parentWindow: NSWindow?
    var onChoose: ((String) -> Void)?
    var onTerminal: (() -> Void)?
    init(connection: SSHRemote,path: String,owner: NSWindow) {
        browser = RemoteBrowser(connection:connection,directoriesOnly:true,initialPath:path)
        self.parentWindow = owner
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:660,height:520),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        panel.title = L.text("Open Remote Folder"); ThemedWindow.install(panel,panel:true)
        super.init(window:panel)
        browser.onTerminal = { [weak self] in self?.cancel(); self?.onTerminal?() }
        let cancel = Theme.actionButton("Cancel",target:self,action:#selector(cancel)),open = Theme.actionButton("Open This Folder",target:self,action:#selector(choose),primary:true)
        openButton = open
        browser.onSelectionChanged = { [weak self] in self?.updateTarget() }
        updateTarget()
        Theme.pin(Theme.stack([browser,Theme.stack([NSView(),cancel,open],spacing:12)],orientation:.vertical,spacing:12),in:panel.contentView!,inset:16)
        owner.beginSheet(panel)
    }
    required init?(coder: NSCoder) { fatalError() }
    private func updateTarget() {
        openButton?.isEnabled = browser.selectedDirectory != nil
        if let path = browser.selectedDirectory { openButton?.title = L.format("Open “%@”",URL(fileURLWithPath:path).lastPathComponent) }
    }
    @objc private func cancel() { if let window { parentWindow?.endSheet(window); window.orderOut(nil) } }
    @objc private func choose() { guard let path = browser.selectedDirectory else { return }; cancel(); onChoose?(path) }
}
