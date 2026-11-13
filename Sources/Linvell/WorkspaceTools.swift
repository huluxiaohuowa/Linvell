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
    static func searchable(_ root: URL) -> [URL] {
        guard let reply = try? ToolCommand.run(URL(fileURLWithPath:"/usr/bin/git"),
                    arguments:["--no-optional-locks","-c","core.fsmonitor=false","-C",root.path,"ls-files","-z","--cached","--others","--exclude-standard","--","."],
                    directory:nil,timeout:5,trimOutput:false,maximumOutputBytes:16*1024*1024),
              reply.succeeded else { return list(root) }
        var seen = Set<String>()
        return reply.output.split(separator:"\0").lazy.filter { seen.insert(String($0)).inserted }.compactMap { path -> URL? in
            let url = root.appendingPathComponent(String(path))
            guard let info = try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),
                  info.isRegularFile == true,info.isSymbolicLink != true,
                  ExplorerActions.relative(url.resolvingSymlinksInPath().path,under:root.resolvingSymlinksInPath().path) != nil else { return nil }
            return url
        }.prefix(20_000).map { $0 }
    }
    static func relative(_ url: URL,root: URL) -> String { ExplorerActions.relative(url.path,under:root.path) ?? url.lastPathComponent }
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
    var openAtLine: ((Int) -> Void)?
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
    var goToCurrentLine: ((Int) -> Void)?
    private var supportsLineTarget: Bool { goToCurrentLine != nil || options.contains { $0.openAtLine != nil } }
    static func fileQuery(_ query: String) -> (name: String,line: Int?) {
        guard let colon = query.lastIndex(of:":") else { return (query,nil) }
        let digits = query[query.index(after:colon)...]
        guard let number = Int(digits),number > 0,digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return (query,nil) }
        return (String(query[..<colon]),number)
    }
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
        let raw = input.stringValue
        let parsed = supportsLineTarget ? Self.fileQuery(raw) : (name:raw,line:nil)
        let query = parsed.name
        if parsed.line != nil,query.isEmpty,goToCurrentLine != nil {
            results = []; table.reloadData(); return
        }
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
    @objc private func choose() {
        let target = supportsLineTarget ? Self.fileQuery(input.stringValue) : (name:input.stringValue,line:nil)
        if target.name.isEmpty,let line = target.line,let goToCurrentLine {
            dismiss(); goToCurrentLine(line); return
        }
        guard results.indices.contains(table.selectedRow) else { return }
        let result = results[table.selectedRow]
        dismiss()
        if let line = target.line,let openAtLine = result.openAtLine { openAtLine(line) }
        else { result.invoke() }
    }
}

final class ProjectSearchTable: ResponsiveTableView {
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76),selectedRow >= 0,let action {
            NSApp.sendAction(action,to:target,from:self)
        } else { super.keyDown(with:event) }
    }
}

