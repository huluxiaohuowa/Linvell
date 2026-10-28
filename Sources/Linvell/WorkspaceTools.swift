import AppKit

enum ProjectFiles {
    static func list(_ root: URL) -> [URL] {
        let excluded: Set<String> = ["node_modules","dist","build","DerivedData","vendor"]
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
        var remaining = Array(query.lowercased())
        for c in text.lowercased() where remaining.first == c { remaining.removeFirst(); if remaining.isEmpty { return true } }
        return remaining.isEmpty
    }
}

struct PickerOption {
    let title: String
    let detail: String
    let invoke: () -> Void
}

final class QuickPicker: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let input = NSSearchField()
    let table = NSTableView()
    let options: [PickerOption]
    var results: [PickerOption] = []
    weak var parentWindow: NSWindow?
    init(title: String,options: [PickerOption],owner: NSWindow) {
        self.options = options; self.results = Array(options.prefix(80)); self.parentWindow = owner
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:660,height:420),styleMask:[.titled],backing:.buffered,defer:false)
        panel.title = title; panel.appearance = owner.appearance; panel.backgroundColor = Theme.panel
        super.init(window:panel)
        input.placeholderString = title; input.font = .systemFont(ofSize:16); input.delegate = self
        input.heightAnchor.constraint(equalToConstant:38).isActive = true
        let c = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("results")); table.addTableColumn(c); table.headerView = nil
        table.rowHeight = 46; table.dataSource = self; table.delegate = self; table.backgroundColor = Theme.panel
        table.target = self; table.doubleAction = #selector(choose); table.allowsEmptySelection = false
        table.setAccessibilityLabel(title+" results")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        let hint = Theme.label("↑↓ Navigate     ↵ Open     Esc Cancel",size:12,color:Theme.secondary)
        let stack = Theme.stack([input,scroll,hint],orientation:.vertical,spacing:12)
        Theme.pin(stack,in:panel.contentView!,inset:18)
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        owner.beginSheet(panel); panel.makeFirstResponder(input)
    }
    required init?(coder: NSCoder) { fatalError() }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let result = results[row]
        let title = Theme.label(result.title,size:14), detail = Theme.label(result.detail,size:11,color:Theme.secondary)
        let stack = NSStackView(views:[title,detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
        return stack
    }
    func controlTextDidChange(_ notification: Notification) {
        let query = input.stringValue
        results = Array(options.filter { ProjectFiles.matches(query,$0.title+" "+$0.detail) }.prefix(80))
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
    private func dismiss() { if let panel = window { parentWindow?.endSheet(panel); panel.orderOut(nil) } }
    @objc private func choose() { guard table.selectedRow >= 0,table.selectedRow < results.count else { return }; let result = results[table.selectedRow]; dismiss(); result.invoke() }
}

final class ToolSidebar: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Result { let title: String; let detail: String; let url: URL; let line: Int }
    let query = NSSearchField()
    let table = NSTableView()
    let caption = Theme.label("",size:11,color:Theme.secondary)
    var results: [Result] = []
    var onSelect: ((URL,Int) -> Void)?
    private var generation = UUID()
    let project: URL
    let kind: String
    init(kind: String,project: URL) {
        self.project = project; self.kind = kind
        super.init(frame:.zero)
        let heading = Theme.label(kind == "search" ? "SEARCH" : "SOURCE CONTROL",size:11,color:Theme.secondary,weight:.semibold)
        let refreshButton = NSButton(title:"Refresh",target:self,action:#selector(refresh)); refreshButton.bezelStyle = .inline
        let row = Theme.stack([heading,NSView(),refreshButton]); row.heightAnchor.constraint(equalToConstant:36).isActive = true
        query.placeholderString = "Search project text"; query.delegate = self; query.font = .systemFont(ofSize:13)
        let c = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("results")); table.addTableColumn(c); table.headerView = nil
        table.rowHeight = 48; table.dataSource = self; table.delegate = self; table.backgroundColor = Theme.panel
        table.target = self; table.action = #selector(selected); table.setAccessibilityLabel(kind == "search" ? "Project search results" : "Changed files")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let stack = Theme.stack(kind == "search" ? [row,query,caption,scroll] : [row,caption,scroll],orientation:.vertical,spacing:12)
        Theme.pin(stack,in:self,inset:16)
        if kind == "search" { caption.stringValue = "Search is literal and case-insensitive." } else { refresh() }
    }
    required init?(coder: NSCoder) { fatalError() }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let item = results[row], a = Theme.label(item.title,size:13), b = Theme.label(item.detail,size:11,color:Theme.secondary)
        a.lineBreakMode = .byTruncatingTail; b.lineBreakMode = .byTruncatingMiddle
        let s = NSStackView(views:[a,b]); s.orientation = .vertical; s.alignment = .leading; s.spacing = 3
        return s
    }
    @objc func selected() { guard table.selectedRow >= 0 else { return }; let r = results[table.selectedRow]; onSelect?(r.url,r.line) }
    func controlTextDidChange(_ notification: Notification) { refresh() }
    @objc func refresh() {
        let request = UUID(); generation = request
        let needle = query.stringValue, project = self.project, kind = self.kind
        if kind == "search" && needle.isEmpty { results = []; table.reloadData(); caption.stringValue = "Search is literal and case-insensitive."; return }
        caption.stringValue = kind == "search" ? "Searching…" : "Reading repository status…"
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
