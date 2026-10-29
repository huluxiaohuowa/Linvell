import AppKit
import LinvellCore

final class EditorSyntaxState {
    static let changed = Notification.Name("Linvell.SourceAnalysisChanged")
    private static let queue = DispatchQueue(label:"top.fuluwa.linvell.source-syntax",qos:.userInitiated)
    var analysis = SourceAnalysis(),version = -1
    private var ticket: LanguageQueryTicket?
    func request(_ document: OpenDocument) {
        guard version != document.buffer.revision else { return }
        ticket?.cancel()
        let ticket = LanguageQueryTicket(); self.ticket = ticket
        let text = document.buffer.text,revision = document.buffer.revision,path = document.remote?.path ?? document.fileURL?.path ?? ""
        ticket.schedule { [weak self,weak document] in
            guard !ticket.cancelled else { return }
            let analysis = SourceSyntax.analyze(text,path:path,cancelled:{ ticket.cancelled })
            DispatchQueue.main.async {
                guard let self,let document,!ticket.cancelled,document.buffer.revision == revision else { return }
                self.analysis = analysis; self.version = revision
                NotificationCenter.default.post(name:Self.changed,object:document)
            }
        }
        Self.queue.async { ticket.run() }
    }
    deinit { ticket?.cancel() }
}

/// Hidden characters remain in the shared text storage, file, undo and LSP data.
/// TextKit suppresses their advance, including paragraph-break control glyphs.
final class FoldingLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var hidden: [NSRange] = [] {
        didSet {
            hidden = MultiEdit.normalized(hidden).filter { $0.length > 0 }
            let whole = NSRange(location:0,length:textStorage?.length ?? 0)
            invalidateGlyphs(forCharacterRange:whole,changeInLength:0,actualCharacterRange:nil)
            invalidateLayout(forCharacterRange:whole,actualCharacterRange:nil)
        }
    }
    override init() { super.init(); delegate = self }
    required init?(coder: NSCoder) { fatalError() }
    func hides(_ character: Int) -> Bool {
        var low = 0,high = hidden.count
        while low < high { let mid = (low+high)/2; if NSMaxRange(hidden[mid]) <= character { low = mid+1 } else { high = mid } }
        return low < hidden.count && NSLocationInRange(character,hidden[low])
    }
    func layoutManager(_ layoutManager: NSLayoutManager,shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,characterIndexes indexes: UnsafePointer<Int>,font: NSFont,forGlyphRange range: NSRange) -> Int {
        guard !hidden.isEmpty else { return 0 }
        var properties = Array(UnsafeBufferPointer(start:props,count:range.length)),changed = false
        for i in properties.indices where hides(indexes[i]) { properties[i] = .controlCharacter; changed = true }
        guard changed else { return 0 }
        properties.withUnsafeBufferPointer { setGlyphs(glyphs,properties:$0.baseAddress!,characterIndexes:indexes,font:font,forGlyphRange:range) }
        return range.length
    }
    func layoutManager(_ layoutManager: NSLayoutManager,shouldUse action: NSLayoutManager.ControlCharacterAction,forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        hides(charIndex) ? .zeroAdvancement : action
    }
}

