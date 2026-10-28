import Foundation

extension VimEngine {
    func next(_ p: Int) -> Int {
        guard p < text.utf16.count else { return p }
        return NSMaxRange((text as NSString).rangeOfComposedCharacterSequence(at:p))
    }
    func previous(_ p: Int) -> Int { p > 0 ? (text as NSString).rangeOfComposedCharacterSequence(at:p-1).location : 0 }
    func lineStart(_ p: Int) -> Int {
        let ns = text as NSString,at = min(max(0,p),ns.length)
        guard at > 0 else { return 0 }
        let found = ns.range(of:"\n",options:.backwards,range:NSRange(location:0,length:at))
        return found.location == NSNotFound ? 0 : NSMaxRange(found)
    }
    func lineEnd(_ p: Int) -> Int {
        let ns = text as NSString,at = min(max(0,p),ns.length)
        let found = ns.range(of:"\n",range:NSRange(location:at,length:ns.length-at))
        return found.location == NSNotFound ? ns.length : found.location
    }
    func firstNonblank(_ p: Int) -> Int {
        var at = lineStart(p)
        while at < lineEnd(p),character(at) == " " || character(at) == "\t" { at = next(at) }
        return at
    }
    func clamp() {
        cursor = min(max(cursor,0),text.utf16.count)
        let start = lineStart(cursor),end = lineEnd(cursor)
        if cursor >= end,end > start { cursor = previous(end) }
        if cursor < text.utf16.count { cursor = (text as NSString).rangeOfComposedCharacterSequence(at:cursor).location }
    }
    func character(_ p: Int) -> String {
        guard p >= 0,p < text.utf16.count else { return "" }
        let ns = text as NSString
        return ns.substring(with:ns.rangeOfComposedCharacterSequence(at:p))
    }
    func category(_ p: Int,big: Bool = false) -> Int {
        let c = character(p)
        if c.isEmpty || c.allSatisfy(\.isWhitespace) { return 0 }
        return big || c.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || CharacterSet.nonBaseCharacters.contains($0) } ? 1 : 2
    }
    func move(_ p: Int,steps: Int,withinLine: Bool) -> Int {
        var at = p
        for _ in 0..<abs(steps) {
            if steps > 0 { if !withinLine || at < lineEnd(p) { at = next(at) } }
            else if !withinLine || at > lineStart(p) { at = previous(at) }
        }
        return at
    }
    func wordForward(_ p: Int,big: Bool) -> Int {
        var at = p; let kind = category(at,big:big)
        while at < text.utf16.count,category(at,big:big) == kind { at = next(at) }
        while at < text.utf16.count,category(at,big:big) == 0 { at = next(at) }
        return at
    }
    func wordBackward(_ p: Int,big: Bool) -> Int {
        var at = previous(p)
        while at > 0,category(at,big:big) == 0 { at = previous(at) }
        let kind = category(at,big:big)
        while at > 0,category(previous(at),big:big) == kind { at = previous(at) }
        return at
    }
    func wordEnd(_ p: Int,big: Bool,advance: Bool = true) -> Int {
        var at = advance ? next(p) : p
        while at < text.utf16.count,category(at,big:big) == 0 { at = next(at) }
        let kind = category(at,big:big)
        while next(at) < text.utf16.count,category(next(at),big:big) == kind { at = next(at) }
        return at
    }
    func vertical(_ p: Int,delta: Int) -> Int {
        let start = lineStart(p)
        let col = desiredColumn ?? (text as NSString).substring(with:NSRange(location:start,length:p-start)).count
        desiredColumn = col
        var row = start
        for _ in 0..<abs(delta) {
            if delta > 0 { let end = lineEnd(row); if end < text.utf16.count { row = end+1 } }
            else if row > 0 { row = lineStart(row-1) }
        }
        var at = row
        for _ in 0..<col { if at < lineEnd(row) { at = next(at) } }
        return at
    }
    func lineRange(_ p: Int,lines: Int) -> NSRange {
        let start = lineStart(p); var end = start
        for _ in 0..<lines { end = lineEnd(end); if end < text.utf16.count { end += 1 } }
        return NSRange(location:start,length:end-start)
    }
    func lineRangeCovering(_ range: NSRange) -> NSRange {
        let start = lineStart(range.location),end = lineEnd(range.length > 0 ? previous(NSMaxRange(range)) : range.location)
        return NSRange(location:start,length:end-start+(end < text.utf16.count ? 1 : 0))
    }
    func executeMotion(_ key: String,times: Int,explicit: Bool) {
        var at = cursor,inclusive = false,linewise = false
        if key != "j" && key != "k" { desiredColumn = nil }
        switch key {
        case "g","f","F","t","T","'","`": awaiting = key; pending += key; return
        case "h": at = move(at,steps:-times,withinLine:true)
        case "l"," ": at = move(at,steps:times,withinLine:true)
        case "j","k": at = vertical(at,delta:key == "j" ? times : -times); linewise = true
        case "w","W":
            if operation == "c",category(at) != 0 {
                for index in 0..<times { at = wordEnd(at,big:key == "W",advance:index > 0) }; inclusive = true
            } else {
                for _ in 0..<times { at = wordForward(at,big:key == "W") }
                if operation != nil,category(cursor) != 0 {
                    var scan = at,newline: Int?
                    while scan > cursor,category(previous(scan)) == 0 {
                        scan = previous(scan)
                        if character(scan) == "\n" { newline = scan }
                    }
                    if let newline {
                        at = newline
                        linewise = lineStart(newline) > lineStart(cursor) && cursor == firstNonblank(cursor)
                    }
                }
            }
        case "b","B": for _ in 0..<times { at = wordBackward(at,big:key == "B") }
        case "e","E": for _ in 0..<times { at = wordEnd(at,big:key == "E") }; inclusive = true
        case "0": at = lineStart(at)
        case "^": at = firstNonblank(at)
        case "$": at = lineEnd(vertical(at,delta:times-1)); inclusive = false
        case "G","gg":
            if key == "gg" || explicit {
                at = 0
                if explicit { for _ in 1..<times { let end = lineEnd(at); if end < text.utf16.count { at = end+1 } } }
            } else { at = lineStart(text.utf16.count); if at == text.utf16.count,at > 0 { at = lineStart(at-1) } }
            at = firstNonblank(at); linewise = true
        case "%":
            guard let target = matchingPair(at) else { finish(); return }; at = target; inclusive = true
        case ";",",":
            guard let last = lastFind else { finish(); return }
            let reverse: [String:String] = ["f":"F","F":"f","t":"T","T":"t"]
            let kind = key == "," ? reverse[last.0]! : last.0
            guard let target = find(last.1,kind:kind,times:times,repeatFind:true) else { finish(); return }
            at = target; inclusive = kind == "f" || kind == "t"
        case "}","{":
            for _ in 0..<times {
                if key == "}" {
                    if at < text.utf16.count { at = min(text.utf16.count,lineEnd(at)+1) }
                    while at < text.utf16.count,lineEnd(at) != lineStart(at) { at = min(text.utf16.count,lineEnd(at)+1) }
                } else {
                    if at > 0 { at = lineStart(lineStart(at) > 0 ? lineStart(at)-1 : 0) }
                    while at > 0,lineEnd(at) != lineStart(at) { at = lineStart(at-1) }
                }
            }
        default: finish(); return
        }
        executeDestination(at,inclusive:inclusive,linewise:linewise)
    }
    func executeDestination(_ at: Int,inclusive: Bool,linewise: Bool) {
        if operation != nil {
            let lower = min(cursor,at),upper = max(cursor,at)
            let end = inclusive && upper < text.utf16.count ? next(upper) : upper
            let range = NSRange(location:lower,length:end-lower)
            let whole = NSRange(location:lineStart(lower),length:lineEnd(upper)-lineStart(lower)+(lineEnd(upper) < text.utf16.count ? 1 : 0))
            applyOperator(linewise ? whole : range,linewise:linewise)
        } else { cursor = at; clamp(); finish() }
    }
    func find(_ value: String,kind: String,times: Int,repeatFind: Bool = false) -> Int? {
        guard value.count == 1 else { return nil }
        let forward = kind == "f" || kind == "t",till = kind == "t" || kind == "T"
        var at = cursor
        if repeatFind && till { at = forward ? next(at) : previous(at) }
        for _ in 0..<times {
            var found = false
            while forward ? at < lineEnd(cursor) : at > lineStart(cursor) {
                at = forward ? next(at) : previous(at)
                if character(at) == value { found = true; break }
            }
            if !found { return nil }
        }
        return till ? (forward ? previous(at) : next(at)) : at
    }
    func matchingPair(_ p: Int) -> Int? {
        let pairs = ["(":")","[":"]","{":"}"],reverse = [")":"(","]":"[","}":"{"]
        var at = p
        while at < lineEnd(p),pairs[character(at)] == nil && reverse[character(at)] == nil { at = next(at) }
        let start = character(at),forward = pairs[start] != nil
        guard let end = pairs[start] ?? reverse[start] else { return nil }
        var depth = 1
        while forward ? at < text.utf16.count : at > 0 {
            at = forward ? next(at) : previous(at)
            let c = character(at)
            if c == start { depth += 1 }; if c == end { depth -= 1 }
            if depth == 0 { return at }
        }
        return nil
    }
    public func textObjectRange(_ key: String,around: Bool,count: Int = 1) -> NSRange? { textObject(key,around:around,times:max(1,min(9999,count))) }
    func textObject(_ key: String,around: Bool,times: Int) -> NSRange? {
        if key == "w" || key == "W" {
            let big = key == "W",kind = category(cursor,big:big)
            var start = cursor,end = cursor
            while start > 0,category(previous(start),big:big) == kind { start = previous(start) }
            while end < text.utf16.count,category(end,big:big) == kind { end = next(end) }
            if times > 1 { for _ in 1..<times { end = next(wordEnd(end,big:big,advance:false)) } }
            if around {
                let tail = end
                while end < lineEnd(cursor),category(end,big:big) == 0 { end = next(end) }
                if end == tail { while start > lineStart(cursor),category(previous(start),big:big) == 0 { start = previous(start) } }
            }
            return NSRange(location:start,length:end-start)
        }
        let opens = ["(":"(",")":"(","b":"(","[":"[","]":"[","{":"{","}":"{","B":"{","<":"<",">":"<"]
        let closes = ["(":")","[":"]","{":"}","<":">"]
        if let open = opens[key],let close = closes[open] {
            var starts: [Int] = [],pairs: [(Int,Int)] = [],at = 0
            while at < text.utf16.count {
                let c = character(at)
                if c == open { starts.append(at) }
                else if c == close,let start = starts.popLast(),start <= cursor,at >= cursor { pairs.append((start,at)) }
                at = next(at)
            }
            guard pairs.count >= times else { return nil }
            let pair = pairs[times-1],lower = around ? pair.0 : next(pair.0),upper = around ? next(pair.1) : pair.1
            return NSRange(location:lower,length:upper-lower)
        }
        if ["\"","'","`"].contains(key) {
            var quotes: [Int] = [],at = lineStart(cursor),escaped = false
            while at < lineEnd(cursor) {
                let c = character(at)
                if c == key && !escaped { quotes.append(at) }
                escaped = c == "\\" && !escaped; at = next(at)
            }
            for i in stride(from:0,to:max(0,quotes.count-1),by:2) {
                if cursor <= quotes[i+1] {
                    var lower = around ? quotes[i] : next(quotes[i]),upper = around ? next(quotes[i+1]) : quotes[i+1]
                    if around {
                        let tail = upper
                        while upper < lineEnd(cursor),[" ","\t"].contains(character(upper)) { upper = next(upper) }
                        if tail == upper { while lower > lineStart(cursor),[" ","\t"].contains(character(previous(lower))) { lower = previous(lower) } }
                    }
                    return NSRange(location:lower,length:upper-lower)
                }
            }
        }
        return nil
    }
}
