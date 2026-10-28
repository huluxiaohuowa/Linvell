import AppKit
import LinvellCore

final class OpenDocument: NSObject, NSTextStorageDelegate {
    let buffer: DocumentBuffer
    let storage = NSTextStorage()
    let vim = VimEngine()
    let lines: LineIndex
    let imageURL: URL?
    var markdownPreview = false
    var fileURL: URL? { imageURL ?? buffer.url }
    var displayName: String { imageURL?.lastPathComponent ?? buffer.url?.lastPathComponent ?? L.text("Untitled") }
    var isMarkdown: Bool { ["md","markdown","mdown"].contains(fileURL?.pathExtension.lowercased() ?? "") }
    var isHTML: Bool { ["html","htm"].contains(fileURL?.pathExtension.lowercased() ?? "") }
    var supportsPreview: Bool { isMarkdown || isHTML }
    init(_ buffer: DocumentBuffer,lines: LineIndex? = nil) {
        self.buffer = buffer; self.lines = lines ?? LineIndex(buffer.text); imageURL = nil; super.init()
        storage.setAttributedString(NSAttributedString(string:buffer.text)); storage.delegate = self
    }
    init(imageURL: URL) {
        buffer = DocumentBuffer(); lines = LineIndex(""); self.imageURL = imageURL; super.init()
    }
    func textStorage(_ textStorage: NSTextStorage,didProcessEditing editedMask: NSTextStorageEditActions,range editedRange: NSRange,changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let old = NSRange(location:editedRange.location,length:editedRange.length-delta)
        lines.apply(range:old,replacement:(textStorage.string as NSString).substring(with:editedRange))
    }
}

