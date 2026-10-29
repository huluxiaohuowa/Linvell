import AppKit
import LinvellCore

struct CodeCompletion {
    let title: String,detail: String,text: String
    let range: CodeRange?
    let additional: [CodeTextEdit]
    static func items(_ value: Any) -> [CodeCompletion] {
        let items = value as? [[String:Any]] ?? (value as? [String:Any])?["items"] as? [[String:Any]] ?? []
        return items.prefix(100).compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            let edit = item["textEdit"] as? [String:Any]
            let rawRange = edit?["range"] ?? edit?["replace"]
            let range = rawRange.flatMap { try? JSONDecoder().decode(CodeRange.self,from:JSONSerialization.data(withJSONObject:$0)) }
            let snippet = item["insertTextFormat"] as? Int == 2
            let text = snippet ? label : edit?["newText"] as? String ?? item["insertText"] as? String ?? label
            let additional = (item["additionalTextEdits"]).flatMap { try? JSONDecoder().decode([CodeTextEdit].self,from:JSONSerialization.data(withJSONObject:$0)) } ?? []
            return CodeCompletion(title:label,detail:item["detail"] as? String ?? "",text:text,range:range,additional:additional)
        }
    }
}

final class CodeCompletionPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    let table = ResponsiveTableView()
    let choices: [CodeCompletion]
    let choose: (CodeCompletion) -> Void
    private var resignObserver: NSObjectProtocol?
    override var canBecomeKey: Bool { false }
    init(items: [CodeCompletion],editor: NSTextView,choose: @escaping (CodeCompletion) -> Void) {
        choices = items; self.choose = choose
        let caret = editor.firstRect(forCharacterRange:editor.selectedRange(),actualRange:nil)
        let height = CGFloat(min(8,items.count))*38+4,width: CGFloat = 460
        let screen = editor.window?.screen?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:900)
        let x = min(max(screen.minX,caret.minX),screen.maxX-width)
        let y = caret.minY-height >= screen.minY ? caret.minY-height : min(screen.maxY-height,caret.maxY)
        super.init(contentRect:NSRect(x:x,y:y,width:width,height:height),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        isReleasedWhenClosed = false; hasShadow = true; backgroundColor = Theme.panel; level = .floating; hidesOnDeactivate = true
        table.addTableColumn(NSTableColumn(identifier:NSUserInterfaceItemIdentifier("suggestion"))); table.headerView = nil
        table.dataSource = self; table.delegate = self; table.rowHeight = 38; table.backgroundColor = Theme.panel
        table.target = self; table.action = #selector(clicked); table.setAccessibilityLabel(L.text("Code suggestions"))
        let scroll = ResponsiveScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table; scroll.drawsBackground = false
        Theme.pin(scroll,in:contentView!); table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        resignObserver = NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:editor.window,queue:.main) { [weak self] _ in self?.dismiss() }
        editor.window?.addChildWindow(self,ordered:.above); orderFront(nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }
    func numberOfRows(in tableView: NSTableView) -> Int { choices.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("suggestion-cell")
        if let cell = tableView.makeView(withIdentifier:id,owner:nil) as? NSTableCellView { cell.textField?.stringValue = choices[row].title; cell.toolTip = choices[row].detail; return cell }
        let cell = NSTableCellView(); cell.identifier = id
        let text = Theme.label(choices[row].title,size:13); text.font = Theme.editorFont; text.lineBreakMode = .byTruncatingTail
        cell.textField = text; Theme.pin(text,in:cell,inset:8); cell.toolTip = choices[row].detail; return cell
    }
    @objc func clicked() { accept() }
    func accept() { guard choices.indices.contains(table.selectedRow) else { return }; choose(choices[table.selectedRow]); dismiss() }
    func handle(_ event: NSEvent) -> Bool {
        if !event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty { dismiss(); return false }
        switch event.keyCode {
        case 125,126:
            let row = max(0,min(choices.count-1,table.selectedRow+(event.keyCode == 125 ? 1 : -1)))
            table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); table.scrollRowToVisible(row); return true
        case 36,48: accept(); return true
        case 53: dismiss(); return true
        case 123,124: dismiss(); return false
        default: return false
        }
    }
    func dismiss() { parent?.removeChildWindow(self); orderOut(nil) }
}

final class CodeHoverContent: NSViewController {
    let text: String
    let highlight: NSRange?
    let navigate: () -> Void
    init(text: String,highlight: NSRange? = nil,navigate: @escaping () -> Void) { self.text = text; self.highlight = highlight; self.navigate = navigate; super.init(nibName:nil,bundle:nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = Surface(Theme.panel)
        let editor = NSTextView(); editor.isEditable = false; editor.isSelectable = true
        editor.frame = NSRect(x:0,y:0,width:412,height:100); editor.isVerticallyResizable = true
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width:412,height:CGFloat.greatestFiniteMagnitude)
        editor.string = text; editor.font = .monospacedSystemFont(ofSize:12,weight:.regular); editor.textColor = Theme.foreground; editor.backgroundColor = Theme.panel
        if let highlight,highlight.location >= 0,NSMaxRange(highlight) <= (text as NSString).length { editor.textStorage?.addAttributes([.font:NSFont.monospacedSystemFont(ofSize:12,weight:.bold),.foregroundColor:Theme.accent],range:highlight) }
        editor.textContainerInset = NSSize(width:12,height:10); editor.isHorizontallyResizable = false; editor.autoresizingMask = [.width]
        let scroll = ResponsiveScrollView(); scroll.documentView = editor; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        Theme.pin(scroll,in:view,inset:4)
        let measured = (text as NSString).boundingRect(with:NSSize(width:388,height:1000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:NSFont.monospacedSystemFont(ofSize:12,weight:.regular)])
        preferredContentSize = NSSize(width:420,height:min(240,max(54,ceil(measured.height)+28)))
        view.setFrameSize(preferredContentSize)
    }
    @objc func goToDefinition() { navigate() }
}

extension EditorTextView {
    static func codeWord(in text: String,at offset: Int,maximumLength: Int = Int.max) -> NSRange {
        let ns = text as NSString; var lower = min(max(0,offset),ns.length),upper = lower
        func part(_ at: Int) -> Bool { guard at >= 0,at < ns.length,let scalar = UnicodeScalar(ns.character(at:at)) else { return false }; return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$" }
        while lower > 0,part(lower-1) { lower -= 1; if upper-lower > maximumLength { return NSRange(location:offset,length:0) } }
        while upper < ns.length,part(upper) { upper += 1; if upper-lower > maximumLength { return NSRange(location:offset,length:0) } }
        return NSRange(location:lower,length:upper-lower)
    }
}
