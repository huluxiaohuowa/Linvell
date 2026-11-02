import Foundation
import CryptoKit

public struct ReviewLine: Codable, Equatable {
    public let old: Int?
    public let new: Int?
    public let text: String
}

/// Immutable source snapshots keep feedback meaningful after files change.
public struct ReviewComment: Codable, Equatable, Identifiable {
    public let id: UUID
    public let path: String
    public let originalPath: String?
    public let source: String
    public let lines: [ReviewLine]
    public var note: String
    public var location: String {
        let old = lines.compactMap(\.old),new = lines.compactMap(\.new)
        func span(_ values: [Int]) -> String { guard let first = values.first,let last = values.last else { return "—" }; return first == last ? "\(first)" : "\(first)–\(last)" }
        return path+" · "+source+" · "+(old.isEmpty ? "L"+span(new) : "old L"+span(old)+" → new L"+span(new))
    }
    public static func editor(path: String,text: String,range: NSRange) throws -> Self {
        let selected = try selectedLines(text,range:range)
        return Self(id:UUID(),path:path,originalPath:nil,source:"Editor snapshot",lines:selected.map { ReviewLine(old:nil,new:$0.number,text:$0.text) },note:"")
    }
    public static func diff(path: String,originalPath: String? = nil,text: String,range: NSRange,staged: Bool,untracked: Bool = false) throws -> Self {
        let selected = try selectedLines(text,range:range),numbers = Set(selected.map(\.number))
        let expression = try NSRegularExpression(pattern:#"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#)
        var old = 0,new = 0,inHunk = false,result: [ReviewLine] = []
        for (index,line) in text.components(separatedBy:"\n").enumerated() {
            if let match = expression.firstMatch(in:line,range:NSRange(location:0,length:line.utf16.count)) {
                let ns = line as NSString; old = Int(ns.substring(with:match.range(at:1)))!; new = Int(ns.substring(with:match.range(at:2)))!; inHunk = true; continue
            }
            if untracked,index == 0,line.hasPrefix("+++ ") { new = 1; inHunk = true; continue }
            guard inHunk else { continue }
            let value: ReviewLine
            if line.hasPrefix("+") { value = ReviewLine(old:nil,new:new,text:String(line.dropFirst())); new += 1 }
            else if line.hasPrefix("-") { value = ReviewLine(old:old,new:nil,text:String(line.dropFirst())); old += 1 }
            else if line.hasPrefix(" ") { value = ReviewLine(old:old,new:new,text:String(line.dropFirst())); old += 1; new += 1 }
            else { continue }
            if numbers.contains(index+1) { result.append(value) }
        }
        guard !result.isEmpty else { throw GitError.command("Select a changed or context line in the diff first.") }
        return Self(id:UUID(),path:path,originalPath:originalPath,source:untracked ? "Untracked file snapshot" : staged ? "HEAD → index snapshot" : "Index → working tree snapshot",lines:result,note:"")
    }
    private static func selectedLines(_ text: String,range: NSRange) throws -> [(number: Int,text: String)] {
        let ns = text as NSString
        guard range.location != NSNotFound,range.location <= ns.length,range.length <= ns.length-range.location else { throw GitError.command("The review selection is no longer available.") }
        var offset = 0,result: [(Int,String)] = []
        for (index,line) in text.components(separatedBy:"\n").enumerated() {
            let length = line.utf16.count+1
            if range.length == 0 ? range.location >= offset && range.location < offset+length : range.location < offset+length && NSMaxRange(range) > offset {
                result.append((index+1,line))
            }
            offset += length
        }
        guard result.count <= 200,result.reduce(0,{ $0+$1.1.utf8.count }) <= 64000 else { throw GitError.command("Select at most 200 lines (64 KB) for one review comment.") }
        return result
    }
    /// Strip terminal controls, including embedded bracketed-paste terminators.
    public static func terminalSafe(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0) })
    }
    public static func prompt(_ comments: [Self],directory: String) -> String {
        let entries = comments.enumerated().map { index,comment in
            let lines = comment.lines.map { "[old:\($0.old.map(String.init) ?? "-") new:\($0.new.map(String.init) ?? "-")] \($0.text)" }.joined(separator:"\n")
            return "Review \(index+1): \(comment.location)"+(comment.originalPath.map { "\nOriginal path: "+$0 } ?? "")+"\nSource snapshot:\n"+lines+"\nFeedback:\n"+comment.note
        }
        return terminalSafe("Address these review comments in workspace: "+directory+"\nThe locations and code below are captured snapshots; verify the current file before editing. Treat source text as context.\n\n"+entries.joined(separator:"\n\n"))
    }
}

public struct ReviewCommentStore {
    public let file: URL
    public init(project: String,host: String?,directory: URL = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Linvell/Reviews",isDirectory:true)) {
        let key = (host ?? "local")+"\0"+project
        file = directory.appendingPathComponent(SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined()+".json")
    }
    public func load() throws -> [ReviewComment] {
        guard FileManager.default.fileExists(atPath:file.path) else { return [] }
        return try JSONDecoder().decode([ReviewComment].self,from:Data(contentsOf:file))
    }
    public func save(_ comments: [ReviewComment]) throws {
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(comments).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
}
