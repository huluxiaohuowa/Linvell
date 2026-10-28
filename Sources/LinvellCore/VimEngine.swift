import Foundation

/// Swift command state machine. Offsets at the AppKit boundary are UTF-16;
/// character motions and edits always preserve extended grapheme clusters.
public final class VimEngine {
    public enum Mode: String { case normal = "NORMAL", insert = "INSERT",replace = "REPLACE",visual = "VISUAL",visualLine = "VISUAL LINE",visualBlock = "VISUAL BLOCK" }
    public private(set) var mode: Mode = .normal
    public internal(set) var pending = ""
    public private(set) var register = ""
    public private(set) var registerRevision = 0
    public var cursor = 0
    public var text = ""
    public internal(set) var changed = false
    public private(set) var lastEdit: (range:NSRange,replacement:String)?
    var count = "", operation: String?, operatorCount = 1
    var awaiting = "", selectedRegister = "\"", wantsRegister = false
    var registers: [String:(String,Bool)] = [:]
    var linewiseRegister = false
    var history: [(String,Int)] = [], future: [(String,Int)] = []
    var lastFind: (String,String)?, marks: [String:Int] = [:]
    var commandKeys: [String] = [], lastChange: [String] = [], replaying = false
    var insertionStart: (String,Int)?, insertionCommand: [String] = []
    var insertionBase: (String,Int)?, lastInsertion: (Int,Int,String)?
    var desiredColumn: Int?
    enum MacroInput { case key(String), edit(Int,Int,String) }
    var macros: [String:[MacroInput]] = [:],macroDepth = 0,macroSteps = 0
    public private(set) var recordingRegister: String?
    var lastMacro: String?
    var searchPattern: String?,searchBackwards = false
    public func recordNativeEdit(range: NSRange,replacement: String,cursor: Int) {
        guard let name = recordingRegister,macroDepth == 0 else { return }
        macros[name,default:[]].append(.edit(range.location-cursor,range.length,replacement))
    }

