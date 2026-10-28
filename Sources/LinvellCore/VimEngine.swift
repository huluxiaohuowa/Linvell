import Foundation

/// Initial native command engine. This deliberately does not claim full Vim compatibility.
public final class VimEngine {
    public enum Mode: String { case normal = "NORMAL", insert = "INSERT",visual = "VISUAL",visualLine = "VISUAL LINE",visualBlock = "VISUAL BLOCK" }
    public private(set) var mode: Mode = .normal
    public private(set) var pending = ""
    public private(set) var register = ""
    public var cursor = 0
    public var text = ""
    public private(set) var changed = false
    private var count = ""
    private var history: [(String, Int)] = []
    private var future: [(String, Int)] = []

    public init() {}
    public func cancelPendingCommand() { pending = ""; count = "" }
    public func beginVisual(_ mode: Mode) { self.mode = mode; cancelPendingCommand() }
    public func enterInsert() { mode = .insert; cancelPendingCommand() }
    public func yank(_ value: String) { register = value }
    public func escape() { mode = .normal; pending = ""; count = ""; clamp() }
    public func sync(text: String, cursor: Int) { self.text = text; self.cursor = min(max(0, cursor), text.utf16.count) }
    public func key(_ key: String) {
        changed = false
        if key == "Escape" { escape(); return }
        guard mode == .normal else { return }
        if key.count == 1, key.first!.isNumber, key != "0" || !count.isEmpty {
            if count.count < 4 { count += key }; return
        }
        let repetitions = min(Int(count) ?? 1, 9999)
        if pending == "g" {
            pending = ""; count = ""
            if key == "g" { cursor = 0 }; return
        }
        if pending == "d" || pending == "y" {
            let op = pending; pending = ""; count = ""
            if key == op {
                let start = lineStart(cursor)
                var end = start
                for _ in 0..<repetitions { end = lineEnd(end); if end < text.utf16.count { end += 1 } }
                let r = NSRange(location: start, length: end - start)
                register = (text as NSString).substring(with: r)
                if op == "d" { edit(r, ""); cursor = min(start, text.utf16.count); clamp() }
            } else if key == "w" || key == "$" {
                let start = cursor
                if key == "$" { cursor = lineEnd(cursor) } else { for _ in 0..<repetitions { wordForward() } }
                let r = NSRange(location: start, length: max(0, cursor - start))
                register = (text as NSString).substring(with: r)
                if op == "d" { edit(r, ""); cursor = start; clamp() }
            }
            return
        }
        count = ""
        switch key {
        case "i": mode = .insert
        case "a": cursor = next(cursor); mode = .insert
        case "I": cursor = lineStart(cursor); mode = .insert
        case "A": cursor = lineEnd(cursor); mode = .insert
        case "h": for _ in 0..<repetitions { cursor = max(lineStart(cursor), previous(cursor)) }
        case "l": for _ in 0..<repetitions { cursor = min(lineEnd(cursor), next(cursor)) }; clamp()
        case "j", "k": for _ in 0..<repetitions { vertical(key == "j" ? 1 : -1) }
        case "w": for _ in 0..<repetitions { wordForward() }; clamp()
        case "b": for _ in 0..<repetitions { wordBackward() }
        case "0": cursor = lineStart(cursor)
        case "$": cursor = lineEnd(cursor); clamp()
        case "G": cursor = lineStart(text.utf16.count)
        case "g", "d", "y": pending = key; count = repetitions == 1 ? "" : String(repetitions)
        case "x":
            let start = cursor; var end = cursor
            for _ in 0..<repetitions { if end < lineEnd(cursor) { end = next(end) } }
            if end > start { register = (text as NSString).substring(with: NSRange(location: start, length: end-start)); edit(NSRange(location: start, length: end-start), ""); clamp() }
        case "p":
            guard !register.isEmpty else { return }
            let at = register.hasSuffix("\n") ? min(text.utf16.count, lineEnd(cursor)+1) : next(cursor)
            edit(NSRange(location: at, length: 0), String(repeating: register, count: repetitions)); cursor = at; clamp()
        case "o", "O":
            let at = key == "o" ? lineEnd(cursor) : lineStart(cursor)
            edit(NSRange(location: at, length: 0), "\n"); cursor = key == "o" ? at + 1 : at; mode = .insert
        case "u":
            if let item = history.popLast() { future.append((text, cursor)); text = item.0; cursor = item.1; changed = true }
        case "Ctrl+r":
            if let item = future.popLast() { history.append((text,cursor)); text = item.0; cursor = item.1; changed = true }
        default: pending = ""
        }
    }

    public func recordInsertion(before: String, cursor: Int) {
        if history.last?.0 != before { history.append((before, cursor)); future.removeAll() }
    }
    private func edit(_ range: NSRange, _ replacement: String) {
        guard Range(range, in: text) != nil else { return }
        history.append((text,cursor)); future.removeAll()
        text = (text as NSString).replacingCharacters(in: range, with: replacement); changed = true
    }
    private func next(_ p: Int) -> Int {
        guard p < text.utf16.count else { return p }
        return NSMaxRange((text as NSString).rangeOfComposedCharacterSequence(at: p))
    }
    private func previous(_ p: Int) -> Int {
        p > 0 ? (text as NSString).rangeOfComposedCharacterSequence(at: p-1).location : 0
    }
    private func lineStart(_ p: Int) -> Int {
        let s = text as NSString
        guard p > 0 else { return 0 }
        let r = s.range(of: "\n", options: .backwards, range: NSRange(location: 0,length: min(p,s.length)))
        return r.location == NSNotFound ? 0 : r.location + 1
    }
    private func lineEnd(_ p: Int) -> Int {
        let s = text as NSString, start = min(p,text.utf16.count)
        let r = s.range(of: "\n", range: NSRange(location:start,length:s.length-start))
        return r.location == NSNotFound ? s.length : r.location
    }
    private func clamp() {
        cursor = min(max(cursor,0),text.utf16.count)
        let end = lineEnd(cursor), start = lineStart(cursor)
        if cursor >= end && end > start { cursor = previous(end) }
        if cursor < text.utf16.count { cursor = (text as NSString).rangeOfComposedCharacterSequence(at: cursor).location }
    }
    private func vertical(_ delta: Int) {
        let start = lineStart(cursor), col = cursor-start
        if delta > 0 { let end = lineEnd(cursor); if end < text.utf16.count { cursor = min(end+1+col,lineEnd(end+1)) } }
        else if start > 0 { let prev = lineStart(start-1); cursor = min(prev+col,start-1) }
        clamp()
    }
    private func whitespace(_ p: Int) -> Bool {
        guard p < text.utf16.count else { return false }
        return (text as NSString).substring(with: (text as NSString).rangeOfComposedCharacterSequence(at:p)).allSatisfy { $0.isWhitespace }
    }
    private func wordForward() {
        while cursor < text.utf16.count && !whitespace(cursor) { cursor = next(cursor) }
        while cursor < text.utf16.count && whitespace(cursor) { cursor = next(cursor) }
    }
    private func wordBackward() {
        cursor = previous(cursor)
        while cursor > 0 && whitespace(cursor) { cursor = previous(cursor) }
        while cursor > 0 && !whitespace(previous(cursor)) { cursor = previous(cursor) }
    }
}
