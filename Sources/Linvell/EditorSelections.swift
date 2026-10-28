import AppKit
import LinvellCore

extension EditorTextView {
    func selectColumns(anchor: Int,head: Int,inclusive: Bool = false) {
        visualAnchor = anchor; visualHead = head
        setSelections(ColumnSelection.ranges(in:string,anchor:anchor,head:head,inclusive:inclusive,tabWidth:Int(PreferencesSync.value("tabWidth")) ?? 4))
        statusChanged?()
    }
    func handleColumnKey(_ event: NSEvent) -> Bool {
        guard [123,124,125,126].contains(event.keyCode),event.modifierFlags.intersection([.command,.option,.shift,.control]) == [.command,.option,.shift] else { return false }
        let anchor = visualAnchor ?? selectedRange().location,head = visualHead ?? NSMaxRange(selectedRange()),ns = string as NSString
        var next = head
        if event.keyCode == 123 { next = head > 0 ? ns.rangeOfComposedCharacterSequence(at:head-1).location : 0 }
        else if event.keyCode == 124 { next = head < ns.length ? NSMaxRange(ns.rangeOfComposedCharacterSequence(at:head)) : ns.length }
        else if let document {
            let row = document.lines.line(at:head),target = row+(event.keyCode == 126 ? -1 : 1)
            if document.lines.starts.indices.contains(target) {
                let end = target+1 < document.lines.starts.count ? document.lines.starts[target+1]-1 : ns.length
                next = min(end,document.lines.starts[target]+head-document.lines.starts[row])
                if next < ns.length { next = ns.rangeOfComposedCharacterSequence(at:next).location }
            }
        }
        selectColumns(anchor:anchor,head:next); return true
    }
    func handleVisualKey(_ event: NSEvent) -> Bool {
        guard let document,!hasMarkedText(),!event.modifierFlags.contains(.command),!event.modifierFlags.contains(.option) else { return false }
        let vim = document.vim,key = event.characters ?? "",ns = string as NSString
        let blockKey = event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "v"
        let visual = [VimEngine.Mode.visual,.visualLine,.visualBlock].contains(vim.mode)
        if vim.mode == .normal && (key == "v" || key == "V" || blockKey) {
            visualAnchor = selectedRange().location; visualHead = visualAnchor
            vim.beginVisual(blockKey ? .visualBlock : key == "V" ? .visualLine : .visual)
            refreshVisualSelection(); return true
        }
        guard visual else { return false }
        if multiPending == "visual-r",key.count == 1 {
            multiPending = ""
            let replacements = editingSelections.map { ns.substring(with:$0).map { $0 == "\n" ? "\n" : key }.joined() }
            performMultiEdit(editingSelections,replacements:replacements)
            visualAnchor = nil; visualHead = nil; vim.escape(); statusChanged?(); return true
        }
        if event.keyCode == 53 {
            multiPending = ""
            let at = visualHead ?? selectedRange().location; vim.escape(); visualAnchor = nil; visualHead = nil
            clearExtraSelections(); setSelectedRange(NSRange(location:at,length:0)); statusChanged?(); return true
        }
        if key == "v" || key == "V" || blockKey {
            vim.beginVisual(blockKey ? .visualBlock : key == "V" ? .visualLine : .visual); refreshVisualSelection(); return true
        }
        if ["d","x","c"].contains(key) {
            let selections = editingSelections
            performMultiEdit(selections,replacement:""); visualAnchor = nil; visualHead = nil
            vim.escape(); if key == "c" { vim.enterInsert() }; statusChanged?(); return true
        }
        if key == "r" { multiPending = "visual-r"; return true }
        if key == "y" {
            vim.yank(editingSelections.map { ns.substring(with:$0) }.joined(separator:"\n"))
            copy(nil); let at = visualAnchor ?? selectedRange().location
            visualAnchor = nil; visualHead = nil; clearExtraSelections(); setSelectedRange(NSRange(location:at,length:0)); vim.escape(); statusChanged?(); return true
        }
        if key == "I" || key == "A" {
            setSelections(editingSelections.map { NSRange(location:key == "I" ? $0.location : NSMaxRange($0),length:0) })
            visualAnchor = nil; visualHead = nil; vim.enterInsert(); statusChanged?(); return true
        }
        let motions = ["h","j","k","l","w","b","0","$","G"]
        if motions.contains(key) {
            let kind = vim.mode; vim.escape(); vim.sync(text:string,cursor:visualHead ?? selectedRange().location); vim.key(key)
            visualHead = min(vim.cursor,ns.length); vim.beginVisual(kind); refreshVisualSelection(); return true
        }
        return true
    }
    func refreshVisualSelection() {
        guard let document,let anchor = visualAnchor,let head = visualHead else { return }
        let ns = string as NSString,mode = document.vim.mode
        if mode == .visualBlock { selectColumns(anchor:anchor,head:head,inclusive:true) }
        else {
            let lower = min(anchor,head),at = max(anchor,head)
            let upper = at < ns.length ? NSMaxRange(ns.rangeOfComposedCharacterSequence(at:at)) : ns.length
            let range = NSRange(location:lower,length:upper-lower)
            setSelections([mode == .visualLine ? ns.lineRange(for:range) : range])
        }
        statusChanged?(); needsDisplay = true
    }
    func handleMultiVim(key: String) {
        guard let document else { return }; let vim = document.vim,ns = string as NSString
        if multiPending == "r",key.count == 1 {
            multiPending = ""
            let ranges = editingSelections.map { $0.length > 0 || $0.location == ns.length ? $0 : ns.rangeOfComposedCharacterSequence(at:$0.location) }
            let replacements = ranges.map { ns.substring(with:$0).map { $0 == "\n" ? "\n" : key }.joined() }
            performMultiEdit(ranges,replacements:replacements); return
        }
        if key == "u" { undoManager?.undo(); return }
        if key == "Ctrl+r" { undoManager?.redo(); return }
        if key == "i" || key == "a" || key == "I" || key == "A" {
            if key != "i" { setSelections(editingSelections.map { range in
                let line = ns.lineRange(for:NSRange(location:range.location,length:0))
                let end = NSMaxRange(line)-(NSMaxRange(line) > line.location && ns.substring(with:NSRange(location:NSMaxRange(line)-1,length:1)) == "\n" ? 1 : 0)
                return NSRange(location:key == "I" ? line.location : key == "A" ? end : NSMaxRange(range),length:0)
            }) }
            vim.enterInsert(); statusChanged?(); return
        }
        if key == "r" { multiPending = "r"; return }
        if key == "y" { vim.yank(editingSelections.map { ns.substring(with:$0) }.joined(separator:"\n")); copy(nil); return }
        if key == "p" {
            let values = vim.register.components(separatedBy:"\n")
            if values.count == editingSelections.count { performMultiEdit(editingSelections,replacements:values) }
            else { performMultiEdit(editingSelections,replacement:vim.register) }; return
        }
        if key == "c",editingSelections.contains(where:{ $0.length > 0 }) { performMultiEdit(editingSelections,replacement:""); vim.enterInsert(); statusChanged?(); return }
        if key == "x" || key == "d" && editingSelections.contains(where:{ $0.length > 0 }) { deleteForward(nil); return }
        if key == "d" || key == "c" { multiPending = key; return }
        if !multiPending.isEmpty {
            let operation = multiPending; multiPending = ""
            let ranges = editingSelections.map { range -> NSRange in
                let engine = VimEngine(); engine.sync(text:string,cursor:range.location)
                if key == "d" || key == "c" { return ns.lineRange(for:NSRange(location:range.location,length:0)) }
                guard key == "w" || key == "$" else { return NSRange(location:range.location,length:0) }
                engine.key(key)
                var end = engine.cursor
                if key == "$",end < ns.length { end = NSMaxRange(ns.rangeOfComposedCharacterSequence(at:end)) }
                return NSRange(location:range.location,length:max(0,end-range.location))
            }
            performMultiEdit(ranges,replacement:""); if operation == "c" { vim.enterInsert() }; statusChanged?(); return
        }
        if ["h","j","k","l","w","b","0","$","G"].contains(key) {
            setSelections(editingSelections.map { range in
                let engine = VimEngine(); engine.sync(text:string,cursor:range.location); engine.key(key)
                return NSRange(location:engine.cursor,length:0)
            }); statusChanged?(); return
        }
    }
}