final class ToolSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Match {
        let title: String
        let detail: String
        let url: URL
        let line: Int
        let range: NSRange
        let highlight: NSRange
        let originalLine: String?
    }
    private enum Row { case file(URL,Int), match(Match) }
    let query = Theme.searchField()
    let table = ProjectSearchTable()
    let caseToggle = NSButton(checkboxWithTitle:L.text("Match case"),target:nil,action:nil)
    let caption = Theme.label("",size:11,color:Theme.secondary)
    private(set) var results: [Match] = []
    private var rows: [Row] = []
    private var collapsed: Set<URL> = []
    var onSelect: ((Match) -> Void)?
    var unsavedTexts: (() -> [URL:String])?
    private var generation = UUID()
    private var displayedQuery = ""
    let project: URL
    private let remote: (connection: SSHRemote,directory: String)?
    private var searchWork: DispatchWorkItem?
    private let searchQueue = DispatchQueue(label:"top.fuluwa.linvell.project-search",qos:.userInitiated)
    private static let limit = 2000

    init(project: URL,remote: (SSHRemote,String)? = nil) {
        self.project = project; self.remote = remote
        super.init(frame:.zero)
        let heading = Theme.label("SEARCH",size:11,color:Theme.secondary,weight:.semibold)
        let refreshButton = WorkspaceGlass.icon("arrow.clockwise",help:"Refresh",target:self,action:#selector(refresh))
        let row = Theme.stack([heading,NSView(),refreshButton])
        row.heightAnchor.constraint(equalToConstant:28).isActive = true
        query.placeholderString = L.text("Search project text"); query.delegate = self; query.font = .systemFont(ofSize:13)
        caseToggle.target = self; caseToggle.action = #selector(refresh)
        table.addTableColumn(NSTableColumn(identifier:NSUserInterfaceItemIdentifier("results")))
        table.headerView = nil; table.rowHeight = 26; table.dataSource = self; table.delegate = self; table.backgroundColor = .clear
        table.target = self; table.action = #selector(selected); table.setAccessibilityLabel(L.text("Project search results"))
        let scroll = ResponsiveScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        Theme.pin(Theme.stack([row,query,caseToggle,caption,scroll],orientation:.vertical,spacing:8),in:self,inset:12)
        caption.stringValue = L.text("Search project text")
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { searchWork?.cancel() }

    private func rebuildRows() {
        var grouped: [URL:[Match]] = [:]
        var order: [URL] = []
        for match in results {
            if grouped[match.url] == nil { order.append(match.url) }
            grouped[match.url,default:[]].append(match)
        }
        rows = order.flatMap { url -> [Row] in
            let matches = grouped[url] ?? []
            let header = Row.file(url,matches.count)
            return collapsed.contains(url) ? [header] : [header]+matches.map(Row.match)
        }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        switch rows[row] {
        case .file(let url,let count):
            let arrow = NSImageView(image:NSImage(systemSymbolName:collapsed.contains(url) ? "chevron.right" : "chevron.down",accessibilityDescription:nil) ?? NSImage())
            arrow.contentTintColor = Theme.liveSecondary
            arrow.widthAnchor.constraint(equalToConstant:11).isActive = true
            let name = Theme.label(ProjectFiles.relative(url,root:project),size:12,weight:.semibold)
            name.lineBreakMode = .byTruncatingMiddle
            return Theme.stack([arrow,FileIcon.view(for:url),name,Theme.label(String(count),size:10,color:Theme.secondary)],spacing:5)
        case .match(let match):
            let line = Theme.label(String(match.line),size:10,color:Theme.secondary)
            line.alignment = .right
            line.widthAnchor.constraint(equalToConstant:31).isActive = true
            let snippet = Theme.label("",size:11)
            snippet.lineBreakMode = .byTruncatingTail
            let styled = NSMutableAttributedString(string:match.title,attributes:[.foregroundColor:Theme.liveForeground,.font:NSFont.monospacedSystemFont(ofSize:11,weight:.regular)])
            if match.highlight.length > 0,NSMaxRange(match.highlight) <= styled.length {
                styled.addAttributes([.backgroundColor:Theme.selection,.foregroundColor:Theme.liveAccent],range:match.highlight)
            }
            snippet.attributedStringValue = styled
            return Theme.stack([line,snippet],spacing:6)
        }
    }
    @objc func selected() {
        guard rows.indices.contains(table.selectedRow) else { return }
        switch rows[table.selectedRow] {
        case .file(let url,_):
            if !collapsed.insert(url).inserted { collapsed.remove(url) }
            rebuildRows()
        case .match(let match): onSelect?(match)
        }
    }
    func controlTextDidChange(_ notification: Notification) { refresh() }
    func control(_ control: NSControl,textView: NSTextView,doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveDown(_:)),table.numberOfRows > 0 {
            window?.makeFirstResponder(table)
            table.selectRowIndexes(IndexSet(integer:table.numberOfRows > 1 ? 1 : 0),byExtendingSelection:false)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)),table.numberOfRows > 0 {
            if table.selectedRow < 0 { table.selectRowIndexes(IndexSet(integer:table.numberOfRows > 1 ? 1 : 0),byExtendingSelection:false) }
            selected(); return true
        }
        return false
    }

    @objc func refresh() {
        searchWork?.cancel()
        let request = UUID(); generation = request
        let needle = query.stringValue, project = self.project, exact = caseToggle.state == .on, remote = self.remote
        guard !needle.isEmpty else {
            results = []; collapsed = []; rebuildRows(); caption.stringValue = L.text("Search project text"); return
        }
        if displayedQuery != needle {
            displayedQuery = needle
            results = []; rebuildRows()
        }
        let overrides = unsavedTexts?() ?? [:]
        caption.stringValue = L.text("Searching…")
        let work = DispatchWorkItem { [weak self] in
            let outcome = Result { () throws -> ([Match],Bool) in
                var matches: [Match] = []
                var truncated = false
                if let remote {
                    let reply = try remote.connection.searchText(needle,directory:remote.directory,caseSensitive:exact)
                    truncated = reply.truncated == true
                    matches = (reply.matches ?? []).compactMap { match in
                        let url = URL(fileURLWithPath:match.path)
                        guard overrides[url] == nil else { return nil }
                        return Match(title:match.text,detail:"\(match.relative):\(match.line)",url:url,line:match.line,
                                     range:NSRange(location:match.column,length:match.length),
                                     highlight:NSRange(location:match.previewColumn,length:match.previewLength),originalLine:nil)
                    }
                } else {
                    for url in ProjectFiles.searchable(project) where overrides[url] == nil {
                        let size = (try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? Int.max
                        guard size < 5*1024*1024,let data = try? Data(contentsOf:url),!data.contains(0),
                              let content = String(data:data,encoding:.utf8) ?? String(data:data,encoding:.isoLatin1) else { continue }
                        let text = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
                        matches += Self.matches(in:text,url:url,project:project,query:needle,exact:exact,limit:Self.limit-matches.count)
                        if matches.count >= Self.limit { truncated = true; break }
                    }
                }
                // Unsaved buffers replace on-disk matches, including files opened before indexing.
                var edited: [Match] = []
                for url in overrides.keys.sorted(by:{ $0.path < $1.path }) {
                    guard let content = overrides[url] else { continue }
                    edited += Self.matches(in:content,url:url,project:project,query:needle,exact:exact,limit:Self.limit-edited.count)
                    if edited.count >= Self.limit { truncated = true; break }
                }
                let combined = edited+matches
                return (Array(combined.prefix(Self.limit)),truncated || combined.count > Self.limit)
            }
            DispatchQueue.main.async {
                guard let self,self.generation == request else { return }
                switch outcome {
                case .success(let (matches,truncated)):
                    self.results = matches
                    self.caption.stringValue = L.format("%@ matches",String(matches.count))+(truncated ? " · "+L.text("limit reached") : "")
                case .failure(let error):
                    self.results = []
                    self.caption.stringValue = error.localizedDescription
                }
                self.rebuildRows()
            }
        }
        searchWork = work
        searchQueue.asyncAfter(deadline:.now()+0.2,execute:work)
    }

    static func matches(in source: String,url: URL,project: URL,query: String,exact: Bool,limit: Int) -> [Match] {
        guard !query.isEmpty,limit > 0 else { return [] }
        let normalized = source.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        let options: NSString.CompareOptions = exact ? [.literal] : [.caseInsensitive]
        var matches: [Match] = []
        for (index,line) in normalized.components(separatedBy:"\n").enumerated() {
            let text = line as NSString
            var start = 0
            while start < text.length {
                let range = text.range(of:query,options:options,range:NSRange(location:start,length:text.length-start))
                guard range.location != NSNotFound,range.length > 0 else { break }
                let context = max(0,range.location-20)
                let previewRange = text.rangeOfComposedCharacterSequences(for:NSRange(location:context,length:min(160,text.length-context)))
                let prefix = previewRange.location > 0 ? "…" : ""
                let preview = prefix+text.substring(with:previewRange)
                let highlight = NSIntersectionRange(range,previewRange)
                matches.append(Match(title:preview,detail:ProjectFiles.relative(url,root:project)+":\(index+1)",url:url,line:index+1,range:range,
                                     highlight:NSRange(location:highlight.location-previewRange.location+prefix.utf16.count,length:highlight.length),originalLine:line))
                if matches.count >= limit { return matches }
                start = NSMaxRange(range)
            }
        }
        return matches
    }
}
