import Foundation

/// Logical display columns; tabs advance to tab stops and graphemes stay whole.
public enum ColumnSelection {
    public static func ranges(in text: String,anchor: Int,head: Int,inclusive: Bool = false,tabWidth: Int = 4) -> [NSRange] {
        let ns = text as NSString,index = LineIndex(text),width = max(1,tabWidth)
        let a = min(max(0,anchor),ns.length),b = min(max(0,head),ns.length)
        let first = index.line(at:a),last = index.line(at:b)
        func end(_ row: Int) -> Int { row+1 < index.starts.count ? index.starts[row+1]-1 : ns.length }
        func column(_ at: Int,_ row: Int) -> Int {
            var p = index.starts[row],col = 0
            while p < min(at,end(row)) {
                let r = ns.rangeOfComposedCharacterSequence(at:p)
                col += ns.substring(with:r) == "\t" ? width-col%width : 1; p = NSMaxRange(r)
            }
            return col
        }
        let left = min(column(a,first),column(b,last)),right = max(column(a,first),column(b,last))+(inclusive ? 1 : 0)
        return (min(first,last)...min(max(first,last),min(first,last)+9999)).map { row in
            var p = index.starts[row],col = 0,start: Int?,finish: Int?
            while p < end(row) {
                let r = ns.rangeOfComposedCharacterSequence(at:p),next = col+(ns.substring(with:r) == "\t" ? width-col%width : 1)
                if start == nil && next > left { start = p }
                if col >= right { finish = p; break }
                col = next; p = NSMaxRange(r)
            }
            let lower = start ?? end(row),upper = max(lower,finish ?? end(row))
            return NSRange(location:lower,length:left == right ? 0 : upper-lower)
        }
    }
}
