import AppKit
import LinvellCore

extension EditorTextView {
    private func editLines(_ action: LineEditing.Action) {
        guard !hasMarkedText() else { return }
        let width = Int(PreferencesSync.value("tabWidth")) ?? 4
        let result = LineEditing.apply(action,text:string,selections:editingSelections,indent:PreferencesSync.value("useSpaces") == "true" ? String(repeating:" ",count:width) : "\t")
        guard result.text != string else { return }
        restoreMultiEdit(result.text,selections:result.selections.map(NSValue.init(range:)))
        scrollRangeToVisible(selectedRange()); statusChanged?()
    }
    @objc func moveLinesUp(_ sender: Any?) { editLines(.moveUp) }
    @objc func moveLinesDown(_ sender: Any?) { editLines(.moveDown) }
    @objc func copyLinesUp(_ sender: Any?) { editLines(.copyUp) }
    @objc func copyLinesDown(_ sender: Any?) { editLines(.copyDown) }
    @objc func deleteLines(_ sender: Any?) { editLines(.delete) }
    @objc func indentLines(_ sender: Any?) { editLines(.indent) }
    @objc func outdentLines(_ sender: Any?) { editLines(.outdent) }
    @objc func toggleLineComment(_ sender: Any?) {
        let ext = document?.fileURL?.pathExtension.lowercased() ?? ""
        let marker = ["py","sh","bash","zsh","fish","rb","yaml","yml","toml","r","pl"].contains(ext) ? "#" : ["sql","lua","hs"].contains(ext) ? "--" : "//"
        editLines(.comment(marker))
    }
    @objc func insertLineBelow(_ sender: Any?) { insertAdjacentLine(above:false) }
    @objc func insertLineAbove(_ sender: Any?) { insertAdjacentLine(above:true) }
    private func insertAdjacentLine(above: Bool) {
        let ns = string as NSString
        let points = MultiEdit.normalized(editingSelections.map { range in
            let line = ns.lineRange(for:NSRange(location:range.location,length:0))
            let end = NSMaxRange(line),hasNewline = end > line.location && ns.substring(with:NSRange(location:end-1,length:1)) == "\n"
            return NSRange(location:above ? line.location : end-(hasNewline ? 1 : 0),length:0)
        })
        performMultiEdit(points,replacement:"\n")
        if above { applySelections(editingSelections.map { NSRange(location:max(0,$0.location-1),length:0) }) }
    }
}
