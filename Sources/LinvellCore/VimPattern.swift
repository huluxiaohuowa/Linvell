import Foundation

public enum VimCommandError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let detail): return detail } }
}

/// Translates Vim's magic switches and common atoms explicitly. Unsupported atoms
/// fail rather than silently running with Foundation's different regex semantics.
struct VimPattern {
    let expression: NSRegularExpression
    init(_ pattern: String,ignoreCase: Bool = false) throws {
        var magic = 1,insensitive = ignoreCase,output = "",i = pattern.startIndex
        let normalSpecial = Set(".^$[*"),verySpecial = Set(".^$*+?()[]{}|")
        func literal(_ c: Character) -> String { NSRegularExpression.escapedPattern(for:String(c)) }
        while i < pattern.endIndex {
            let c = pattern[i]; i = pattern.index(after:i)
            if c == "\\" {
                guard i < pattern.endIndex else { throw VimCommandError.invalid("Trailing backslash in Vim pattern.") }
                let atom = pattern[i]; i = pattern.index(after:i)
                switch atom {
                case "v": magic = 2
                case "m": magic = 1
                case "M": magic = 0
                case "V": magic = -1
                case "c": insensitive = true
                case "C": insensitive = false
                case "<": output += #"(?<![\p{L}\p{N}_])(?=[\p{L}\p{N}_])"#
                case ">": output += #"(?<=[\p{L}\p{N}_])(?![\p{L}\p{N}_])"#
                case "n": output += "\\n"
                case "t": output += "\\t"
                case "r": output += "\\r"
                case "d","D","s","S","w","W","b","B": output += "\\"+String(atom)
                case "1"..."9": output += "\\"+String(atom)
                case "(",")","+","?","|","{","}": output += magic == 2 ? literal(atom) : String(atom)
                case "=": output += "?"
                case "z","@","_","%": throw VimCommandError.invalid("This Vim pattern atom is not supported yet: \\"+String(atom))
                default: output += literal(atom)
                }
            } else if c == "[",magic >= 1 {
                output += "["
                var closed = false
                while i < pattern.endIndex {
                    let item = pattern[i]; i = pattern.index(after:i); output.append(item)
                    if item == "\\",i < pattern.endIndex { output.append(pattern[i]); i = pattern.index(after:i) }
                    else if item == "]" { closed = true; break }
                }
                if !closed { throw VimCommandError.invalid("Unclosed character class in Vim pattern.") }
            } else {
                let special = magic == 2 ? verySpecial.contains(c) : magic == 1 ? normalSpecial.contains(c) : magic == 0 ? c == "^" || c == "$" : false
                output += special ? String(c) : literal(c)
            }
        }
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if insensitive { options.insert(.caseInsensitive) }
        expression = try NSRegularExpression(pattern:output,options:options)
    }
}

