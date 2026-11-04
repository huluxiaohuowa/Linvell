import AppKit

/// A native outline keeps selection, disclosure and arrow-key traversal in one place.
final class GitReviewFileTree: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Node: NSObject {
        let path: String
        let directory: Bool
        var children: [Node] = []
        init(_ path: String,directory: Bool) { self.path = path; self.directory = directory }
    }
    let outline = ResponsiveOutlineView()
    private let scroll = NSScrollView()
    private var roots: [Node] = []
    private var nodes: [String:Node] = [:]
    private var collapsed: Set<String> = []
    private var paths: [String] = []
    private var query = ""
    private var selectedPath: String?
    private var updating = false
    var onSelect: ((String) -> Void)?
    var onVisibilityChange: (() -> Void)?
    var visiblePaths: [String] {
        (0..<outline.numberOfRows).compactMap { (outline.item(atRow:$0) as? Node).flatMap { $0.directory ? nil : $0.path } }
    }
    var visibleRows: [(path:String,directory:Bool,depth:Int)] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow:row) as? Node else { return nil }
            return (node.path,node.directory,outline.level(forItem:node))
        }
    }
    func toggle(path: String) {
        guard let node = nodes[path],node.directory else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }
    var directoryPaths: Set<String> { Set(nodes.values.filter(\.directory).map(\.path)) }

    override init(frame: NSRect) {
        super.init(frame:frame)
        let column = NSTableColumn(identifier:.init("file")); outline.addTableColumn(column)
        outline.outlineTableColumn = column; outline.headerView = nil
        outline.rowHeight = 26; outline.indentationPerLevel = 14
        outline.dataSource = self; outline.delegate = self
        outline.setAccessibilityLabel(L.text("Repository files"))
        outline.target = self; outline.doubleAction = #selector(activate)
        scroll.documentView = outline; scroll.hasVerticalScroller = true
        Theme.pin(scroll,in:self)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(paths: [String],query: String,selection: String?) {
        self.paths = paths; self.query = query; selectedPath = selection
        rebuild()
    }
    private func rebuild() {
        updating = true
        roots = []; nodes = [:]
        for path in paths.sorted(by:{ $0.localizedStandardCompare($1) == .orderedAscending }) where query.isEmpty || path.localizedStandardContains(query) {
            let parts = path.split(separator:"/").map(String.init)
            var parent: Node?,prefix = ""
            for (index,part) in parts.enumerated() {
                prefix = prefix.isEmpty ? part : prefix+"/"+part
                if let existing = nodes[prefix] { parent = existing; continue }
                let node = Node(prefix,directory:index < parts.count-1); nodes[prefix] = node
                if let parent { parent.children.append(node) } else { roots.append(node) }
                parent = node
            }
        }
        func sorted(_ values: [Node]) -> [Node] {
            values.sorted { a,b in a.directory != b.directory ? a.directory : a.path.localizedStandardCompare(b.path) == .orderedAscending }
        }
        roots = sorted(roots)
        for node in nodes.values { node.children = sorted(node.children) }
        outline.reloadData()
        for node in nodes.values.filter(\.directory).sorted(by:{ $0.path.count < $1.path.count }) where !collapsed.contains(node.path) || !query.isEmpty { outline.expandItem(node) }
        if let selectedPath,let node = nodes[selectedPath] {
            let row = outline.row(forItem:node)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
        }
        updating = false
    }
    func select(path: String) {
        selectedPath = path
        guard let node = nodes[path] else { return }
        let row = outline.row(forItem:node)
        if row >= 0 { updating = true; outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); updating = false }
    }
    func setExpanded(_ expanded: Bool) {
        collapsed = expanded ? [] : directoryPaths
        rebuild(); onVisibilityChange?()
    }
    @objc private func activate() {
        guard let node = outline.item(atRow:outline.clickedRow) as? Node,node.directory else { return }
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }
    func outlineView(_ outlineView: NSOutlineView,numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView,child index: Int,ofItem item: Any?) -> Any { ((item as? Node)?.children ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView,isItemExpandable item: Any) -> Bool { (item as? Node)?.directory == true }
    func outlineView(_ outlineView: NSOutlineView,viewFor tableColumn: NSTableColumn?,item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let label = NSTextField(labelWithString:(node.path as NSString).lastPathComponent)
        label.lineBreakMode = .byTruncatingMiddle; label.toolTip = node.path
        label.identifier = NSUserInterfaceItemIdentifier(node.path)
        return Theme.stack([FileIcon.view(for:URL(fileURLWithPath:node.path),folder:node.directory,expanded:outline.isItemExpanded(node)),label],spacing:5)
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !updating,let node = outline.item(atRow:outline.selectedRow) as? Node,!node.directory else { return }
        selectedPath = node.path; onSelect?(node.path)
    }
    func outlineViewItemDidExpand(_ notification: Notification) { changed(notification,expanded:true) }
    func outlineViewItemDidCollapse(_ notification: Notification) { changed(notification,expanded:false) }
    private func changed(_ notification: Notification,expanded: Bool) {
        guard !updating,let node = notification.userInfo?["NSObject"] as? Node else { return }
        if expanded { collapsed.remove(node.path) } else { collapsed.insert(node.path) }
        onVisibilityChange?()
    }
}
