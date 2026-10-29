import AppKit
import LinvellCore

final class OpenDocument: NSObject, NSTextStorageDelegate {
    let buffer: DocumentBuffer
    let storage = NSTextStorage()
    let vim = VimEngine()
    let lines: LineIndex
    let syntax = EditorSyntaxState()
    let imageURL: URL?
    var codeDiagnostics: [CodeDiagnostic] = []
    var markdownPreview = false
    var remote: RemoteDocument?
    var lastScroll: DocumentScrollAnchor?
    var lastSelections: [NSRange]?
    var fileURL: URL? { imageURL ?? buffer.url }
    var displayName: String { remote.map { URL(fileURLWithPath:$0.path).lastPathComponent } ?? imageURL?.lastPathComponent ?? buffer.url?.lastPathComponent ?? L.text("Untitled") }
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
        // Vim, multi-edit, refactor and native input all pass through this shared
        // delegate. Never carry old hidden offsets across a text replacement.
        for manager in textStorage.layoutManagers.compactMap({ $0 as? FoldingLayoutManager }) where !manager.hidden.isEmpty { manager.hidden = [] }
        let old = NSRange(location:editedRange.location,length:editedRange.length-delta)
        lines.apply(range:old,replacement:(textStorage.string as NSString).substring(with:editedRange))
    }
}