extension VimEngine {
    @discardableResult public func search(_ pattern: String,backwards: Bool = false,times: Int = 1) throws -> Bool {
        changed = false
        let value = pattern.isEmpty ? (searchPattern ?? "") : pattern
        guard !value.isEmpty else { throw VimCommandError.invalid("No previous search pattern.") }
        let regex = try VimPattern(value).expression
        let matches = regex.matches(in:text,range:NSRange(location:0,length:text.utf16.count))
        guard !matches.isEmpty else { finish(); return false }
        searchPattern = value; searchBackwards = backwards
        var at = cursor
        for _ in 0..<min(9999,max(1,times)) {
            if backwards { at = matches.last(where:{ $0.range.location < at })?.range.location ?? matches.last!.range.location }
            else { at = matches.first(where:{ $0.range.location > at })?.range.location ?? matches.first!.range.location }
        }
        executeDestination(at,inclusive:false,linewise:false); return true
    }
    func searchWord(backwards: Bool) {
        guard let range = textObject("w",around:false,times:1),range.length > 0 else { finish(); return }
        let word = (text as NSString).substring(with:range)
        let escaped = word.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"/",with:"\\/")
        let pattern = "\\<\\V"+escaped+"\\m\\>"
        _ = try? search(pattern,backwards:backwards,times:effectiveCount)
    }
    /// Executes text-only Ex commands. File writes and window commands stay in the host.
    public func executeEx(_ raw: String) throws {
        changed = false
        var input = raw.trimmingCharacters(in:.whitespaces)
        if input.hasPrefix(":") { input.removeFirst() }
        var range = lineRange(cursor,lines:1)
        let address = try NSRegularExpression(pattern:#"^(%|(?:\d+|\.|\$)(?:,(?:\d+|\.|\$))?)"#)
        if let match = address.firstMatch(in:input,range:NSRange(location:0,length:input.utf16.count)) {
            let token = (input as NSString).substring(with:match.range)
            input = (input as NSString).substring(from:NSMaxRange(match.range))
            let starts = LineIndex(text).starts
            func row(_ value: Substring) -> Int {
                if value == "." { return LineIndex(text).line(at:cursor) }
                if value == "$" { return max(0,starts.count-(text.hasSuffix("\n") ? 2 : 1)) }
                return max(0,min(starts.count-1,(Int(value) ?? 1)-1))
            }
            if token == "%" { range = NSRange(location:0,length:text.utf16.count) }
            else {
                let parts = token.split(separator:","),a = row(parts[0]),b = parts.count == 2 ? row(parts[1]) : a
                guard b >= a else { throw VimCommandError.invalid("Backwards Ex range.") }
                let end = b+1 < starts.count ? starts[b+1] : text.utf16.count
                range = NSRange(location:starts[a],length:end-starts[a])
            }
        }
        if input.isEmpty { cursor = firstNonblank(range.location); clamp(); finish(); return }
        if let number = Int(input),number > 0 {
            cursor = 0
            for _ in 1..<min(9999,number) { let end = lineEnd(cursor); if end < text.utf16.count { cursor = end+1 } }
            cursor = firstNonblank(cursor); clamp(); finish(); return
        }
        if input.hasPrefix("s"),input.count > 1 {
            try substitute(input,range:range); finish(); return
        }
        if ["d","delete","y","yank",">","<"].contains(input) {
            operation = input == "delete" ? "d" : input == "yank" ? "y" : input
            applyOperator(range,linewise:true); return
        }
        throw VimCommandError.invalid("This Ex command is not implemented yet.")
    }
    private func substitute(_ input: String,range: NSRange) throws {
        let chars = Array(input),delimiter = chars[1]
        guard !delimiter.isLetter,!delimiter.isNumber,delimiter != "\\",!delimiter.isWhitespace else { throw VimCommandError.invalid("Invalid substitute delimiter.") }
        var at = 2
        func part() -> String {
            var output = ""
            while at < chars.count {
                let c = chars[at]; at += 1
                if c == delimiter { return output }
                if c == "\\",at < chars.count {
                    let next = chars[at]; at += 1
                    if next == delimiter { output.append(next) }
                    else { output.append(c); output.append(next) }
                } else { output.append(c) }
            }
            return output
        }
        let pattern = part(),replacement = part(),flags = String(chars[at...])
        guard flags.allSatisfy({ "giIe".contains($0) }) else { throw VimCommandError.invalid("Unsupported substitute flag. Confirmation is not applied silently.") }
        let actual = pattern.isEmpty ? searchPattern ?? "" : pattern
        guard !actual.isEmpty else { throw VimCommandError.invalid("No previous search pattern.") }
        let regex = try VimPattern(actual,ignoreCase:flags.contains("i") && !flags.contains("I")).expression
        let ns = text as NSString,subject = ns.substring(with:range),subjectNS = subject as NSString
        let matches = regex.matches(in:subject,range:NSRange(location:0,length:subjectNS.length))
        var accepted: [NSTextCheckingResult] = [],lastRow = -1
        let index = LineIndex(subject)
        for match in matches {
            let row = index.line(at:match.range.location)
            if flags.contains("g") || row != lastRow { accepted.append(match); lastRow = row }
        }
        guard !accepted.isEmpty else {
            if !flags.contains("e") { throw VimCommandError.invalid("Pattern not found.") }; return
        }
        var output = subject
        for match in accepted.reversed() {
            let parts = Array(replacement); var rendered = "",i = 0
            while i < parts.count {
                let c = parts[i]; i += 1
                if c == "&" { rendered += subjectNS.substring(with:match.range) }
                else if c == "\\",i < parts.count {
                    let atom = parts[i]; i += 1
                    if let group = Int(String(atom)),group < match.numberOfRanges,match.range(at:group).location != NSNotFound { rendered += subjectNS.substring(with:match.range(at:group)) }
                    else if atom == "r" { rendered += "\n" }
                    else if atom == "t" { rendered += "\t" }
                    else { rendered.append(atom) }
                } else { rendered.append(c) }
            }
            output = (output as NSString).replacingCharacters(in:match.range,with:rendered)
        }
        edit(range,output); cursor = range.location+accepted[0].range.location; clamp()
        searchPattern = actual
    }
}