    public init() {}
    public var activeRegister: String { selectedRegister }
    public func setRegister(_ name: String,value: String,linewise: Bool = false) { registers[name] = (value,linewise) }
    public func cancelPendingCommand() {
        pending = ""; count = ""; operation = nil; operatorCount = 1
        awaiting = ""; wantsRegister = false; selectedRegister = "\""; commandKeys = []
    }
    public func beginVisual(_ mode: Mode) { self.mode = mode; cancelPendingCommand() }
    public func enterInsert() { insertionStart = (text,cursor); insertionBase = (text,cursor); mode = .insert; cancelPendingCommand() }
    public func yank(_ value: String,linewise: Bool = false) { storeRegister(value,linewise:linewise) }
    public func escape() {
        if (mode == .insert || mode == .replace),let start = insertionStart {
            if !replaying,let base = insertionBase,base.0 != text {
                let before = Array(base.0),after = Array(text)
                var prefix = 0,suffix = 0
                while prefix < min(before.count,after.count),before[prefix] == after[prefix] { prefix += 1 }
                while suffix < min(before.count,after.count)-prefix,before[before.count-1-suffix] == after[after.count-1-suffix] { suffix += 1 }
                let startOffset = String(before.prefix(prefix)).utf16.count
                let removed = String(before[prefix..<(before.count-suffix)]).utf16.count
                lastInsertion = (startOffset-base.1,removed,String(after[prefix..<(after.count-suffix)]))
                lastChange = insertionCommand
            }
            // Native IME/typing owns insertion. Keep a complete insertion session as one undo unit.
            if start.0 != text {
                if history.last?.0 != start.0 { history.append(start); future.removeAll() }
            }
            if cursor > lineStart(cursor) { cursor = previous(cursor) }
            insertionStart = nil; insertionBase = nil
        }
        mode = .normal; cancelPendingCommand(); clamp(); desiredColumn = nil
    }
    public func sync(text: String,cursor: Int) {
        self.text = text; self.cursor = min(max(0,cursor),text.utf16.count)
    }
    public func key(_ key: String) {
        changed = false; lastEdit = nil
        if awaiting == "record" {
            guard key.count == 1,key.first?.isLetter == true else { finish(); return }
            let name = key.lowercased()
            if key == name { macros[name] = [] }
            recordingRegister = name; finish(); return
        }
        if key == "q",recordingRegister != nil,awaiting.isEmpty,operation == nil,macroDepth == 0 {
            recordingRegister = nil; finish(); return
        }
        if let name = recordingRegister,macroDepth == 0 { macros[name,default:[]].append(.key(key)) }
        if awaiting == "macro" {
            let name = key == "@" ? lastMacro : key.lowercased(),times = effectiveCount
            finish()
            guard let name,let input = macros[name],macroDepth < 20 else { return }
            lastMacro = name
            if macroDepth == 0 { macroSteps = 0 }
            macroDepth += 1
            var didEdit = false
            for _ in 0..<times {
                for event in input {
                    macroSteps += 1
                    guard macroSteps <= 100_000 else { macroDepth -= 1; changed = didEdit; return }
                    switch event {
                    case .key(let value): self.key(value); didEdit = didEdit || changed
                    case .edit(let offset,let length,let replacement):
                        let at = cursor+offset
                        guard at >= 0,at+length <= text.utf16.count else { continue }
                        edit(NSRange(location:at,length:length),replacement); cursor = at+replacement.utf16.count; didEdit = true
                    }
                }
            }
            macroDepth -= 1; changed = didEdit; return
        }
        if key == "Escape" { escape(); return }
        guard mode == .normal else { return }
        commandKeys.append(key)
        if wantsRegister {
            wantsRegister = false
            guard key.count == 1 else { cancelPendingCommand(); return }
            selectedRegister = key; pending += key; return
        }
        if !awaiting.isEmpty {
            let state = awaiting; awaiting = ""
            if state == "g" {
                if key == "g" { executeMotion("gg",times:effectiveCount,explicit:!count.isEmpty || operatorCount != 1) }
                else { finish() }; return
            }
            if state == "i" || state == "a" {
                if let range = textObject(key,around:state == "a",times:effectiveCount) { applyOperator(range,linewise:false) }
                else { finish() }; return
            }
            if state == "r" {
                let times = effectiveCount,start = cursor
                var end = cursor,available = 0
                for _ in 0..<times { if end < lineEnd(start) { end = next(end); available += 1 } }
                if available == times,end > start,key.count == 1 { edit(NSRange(location:start,length:end-start),String(repeating:key,count:times)); cursor = previous(start+key.utf16.count*times); remember() }
                finish(); return
            }
            if state == "m" { marks[key] = cursor; finish(); return }
            if state == "'" || state == "`" {
                if let at = marks[key] { executeDestination(state == "'" ? firstNonblank(at) : at,inclusive:false,linewise:state == "'") }
                else { finish() }; return
            }
            if ["f","F","t","T"].contains(state) {
                if let at = find(key,kind:state,times:effectiveCount) { lastFind = (state,key); executeDestination(at,inclusive:state == "f" || state == "t",linewise:false) }
                else { finish() }; return
            }
        }
        if key == "\"" { wantsRegister = true; pending += key; return }
        if key.count == 1,key.first?.isASCII == true,key.first?.isNumber == true,key != "0" || !count.isEmpty {
            if count.count < 4 { count += key }; pending += key; return
        }
        if let op = operation {
            if key == op { applyOperator(lineRange(cursor,lines:effectiveCount),linewise:true); return }
            if key == "i" || key == "a" { awaiting = key; pending += key; return }
            executeMotion(key,times:effectiveCount,explicit:!count.isEmpty || operatorCount != 1); return
        }
        let times = effectiveCount,explicit = !count.isEmpty
        switch key {
        case "*","#": searchWord(backwards:key == "#")
        case "n","N":
            let originalDirection = searchBackwards
            _ = try? search("",backwards:key == "n" ? originalDirection : !originalDirection,times:times)
            searchBackwards = originalDirection
        case "q": awaiting = "record"; pending += key
        case "@": awaiting = "macro"; pending += key
        case "d","c","y",">","<": operation = key; operatorCount = times; count = ""; pending += key
        case "g","f","F","t","T","r","m","'","`": awaiting = key; pending += key
        case "i","a","I","A","R":
            if key == "a" { cursor = min(next(cursor),lineEnd(cursor)) }
            if key == "I" { cursor = firstNonblank(cursor) }
            if key == "A" { cursor = lineEnd(cursor) }
            insertionCommand = commandKeys; insertionStart = (text,cursor); insertionBase = (text,cursor); mode = key == "R" ? .replace : .insert; finish()
        case "D","C","Y":
            operation = key == "D" ? "d" : key == "C" ? "c" : "y"
            if key == "Y" { applyOperator(lineRange(cursor,lines:times),linewise:true) }
            else { executeMotion("$",times:times,explicit:explicit) }
        case "x","X","s":
            operation = key == "s" ? "c" : "d"
            let start = key == "X" ? move(cursor,steps:-times,withinLine:true) : cursor
            let end = key == "X" ? cursor : move(cursor,steps:times,withinLine:true)
            applyOperator(NSRange(location:start,length:end-start),linewise:false)
        case "S": operation = "c"; applyOperator(lineRange(cursor,lines:times),linewise:true)
        case "p","P": put(before:key == "P",times:times); finish()
        case "o","O":
            insertionStart = (text,cursor); insertionCommand = commandKeys
            let at = key == "o" ? lineEnd(cursor) : lineStart(cursor)
            edit(NSRange(location:at,length:0),"\n"); cursor = key == "o" ? at+1 : at
            insertionBase = (text,cursor); mode = .insert; remember(); finish()
        case "J": join(lines:max(2,times)); finish()
        case "~":
            let end = move(cursor,steps:times,withinLine:true),range = NSRange(location:cursor,length:end-cursor)
            edit(range,toggled((text as NSString).substring(with:range))); cursor = end; clamp(); remember(); finish()
        case ".":
            let keys = lastChange; finish()
            guard !keys.isEmpty,!replaying else { return }
            replaying = true
            for _ in 0..<times {
                let before = (text,cursor),historyCount = history.count
                for item in keys { self.key(item) }
                if (mode == .insert || mode == .replace),let insertion = lastInsertion {
                    let at = min(max(0,cursor+insertion.0),text.utf16.count)
                    let range = NSRange(location:at,length:min(insertion.1,text.utf16.count-at))
                    edit(range,insertion.2); cursor = at+insertion.2.utf16.count; escape()
                }
                if history.count > historyCount { history.removeLast(history.count-historyCount); history.append(before) }
            }
            replaying = false
        case "u":
            for _ in 0..<times { if let item = history.popLast() { future.append((text,cursor)); text = item.0; cursor = item.1; changed = true } }
            finish()
        case "Ctrl+r":
            for _ in 0..<times { if let item = future.popLast() { history.append((text,cursor)); text = item.0; cursor = item.1; changed = true } }
            finish()
        default: executeMotion(key,times:times,explicit:explicit)
        }
    }
    var effectiveCount: Int { min(9999,(Int(count) ?? 1)*operatorCount) }
    func finish() { cancelPendingCommand() }
    func remember() { if !replaying { lastChange = commandKeys } }
    public func recordInsertion(before: String,cursor: Int) {
        if mode == .insert || mode == .replace { if insertionStart == nil { insertionStart = (before,cursor) }; return }
        if history.last?.0 != before { history.append((before,cursor)); future.removeAll() }
    }
    func edit(_ range: NSRange,_ replacement: String) {
        guard Range(range,in:text) != nil else { return }
        history.append((text,cursor)); future.removeAll(); lastEdit = (range,replacement)
        text = (text as NSString).replacingCharacters(in:range,with:replacement); changed = true
    }
    func storeRegister(_ value: String,linewise: Bool) {
        if selectedRegister == "_" { return }
        registerRevision &+= 1
        register = value; linewiseRegister = linewise; registers["\""] = (value,linewise)
        if selectedRegister != "\"" {
            let name = selectedRegister.lowercased()
            if selectedRegister != name { registers[name] = ((registers[name]?.0 ?? "")+value,linewise) }
            else { registers[name] = (value,linewise) }
        }
    }
    func applyOperator(_ supplied: NSRange,linewise: Bool) {
        guard let op = operation else { finish(); return }
        let range = supplied,old = text,originalCursor = cursor
        guard Range(range,in:text) != nil else { finish(); return }
        let value = (text as NSString).substring(with:range)
        if op == "y" { storeRegister(value,linewise:linewise); cursor = range.location; clamp(); finish(); return }
        if op == "d" || op == "c" {
            storeRegister(value,linewise:linewise)
            var deletion = range,replacement = ""
            if linewise,op == "c",value.hasSuffix("\n") { replacement = "\n" }
            // Deleting a final, unterminated line consumes the preceding separator.
            if linewise,op == "d",NSMaxRange(range) == text.utf16.count,!value.hasSuffix("\n"),range.location > 0 {
                deletion.location -= 1; deletion.length += 1
            }
            edit(deletion,replacement); cursor = min(range.location,text.utf16.count)
            if op == "c" { insertionStart = (old,originalCursor); insertionCommand = commandKeys; insertionBase = (text,cursor); mode = .insert }
            else { clamp() }
        } else if op == ">" || op == "<" {
            let whole = lineRangeCovering(range),lines = (text as NSString).substring(with:whole).components(separatedBy:"\n")
            let replacement = lines.enumerated().map { index,line -> String in
                if index == lines.count-1,line.isEmpty { return line }
                if op == ">" { return "    "+line }
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                return String(line.dropFirst(line.prefix(4).prefix { $0 == " " }.count))
            }.joined(separator:"\n")
            edit(whole,replacement); cursor = firstNonblank(whole.location)
        }
        if changed { remember() }; finish()
    }
    func put(before: Bool,times: Int) {
        guard selectedRegister != "_" else { return }
        let value = registers[selectedRegister.lowercased()] ?? (register,linewiseRegister)
        guard !value.0.isEmpty else { return }
        var payload = String(repeating:value.0,count:times),at: Int
        if value.1 {
            at = before ? lineStart(cursor) : min(text.utf16.count,lineEnd(cursor)+1)
            if !before,at == text.utf16.count,!text.hasSuffix("\n"),!text.isEmpty {
                if payload.hasSuffix("\n") { payload.removeLast() }
                payload = "\n"+payload
            } else if !payload.hasSuffix("\n") { payload += "\n" }
        } else { at = before ? cursor : min(next(cursor),lineEnd(cursor)) }
        edit(NSRange(location:at,length:0),payload); cursor = value.1 ? firstNonblank(at+(payload.hasPrefix("\n") ? 1 : 0)) : previous(at+payload.utf16.count)
        clamp(); remember()
    }
    func join(lines: Int) {
        let range = lineRange(cursor,lines:lines),value = (text as NSString).substring(with:range)
        var pieces = value.components(separatedBy:"\n"),suffix = ""
        if pieces.last == "" { pieces.removeLast(); suffix = "\n" }
        guard pieces.count > 1 else { return }
        let joined = pieces.enumerated().map { $0.offset == 0 ? $0.element : $0.element.trimmingCharacters(in:.whitespaces) }.joined(separator:" ")+suffix
        let at = range.location+pieces[0].utf16.count
        edit(range,joined); cursor = at; clamp(); remember()
    }
    func toggled(_ value: String) -> String { value.map { c in let s = String(c); return s == s.uppercased() ? s.lowercased() : s.uppercased() }.joined() }
}
