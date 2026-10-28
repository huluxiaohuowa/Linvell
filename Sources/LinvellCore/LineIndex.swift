import Foundation

/// UTF-16 line starts; scrolling and cursor movement use binary search rather than rescanning prefixes.
public final class LineIndex {
    public private(set) var starts: [Int] = [0]
    public init(_ text: String) { starts += text.utf16.enumerated().compactMap { $0.element == 10 ? $0.offset+1 : nil } }
    public func line(at offset: Int) -> Int {
        var lower = 0,upper = starts.count
        while lower < upper { let middle = (lower+upper)/2; if starts[middle] <= offset { lower = middle+1 } else { upper = middle } }
        return max(0,lower-1)
    }
    public func apply(range: NSRange,replacement: String) {
        let end = NSMaxRange(range),delta = replacement.utf16.count-range.length
        let first = line(at:range.location)+1,last = line(at:end)+1
        let inserted = replacement.utf16.enumerated().compactMap { $0.element == 10 ? range.location+$0.offset+1 : nil }
        starts.replaceSubrange(first..<last,with:inserted)
        let suffix = first+inserted.count
        if delta != 0,suffix < starts.count { for i in suffix..<starts.count { starts[i] += delta } }
    }
}