final class EditorTextView: NSTextView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        FileDrop.urls(sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        FileDrop.urls(sender.draggingPasteboard).isEmpty ? super.draggingUpdated(sender) : .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !FileDrop.urls(sender.draggingPasteboard).isEmpty || super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        FileDrop.urls(sender.draggingPasteboard).isEmpty ? super.performDragOperation(sender) : FileDrop.perform(sender,in:window)
    }
    var document: OpenDocument?
    var vimEnabled = false
    var statusChanged: (() -> Void)?
    var exCommand: ((String) -> Void)?
    var applyingVim = false
    var selectionHistory: [[NSValue]] = []
    private var extraSelections: [NSRange]?
    var editingSelections: [NSRange] { extraSelections ?? selectedRanges.map(\.rangeValue) }
    private func applySelections(_ ranges: [NSRange]) {
        let values = MultiEdit.normalized(ranges)
        guard !values.isEmpty else { return }
        if values.count > 1 && values.contains(where: { $0.length == 0 }) {
            super.setSelectedRange(values[0]); extraSelections = values
        } else { extraSelections = nil; selectedRanges = values.map(NSValue.init(range:)) }
        needsDisplay = true
    }
    func setSelections(_ values: [NSRange]) {
        selectionHistory.append(editingSelections.map(NSValue.init(range:)))
        if selectionHistory.count > 100 { selectionHistory.removeFirst() }
        applySelections(values)
    }
    func undoSelection() { if let previous = selectionHistory.popLast() { applySelections(previous.map(\.rangeValue)) } }
    func clearExtraSelections() { extraSelections = nil; needsDisplay = true }
    func synchronizeNativeSelection() {
        if let extraSelections,selectedRange() != extraSelections[0] { clearExtraSelections() }
        if vimEnabled {
            document?.vim.cursor = selectedRange().location
            // NSTextView invalidates a thin caret; our wider block needs its old area repainted.
            if document?.vim.mode == .normal { needsDisplay = true }
        }
    }
    private func moveMultipleCarets(_ event: NSEvent) -> Bool {
        guard editingSelections.count > 1,[123,124,125,126].contains(event.keyCode),event.modifierFlags.intersection([.command,.control,.option]).isEmpty,let document else { return false }
        let ns = string as NSString,backward = event.keyCode == 123 || event.keyCode == 126
        let ranges = editingSelections.map { range -> NSRange in
            let from = backward ? range.location : NSMaxRange(range)
            var at = from
            if event.keyCode == 123 { at = from > 0 ? ns.rangeOfComposedCharacterSequence(at:from-1).location : 0 }
            else if event.keyCode == 124 { at = from < ns.length ? NSMaxRange(ns.rangeOfComposedCharacterSequence(at:from)) : ns.length }
            else {
                let row = document.lines.line(at:from),target = row+(event.keyCode == 126 ? -1 : 1)
                if target >= 0 && target < document.lines.starts.count {
                    let start = document.lines.starts[target],end = target+1 < document.lines.starts.count ? document.lines.starts[target+1]-1 : ns.length
                    at = min(end,start+from-document.lines.starts[row]); if at < ns.length { at = ns.rangeOfComposedCharacterSequence(at:at).location }
                }
            }
            if event.modifierFlags.contains(.shift) {
                let anchor = backward ? NSMaxRange(range) : range.location
                return NSRange(location:min(anchor,at),length:abs(anchor-at))
            }
            return NSRange(location:at,length:0)
        }
        applySelections(ranges); statusChanged?(); return true
    }
    override func mouseDown(with event: NSEvent) {
        if vimEnabled { document?.vim.cancelPendingCommand() }
        if event.modifierFlags.intersection([.command,.option,.shift]) == .option {
            let point = convert(event.locationInWindow,from:nil),at = characterIndexForInsertion(at:point)
            setSelections(editingSelections+[NSRange(location:at,length:0)]); window?.makeFirstResponder(self); return
        }
        clearExtraSelections(); super.mouseDown(with:event); synchronizeNativeSelection()
    }
    override func selectAll(_ sender: Any?) { clearExtraSelections(); super.selectAll(sender) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let rect = normalCaretRect {
            NSGraphicsContext.saveGraphicsState(); bounds.clip()
            Theme.accent.withAlphaComponent(0.55).setFill(); rect.intersection(visibleRect).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let extraSelections,let manager = layoutManager,let container = textContainer else { return }
        NSGraphicsContext.saveGraphicsState(); bounds.clip(); defer { NSGraphicsContext.restoreGraphicsState() }
        for range in extraSelections.dropFirst() {
            if range.length == 0,let window {
                let screen = firstRect(forCharacterRange:range,actualRange:nil)
                let rect = convert(window.convertFromScreen(screen),from:nil)
                Theme.accent.setFill(); NSRect(x:rect.minX,y:rect.minY,width:2,height:rect.height).intersection(visibleRect).fill()
            } else {
                let glyphs = manager.glyphRange(forCharacterRange:range,actualCharacterRange:nil)
                Theme.selection.withAlphaComponent(0.5).setFill()
                manager.enumerateEnclosingRects(forGlyphRange:glyphs,withinSelectedGlyphRange:glyphs,in:container) { rect,_ in
                    rect.offsetBy(dx:self.textContainerOrigin.x,dy:self.textContainerOrigin.y).intersection(self.visibleRect).fill()
                }
            }
        }
    }
    override func paste(_ sender: Any?) {
        guard editingSelections.count > 1,!hasMarkedText() else { super.paste(sender); return }
        if let value = NSPasteboard.general.string(forType:.string) { performMultiEdit(editingSelections,replacement:value) }
    }
    override func copy(_ sender: Any?) {
        guard editingSelections.count > 1 else { super.copy(sender); return }
        let ns = string as NSString,value = editingSelections.map { ns.substring(with:$0) }.joined(separator:"\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value,forType:.string)
    }
    override func cut(_ sender: Any?) {
        guard editingSelections.count > 1,!hasMarkedText() else { super.cut(sender); return }
        copy(sender); performMultiEdit(editingSelections,replacement:"")
    }
    override func insertText(_ insertString: Any,replacementRange: NSRange) {
        guard editingSelections.count > 1,!hasMarkedText() else { super.insertText(insertString,replacementRange:replacementRange); return }
        let value = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        performMultiEdit(editingSelections,replacement:value)
    }
    override func deleteBackward(_ sender: Any?) {
        guard editingSelections.count > 1,!hasMarkedText() else { super.deleteBackward(sender); return }
        let ns = string as NSString
        performMultiEdit(editingSelections.map { r in r.length > 0 || r.location == 0 ? r : ns.rangeOfComposedCharacterSequence(at:r.location-1) },replacement:"")
    }
    override func deleteForward(_ sender: Any?) {
        guard editingSelections.count > 1,!hasMarkedText() else { super.deleteForward(sender); return }
        let ns = string as NSString
        performMultiEdit(editingSelections.map { r in r.length > 0 || r.location == ns.length ? r : ns.rangeOfComposedCharacterSequence(at:r.location) },replacement:"")
    }
    override func insertNewline(_ sender: Any?) {
        if editingSelections.count > 1,!hasMarkedText() { performMultiEdit(editingSelections,replacement:"\n") }
        else { super.insertNewline(sender) }
    }
    private func performMultiEdit(_ ranges: [NSRange],replacement: String) {
        do {
            let result = try MultiEdit.apply(ranges,replacement:replacement,to:string)
            restoreMultiEdit(result.text,selections:result.selections.map(NSValue.init(range:)))
        } catch { NSSound.beep() }
    }
    private func restoreMultiEdit(_ text: String,selections: [NSValue]) {
        let before = string,previous = editingSelections.map(NSValue.init(range:))
        let manager = undoManager
        manager?.beginUndoGrouping(); manager?.disableUndoRegistration()
        textStorage?.replaceCharacters(in:NSRange(location:0,length:(string as NSString).length),with:text)
        didChangeText(); applySelections(selections.map(\.rangeValue))
        manager?.enableUndoRegistration()
        manager?.registerUndo(withTarget:self) { $0.restoreMultiEdit(before,selections:previous) }
        manager?.setActionName("Multi-cursor Edit"); manager?.endUndoGrouping()
    }
    override func insertTab(_ sender: Any?) {
        if editingSelections.count > 1,!hasMarkedText() {
            performMultiEdit(editingSelections,replacement:PreferencesSync.value("useSpaces") == "true" ? String(repeating:" ",count:Int(PreferencesSync.value("tabWidth")) ?? 4) : "\t"); return
        }
        if PreferencesSync.value("useSpaces") == "true" {
            let width = Int(PreferencesSync.value("tabWidth")) ?? 4
            let offset = selectedRange().location,start = document.map { $0.lines.starts[$0.lines.line(at:offset)] } ?? 0
            let column = (string as NSString).substring(with:NSRange(location:start,length:offset-start)).count
            insertText(String(repeating:" ",count:width-column%width),replacementRange:selectedRange())
        } else { super.insertTab(sender) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53,editingSelections.count > 1 {
            let first = editingSelections[0]; clearExtraSelections(); setSelectedRange(first); document?.vim.escape(); statusChanged?(); return
        }
        if !hasMarkedText(),moveMultipleCarets(event) { return }
        guard vimEnabled, let document, !hasMarkedText() else { super.keyDown(with:event); return }
        let vim = document.vim
        if event.keyCode == 53 {
            vim.sync(text:string,cursor:selectedRange().location); vim.escape(); statusChanged?(); needsDisplay = true; return
        }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) { super.keyDown(with:event); return }
        guard vim.mode == .normal else { super.keyDown(with:event); return }
        let key = event.characters ?? ""
        if editingSelections.count > 1 {
            if key == "i" || key == "a" { vim.key("i"); statusChanged?(); return }
            if key == "x" { deleteForward(nil); return }
            NSSound.beep(); return
        }
        if key == ":" { exCommand?(":"); return }
        vim.sync(text:string,cursor:selectedRange().location)
        vim.key(event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "r" ? "Ctrl+r" : key)
        if vim.changed, shouldChangeText(in:NSRange(location:0,length:(string as NSString).length), replacementString:vim.text) {
            applyingVim = true
            textStorage?.replaceCharacters(in:NSRange(location:0,length:(string as NSString).length),with:vim.text)
            didChangeText()
            applyingVim = false
        }
        setSelectedRange(NSRange(location:min(vim.cursor,(string as NSString).length),length:0))
        scrollRangeToVisible(selectedRange()); statusChanged?(); needsDisplay = true
    }
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // Draw the Normal-mode block in draw(_:), where selection invalidation clears it fully.
        guard !(vimEnabled && document?.vim.mode == .normal) else { return }
        super.drawInsertionPoint(in:rect,color:Theme.accent,turnedOn:flag)
    }
    var normalCaretRect: NSRect? {
        guard vimEnabled,document?.vim.mode == .normal,let window,window.firstResponder === self,
              selectedRange().length == 0 else { return nil }
        let rect = convert(window.convertFromScreen(firstRect(forCharacterRange:selectedRange(),actualRange:nil)),from:nil)
        return NSRect(x:rect.minX,y:rect.minY,width:max(8,Theme.fontSize*0.6),height:rect.height)
    }
}

