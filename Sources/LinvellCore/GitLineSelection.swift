import Foundation

extension GitHunk {
    /// Builds a patch against the current index. Unselected edits become context or disappear.
    /// The source range uses UTF-16 offsets, matching NSTextView and the split diff source map.
    public static func selection(in patch: String,range: NSRange,unstage: Bool) throws -> GitHunk {
        let source = patch as NSString
        guard range.location != NSNotFound,NSMaxRange(range) <= source.length else { throw GitError.invalidPath }
        var lines: [(String,NSRange)] = []
        source.enumerateSubstrings(in:NSRange(location:0,length:source.length),options:.byLines) { value,_,enclosing,_ in
            lines.append((value ?? "",enclosing))
        }
        guard !patch.contains("\ndiff --git "),let first = lines.firstIndex(where:{ $0.0.hasPrefix("@@ ") }) else {
            throw GitError.command("Select changed lines in one file's diff.")
        }
        let pattern = try NSRegularExpression(pattern:#"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#)
        var header = lines[..<first].map(\.0).filter { !$0.hasPrefix("index ") }
        if unstage {
            header = header.map { line in
                if line.hasPrefix("new file mode ") { return line.replacingOccurrences(of:"new file mode ",with:"deleted file mode ") }
                if line.hasPrefix("deleted file mode ") { return line.replacingOccurrences(of:"deleted file mode ",with:"new file mode ") }
                if line.hasPrefix("--- ") { return "+++ "+line.dropFirst(4) }
                if line.hasPrefix("+++ ") { return "--- "+line.dropFirst(4) }
                return line
            }
            if let a = header.firstIndex(where:{ $0.hasPrefix("+++ ") }),let b = header.firstIndex(where:{ $0.hasPrefix("--- ") }) { header.swapAt(a,b) }
        }
        var output: [String] = [],offset = 0,index = first,totalOld = 0,totalNew = 0
        while index < lines.count {
            let raw = lines[index].0 as NSString
            guard let match = pattern.firstMatch(in:raw as String,range:NSRange(location:0,length:raw.length)) else { index += 1; continue }
            func number(_ group: Int,_ fallback: Int) -> Int { match.range(at:group).location == NSNotFound ? fallback : Int(raw.substring(with:match.range(at:group))) ?? fallback }
            let start = number(unstage ? 3 : 1,0),count = number(unstage ? 4 : 2,1)
            let baseStart = start+(count == 0 ? 1 : 0)
            index += 1
            var body: [String] = [],oldCount = 0,newCount = 0,changed = false,lastEmitted = false
            while index < lines.count,!lines[index].0.hasPrefix("@@ ") {
                let (line,lineRange) = lines[index]; index += 1
                if line.hasPrefix("\\") { if lastEmitted { body.append(line) }; continue }
                guard let prefix = line.first,[" ","+","-"].contains(prefix) else { continue }
                let kind: Character = unstage ? (prefix == "+" ? "-" : prefix == "-" ? "+" : " ") : prefix
                let selected = range.length == 0 ? NSLocationInRange(range.location,lineRange) : NSIntersectionRange(range,lineRange).length > 0
                lastEmitted = false
                if kind == " " || (kind == "-" && !selected) {
                    body.append(" "+line.dropFirst()); lastEmitted = true; oldCount += 1; newCount += 1
                } else if selected {
                    body.append(String(kind)+line.dropFirst()); lastEmitted = true; changed = true
                    if kind == "-" { oldCount += 1 } else { newCount += 1 }
                }
            }
            if changed {
                let newStart = baseStart+offset
                output.append("@@ -\(oldCount == 0 ? baseStart-1 : baseStart),\(oldCount) +\(newCount == 0 ? newStart-1 : newStart),\(newCount) @@")
                output += body
                offset += newCount-oldCount
                totalOld += oldCount; totalNew += newCount
            }
        }
        guard !output.isEmpty else { throw GitError.command("Select added or removed lines first.") }
        if totalOld > 0,let index = header.firstIndex(of:"--- /dev/null"),let other = header.first(where:{ $0.hasPrefix("+++ ") }) {
            header[index] = "--- "+other.dropFirst(4)
        }
        if totalNew > 0,let index = header.firstIndex(of:"+++ /dev/null"),let other = header.first(where:{ $0.hasPrefix("--- ") }) {
            header[index] = "+++ "+other.dropFirst(4)
        }
        if !header.contains("--- /dev/null") { header.removeAll { $0.hasPrefix("new file mode ") } }
        if !header.contains("+++ /dev/null") { header.removeAll { $0.hasPrefix("deleted file mode ") } }
        return GitHunk(header:output[0],patch:(header+output).joined(separator:"\n")+"\n")
    }
}