final class EditorTextView: NSTextView {
    override class var isCompatibleWithResponsiveScrolling: Bool { true }
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
    var codeDismiss: (() -> Void)?
    var codeAction: ((String,Int?) -> Void)?
    var completionKey: ((NSEvent) -> Bool)?
    var hoverOffset: Int?
    var hoverWork: DispatchWorkItem?
    var codeTracking: NSTrackingArea?
    var document: OpenDocument?
    var vimEnabled = false
    var statusChanged: (() -> Void)?
    var exCommand: ((String) -> Void)?
    var applyingVim = false
    var selectionHistory: [[NSValue]] = []
    private var extraSelections: [NSRange]?
    var visualAnchor: Int?
    var visualHead: Int?
    let visualMotion = VimEngine()
    var multiPending = "",multiCount = "",multiOperatorCount = 1
    var replacedCharacters: [(Int,String,Int)] = []
    var editingSelections: [NSRange] { extraSelections ?? selectedRanges.map(\.rangeValue) }
    func applySelections(_ ranges: [NSRange]) {
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
        codeDismiss?()
        hoverWork?.cancel(); hoverOffset = nil
        if event.modifierFlags.intersection([.command,.option,.shift]) == .command {
            codeAction?("definition",characterIndexForInsertion(at:convert(event.locationInWindow,from:nil))); return
        }
        if vimEnabled { document?.vim.cancelPendingCommand() }
        if event.modifierFlags.intersection([.command,.option,.shift]) == [.option,.shift] {
            let anchor = characterIndexForInsertion(at:convert(event.locationInWindow,from:nil))
            window?.makeFirstResponder(self)
            var next: NSEvent? = event
            while let current = next {
                let head = characterIndexForInsertion(at:convert(current.locationInWindow,from:nil))
                selectColumns(anchor:anchor,head:head)
                if current.type == .leftMouseUp { break }
                next = window?.nextEvent(matching:[.leftMouseDragged,.leftMouseUp])
            }
            return
        }
        visualAnchor = nil; visualHead = nil
        if event.modifierFlags.intersection([.command,.option,.shift]) == .option {
            let point = convert(event.locationInWindow,from:nil),at = characterIndexForInsertion(at:point)
            setSelections(editingSelections+[NSRange(location:at,length:0)]); window?.makeFirstResponder(self); return
        }
        clearExtraSelections(); super.mouseDown(with:event); synchronizeNativeSelection()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let codeTracking { removeTrackingArea(codeTracking) }
        let area = NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area); codeTracking = area
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true
    }
    override func mouseMoved(with event: NSEvent) {
        let offset = characterIndexForInsertion(at:convert(event.locationInWindow,from:nil)),word = Self.codeWord(in:string,at:offset)
        let at = word.location
        guard hoverOffset != at else { return }; hoverWork?.cancel(); hoverOffset = at
        guard word.length > 0 else { return }
        let work = DispatchWorkItem { [weak self] in guard let self,self.hoverOffset == at else { return }; self.codeAction?("hover",at) }
        hoverWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.5,execute:work)
    }
    override func mouseExited(with event: NSEvent) { hoverWork?.cancel(); hoverOffset = -1 }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for:event) ?? NSMenu()
        menu.addItem(.separator())
        for (title,selector) in [("Go to Definition",#selector(codeDefinition)),("Find All References",#selector(codeReferences)),("Rename Symbol…",#selector(codeRename))] {
            let item = NSMenuItem(title:L.text(title),action:selector,keyEquivalent:""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc private func codeDefinition() { codeAction?("definition",nil) }
    @objc private func codeReferences() { codeAction?("references",nil) }
    @objc private func codeRename() { codeAction?("rename",nil) }
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
        if let value = NSPasteboard.general.string(forType:.string) {
            let lines = value.components(separatedBy:"\n")
            if lines.count == editingSelections.count { performMultiEdit(editingSelections,replacements:lines) }
            else { performMultiEdit(editingSelections,replacement:value) }
        }
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
        let value = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
        if value.count == 1,"}])".contains(value),editingSelections.count == 1,!hasMarkedText() {
            let selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
            let start = document?.lines.starts[document!.lines.line(at:selection.location)] ?? 0
            let prefix = (string as NSString).substring(with:NSRange(location:start,length:selection.location-start))
            let unit = PreferencesSync.value("useSpaces") == "true" ? String(repeating:" ",count:max(1,Int(PreferencesSync.value("tabWidth")) ?? 4)) : "\t"
            if selection.length == 0,prefix.hasSuffix(unit),prefix.allSatisfy({ $0 == " " || $0 == "\t" }) {
                super.insertText(String(prefix.dropLast(unit.count))+value,replacementRange:NSRange(location:start,length:selection.location-start)); return
            }
        }
        if vimEnabled,document?.vim.mode == .replace,editingSelections.count == 1,!hasMarkedText() {
            let ns = string as NSString,start = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
            var end = NSMaxRange(start)
            if start.length == 0 {
                for character in value {
                    if character == "\n" { break }
                    if end < ns.length,ns.substring(with:ns.rangeOfComposedCharacterSequence(at:end)) != "\n" { end = NSMaxRange(ns.rangeOfComposedCharacterSequence(at:end)) }
                }
            }
            let range = NSRange(location:start.location,length:end-start.location)
            replacedCharacters.append((start.location,ns.substring(with:range),value.utf16.count))
            super.insertText(value,replacementRange:range); return
        }
        guard editingSelections.count > 1,!hasMarkedText() else { super.insertText(insertString,replacementRange:replacementRange); return }
        performMultiEdit(editingSelections,replacement:value)
    }
    override func deleteBackward(_ sender: Any?) {
        if vimEnabled,document?.vim.mode == .replace,!hasMarkedText(),selectedRange().length == 0,
           let last = replacedCharacters.last,selectedRange().location == last.0+last.2 {
            replacedCharacters.removeLast()
            super.insertText(last.1,replacementRange:NSRange(location:last.0,length:last.2))
            setSelectedRange(NSRange(location:last.0,length:0)); return
        }
        guard editingSelections.count > 1,!hasMarkedText() else { super.deleteBackward(sender); return }
        let ns = string as NSString
        performMultiEdit(editingSelections.map { r in r.length > 0 || r.location == 0 ? r : ns.rangeOfComposedCharacterSequence(at:r.location-1) },replacement:"")
    }
    override func deleteForward(_ sender: Any?) {
        guard editingSelections.count > 1,!hasMarkedText() else { super.deleteForward(sender); return }
        let ns = string as NSString
        performMultiEdit(editingSelections.map { r in r.length > 0 || r.location == ns.length ? r : ns.rangeOfComposedCharacterSequence(at:r.location) },replacement:"")
    }
    override func insertNewline(_ sender: Any?) { insertIndentedNewline(sender) }

    func performMultiEdit(_ ranges: [NSRange],replacement: String) {
        do {
            let result = try MultiEdit.apply(ranges,replacement:replacement,to:string)
            restoreMultiEdit(result.text,selections:result.selections.map(NSValue.init(range:)))
        } catch { NSSound.beep() }
    }
    func performMultiEdit(_ ranges: [NSRange],replacements: [String]) {
        do {
            let result = try MultiEdit.apply(ranges,replacements:replacements,to:string)
            restoreMultiEdit(result.text,selections:result.selections.map(NSValue.init(range:)))
        } catch { NSSound.beep() }
    }
    func restoreMultiEdit(_ text: String,selections: [NSValue]) {
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
        hoverWork?.cancel(); hoverOffset = nil
        if completionKey?(event) == true { return }
        if event.modifierFlags.intersection([.command,.control,.option,.shift]) == .control,event.keyCode == 49 { codeAction?("completion",nil); return }
        if handleColumnKey(event) { return }
        if vimEnabled,handleVisualKey(event) { return }
        if event.keyCode == 53,editingSelections.count > 1 {
            multiPending = ""; multiCount = ""; multiOperatorCount = 1
            if document?.vim.mode == .insert { document?.vim.escape(); statusChanged?(); needsDisplay = true; return }
            let first = editingSelections[0]; clearExtraSelections(); setSelectedRange(first); document?.vim.escape(); statusChanged?(); return
        }
        if !hasMarkedText(),moveMultipleCarets(event) { return }
        guard vimEnabled, let document, !hasMarkedText() else { super.keyDown(with:event); return }
        let vim = document.vim
        if event.keyCode == 53 {
            vim.sync(text:string,cursor:selectedRange().location); vim.key("Escape"); setSelectedRange(NSRange(location:vim.cursor,length:0)); statusChanged?(); needsDisplay = true; return
        }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) { super.keyDown(with:event); return }
        guard vim.mode == .normal else { super.keyDown(with:event); return }
        let key = event.characters ?? ""
        if editingSelections.count > 1 {
            handleMultiVim(key:event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "r" ? "Ctrl+r" : key); return
        }
        if [":","/","?"].contains(key) { exCommand?(key); return }
        vim.sync(text:string,cursor:selectedRange().location)
        let clipboardRegister = ["+","*"].contains(vim.activeRegister),registerRevision = vim.registerRevision
        if clipboardRegister,["p","P"].contains(key),let value = NSPasteboard.general.string(forType:.string) { vim.setRegister(vim.activeRegister,value:value) }
        vim.key(event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "r" ? "Ctrl+r" : key)
        if clipboardRegister,vim.registerRevision != registerRevision {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(vim.register,forType:.string)
        }
        if vim.mode == .replace,key == "R" { replacedCharacters.removeAll() }
        let resultCursor = vim.cursor
        if vim.changed, shouldChangeText(in:NSRange(location:0,length:(string as NSString).length), replacementString:vim.text) {
            applyingVim = true
            textStorage?.replaceCharacters(in:NSRange(location:0,length:(string as NSString).length),with:vim.text)
            didChangeText()
            applyingVim = false
        }
        setSelectedRange(NSRange(location:min(resultCursor,(string as NSString).length),length:0))
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
    let scroll = ResponsiveScrollView()
    let gutter = LineNumbers()
    let document: OpenDocument
    var onChange: (() -> Void)?
    var onTextChanged: (() -> Void)?
    var onFocus: (() -> Void)?
    var onScroll: ((DocumentScrollAnchor) -> Void)?
    private var followingPreviewScroll = false
    private var highlighting = false
    private var highlightWork: DispatchWorkItem?

    init(document: OpenDocument, vim: Bool) {
        self.document = document
        let manager = FoldingLayoutManager(), container = NSTextContainer(size:NSSize(width:0,height:CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true; manager.allowsNonContiguousLayout = true; manager.addTextContainer(container); document.storage.addLayoutManager(manager)
        textView = EditorTextView(frame:NSRect(x:0,y:0,width:800,height:600),textContainer:container)
        super.init(frame:.zero)
        wantsLayer = true; clipsToBounds = true; layer?.masksToBounds = true
        textView.clipsToBounds = true; scroll.clipsToBounds = true
        textView.document = document; textView.vimEnabled = vim
        gutter.pane = self
        NotificationCenter.default.addObserver(self,selector:#selector(sourceAnalysisChanged(_:)),name:EditorSyntaxState.changed,object:document)
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
    @objc private func scrolled() { gutter.needsDisplay = true; paintSyntax(); if !followingPreviewScroll { onScroll?(scrollAnchor) } }
    var scrollAnchor: DocumentScrollAnchor {
        guard let manager = textView.layoutManager,let container = textView.textContainer,manager.numberOfGlyphs > 0 else { return DocumentScrollAnchor(line:1,progress:0) }
        let y = scroll.contentView.bounds.minY,origin = textView.textContainerOrigin
        let glyph = min(manager.numberOfGlyphs-1,manager.glyphIndex(for:NSPoint(x:0,y:max(0,y-origin.y)),in:container))
        let offset = manager.characterIndexForGlyph(at:glyph),row = document.lines.line(at:offset)
        let start = document.lines.starts[row],end = row+1 < document.lines.starts.count ? document.lines.starts[row+1] : document.buffer.text.utf16.count
        let rect = manager.boundingRect(forGlyphRange:manager.glyphRange(forCharacterRange:NSRange(location:start,length:end-start),actualCharacterRange:nil),in:container)
        let fraction = max(0,min(0.999,(y-origin.y-rect.minY)/max(1,rect.height)))
        let maximum = max(0,textView.frame.height-scroll.contentView.bounds.height)
        return DocumentScrollAnchor(line:Double(row+1)+Double(fraction),progress:maximum > 0 ? Double(max(0,min(1,y/maximum))) : 0)
    }
    func scrollFromPreview(_ anchor: DocumentScrollAnchor) {
        guard let manager = textView.layoutManager,let container = textView.textContainer else { return }
        let row = min(document.lines.starts.count-1,max(0,Int(anchor.line)-1))
        let start = document.lines.starts[row],end = row+1 < document.lines.starts.count ? document.lines.starts[row+1] : document.buffer.text.utf16.count
        let range = NSRange(location:start,length:end-start)
        manager.ensureLayout(forCharacterRange:range)
        let rect = manager.boundingRect(forGlyphRange:manager.glyphRange(forCharacterRange:range,actualCharacterRange:nil),in:container)
        let maximum = max(0,textView.frame.height-scroll.contentView.bounds.height)
        let target = anchor.progress <= 0.001 ? 0 : anchor.progress >= 0.999 ? maximum : textView.textContainerOrigin.y+rect.minY+CGFloat(anchor.line-floor(anchor.line))*rect.height
        followingPreviewScroll = true
        scroll.contentView.scroll(to:NSPoint(x:scroll.contentView.bounds.minX,y:max(0,min(maximum,target))))
        scroll.reflectScrolledClipView(scroll.contentView)
        DispatchQueue.main.async { [weak self] in self?.followingPreviewScroll = false }
    }
    func textView(_ textView: NSTextView,shouldChangeTextIn affectedCharRange: NSRange,replacementString: String?) -> Bool {
        for manager in document.storage.layoutManagers.compactMap({ $0 as? FoldingLayoutManager }) where !manager.hidden.isEmpty { manager.hidden = [] }
        if self.textView.vimEnabled,!self.textView.applyingVim,(document.vim.mode == .insert || document.vim.mode == .replace),let replacementString {
            document.vim.recordNativeEdit(range:affectedCharRange,replacement:replacementString,cursor:textView.selectedRange().location)
        }
        return true
    }
    func textDidChange(_ notification: Notification) {
        guard !highlighting else { return }
        let before = document.buffer.text
        if !textView.applyingVim { document.vim.recordInsertion(before:before,cursor:textView.selectedRange().location); document.vim.sync(text:document.storage.string,cursor:textView.selectedRange().location) }
        document.buffer.update(document.storage.string)
        document.syntax.request(document)
        onTextChanged?()
        gutter.needsDisplay = true; onChange?()
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlight() }
        highlightWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
    }
    func textViewDidChangeSelection(_ notification: Notification) { revealSelection(); textView.synchronizeNativeSelection(); highlightBrackets(); gutter.needsDisplay = true; onFocus?(); onChange?() }
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
    func refreshCodePresentation() { gutter.needsDisplay = true; highlight(); applyCodeDiagnostics(); onChange?() }
    func applyCodeDiagnostics() {
        let whole = NSRange(location:0,length:(document.storage.string as NSString).length)
        textView.layoutManager?.removeTemporaryAttribute(.underlineStyle,forCharacterRange:whole)
        for diagnostic in document.codeDiagnostics.prefix(500) {
            guard let range = try? diagnostic.range.range(in:document.buffer.text,index:document.lines),NSMaxRange(range) <= whole.length else { continue }
            textView.layoutManager?.addTemporaryAttributes([.underlineStyle:NSUnderlineStyle.single.rawValue,.underlineColor:(diagnostic.severity == 1 ? NSColor.systemRed : NSColor.systemOrange)],forCharacterRange:range)
        }
    }
    private func highlight() {
        document.syntax.request(document); paintSyntax(); highlightBrackets()
    }

}

final class LineNumbers: NSRulerView {
    weak var editor: NSTextView?
    weak var pane: EditorPane?
    var foldHits: [(CGRect,Int)] = []
    func numberLabel(row: Int,current: Int) -> String {
        String(PreferencesSync.value("relativeLineNumbers") == "true" && row != current ? abs(row-current) : row+1)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        if let hit = foldHits.first(where:{ $0.0.contains(point) }) { pane?.toggleFold(line:hit.1) }
        else { super.mouseDown(with:event) }
    }
    init() { super.init(scrollView:nil,orientation:.verticalRuler); ruleThickness = 72; clipsToBounds = true; wantsLayer = true }
    required init(coder: NSCoder) { fatalError() }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState(); bounds.clip(); defer { NSGraphicsContext.restoreGraphicsState() }
        Theme.canvas.setFill(); bounds.fill()
        guard let editor, let lm = editor.layoutManager, let tc = editor.textContainer else { return }
        let digits = String((editor as? EditorTextView)?.document?.lines.starts.count ?? 1).count
        let desired = max(72,CGFloat(digits)*8+30)
        if ruleThickness != desired { ruleThickness = desired }
        foldHits.removeAll()
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
                let row = (editor as? EditorTextView)?.document?.lines.line(at:idx) ?? line-1
                let current = (editor as? EditorTextView)?.document?.lines.line(at:editor.selectedRange().location) ?? 0
                let label = numberLabel(row:row,current:current) as NSString
                if let pane,let fold = pane.document.syntax.analysis.fold(atLine:row) {
                    let hit = CGRect(x:0,y:y,width:15,height:18); foldHits.append((hit,row))
                    let mark = (pane.folding.hides(fold.range.location) ? "▸" : "▾") as NSString
                    mark.draw(at:NSPoint(x:2,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:Theme.accent])
                }
                let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:12,weight:.regular),.foregroundColor:Theme.secondary]
                label.draw(at:NSPoint(x:ruleThickness-14-label.size(withAttributes:attrs).width,y:y),withAttributes:attrs)
                line += 1
            }
            glyph = max(glyph+1,NSMaxRange(range))
        }
    }
}

final class HierarchyOutlineView: ResponsiveOutlineView {
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