final class EditorPane: NSView, NSTextViewDelegate {
    let textView: EditorTextView
    let scroll = NSScrollView()
    let gutter = LineNumbers()
    let document: OpenDocument
    var onChange: (() -> Void)?
    var onTextChanged: (() -> Void)?
    var onFocus: (() -> Void)?
    private var highlighting = false
    private var highlightWork: DispatchWorkItem?

    init(document: OpenDocument, vim: Bool) {
        self.document = document
        let manager = NSLayoutManager(), container = NSTextContainer(size:NSSize(width:0,height:CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true; manager.allowsNonContiguousLayout = true; manager.addTextContainer(container); document.storage.addLayoutManager(manager)
        textView = EditorTextView(frame:NSRect(x:0,y:0,width:800,height:600),textContainer:container)
        super.init(frame:.zero)
        wantsLayer = true; clipsToBounds = true; layer?.masksToBounds = true
        textView.clipsToBounds = true; scroll.clipsToBounds = true
        textView.document = document; textView.vimEnabled = vim
        textView.registerForDraggedTypes(textView.registeredDraggedTypes+[.fileURL])
        textView.delegate = self; textView.isRichText = false; textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isContinuousSpellCheckingEnabled = false
        textView.font = Theme.editorFont
        textView.textColor = Theme.foreground; textView.backgroundColor = Theme.canvas
        textView.insertionPointColor = Theme.accent
        textView.selectedTextAttributes = [.backgroundColor:Theme.selection]
        textView.textContainerInset = NSSize(width:12,height:18)
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width:0,height:0); textView.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        textView.usesFindBar = true; textView.isIncrementalSearchingEnabled = true
        textView.setAccessibilityLabel("Source editor")
        scroll.documentView = textView; scroll.hasVerticalScroller = true; scroll.drawsBackground = true; scroll.backgroundColor = Theme.canvas
        scroll.borderType = .noBorder
        gutter.editor = textView
        scroll.verticalRulerView = gutter; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        Theme.pin(scroll,in:self)
        textView.statusChanged = { [weak self] in self?.onChange?() }
        NotificationCenter.default.addObserver(self, selector:#selector(scrolled),name:NSView.boundsDidChangeNotification,object:scroll.contentView)
        scroll.contentView.postsBoundsChangedNotifications = true
        highlight()
        updatePreferences()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func scrolled() { gutter.needsDisplay = true }
    func textDidChange(_ notification: Notification) {
        guard !highlighting else { return }
        let before = document.buffer.text
        if !textView.applyingVim { document.vim.recordInsertion(before:before,cursor:textView.selectedRange().location) }
        document.buffer.update(document.storage.string)
        onTextChanged?()
        gutter.needsDisplay = true; onChange?()
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlight() }
        highlightWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
    }
    func textViewDidChangeSelection(_ notification: Notification) { textView.synchronizeNativeSelection(); onFocus?(); onChange?() }
    func textDidBeginEditing(_ notification: Notification) { onFocus?() }
    func updateFont() {
        textView.font = Theme.editorFont
        let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = ceil(Theme.fontSize*1.45)
        paragraph.defaultTabInterval = Theme.editorFont.maximumAdvancement.width*CGFloat(Int(PreferencesSync.value("tabWidth")) ?? 4)
        paragraph.tabStops = []; textView.defaultParagraphStyle = paragraph
        document.storage.addAttribute(.paragraphStyle,value:paragraph,range:NSRange(location:0,length:document.storage.length))
        textView.typingAttributes[.paragraphStyle] = paragraph; gutter.needsDisplay = true
    }
    func updatePreferences() {
        updateFont(); scroll.rulersVisible = PreferencesSync.value("lineNumbers") == "true"
        let wrap = PreferencesSync.value("wordWrap") == "true"
        textView.isHorizontallyResizable = !wrap; scroll.hasHorizontalScroller = !wrap
        textView.textContainer?.widthTracksTextView = wrap
        textView.textContainer?.containerSize = NSSize(width:wrap ? max(100,scroll.contentSize.width) : CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        if wrap { textView.setFrameSize(NSSize(width:scroll.contentSize.width,height:textView.frame.height)) }
    }
    override func layout() {
        super.layout()
        if PreferencesSync.value("wordWrap") == "true" {
            textView.textContainer?.containerSize = NSSize(width:max(100,scroll.contentSize.width),height:CGFloat.greatestFiniteMagnitude)
            textView.setFrameSize(NSSize(width:scroll.contentSize.width,height:textView.frame.height))
        }
    }
    func updateTheme() {
        textView.textColor = Theme.foreground; textView.backgroundColor = Theme.canvas; textView.insertionPointColor = Theme.accent
        textView.selectedTextAttributes = [.backgroundColor:Theme.selection]; scroll.backgroundColor = Theme.canvas
        gutter.needsDisplay = true; highlight()
    }
    private func highlight() {
        // Attribute-only highlighting leaves content, marked text and undo untouched.
        guard !textView.hasMarkedText(), document.storage.length < 1_000_000 else { return }
        highlighting = true; defer { highlighting = false }
        let storage = document.storage, whole = NSRange(location:0,length:document.storage.length)
        storage.beginEditing(); storage.addAttribute(.foregroundColor,value:Theme.foreground,range:whole)
        let ext = document.buffer.url?.pathExtension.lowercased() ?? ""
        if ["swift","js","ts","tsx","jsx","py","json","sh","css","rs","go","c","h","cpp"].contains(ext) {
            let rules: [(String,NSColor)] = [
                (#"\b(import|func|let|var|class|struct|enum|if|else|return|public|private|final|const|function|export|from|def|for|in|while|true|false|nil|null|self|async|await|throws|try)\b"#,Theme.keyword),
                (#"\b[0-9]+(?:\.[0-9]+)?\b"#,Theme.number),
                (#""(?:[^"\\]|\\.)*""#,Theme.accent),
                (#"//[^\n]*|(?m)^\s*#[^\n]*"#,Theme.secondary)
            ]
            for (pattern,color) in rules {
                if let regex = try? NSRegularExpression(pattern:pattern) {
                    regex.enumerateMatches(in:storage.string,range:whole) { result,_,_ in
                        if let result { storage.addAttribute(.foregroundColor,value:color,range:result.range) }
                    }
                }
            }
        }
        storage.endEditing()
    }
}

final class LineNumbers: NSRulerView {
    weak var editor: NSTextView?
    init() { super.init(scrollView:nil,orientation:.verticalRuler); ruleThickness = 48; clipsToBounds = true; wantsLayer = true }
    required init(coder: NSCoder) { fatalError() }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); bounds.clip(); defer { NSGraphicsContext.restoreGraphicsState() }
        Theme.canvas.setFill(); bounds.fill()
        guard let editor, let lm = editor.layoutManager, let tc = editor.textContainer else { return }
        let visible = editor.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect:visible.offsetBy(dx:0,dy:-editor.textContainerInset.height),in:tc)
        guard lm.numberOfGlyphs > 0 else { return }
        var glyph = glyphRange.location
        let ns = editor.string as NSString
        let initial = lm.characterIndexForGlyph(at:min(glyph,lm.numberOfGlyphs-1))
        var line = (editor as? EditorTextView)?.document?.lines.line(at:initial) ?? 0
        line += 1
        while glyph < NSMaxRange(glyphRange) && glyph < lm.numberOfGlyphs {
            var range = NSRange()
            let lineRect = lm.lineFragmentRect(forGlyphAt:glyph,effectiveRange:&range)
            let idx = lm.characterIndexForGlyph(at:glyph)
            if idx == 0 || ns.character(at:idx-1) == 10 {
                let y = lineRect.minY + editor.textContainerInset.height-visible.minY+max(0,(lineRect.height-15)/2)
                let label = String(line) as NSString
                let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:12,weight:.regular),.foregroundColor:Theme.secondary]
                label.draw(at:NSPoint(x:ruleThickness-14-label.size(withAttributes:attrs).width,y:y),withAttributes:attrs)
                line += 1
            }
            glyph = NSMaxRange(range)
        }
    }
}

final class HierarchyOutlineView: NSOutlineView {
    override func drawBackground(inClipRect clipRect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); bounds.clip(); defer { NSGraphicsContext.restoreGraphicsState() }
        super.drawBackground(inClipRect:clipRect)
        Theme.secondary.withAlphaComponent(0.18).setStroke()
        let visible = rows(in:clipRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<NSMaxRange(visible) {
            guard let item = item(atRow:row) else { continue }
            let depth = level(forItem:item), rect = rect(ofRow:row)
            for level in 0..<max(0,depth) {
                let x = CGFloat(level)*indentationPerLevel+9
                let path = NSBezierPath(); path.move(to:NSPoint(x:x,y:rect.minY)); path.line(to:NSPoint(x:x,y:rect.maxY)); path.lineWidth = 1; path.stroke()
            }
        }
    }
}
