import AppKit
import LinvellCore

final class EditorSyntaxState {
    static let changed = Notification.Name("Linvell.SourceAnalysisChanged")
    private static let queue = DispatchQueue(label:"top.fuluwa.linvell.source-syntax",qos:.userInitiated)
    var analysis = SourceAnalysis(),version = -1
    private(set) var ticket: LanguageQueryTicket?
    private var pendingRevision: Int?
    func request(_ document: OpenDocument) {
        // Split panes share this state; keep an existing analysis of the same revision.
        guard version != document.buffer.revision,pendingRevision != document.buffer.revision else { return }
        ticket?.cancel()
        let ticket = LanguageQueryTicket(); self.ticket = ticket
        let text = document.buffer.text,revision = document.buffer.revision,path = document.remote?.path ?? document.fileURL?.path ?? ""
        pendingRevision = revision
        ticket.schedule { [weak self,weak document] in
            guard !ticket.cancelled else { return }
            let analysis = SourceSyntax.analyze(text,path:path,cancelled:{ ticket.cancelled })
            DispatchQueue.main.async {
                guard let self,let document,!ticket.cancelled,document.buffer.revision == revision else { return }
                self.analysis = analysis; self.version = revision
                self.pendingRevision = nil; self.ticket = nil
                NotificationCenter.default.post(name:Self.changed,object:document)
            }
        }
        Self.queue.async { ticket.run() }
    }
    func invalidate() {
        ticket?.cancel()
        ticket = nil
        pendingRevision = nil
        version = -1
        analysis = SourceAnalysis()
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
        paintSyntax(reset:true); highlightBrackets(); gutter.needsDisplay = true; minimap.invalidateCodeMap()
    }
    func paintSyntax(reset: Bool = false) {
        guard !textView.hasMarkedText(),let container = textView.textContainer,let manager = textView.layoutManager else { return }
        let whole = NSRange(location:0,length:document.storage.length)
        if reset {
            manager.removeTemporaryAttribute(.foregroundColor,forCharacterRange:whole)
            paintedSyntaxRange = nil
        }
        guard document.syntax.version == document.buffer.revision else { return }
        let glyphs = manager.glyphRange(forBoundingRect:textView.visibleRect.offsetBy(dx:0,dy:-textView.textContainerOrigin.y),in:container)
        let visible = manager.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
        guard visible.length > 0 else { return }
        if let paintedSyntaxRange,NSIntersectionRange(paintedSyntaxRange,visible) == visible { return }
        // Keep a margin around the viewport so small scroll steps reuse the existing colors.
        let margin = min(visible.length,4096)
        let start = max(0,visible.location-margin)
        let end = min(whole.length,NSMaxRange(visible)+margin)
        let paint = NSRange(location:start,length:end-start)
        let previous = paintedSyntaxRange.map { NSIntersectionRange($0,whole) }
        paintedSyntaxRange = paint
        let tokens = document.syntax.analysis.tokens

        func outside(_ range: NSRange, _ retained: NSRange?) -> [NSRange] {
            guard range.length > 0 else { return [] }
            guard let retained else { return [range] }
            let overlap = NSIntersectionRange(range,retained)
            guard overlap.length > 0 else { return [range] }
            return [
                NSRange(location:range.location,length:overlap.location-range.location),
                NSRange(location:NSMaxRange(overlap),length:NSMaxRange(range)-NSMaxRange(overlap))
            ].filter { $0.length > 0 }
        }
        if let previous {
            for range in outside(previous,paint) {
                manager.removeTemporaryAttribute(.foregroundColor,forCharacterRange:range)
            }
        }
        for added in outside(paint,previous) {
            var low = 0, high = tokens.count
            while low < high {
                let mid = (low+high)/2
                if NSMaxRange(tokens[mid].range) <= added.location { low = mid+1 }
                else { high = mid }
            }
            var index = low
            while index < tokens.count, tokens[index].range.location < NSMaxRange(added) {
                let token = tokens[index]
                let range = NSIntersectionRange(token.range,added)
                if range.length > 0 {
                    manager.addTemporaryAttribute(.foregroundColor,value:Theme.syntaxColor(token.kind),forCharacterRange:range)
                }
                index += 1
            }
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
        guard document.syntax.version == document.buffer.revision else { document.syntax.request(document); return }
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
        guard document.syntax.version == document.buffer.revision else { document.syntax.request(document); return }
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
        let unit = indentation.unit
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
