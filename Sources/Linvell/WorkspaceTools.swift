import AppKit
import LinvellCore

enum ProjectFiles {
    static func list(_ root: URL) -> [URL] {
        let excluded: Set<String> = ["node_modules","dist","build","DerivedData","vendor","__pycache__"]
        guard let iterator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles]) else { return [] }
        var urls: [URL] = []
        for case let url as URL in iterator {
            if excluded.contains(url.lastPathComponent) { iterator.skipDescendants(); continue }
            let info = try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey])
            if info?.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if info?.isRegularFile == true { urls.append(url) }
            if urls.count >= 20_000 { break }
        }
        return urls
    }
    static func relative(_ url: URL,root: URL) -> String { String(url.path.dropFirst(root.path.count+1)) }
    static func matches(_ query: String,_ text: String) -> Bool {
        if query.isEmpty { return true }
        var characters = query.lowercased().makeIterator()
        var next = characters.next()
        for character in text.lowercased() where character == next {
            next = characters.next()
            if next == nil { return true }
        }
        return false
    }
}

struct PickerOption {
    let title: String
    let detail: String
    let fileURL: URL?
    let reorderID: String?
    let invoke: () -> Void
    init(title: String,detail: String,fileURL: URL? = nil,reorderID: String? = nil,invoke: @escaping () -> Void) { self.title = title; self.detail = detail; self.fileURL = fileURL; self.reorderID = reorderID; self.invoke = invoke }
}

private final class QuickPickerPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else { super.keyDown(with:event) }
    }
}

