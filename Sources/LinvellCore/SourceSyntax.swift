import Foundation

public enum SourceTokenKind { case keyword, string, comment, number, type, directive }
public struct SourceToken { public let range: NSRange; public let kind: SourceTokenKind }
public struct SourceFold: Equatable {
    public let line: Int,endLine: Int,range: NSRange
}
public struct SourceAnalysis {
    public init() {}
    public var tokens: [SourceToken] = []
    public var pairs: [Int:Int] = [:]
    public var folds: [SourceFold] = []
    public var ignored: [NSRange] = []
    public func fold(atLine line: Int) -> SourceFold? {
        var low = 0,high = folds.count
        while low < high { let mid = (low+high)/2; if folds[mid].line < line { low = mid+1 } else { high = mid } }
        return low < folds.count && folds[low].line == line ? folds[low] : nil
    }
    public func isCode(_ offset: Int) -> Bool {
        var low = 0,high = ignored.count
        while low < high { let mid = (low+high)/2; if NSMaxRange(ignored[mid]) <= offset { low = mid+1 } else { high = mid } }
        return low == ignored.count || !NSLocationInRange(offset,ignored[low])
    }
}

/// Lexical features remain independent of interpreters, network access and LSP.
public enum SourceSyntax {
    private static let common = Set("if else for while do switch case default break continue return throw try catch finally import export from as in is new this self super true false null nil void public private protected static final const let var async await class struct enum interface protocol extension func function def fn type typedef using namespace package module include guard defer mut impl trait match where throws rethrows yield lambda with pass raise assert del global nonlocal except elif None True False and or not print end then local repeat until begin rescue ensure elsif unless require attr_reader echo fi done esac function select declare readonly source case when of data deriving instance union signed unsigned auto volatile sizeof operator template typename virtual override synchronized abstract sealed record internal extern unsafe use pub mod crate move dyn loop macro_rules actor nonisolated isolated some any associatedtype init deinit get set willSet didSet weak unowned lazy open required convenience optional boolean string int float double char long short bool byte decimal object str list dict set tuple bytes Self SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER ON GROUP BY ORDER HAVING LIMIT INSERT INTO VALUES UPDATE DELETE CREATE TABLE ALTER DROP PRIMARY KEY FOREIGN REFERENCES DISTINCT AS AND OR NOT NULL TRUE FALSE WITH UNION ALL BEGIN END COMMIT ROLLBACK EXPLAIN fn let mut match impl trait pub use mod crate".split(separator:" ").map(String.init))
    static func hashComments(_ ext: String) -> Bool { ["py","pyw","sh","bash","zsh","fish","rb","r","pl","pm","yaml","yml","toml","conf","ini","dockerfile","makefile","cmake","ps1","jl"].contains(ext) }
    static func dashComments(_ ext: String) -> Bool { ["sql","lua","hs","vhd","vhdl"].contains(ext) }
    public static func analyze(_ text: String,path: String,cancelled: () -> Bool = { false }) -> SourceAnalysis {
        let ns = text as NSString,n = ns.length,index = LineIndex(text)
        let ext = URL(fileURLWithPath:path).pathExtension.lowercased()
        let name = URL(fileURLWithPath:path).lastPathComponent.lowercased(),language = ext.isEmpty ? name : ext
        let hash = hashComments(language),dash = dashComments(language),markup = ["html","htm","xml","svg","vue","svelte"].contains(language)
        let slash = !hash && !dash && !["json","yaml","yml","toml","md","markdown","txt"].contains(language)
        var result = SourceAnalysis(),i = 0,stack: [(UInt16,Int)] = [],nextCheck = 0
        func c(_ at: Int) -> UInt16 { at >= 0 && at < n ? ns.character(at:at) : 0 }
        func starts(_ literal: String,_ at: Int) -> Bool {
            switch literal {
            case "--": return c(at) == 45 && c(at+1) == 45
            case "//": return c(at) == 47 && c(at+1) == 47
            case "/*": return c(at) == 47 && c(at+1) == 42
            case "*/": return c(at) == 42 && c(at+1) == 47
            case "<!--": return c(at) == 60 && c(at+1) == 33 && c(at+2) == 45 && c(at+3) == 45
            case "-->": return c(at) == 45 && c(at+1) == 45 && c(at+2) == 62
            case "--[[": return c(at) == 45 && c(at+1) == 45 && c(at+2) == 91 && c(at+3) == 91
            case "]]": return c(at) == 93 && c(at+1) == 93
            default: return false
            }
        }
        func add(_ start: Int,_ end: Int,_ kind: SourceTokenKind,_ ignore: Bool = false) {
            let range = NSRange(location:start,length:end-start)
            if result.tokens.count < 500_000 { result.tokens.append(SourceToken(range:range,kind:kind)) }
            if ignore { result.ignored.append(range) }
        }
        func fold(_ open: Int,_ close: Int) {
            let first = index.line(at:open),last = index.line(at:close)
            guard last > first+1,result.folds.count < 100_000 else { return }
            let start = index.starts[first+1],end = index.starts[last]
            result.folds.append(SourceFold(line:first,endLine:last,range:NSRange(location:start,length:end-start)))
        }
        func letter(_ ch: UInt16) -> Bool { ch == 95 || ch == 36 || (65...90).contains(ch) || (97...122).contains(ch) || ch >= 128 }
        func digit(_ ch: UInt16) -> Bool { (48...57).contains(ch) }
        while i < n {
            if i >= nextCheck { nextCheck = i+4096; if cancelled() { return SourceAnalysis() } }
            let start = i,ch = c(i)
            if (hash && ch == 35) || (dash && starts("--",i) && !(language == "lua" && starts("--[[",i))) || (slash && starts("//",i)) || (language == "php" && ch == 35) {
                while i < n,c(i) != 10,c(i) != 13 { i += 1 }; add(start,i,.comment,true); continue
            }
            let blockEnd: String?
            if starts("/*",i),slash || language == "css" || language == "scss" { blockEnd = "*/" }
            else if markup,starts("<!--",i) { blockEnd = "-->" }
            else if language == "lua",starts("--[[",i) { blockEnd = "]]" }
            else { blockEnd = nil }
            if let end = blockEnd {
                i += end == "-->" ? 4 : end == "]]" ? 4 : 2
                var depth = 1
                while i < n,depth > 0 {
                    if i >= nextCheck { nextCheck = i+4096; if cancelled() { return SourceAnalysis() } }
                    if ["swift","rs"].contains(language),starts("/*",i) { depth += 1; i += 2 }
                    else if starts(end,i) { depth -= 1; i += end.utf16.count } else { i += 1 }
                }
                add(start,i,.comment,true); fold(start,max(start,i-1)); continue
            }
            if ch == 34 || ch == 39 || (ch == 96 && ["js","jsx","ts","tsx","go","sh","bash","zsh"].contains(language)) {
                // Rust lifetimes and C digit separators are not quoted strings.
                if ch == 39,language == "rs",letter(c(i+1)),c(i+2) != 39 { i += 1; continue }
                let triple = (language == "py" || language == "swift") && c(i+1) == ch && c(i+2) == ch
                let amount = triple ? 3 : 1; i += amount
                while i < n {
                    if i >= nextCheck { nextCheck = i+4096; if cancelled() { return SourceAnalysis() } }
                    if c(i) == 92 { i = min(n,i+2); continue }
                    if c(i) == ch && (!triple || (c(i+1) == ch && c(i+2) == ch)) { i += amount; break }
                    if !triple,ch != 96,c(i) == 10,!["go","sh","bash","zsh","rb"].contains(language) { break }
                    i += 1
                }
                add(start,i,.string,true); if triple || ch == 96 { fold(start,max(start,i-1)) }; continue
            }
            if digit(ch),!letter(c(i-1)) {
                i += 1; while i < n,(letter(c(i)) || digit(c(i)) || c(i) == 46) { i += 1 }; add(start,i,.number); continue
            }
            if letter(ch) {
                i += 1; while i < n,letter(c(i)) || digit(c(i)) { i += 1 }
                let word = ns.substring(with:NSRange(location:start,length:i-start))
                if common.contains(word) || (language == "sql" && common.contains(word.uppercased())) { add(start,i,.keyword) }
                else if (65...90).contains(ch) { add(start,i,.type) }
                continue
            }
            if ch == 35,!hash { i += 1; while i < n,letter(c(i)) { i += 1 }; add(start,i,.directive); continue }
            if [40,91,123].contains(ch),stack.count < 10_000 { stack.append((ch,i)) }
            else if let expected: UInt16 = ch == 41 ? 40 : ch == 93 ? 91 : ch == 125 ? 123 : nil {
                if let last = stack.last,last.0 == expected {
                    stack.removeLast()
                    if result.pairs.count < 200_000 { result.pairs[last.1] = i; result.pairs[i] = last.1 }; fold(last.1,i)
                }
            }
            i += 1
        }
        if ["py","pyw","yaml","yml"].contains(language) {
            var levels: [(Int,Int)] = []
            for row in index.starts.indices {
                let start = index.starts[row],end = row+1 < index.starts.count ? index.starts[row+1] : n
                var p = start,width = 0
                while p < end,c(p) == 32 || c(p) == 9 { width += c(p) == 9 ? 4 : 1; p += 1 }
                guard p < end,c(p) != 10,c(p) != 13,result.isCode(p) else { continue }
                while let last = levels.last,width <= last.0 {
                    levels.removeLast()
                    if row > last.1+1 { let a = index.starts[last.1+1]; result.folds.append(SourceFold(line:last.1,endLine:row-1,range:NSRange(location:a,length:start-a))) }
                }
                var last = end-1; while last >= p,[10,13,32,9].contains(c(last)) { last -= 1 }
                if c(last) == 58 { levels.append((width,row)) }
            }
            for (_,row) in levels where row+1 < index.starts.count { let a = index.starts[row+1]; if n > a { result.folds.append(SourceFold(line:row,endLine:index.starts.count-1,range:NSRange(location:a,length:n-a))) } }
        }
        if markup,let regex = try? NSRegularExpression(pattern:#"</?([A-Za-z][\w:.-]*)\b[^>]*>"#) {
            var tags: [(String,Int)] = []
            let voids: Set<String> = ["img","input","br","hr","meta","link","area","base","embed","source","track","wbr"]
            regex.enumerateMatches(in:text,range:NSRange(location:0,length:n)) { match,_,_ in
                guard let match,result.isCode(match.range.location) else { return }
                let tag = ns.substring(with:match.range),name = ns.substring(with:match.range(at:1)).lowercased()
                if tag.hasPrefix("</"),let at = tags.lastIndex(where:{ $0.0 == name }) { fold(tags[at].1,match.range.location); tags.removeSubrange(at...) }
                else if !tag.hasPrefix("</"),!tag.hasSuffix("/>"),!voids.contains(name) { tags.append((name,match.range.location)) }
                add(match.range.location,NSMaxRange(match.range),.directive)
            }
        }
        if ["rb","lua","sql","vhd","vhdl","v","sv","sh","bash","zsh"].contains(language) {
            var blocks: [Int] = []
            for row in index.starts.indices {
                let start = index.starts[row],end = row+1 < index.starts.count ? index.starts[row+1] : n
                let line = ns.substring(with:NSRange(location:start,length:end-start)).trimmingCharacters(in:.whitespacesAndNewlines)
                let word = line.split(whereSeparator:{ !$0.isLetter && $0 != "_" }).first.map(String.init)?.lowercased() ?? ""
                guard result.isCode(start+max(0,(ns.substring(with:NSRange(location:start,length:end-start)) as NSString).range(of:word,options:.caseInsensitive).location == NSNotFound ? 0 : (ns.substring(with:NSRange(location:start,length:end-start)) as NSString).range(of:word,options:.caseInsensitive).location)) else { continue }
                if ["end","fi","done","esac","until","endmodule","endfunction","endtask","endclass","endgenerate","endcase"].contains(word),let head = blocks.popLast() { fold(index.starts[head],start) }
                else if ["def","class","module","function","if","for","while","case","begin","repeat","process","architecture","entity","task","generate"].contains(word) || (language == "lua" && line.hasPrefix("local function ")) || (language == "rb" && line.hasSuffix(" do")) { blocks.append(row) }
            }
        }
        result.tokens.sort { $0.range.location < $1.range.location }
        result.folds = Array(Dictionary(result.folds.map { ($0.line,$0) },uniquingKeysWith:{ $0.range.length >= $1.range.length ? $0 : $1 }).values).sorted { $0.line < $1.line }
        return result
    }

