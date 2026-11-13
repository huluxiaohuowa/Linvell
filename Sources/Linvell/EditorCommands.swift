import AppKit
import LinvellCore

extension EditorTextView {
    private func editLines(_ action: LineEditing.Action) {
        guard !hasMarkedText() else { return }
        let result = LineEditing.apply(action,text:string,selections:editingSelections,indent:indentation.unit,tabWidth:indentation.width)
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
        let path = document?.remote?.path ?? document?.fileURL?.path ?? ""
        let comment = SourceSyntax.commentDelimiters(for:path)
        if let close = comment.close { editLines(.blockComment(comment.open,close)) }
        else { editLines(.comment(comment.open)) }
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