final class QuickPicker: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    let input = Theme.searchField()
    let table = ResponsiveTableView()
    private(set) var options: [PickerOption]
    private let compact: Bool
    private let reorderType = NSPasteboard.PasteboardType("com.linvell.repository-order")
    var onReorder: (([String]) -> Void)? {
        didSet {
            if onReorder != nil {
                table.registerForDraggedTypes([reorderType])
                table.setDraggingSourceOperationMask(.move,forLocal:true)
            }
        }
    }
    var rowActions: ((PickerOption) -> [PickerOption])? {
        didSet { let menu = NSMenu(); menu.delegate = self; table.menu = rowActions == nil ? nil : menu }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard results.indices.contains(table.clickedRow),let rowActions else { return }
        for option in rowActions(results[table.clickedRow]) {
            let item = NSMenuItem(title:option.title,action:#selector(invokeContextAction(_:)),keyEquivalent:"")
            item.target = self; item.representedObject = option; menu.addItem(item)
        }
    }
    @objc private func invokeContextAction(_ sender: NSMenuItem) { (sender.representedObject as? PickerOption)?.invoke() }
    var selectionActions: [(String,([String]) -> Void)] = [] {
        didSet {
            table.allowsMultipleSelection = !selectionActions.isEmpty
            selectionBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (index,action) in selectionActions.enumerated() {
                let button = NSButton(title:L.text(action.0),target:self,action:#selector(applySelection(_:)))
                button.tag = index; selectionBar.addArrangedSubview(button)
            }
            selectionBar.isHidden = selectionActions.isEmpty
            controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:input))
            tableViewSelectionDidChange(Notification(name:NSTableView.selectionDidChangeNotification,object:table))
        }
    }
    private let selectionBar = NSStackView()
    var selectedRepositoryIDs: [String] { table.selectedRowIndexes.compactMap { results.indices.contains($0) ? results[$0].reorderID : nil } }
    func tableViewSelectionDidChange(_ notification: Notification) {
        selectionBar.arrangedSubviews.compactMap { $0 as? NSButton }.forEach { $0.isEnabled = !selectedRepositoryIDs.isEmpty }
    }
    @objc private func applySelection(_ sender: NSButton) {
        let ids = selectedRepositoryIDs
        guard !ids.isEmpty,selectionActions.indices.contains(sender.tag) else { return }
        let action = selectionActions[sender.tag].1; dismiss(); action(ids)
    }
    var onDismiss: (() -> Void)?
    var onQuery: ((String,@escaping ([PickerOption]) -> Void) -> Void)? { didSet { controlTextDidChange(Notification(name:NSControl.textDidChangeNotification)) } }
    private var queryWork: DispatchWorkItem?
    private var queryGeneration = UUID()
    var results: [PickerOption] = []
    weak var parentWindow: NSWindow?
    init(title: String,options: [PickerOption],owner: NSWindow,compact: Bool = false) {
        self.compact = compact
        self.options = options; self.results = Array(options.prefix(80)); self.parentWindow = owner
        let panel = QuickPickerPanel(contentRect:NSRect(x:0,y:0,width:compact ? 620 : 660,height:compact ? 360 : 420),styleMask:[.titled],backing:.buffered,defer:false)
        panel.title = title; ThemedWindow.install(panel,panel:true)
        super.init(window:panel)
        panel.onCancel = { [weak self] in self?.dismiss() }
        input.placeholderString = title; input.font = .systemFont(ofSize:16); input.delegate = self
        input.heightAnchor.constraint(equalToConstant:38).isActive = true
        let c = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("results")); table.addTableColumn(c); table.headerView = nil
        table.rowHeight = compact ? 32 : 46; table.dataSource = self; table.delegate = self; table.backgroundColor = Theme.panel
        table.target = self; table.doubleAction = #selector(choose); table.allowsEmptySelection = false
        table.setAccessibilityLabel(title+" results")
        let scroll = ResponsiveScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        let hint = Theme.label("↑↓ Navigate     ↵ Open     Esc Cancel",size:12,color:Theme.secondary)
        selectionBar.spacing = 6; selectionBar.isHidden = true
        let stack = Theme.stack([input,scroll,selectionBar,hint],orientation:.vertical,spacing:12)
        if compact {
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.styleMask.insert(.fullSizeContentView)
            table.backgroundColor = .clear
            scroll.drawsBackground = false
            let contents = NSView()
            Theme.pin(stack,in:contents,inset:12)
            let surface = WorkspaceGlass.surface(containing:contents,radius:14)
            WorkspaceGlass.tintEditor(surface)
            Theme.pin(surface,in:panel.contentView!,inset:6)
        } else {
            Theme.pin(stack,in:panel.contentView!,inset:18)
        }
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        owner.beginSheet(panel); panel.makeFirstResponder(input)
    }
    required init?(coder: NSCoder) { fatalError() }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let result = results[row]
        let title = Theme.label(result.title,size:compact ? 13 : 14), detail = Theme.label(result.detail,size:compact ? 10 : 11,color:Theme.secondary)
        title.lineBreakMode = .byTruncatingMiddle; detail.lineBreakMode = .byTruncatingMiddle
        let lines: [NSView] = compact && result.title == result.detail ? [title] : [title,detail]
        let stack = NSStackView(views:lines); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = compact ? 0 : 3
        if let url = result.fileURL { return Theme.stack([FileIcon.view(for:url),stack],spacing:10) }
        return stack
    }
    func tableView(_ tableView: NSTableView,pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard onReorder != nil,input.stringValue.isEmpty,results.indices.contains(row),let id = results[row].reorderID else { return nil }
        let item = NSPasteboardItem()
        item.setString(id,forType:reorderType)
        return item
    }
    func tableView(_ tableView: NSTableView,validateDrop info: NSDraggingInfo,proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard onReorder != nil,input.stringValue.isEmpty,info.draggingSource as? NSTableView === table,
              row > 0,row <= results.count,
              (row == results.count || results[row].reorderID != nil),
              results[row-1].reorderID != nil || row < results.count else { return [] }
        table.setDropRow(row,dropOperation:.above)
        return .move
    }
    func tableView(_ tableView: NSTableView,acceptDrop info: NSDraggingInfo,row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let ids = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType:reorderType) }
        guard !ids.isEmpty,row >= 0,row <= results.count else { return false }
        return moveRepositories(ids,before:row < results.count ? results[row].reorderID : nil)
    }
    func moveRepository(_ id: String,before target: String?) -> Bool { moveRepositories([id],before:target) }
    func moveRepositories(_ ids: [String],before target: String?) -> Bool {
        let chosen = Set(ids)
        guard onReorder != nil,!chosen.isEmpty else { return false }
        let moving = options.filter { $0.reorderID.map(chosen.contains) == true }
        guard moving.count == chosen.count else { return false }
        if let target,chosen.contains(target) { return true }
        options.removeAll { $0.reorderID.map(chosen.contains) == true }
        let destination = target.flatMap { id in options.firstIndex(where:{ $0.reorderID == id }) } ?? options.count
        options.insert(contentsOf:moving,at:destination)
        onReorder?(options.compactMap(\.reorderID))
        controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
        return true
    }
    func controlTextDidChange(_ notification: Notification) {
        let query = input.stringValue
        queryWork?.cancel(); queryGeneration = UUID()
        if let onQuery {
            let generation = queryGeneration
            let work = DispatchWorkItem { [weak self] in
                onQuery(query) { [weak self] options in
                    guard let self,self.queryGeneration == generation,self.window?.sheetParent != nil else { return }
                    self.results = Array(options.prefix(500)); self.table.reloadData()
                    if !self.results.isEmpty { self.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
                }
            }
            queryWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:work); return
        }
        if compact, !query.trimmingCharacters(in:.whitespaces).isEmpty {
            let needle = query.trimmingCharacters(in:.whitespaces).lowercased()
            var ranked = Array(repeating:[PickerOption](),count:5)
            for option in options {
                let name = option.title.lowercased(), path = option.detail.lowercased()
                let rank: Int
                if name == needle { rank = 0 }
                else if name.hasPrefix(needle) { rank = 1 }
                else if name.contains(needle) { rank = 2 }
                else if ProjectFiles.matches(needle,name) { rank = 3 }
                else if ProjectFiles.matches(needle,path) { rank = 4 }
                else { continue }
                if ranked[rank].count < 80 { ranked[rank].append(option) }
            }
            results = Array(ranked.joined().prefix(80))
        } else {
            results = Array(options.lazy.filter { ProjectFiles.matches(query,$0.title+" "+$0.detail) }.prefix(selectionActions.isEmpty ? 80 : Int.max))
        }
        table.reloadData(); if !results.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
    }
    func control(_ control: NSControl,textView: NSTextView,doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow+1); return true
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow-1); return true
        case #selector(NSResponder.insertNewline(_:)): choose(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }
    private func select(_ row: Int) {
        guard !results.isEmpty else { return }
        let index = min(max(row,0),results.count-1); table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false); table.scrollRowToVisible(index)
    }
    func updateRepositoryOrder(_ ids: [String]) {
        let selection = Set(selectedRepositoryIDs)
        let repositories = Dictionary(options.compactMap { option in option.reorderID.map { ($0,option) } },uniquingKeysWith:{ a,_ in a })
        options = options.filter { $0.reorderID == nil }+ids.compactMap { repositories[$0] }
        controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:input))
        if !selection.isEmpty { table.selectRowIndexes(IndexSet(results.indices.filter { results[$0].reorderID.map(selection.contains) == true }),byExtendingSelection:false) }
    }
    func dismiss() { queryGeneration = UUID(); queryWork?.cancel(); let callback = onDismiss; onDismiss = nil; callback?(); if let panel = window { if panel.sheetParent != nil { parentWindow?.endSheet(panel) }; panel.orderOut(nil) } }
    @objc private func choose() { guard table.selectedRow >= 0,table.selectedRow < results.count else { return }; let result = results[table.selectedRow]; dismiss(); result.invoke() }
}

