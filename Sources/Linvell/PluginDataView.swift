import AppKit
import LinvellCore
import LinvellPluginKit

private final class PluginRow: NSObject {
    let value: PluginItem
    let children: [PluginRow]
    init(_ value: PluginItem) { self.value = value; children = (value.children ?? []).map(PluginRow.init) }
}
final class PluginDataView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let definition: PluginView
    let table: NSTableView
    let summary = NSTextView(frame:NSRect(x:0,y:0,width:500,height:100))
    let summaryScroll = ResponsiveScrollView()
    private var rows: [PluginRow] = []
    var invoke: ((String,PluginUIEvent) -> Void)?
    private let headerIcon = NSImageView()
    var icon: ((String) -> NSImage?)? { didSet { headerIcon.image = definition.icon.flatMap { icon?($0) }; headerIcon.isHidden = headerIcon.image == nil } }
    init(_ definition: PluginView) {
        self.definition = definition
        table = definition.kind == .tree ? NSOutlineView() : NSTableView()
        super.init(frame:.zero)
        let header = NSTextField(labelWithString:definition.title); header.font = .systemFont(ofSize:15,weight:.semibold); header.textColor = Theme.foreground
        headerIcon.isHidden = true; headerIcon.widthAnchor.constraint(equalToConstant:18).isActive = true; headerIcon.heightAnchor.constraint(equalToConstant:18).isActive = true
        var actions: [NSView] = [headerIcon,header,NSView()]
        if definition.refreshCommand != nil { actions.append(Theme.button("arrow.clockwise",help:"Refresh Plugin View",target:self,action:#selector(refreshView))) }
        actions.append(Theme.actionButton("Run Selected",target:self,action:#selector(activateSelection)))
        let heading = Theme.stack(actions); heading.detachesHiddenViews = true; heading.heightAnchor.constraint(equalToConstant:36).isActive = true
        summary.font = .systemFont(ofSize:13); summary.textColor = Theme.foreground; summary.isSelectable = true; summary.isEditable = false; summary.isRichText = false; summary.backgroundColor = Theme.canvas
        summary.isVerticallyResizable = true; summary.autoresizingMask = .width; summary.textContainer?.widthTracksTextView = true
        summaryScroll.documentView = summary; summaryScroll.hasVerticalScroller = true; summaryScroll.heightAnchor.constraint(equalToConstant:100).isActive = true
        let column = NSTableColumn(identifier:.init("plugin.item")); column.title = definition.title; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 46; table.backgroundColor = Theme.canvas; table.selectionHighlightStyle = .regular; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.doubleAction = #selector(activateSelection); table.target = self
        table.setAccessibilityLabel(definition.title)
        if let outline = table as? NSOutlineView { outline.outlineTableColumn = column; outline.dataSource = self; outline.delegate = self }
        else { table.dataSource = self; table.delegate = self }
        let scroll = ResponsiveScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:100).isActive = true
        let stack = Theme.stack([heading,summaryScroll,scroll],orientation:.vertical,spacing:10); stack.detachesHiddenViews = true
        Theme.pin(stack,in:self,inset:12)
        update(text:definition.text ?? "",items:definition.items ?? [])
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(text: String,items: [PluginItem]) {
        summary.string = text; summaryScroll.isHidden = text.isEmpty
        let selected = selectedRow()?.value.id
        var expanded = Set<String>()
        if let outline = table as? NSOutlineView {
            for row in 0..<outline.numberOfRows { if let item = outline.item(atRow:row) as? PluginRow,outline.isItemExpanded(item) { expanded.insert(item.value.id) } }
        }
        rows = items.map(PluginRow.init); table.reloadData()
        if let outline = table as? NSOutlineView {
            func restore(_ values: [PluginRow]) { for value in values { if expanded.contains(value.value.id) { outline.expandItem(value) }; restore(value.children) } }; restore(rows)
            if let selected { for index in 0..<outline.numberOfRows where (outline.item(atRow:index) as? PluginRow)?.value.id == selected { outline.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) } }
        } else if let selected,let index = rows.firstIndex(where:{ $0.value.id == selected }) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
    }
    func refreshAppearance() { table.backgroundColor = Theme.canvas; summary.textColor = Theme.foreground; summary.backgroundColor = Theme.canvas; table.reloadData() }
    private func selectedRow() -> PluginRow? {
        guard table.selectedRow >= 0 else { return nil }
        if let outline = table as? NSOutlineView { return outline.item(atRow:outline.selectedRow) as? PluginRow }
        return rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }
    @objc private func activateSelection() {
        let item = selectedRow()?.value
        guard let command = item?.command ?? definition.command else { return }
        invoke?(command,PluginUIEvent(viewID:definition.id,kind:"activate",itemID:item?.id))
    }
    @objc private func refreshView() { if let command = definition.refreshCommand { invoke?(command,PluginUIEvent(viewID:definition.id,kind:"refresh")) } }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? { cell(rows[row]) }
    func outlineView(_ outlineView: NSOutlineView,numberOfChildrenOfItem item: Any?) -> Int { (item as? PluginRow)?.children.count ?? rows.count }
    func outlineView(_ outlineView: NSOutlineView,child index: Int,ofItem item: Any?) -> Any { ((item as? PluginRow)?.children ?? rows)[index] }
    func outlineView(_ outlineView: NSOutlineView,isItemExpandable item: Any) -> Bool { !(item as! PluginRow).children.isEmpty }
    func outlineView(_ outlineView: NSOutlineView,viewFor tableColumn: NSTableColumn?,item: Any) -> NSView? { cell(item as! PluginRow) }
    private func cell(_ row: PluginRow) -> NSView {
        let cell = NSTableCellView(),title = NSTextField(labelWithString:row.value.title)
        cell.toolTip = row.value.title+"\n"+(row.value.detail ?? "")
        title.font = .systemFont(ofSize:13); title.textColor = Theme.foreground; title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString:row.value.detail ?? ""); detail.font = .systemFont(ofSize:11); detail.textColor = Theme.secondary; detail.lineBreakMode = .byTruncatingTail
        var content: [NSView] = []
        if let id = row.value.icon,let image = icon?(id) { let view = NSImageView(image:image); view.widthAnchor.constraint(equalToConstant:18).isActive = true; view.heightAnchor.constraint(equalToConstant:18).isActive = true; content.append(view) }
        content.append(Theme.stack([title,detail],orientation:.vertical,spacing:2))
        Theme.pin(Theme.stack(content,spacing:8),in:cell,inset:4); return cell
    }
}

class PluginOwnedWindow: NSWindowController, NSWindowDelegate {
    weak var workspaceOwner: WorkspaceController?
    init(owner: WorkspaceController,title: String) {
        self.workspaceOwner = owner
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:520),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.appearance = NSAppearance(named:Theme.isDark ? .darkAqua : .aqua); window.backgroundColor = Theme.canvas
        window.title = title; window.minSize = NSSize(width:400,height:320); window.isReleasedWhenClosed = false
        super.init(window:window); window.delegate = self; window.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refreshAppearance() {
        window?.appearance = NSAppearance(named:Theme.isDark ? .darkAqua : .aqua); window?.backgroundColor = Theme.canvas
        func refresh(_ view: NSView) { if let label = view as? NSTextField,!label.isEditable { label.textColor = Theme.foreground }; (view as? ThemedLabel)?.refreshTheme(); (view as? PluginDataView)?.refreshAppearance(); view.subviews.forEach(refresh) }
        if let view = window?.contentView { refresh(view) }
    }
    func windowDidBecomeKey(_ notification: Notification) { PluginMenus.refresh(workspace:workspaceOwner) }
}