    public static func newline(in text: String,at offset: Int,path: String,unit: String) -> (String,Int) {
        let ns = text as NSString,at = min(ns.length,max(0,offset)),row = ns.lineRange(for:NSRange(location:at,length:0))
        let before = ns.substring(with:NSRange(location:row.location,length:at-row.location))
        let indent = String(before.prefix { $0 == " " || $0 == "\t" }),trimmed = before.trimmingCharacters(in:.whitespaces)
        let ext = URL(fileURLWithPath:path).pathExtension.lowercased()
        let opens = trimmed.last.map { "{[(".contains($0) } ?? false
        let block = ["py","pyw","yaml","yml"].contains(ext) && trimmed.hasSuffix(":")
        let word = trimmed.split(separator:" ").first.map(String.init) ?? ""
        let keyword = ["rb","lua","sh","bash","zsh"].contains(ext) && ["def","class","module","function","if","for","while","case","begin"].contains(word)
        let markup = ["html","htm","xml","svg","vue","svelte"].contains(ext) && trimmed.hasSuffix(">") && !trimmed.hasSuffix("/>") && trimmed.range(of:#"<(?!(?:/|!|br\b|hr\b|img\b|input\b|meta\b|link\b))[^>]+>$"#,options:[.regularExpression,.caseInsensitive]) != nil
        let code = before.utf16.count <= 16_384 && SourceSyntax.analyze(before,path:path).isCode(max(0,before.utf16.count-1))
        let extra = code && (opens || block || keyword || markup)
        let next = at < ns.length ? ns.character(at:at) : 0
        if code,(opens && [41,93,125].contains(next)) || (markup && at+1 < ns.length && ns.substring(with:NSRange(location:at,length:2)) == "</") {
            let value = "\n"+indent+unit+"\n"+indent
            return (value,1+indent.utf16.count+unit.utf16.count)
        }
        let value = "\n"+indent+(extra ? unit : "")
        return (value,value.utf16.count)
    }
}