final class ToolSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Result { let title: String; let detail: String; let url: URL; let line: Int }
    let query = Theme.searchField()
    let table = ResponsiveTableView()
    let caption = Theme.label("",size:11,color:Theme.secondary)
    var results: [Result] = []
    var onSelect: ((URL,Int) -> Void)?
    private var generation = UUID()
    let project: URL
    let kind: String
    private let remote: (connection: SSHRemote,directory: String)?
    private var searchWork: DispatchWorkItem?
    private static let remoteSearchQueue = DispatchQueue(label:"top.fuluwa.linvell.remote-search",qos:.userInitiated)
    init(kind: String,project: URL,remote: (SSHRemote,String)? = nil) {
        self.project = project; self.kind = kind; self.remote = remote
        super.init(frame:.zero)
        let heading = Theme.label(kind == "search" ? "SEARCH" : "SOURCE CONTROL",size:11,color:Theme.secondary,weight:.semibold)
        let refreshButton = NSButton(title:L.text("Refresh"),target:self,action:#selector(refresh)); refreshButton.bezelStyle = .inline
        let row = Theme.stack([heading,NSView(),refreshButton]); row.heightAnchor.constraint(equalToConstant:36).isActive = true
        query.placeholderString = L.text("Search project text"); query.delegate = self; query.font = .systemFont(ofSize:13)
        let c = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("results")); table.addTableColumn(c); table.headerView = nil
        table.rowHeight = 48; table.dataSource = self; table.delegate = self; table.backgroundColor = Theme.panel
        table.target = self; table.action = #selector(selected); table.setAccessibilityLabel(L.text(kind == "search" ? "Project search results" : "Changed files"))
        let scroll = ResponsiveScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let stack = Theme.stack(kind == "search" ? [row,query,caption,scroll] : [row,caption,scroll],orientation:.vertical,spacing:12)
        Theme.pin(stack,in:self,inset:16)
        if kind == "search" { caption.stringValue = L.text("Search is literal and case-insensitive.") } else { refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let item = results[row], a = Theme.label(item.title,size:13), b = Theme.label(item.detail,size:11,color:Theme.secondary)
        a.lineBreakMode = .byTruncatingTail; b.lineBreakMode = .byTruncatingMiddle
        let s = NSStackView(views:[a,b]); s.orientation = .vertical; s.alignment = .leading; s.spacing = 3
        return Theme.stack([FileIcon.view(for:item.url),s],spacing:9)
    }
    @objc func selected() { guard results.indices.contains(table.selectedRow) else { return }; let r = results[table.selectedRow]; onSelect?(r.url,r.line) }
    func controlTextDidChange(_ notification: Notification) { refresh() }
    deinit { searchWork?.cancel() }
    @objc func refresh() {
        searchWork?.cancel()
        let request = UUID(); generation = request
        let needle = query.stringValue, project = self.project, kind = self.kind
        if kind == "search" && needle.isEmpty { results = []; table.reloadData(); caption.stringValue = L.text("Search is literal and case-insensitive."); return }
        caption.stringValue = L.text(kind == "search" ? "Searching…" : "Reading repository status…")
        if let remote, kind == "search" {
            results = []; table.reloadData()
            let work = DispatchWorkItem { [weak self] in
                let result = Swift.Result { try remote.connection.searchText(needle,directory:remote.directory) }
                DispatchQueue.main.async {
                    guard let self,self.generation == request else { return }
                    switch result {
                    case .success(let reply):
                        self.results = (reply.matches ?? []).map { match in
                            Result(title:match.text,detail:"\(match.relative):\(match.line)",url:URL(fileURLWithPath:match.path),line:match.line)
                        }
                        self.caption.stringValue = L.format("%@ matches · UTF-8 files under 2 MB",String(self.results.count))
                            + (reply.truncated == true ? " · "+L.text("limit reached") : "")
                    case .failure(let error): self.caption.stringValue = error.localizedDescription
                    }
                    self.table.reloadData()
                }
            }
            searchWork = work
            Self.remoteSearchQueue.asyncAfter(deadline:.now()+0.25,execute:work)
            return
        }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            var found: [Result] = [], note = ""
            if kind == "search" {
                let files = ProjectFiles.list(project)
                for url in files {
                    let size = (try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? Int.max
                    guard size < 2_000_000,
                          let data = try? Data(contentsOf:url), !data.contains(0),let content = String(data:data,encoding:.utf8) else { continue }
                    for (i,line) in content.components(separatedBy:.newlines).enumerated() where line.localizedCaseInsensitiveContains(needle) {
                        found.append(Result(title:String(line.trimmingCharacters(in:.whitespaces).prefix(160)),detail:ProjectFiles.relative(url,root:project)+":\(i+1)",url:url,line:i+1))
                        if found.count >= 500 { break }
                    }
                    if found.count >= 500 { break }
                }
                note = "\(found.count) matches · UTF-8 files under 2 MB" + (found.count >= 500 ? " · limit reached" : "")
            } else {
                let process = Process(), output = Pipe(), errors = Pipe()
                process.executableURL = URL(fileURLWithPath:"/usr/bin/git"); process.arguments = ["-C",project.path,"status","--porcelain=v1","-z","--untracked-files=normal"]
                process.standardOutput = output; process.standardError = errors
                do {
                    try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        let fields = String(decoding:bytes,as:UTF8.self).split(separator:"\0").map(String.init)
                        var i = 0
                        while i < fields.count {
                            let field = fields[i]; i += 1; guard field.count >= 4 else { continue }
                            let state = String(field.prefix(2)), path = String(field.dropFirst(3))
                            if state.contains("R") || state.contains("C") { i += 1 }
                            found.append(Result(title:state+"  "+URL(fileURLWithPath:path).lastPathComponent,detail:path,url:project.appendingPathComponent(path),line:1))
                        }
                        note = found.isEmpty ? "Working tree is clean" : "\(found.count) changed files · read-only status"
                    } else { note = "This folder is not an available Git repository." }
                } catch { note = "Git could not be started." }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.generation == request else { return }
                self.results = found; self.caption.stringValue = note; self.table.reloadData()
            }
        }
    }
}
