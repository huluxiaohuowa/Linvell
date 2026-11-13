import Foundation

public enum LineEditing {
    public enum Action { case moveUp,moveDown,copyUp,copyDown,delete,indent,outdent,comment(String),blockComment(String,String) }
    public static func apply(_ action: Action,text: String,selections: [NSRange],indent: String = "    ",tabWidth: Int? = nil) -> MultiEdit.Result {
        let source = text as NSString,index = LineIndex(text)
        var rows = text.components(separatedBy:"\n").enumerated().map { (id:$0.offset,text:$0.element) }
        var selected = IndexSet()
        for range in selections {
            let start = index.line(at:min(range.location,source.length))
            let end = index.line(at:min(source.length,range.length > 0 ? NSMaxRange(range)-1 : range.location))
            selected.insert(integersIn:start...max(start,end))
        }
        let blocks = selected.rangeView.map { $0 }
        var prefixes: [Int:Int] = [:]
        switch action {
        case .moveUp:
            for block in blocks where block.lowerBound > 0 {
                let prior = rows.remove(at:block.lowerBound-1); rows.insert(prior,at:block.upperBound-1)
            }
        case .moveDown:
            for block in blocks.reversed() where block.upperBound < rows.count {
                let next = rows.remove(at:block.upperBound); rows.insert(next,at:block.lowerBound)
            }
        case .copyUp,.copyDown:
            let up: Bool = { if case .copyUp = action { return true }; return false }()
            for block in blocks.reversed() {
                let copied = Array(rows[block])
                for row in block { rows[row].id = -row-1 }
                rows.insert(contentsOf:copied,at:up ? block.lowerBound : block.upperBound)
            }
        case .delete:
            for row in selected.reversed() { rows.remove(at:row) }
            if rows.isEmpty { rows = [(id:-1,text:"")] }
        case .indent:
            for row in selected { rows[row].text = indent+rows[row].text; prefixes[row] = indent.utf16.count }
        case .outdent:
            for row in selected {
                let value = rows[row].text,amount = value.hasPrefix("\t") ? 1 : value.prefix(tabWidth ?? indent.count).prefix { $0 == " " }.count
                let removed = String(value.prefix(amount)).utf16.count
                rows[row].text = String(value.dropFirst(amount)); prefixes[row] = -removed
            }
        case .comment(let marker):
            let nonBlank = selected.filter { !rows[$0].text.trimmingCharacters(in:.whitespaces).isEmpty }
            let uncomment = nonBlank.allSatisfy { rows[$0].text.trimmingCharacters(in:.whitespaces).hasPrefix(marker) }
            for row in nonBlank {
                let value = rows[row].text,leading = value.prefix { $0 == " " || $0 == "\t" }
                if uncomment {
                    var rest = String(value.dropFirst(leading.count+marker.count))
                    var removed = marker.utf16.count
                    if rest.hasPrefix(" ") { rest.removeFirst(); removed += 1 }
                    rows[row].text = leading+rest; prefixes[row] = -removed
                } else {
                    rows[row].text = leading+marker+" "+value.dropFirst(leading.count)
                    prefixes[row] = marker.utf16.count+1
                }
            }
        case .blockComment(let open,let close):
            let nonBlank = selected.filter { !rows[$0].text.trimmingCharacters(in:.whitespaces).isEmpty }
            let uncomment = nonBlank.allSatisfy {
                let body = rows[$0].text.trimmingCharacters(in:.whitespaces)
                return body.count >= open.count+close.count && body.hasPrefix(open) && body.hasSuffix(close)
            }
            for row in nonBlank {
                let value = rows[row].text,leading = value.prefix { $0 == " " || $0 == "\t" }
                if uncomment {
                    let trimmed = value.trimmingCharacters(in:.whitespaces)
                    var inner = String(trimmed.dropFirst(open.count).dropLast(close.count))
                    if inner.hasPrefix(" ") { inner.removeFirst() }
                    if inner.hasSuffix(" ") { inner.removeLast() }
                    rows[row].text = leading+inner
                    prefixes[row] = -open.utf16.count-1
                } else {
                    rows[row].text = leading+open+" "+value.dropFirst(leading.count)+" "+close
                    prefixes[row] = open.utf16.count+1
                }
            }
        }
        let output = rows.map(\.text).joined(separator:"\n"),newIndex = LineIndex(output)
        let locations = Dictionary(uniqueKeysWithValues:rows.enumerated().map { ($0.element.id,$0.offset) })
        func mapped(_ offset: Int,endBoundary: Bool = false) -> Int {
            if endBoundary,offset > 0,offset <= source.length,source.substring(with:NSRange(location:offset-1,length:1)) == "\n" {
                let oldRow = index.line(at:offset-1)
                if let row = locations[oldRow] { return min(output.utf16.count,newIndex.starts[row]+rows[row].text.utf16.count+1) }
            }
            let oldRow = index.line(at:min(source.length,offset)),column = offset-index.starts[oldRow]
            guard let row = locations[oldRow] else {
                let remainingBefore = rows.filter { $0.id >= 0 && $0.id < oldRow }.count
                return newIndex.starts[min(rows.count-1,remainingBefore)]
            }
            let col = max(0,min(rows[row].text.utf16.count,column+(prefixes[oldRow] ?? 0)))
            return newIndex.starts[row]+col
        }
        let ranges = selections.map { selection -> NSRange in
            let start = mapped(selection.location),end = mapped(NSMaxRange(selection),endBoundary:selection.length > 0)
            return NSRange(location:min(start,end),length:abs(end-start))
        }
        return MultiEdit.Result(text:output,selections:MultiEdit.normalized(ranges))
    }
}
