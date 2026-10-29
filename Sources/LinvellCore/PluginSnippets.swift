import Foundation

public struct PluginSnippetExpansion {
    public let text: String
    public let stops: [NSRange]
    /// Unique $1 / ${1:default} tab stops, $0 final cursor. Escaped dollars stay literal.
    public init(_ body: String) throws {
        guard body.utf8.count <= 64*1024 else { throw PluginError.invalidPackage }
        let chars = Array(body); var at = 0,result = "",fields: [Int:NSRange] = [:]
        while at < chars.count {
            let ch = chars[at]; at += 1
            if ch == "\\",at < chars.count,["$","\\","}"].contains(chars[at]) { result.append(chars[at]); at += 1; continue }
            guard ch == "$",at < chars.count else { result.append(ch); continue }
            let braced = chars[at] == "{",start = braced ? at+1 : at
            guard start < chars.count,chars[start].isASCII,chars[start].isNumber else { result.append(ch); continue }
            at = start; var digits = ""
            while at < chars.count,chars[at].isASCII,chars[at].isNumber { digits.append(chars[at]); at += 1 }
            guard let index = Int(digits),index <= 99,fields[index] == nil,fields.count < 32 else { throw PluginError.invalidPackage }
            var value = ""
            if braced {
                guard at < chars.count else { throw PluginError.invalidPackage }
                if chars[at] == ":" {
                    at += 1
                    while at < chars.count,chars[at] != "}" {
                        guard chars[at] != "{" else { throw PluginError.invalidPackage }
                        if chars[at] == "\\",at+1 < chars.count,["$","\\","}"].contains(chars[at+1]) { at += 1 }
                        value.append(chars[at]); at += 1
                    }
                }
                guard at < chars.count,chars[at] == "}" else { throw PluginError.invalidPackage }; at += 1
            }
            fields[index] = NSRange(location:result.utf16.count,length:value.utf16.count); result += value
        }
        if fields[0] == nil { guard fields.count < 32 else { throw PluginError.invalidPackage }; fields[0] = NSRange(location:result.utf16.count,length:0) }
        text = result; stops = fields.keys.filter { $0 != 0 }.sorted().map { fields[$0]! }+[fields[0]!]
    }
}

public struct PluginSnippetCursor {
    public private(set) var stops: [NSRange]
    public private(set) var index = 0
    public var current: NSRange { stops[index] }
    public init(stops: [NSRange],offset: Int) { self.stops = stops.map { NSRange(location:$0.location+offset,length:$0.length) } }
    public mutating func advance(backwards: Bool = false) -> NSRange? {
        let next = index+(backwards ? -1 : 1)
        guard stops.indices.contains(next) else { return nil }; index = next; return current
    }
    public var isFinal: Bool { index == stops.count-1 }
    public mutating func edit(_ range: NSRange,replacementLength: Int) -> Bool {
        guard range.location >= current.location,NSMaxRange(range) <= NSMaxRange(current) else { return false }
        let delta = replacementLength-range.length,old = current
        for i in stops.indices {
            if i == index { stops[i].length += delta }
            else if stops[i].location >= NSMaxRange(old) { stops[i].location += delta }
        }
        return true
    }
}
