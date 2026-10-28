import AppKit
import LinvellCore

final class OpenDocument {
    let buffer: DocumentBuffer
    let storage = NSTextStorage()
    let vim = VimEngine()
    init(_ buffer: DocumentBuffer) { self.buffer = buffer; storage.setAttributedString(NSAttributedString(string: buffer.text)) }
}

final class EditorTextView: NSTextView {
    var document: OpenDocument?
    var vimEnabled = false
    var statusChanged: (() -> Void)?
    var exCommand: ((String) -> Void)?
    var applyingVim = false
    override func insertTab(_ sender: Any?) {
        if PreferencesSync.value("useSpaces") == "true" {
            let width = Int(PreferencesSync.value("tabWidth")) ?? 4
            let before = (string as NSString).substring(to:selectedRange().location)
            let column = before.components(separatedBy:"\n").last?.count ?? 0
            insertText(String(repeating:" ",count:width-column%width),replacementRange:selectedRange())
        } else { super.insertTab(sender) }
    }
    override func keyDown(with event: NSEvent) {
        guard vimEnabled, let document, !hasMarkedText() else { super.keyDown(with:event); return }
        let vim = document.vim
        if event.keyCode == 53 {
            vim.sync(text:string,cursor:selectedRange().location); vim.escape(); statusChanged?(); needsDisplay = true; return
        }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) { super.keyDown(with:event); return }
        guard vim.mode == .normal else { super.keyDown(with:event); return }
        let key = event.characters ?? ""
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
        if vimEnabled && document?.vim.mode == .normal {
            if flag { Theme.accent.withAlphaComponent(0.55).setFill(); NSRect(x:rect.minX,y:rect.minY,width:max(8,Theme.fontSize * 0.6),height:rect.height).fill() }
        } else { super.drawInsertionPoint(in:rect,color:Theme.accent,turnedOn:flag) }
    }
}

final class EditorPane: NSView, NSTextViewDelegate {
    let textView: EditorTextView
    let scroll = NSScrollView()
    let gutter = LineNumbers()
    let document: OpenDocument
    var onChange: (() -> Void)?
    var onFocus: (() -> Void)?
    private var highlighting = false
    private var highlightWork: DispatchWorkItem?

    init(document: OpenDocument, vim: Bool) {
        self.document = document
        let manager = NSLayoutManager(), container = NSTextContainer(size:NSSize(width:0,height:CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true; manager.addTextContainer(container); document.storage.addLayoutManager(manager)
        textView = EditorTextView(frame:NSRect(x:0,y:0,width:800,height:600),textContainer:container)
        super.init(frame:.zero)
        textView.document = document; textView.vimEnabled = vim
        textView.delegate = self; textView.isRichText = false; textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false; textView.isContinuousSpellCheckingEnabled = false
        textView.font = Theme.editorFont
        textView.textColor = Theme.foreground; textView.backgroundColor = Theme.canvas
        textView.insertionPointColor = Theme.accent
        textView.selectedTextAttributes = [.backgroundColor:Theme.selection]
        textView.textContainerInset = NSSize(width:18,height:20)
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
        gutter.needsDisplay = true; onChange?()
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlight() }
        highlightWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
    }
    func textViewDidChangeSelection(_ notification: Notification) { onFocus?(); onChange?() }
    func textDidBeginEditing(_ notification: Notification) { onFocus?() }
    func updateFont() { textView.font = Theme.editorFont; gutter.needsDisplay = true }
    func updatePreferences() {
        updateFont(); scroll.rulersVisible = PreferencesSync.value("lineNumbers") == "true"
        let wrap = PreferencesSync.value("wordWrap") == "true"
        textView.isHorizontallyResizable = !wrap; scroll.hasHorizontalScroller = !wrap
        textView.textContainer?.widthTracksTextView = wrap
        textView.textContainer?.containerSize = NSSize(width:wrap ? max(100,scroll.contentSize.width) : CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        if wrap { textView.setFrameSize(NSSize(width:scroll.contentSize.width,height:textView.frame.height)) }
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
    init() { super.init(scrollView:nil,orientation:.verticalRuler); ruleThickness = 58 }
    required init(coder: NSCoder) { fatalError() }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.canvas.setFill(); bounds.fill()
        guard let editor, let lm = editor.layoutManager, let tc = editor.textContainer else { return }
        let visible = editor.visibleRect
        let glyphRange = lm.glyphRange(forBoundingRect:visible.offsetBy(dx:0,dy:-editor.textContainerInset.height),in:tc)
        guard lm.numberOfGlyphs > 0 else { return }
        var glyph = glyphRange.location
        let ns = editor.string as NSString
        let initial = lm.characterIndexForGlyph(at:min(glyph,lm.numberOfGlyphs-1))
        var line = ns.substring(to:initial).filter { $0 == "\n" }.count + 1
        while glyph < NSMaxRange(glyphRange) && glyph < lm.numberOfGlyphs {
            var range = NSRange()
            let lineRect = lm.lineFragmentRect(forGlyphAt:glyph,effectiveRange:&range)
            let idx = lm.characterIndexForGlyph(at:glyph)
            if idx == 0 || ns.character(at:idx-1) == 10 {
                let y = lineRect.minY + editor.textContainerInset.height-visible.minY
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