extension EditorPane {
    var folding: FoldingLayoutManager { textView.layoutManager as! FoldingLayoutManager }
    @objc func sourceAnalysisChanged(_ notification: Notification) {
        guard notification.object as? OpenDocument === document else { return }
        paintSyntax(); highlightBrackets(); gutter.needsDisplay = true
    }
    func paintSyntax() {
        guard document.syntax.version == document.buffer.revision,!textView.hasMarkedText(),let container = textView.textContainer,let manager = textView.layoutManager else { return }
        let glyphs = manager.glyphRange(forBoundingRect:textView.visibleRect.offsetBy(dx:0,dy:-textView.textContainerOrigin.y),in:container)
        let visible = manager.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
        guard visible.length > 0 else { return }
        manager.removeTemporaryAttribute(.foregroundColor,forCharacterRange:NSRange(location:0,length:document.storage.length))
        let tokens = document.syntax.analysis.tokens
        var low = 0,high = tokens.count
        while low < high { let mid = (low+high)/2; if tokens[mid].range.location < visible.location { low = mid+1 } else { high = mid } }
        var i = max(0,low-1)
        while i < tokens.count,tokens[i].range.location < NSMaxRange(visible) {
            let token = tokens[i],range = NSIntersectionRange(token.range,visible)
            let color: NSColor
            switch token.kind {
            case .keyword: color = Theme.keyword
            case .string: color = Theme.accent
            case .number: color = Theme.number
            case .comment: color = Theme.secondary
            case .type,.directive: color = Theme.keyword.withAlphaComponent(0.85)
            }
            if range.length > 0 { manager.addTemporaryAttribute(.foregroundColor,value:color,forCharacterRange:range) }; i += 1
        }
    }
    func highlightBrackets() {
        guard let manager = textView.layoutManager else { return }
        manager.removeTemporaryAttribute(.backgroundColor,forCharacterRange:NSRange(location:0,length:document.storage.length))
        guard document.syntax.version == document.buffer.revision else { return }
        let at = textView.selectedRange().location,pairs = document.syntax.analysis.pairs
        let key = pairs[at] != nil ? at : at > 0 && pairs[at-1] != nil ? at-1 : -1
        if let other = pairs[key] {
            for offset in [key,other] { manager.addTemporaryAttribute(.backgroundColor,value:Theme.accent.withAlphaComponent(0.24),forCharacterRange:NSRange(location:offset,length:1)) }
        }
    }
    func toggleFold(line: Int) {
        guard let fold = document.syntax.analysis.folds.first(where:{ $0.line == line }),fold.range.length > 0 else { return }
        if let i = folding.hidden.firstIndex(of:fold.range) { folding.hidden.remove(at:i) }
        else {
            textView.setSelectedRange(NSRange(location:document.lines.starts[fold.line],length:0))
            folding.hidden.append(fold.range)
        }
        textView.needsDisplay = true; gutter.needsDisplay = true; paintSyntax()
    }
    func foldAtCursor() {
        let at = textView.selectedRange().location,row = document.lines.line(at:at)
        if let fold = document.syntax.analysis.folds.last(where:{ $0.line <= row && $0.endLine >= row }) { toggleFold(line:fold.line) }
    }
    func unfoldAll() { if !folding.hidden.isEmpty { folding.hidden = []; textView.needsDisplay = true; gutter.needsDisplay = true } }
    func foldAll() {
        textView.setSelectedRange(NSRange(location:0,length:0))
        folding.hidden = document.syntax.analysis.folds.map(\.range)
        textView.needsDisplay = true; gutter.needsDisplay = true
    }
    func revealSelection() {
        let at = textView.selectedRange().location
        if folding.hides(at) { folding.hidden.removeAll { NSLocationInRange(at,$0) }; textView.needsDisplay = true }
    }
}

extension EditorTextView {
    func insertIndentedNewline(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertNewline(sender); return }
        let unit = PreferencesSync.value("useSpaces") == "true" ? String(repeating:" ",count:max(1,Int(PreferencesSync.value("tabWidth")) ?? 4)) : "\t"
        let source = string,path = document?.remote?.path ?? document?.fileURL?.path ?? ""
        let selections = editingSelections
        func insertion(_ range: NSRange) -> (String,Int) {
            if let document,document.syntax.version == document.buffer.revision,range.location > 0,!document.syntax.analysis.isCode(range.location-1) {
                let row = (source as NSString).lineRange(for:NSRange(location:range.location,length:0)),before = (source as NSString).substring(with:NSRange(location:row.location,length:range.location-row.location))
                let value = "\n"+before.prefix { $0 == " " || $0 == "\t" }; return (value,value.utf16.count)
            }
            return SourceSyntax.newline(in:source,at:range.location,path:path,unit:unit)
        }
        if selections.count == 1,let range = selections.first {
            let insertion = insertion(range)
            insertText(insertion.0,replacementRange:range)
            setSelectedRange(NSRange(location:range.location+insertion.1,length:0)); return
        }
        var result = source as NSString,carets: [NSRange] = []
        for range in selections.sorted(by:{ $0.location > $1.location }) {
            let insertion = insertion(range)
            result = result.replacingCharacters(in:range,with:insertion.0) as NSString
            let delta = insertion.0.utf16.count-range.length
            carets = carets.map { NSRange(location:$0.location+delta,length:0) }; carets.append(NSRange(location:range.location+insertion.1,length:0))
        }
        restoreMultiEdit(result as String,selections:carets.sorted { $0.location < $1.location }.map(NSValue.init(range:)))
    }
}

extension WorkspaceController {
    @objc func foldCode() { activePane?.foldAtCursor() }
    @objc func unfoldCode() { activePane?.unfoldAll() }
    @objc func foldAllCode() { activePane?.foldAll() }
    @objc func unfoldAllCode() { activePane?.unfoldAll() }
}
