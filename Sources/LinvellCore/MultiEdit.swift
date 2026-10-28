import Foundation

public enum MultiEdit {
    public struct Result { public let text: String; public let selections: [NSRange] }
    public static func normalized(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location }) {
            if let last = result.last,range == last || range.location < NSMaxRange(last) {
                result[result.count-1] = NSUnionRange(last,range)
            } else { result.append(range) }
        }
        return result
    }
    public static func apply(_ ranges: [NSRange],replacement: String,to text: String) throws -> Result {
        let ranges = normalized(ranges)
        return try apply(ranges,replacements:Array(repeating:replacement,count:ranges.count),to:text)
    }
    public static func apply(_ ranges: [NSRange],replacements: [String],to text: String) throws -> Result {
        guard ranges == normalized(ranges),ranges.count == replacements.count else { throw DocumentError.invalidRange }
        guard ranges.allSatisfy({ range in
            guard let r = Range(range,in:text) else { return false }
            return r.lowerBound.samePosition(in:text.unicodeScalars) != nil && r.upperBound.samePosition(in:text.unicodeScalars) != nil
        }) else { throw DocumentError.invalidRange }
        let result = NSMutableString(string:text)
        for (range,replacement) in zip(ranges,replacements).reversed() { result.replaceCharacters(in:range,with:replacement) }
        var delta = 0
        let selections = zip(ranges,replacements).map { range,replacement -> NSRange in
            let cursor = range.location+delta+replacement.utf16.count
            delta += replacement.utf16.count-range.length; return NSRange(location:cursor,length:0)
        }
        return Result(text:result as String,selections:selections)
    }
}
