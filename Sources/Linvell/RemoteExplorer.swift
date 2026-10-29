import AppKit
import LinvellCore

final class RemoteTreeNode: NSObject {
    var name: String,path: String
    let isDirectory: Bool
    var children: [RemoteTreeNode]?
    var loading = false
    var wantsExpanded = false
    init(name: String,path: String,directory: Bool) { self.name = name; self.path = path; isDirectory = directory }
}

final class RemoteExplorer: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let connection: SSHRemote
    let table = ResponsiveOutlineView()
    private let note = NSTextField(wrappingLabelWithString:"")
    private(set) var rootNode: RemoteTreeNode
    var directory: String { rootNode.path }
    var onOpen: ((String) -> Void)?
    var onRootLoaded: ((String) -> Void)?
    var onTerminal: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    init(connection: SSHRemote,path: String) {
        self.connection = connection
        rootNode = RemoteTreeNode(name:URL(fileURLWithPath:path).lastPathComponent,path:path,directory:true)
        super.init(frame:.zero)
        let title = Theme.label("SSH · "+connection.host,size:12,weight:.semibold); title.lineBreakMode = .byTruncatingMiddle
        let open = Theme.button("folder.badge.plus",help:"Open Remote Folder…",target:self,action:#selector(chooseFolder))
        let create = Theme.button("doc.badge.plus",help:"New File",target:self,action:#selector(createFile))
        let shell = Theme.button("terminal",help:"SSH Terminal",target:self,action:#selector(terminal))
        let refresh = Theme.button("arrow.clockwise",help:"Refresh Files",target:self,action:#selector(reload))
        note.font = .systemFont(ofSize:11); note.textColor = Theme.secondary; note.maximumNumberOfLines = 3
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("remote-tree")); column.width = 300; column.resizingMask = .autoresizingMask
        table.addTableColumn(column); table.outlineTableColumn = column; table.headerView = nil
        table.dataSource = self; table.delegate = self; table.rowHeight = 30; table.indentationPerLevel = 16
        table.backgroundColor = Theme.panel; table.autoresizingMask = [.width]; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self; table.action = #selector(selected); table.doubleAction = #selector(toggled)
        table.setAccessibilityLabel(L.text("Remote project files"))
        let scroll = ResponsiveScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        Theme.pin(Theme.stack([title,Theme.stack([open,create,shell,NSView(),refresh],spacing:4),note,scroll],orientation:.vertical,spacing:10),in:self,inset:12)
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
        return RemoteEntryCell.make(in:outlineView,name:node.name,path:node.path,directory:node.isDirectory)
    }
    @objc private func selected() {
        guard let node = table.item(atRow:table.selectedRow) as? RemoteTreeNode,!node.isDirectory else { return }
        onOpen?(node.path)
    }
    @objc private func toggled() {
        guard let node = table.item(atRow:table.clickedRow) as? RemoteTreeNode,node.isDirectory else { return }
        if table.isItemExpanded(node) { table.collapseItem(node) } else { table.expandItem(node) }
    }
    @objc private func chooseFolder() { onChooseFolder?() }
    @objc private func terminal() { onTerminal?() }
    @objc func reload() { rootNode.wantsExpanded = true; load(rootNode,force:true) }
    private func apply(_ reply: RemoteReply,to node: RemoteTreeNode) {
        if node === rootNode,let path = reply.path { node.path = path; node.name = URL(fileURLWithPath:path).lastPathComponent }
        let entries = reply.entries ?? []
        let existing = node.children ?? []
        let unchanged = node.children != nil && existing.count == entries.count && zip(existing,entries).allSatisfy { $0.name == $1.name && $0.path == $1.path && $0.isDirectory == $1.directory }
        guard !unchanged else { return }
        let retained = Dictionary(existing.map { ($0.path,$0) },uniquingKeysWith:{ first,_ in first })
        node.children = entries.map { entry in
            if let old = retained[entry.path],old.isDirectory == entry.directory,old.name == entry.name { return old }
            return RemoteTreeNode(name:entry.name,path:entry.path,directory:entry.directory)
        }
        func expandedNodes(_ nodes: [RemoteTreeNode]) -> [RemoteTreeNode] {
            nodes.flatMap { child in table.isItemExpanded(child) ? [child]+expandedNodes(child.children ?? []) : [] }
        }
        let expanded = expandedNodes(existing)
        table.reloadItem(node,reloadChildren:true)
        if node.wantsExpanded { table.expandItem(node) }
        for child in expanded { table.expandItem(child) }
    }
    private func load(_ node: RemoteTreeNode,force: Bool = false) {
        guard !node.loading else { return }; node.loading = true
        if let cached = connection.cachedDirectory(node.path) { apply(cached,to:node) }
        if node.children == nil { note.stringValue = L.text("Loading remote folder…") }
        let root = rootNode,remote = connection
        DispatchQueue.global(qos:.userInitiated).async { [weak self,weak node] in
            guard let node else { return }
            let result = Result { try remote.listDirectory(node.path,force:force) }
            DispatchQueue.main.async {
                guard let self,self.rootNode === root else { return }; node.loading = false
                switch result {
                case .success(let reply):
                    self.apply(reply,to:node); self.note.stringValue = ""
                    if node === root { self.onRootLoaded?(reply.path ?? node.path) }
                case .failure(let error): self.note.stringValue = error.localizedDescription
                }
            }
        }
    }
    @objc func createFile() {
        let alert = NSAlert(); alert.messageText = L.text("New remote file")
        let name = NSTextField(frame:NSRect(x:0,y:0,width:340,height:28)); name.placeholderString = L.text("File name")
        alert.accessoryView = name; alert.window.initialFirstResponder = name
        alert.addButton(withTitle:L.text("Create")); alert.addButton(withTitle:L.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn,!name.stringValue.isEmpty else { return }
        let selected = table.item(atRow:table.selectedRow) as? RemoteTreeNode
        let target = selected?.isDirectory == true ? selected! : rootNode
        let base = target.path
        let path = (base as NSString).appendingPathComponent(name.stringValue),remote = connection
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
    private let icon = NSImageView(),label = Theme.label("",size:13)
    init(name: String,path: String,directory: Bool) {
        super.init(frame:.zero); identifier = Self.reuseID; clipsToBounds = true
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.maximumNumberOfLines = 1; label.usesSingleLineMode = true; label.lineBreakMode = .byTruncatingMiddle
        for view in [icon,label] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant:16),icon.heightAnchor.constraint(equalToConstant:16),icon.leadingAnchor.constraint(equalTo:leadingAnchor,constant:3),icon.centerYAnchor.constraint(equalTo:centerYAnchor),label.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:7),label.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-6),label.centerYAnchor.constraint(equalTo:centerYAnchor),label.heightAnchor.constraint(equalToConstant:20)])
        configure(name:name,path:path,directory:directory)
    }
    func configure(name: String,path: String,directory: Bool) {
        let image = FileIcon.image(for:URL(fileURLWithPath:path),folder:directory)
        icon.image = image; icon.contentTintColor = directory ? Theme.accent : image.isTemplate ? Theme.secondary : nil
        label.stringValue = name; label.textColor = Theme.foreground; toolTip = path
    }
    static func make(in table: NSTableView,name: String,path: String,directory: Bool) -> RemoteEntryCell {
        if let cell = table.makeView(withIdentifier:reuseID,owner:nil) as? RemoteEntryCell { cell.configure(name:name,path:path,directory:directory); return cell }
        return RemoteEntryCell(name:name,path:path,directory:directory)
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
        panel.title = L.text("Open Remote Folder"); panel.appearance = owner.appearance; panel.backgroundColor = Theme.panel
        super.init(window:panel)
        browser.onTerminal = { [weak self] in self?.cancel(); self?.onTerminal?() }
        let cancel = Theme.actionButton("Cancel",target:self,action:#selector(cancel)),open = Theme.actionButton("Open This Folder",target:self,action:#selector(choose))
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
