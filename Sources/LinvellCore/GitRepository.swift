import Foundation

public struct GitChange: Equatable {
    public let index: Character
    public let worktree: Character
    public let path: String
    public let originalPath: String?
    public var staged: Bool { index != " " && index != "?" }
    public var unstaged: Bool { worktree != " " }
    public var conflicted: Bool { index == "U" || worktree == "U" || (index == "A" && worktree == "A") || (index == "D" && worktree == "D") }
}

public struct GitCommit {
    public let hash: String
    public let parents: [String]
    public let author: String
    public let date: String
    public let subject: String
    public let refs: String
}
public struct GitHunk {
    public let header: String
    public let patch: String
    public static func parse(_ diff: String) -> [GitHunk] {
        let lines = diff.components(separatedBy:"\n")
        guard let first = lines.firstIndex(where:{ $0.hasPrefix("@@ ") }) else { return [] }
        let prefix = lines[..<first].joined(separator:"\n")+"\n"
        let starts = lines.indices.filter { lines[$0].hasPrefix("@@ ") }
        return starts.enumerated().map { index,start in
            let end = index+1 < starts.count ? starts[index+1] : lines.count
            var body = lines[start..<end].joined(separator:"\n")
            if !body.hasSuffix("\n") { body += "\n" }
            return GitHunk(header:lines[start],patch:prefix+body)
        }
    }
}

public enum GitError: LocalizedError {
    case command(String),invalidPath,emptyMessage
    public var errorDescription: String? {
        switch self {
        case .command(let text): return text
        case .invalidPath: return "The Git path is invalid."
        case .emptyMessage: return "Enter a commit message first."
        }
    }
}

public struct GitRepository {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func resolvedWorkingTree() throws -> GitRepository {
        var path = try run(["rev-parse","--show-toplevel"])
        if path.hasSuffix("\n") { path.removeLast() }
        return GitRepository(root:URL(fileURLWithPath:path,isDirectory:true))
    }
    public func run(_ arguments: [String],timeout: TimeInterval = 30) throws -> String {
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/git"),arguments:["--no-pager","--literal-pathspecs","-c","color.ui=false","-c","core.fsmonitor=false","-C",root.path]+arguments,directory:root,timeout:timeout,trimOutput:false)
        guard result.succeeded else { throw GitError.command(result.timedOut ? "Git operation timed out." : result.output) }
        return result.output
    }
    public func changes() throws -> [GitChange] { Self.parseStatus(try run(["status","--porcelain=v1","-z","--untracked-files=all"])) }
    public static func parseStatus(_ text: String) -> [GitChange] {
        let fields = text.split(separator:"\0",omittingEmptySubsequences:true).map(String.init)
        var changes: [GitChange] = [],i = 0
        while i < fields.count {
            let record = fields[i]; i += 1
            let bytes = Array(record.utf8)
            guard bytes.count >= 4,bytes[2] == 32 else { continue }
            let x = Character(UnicodeScalar(bytes[0])),y = Character(UnicodeScalar(bytes[1]))
            let path = String(decoding:bytes.dropFirst(3),as:UTF8.self)
            var original: String?
            if x == "R" || y == "R" || x == "C" || y == "C" {
                guard i < fields.count else { break }; original = fields[i]; i += 1
            }
            changes.append(GitChange(index:x,worktree:y,path:path,originalPath:original))
        }
        return changes
    }
    private func checked(_ path: String) throws -> String {
        guard !path.isEmpty,!path.hasPrefix("/"),!path.utf8.contains(0),!path.components(separatedBy:"/").contains("..") else { throw GitError.invalidPath }
        return path
    }
    public func diff(_ change: GitChange,staged: Bool) throws -> String {
        if change.index == "?" {
            let file = root.appendingPathComponent(try checked(change.path))
            let attrs = try file.resourceValues(forKeys:[.fileSizeKey])
            guard (attrs.fileSize ?? 0) <= 1024*1024 else { return "File too large for an untracked-file preview." }
            let data = try Data(contentsOf:file)
            guard !data.contains(0),let value = String(data:data,encoding:.utf8) else { return "Binary file" }
            return "+++ \(change.path)\n"+value.components(separatedBy:"\n").map { "+"+$0 }.joined(separator:"\n")
        }
        return try run(["diff","--no-ext-diff","--no-textconv"]+(staged ? ["--cached"] : [])+["--",checked(change.path)])
    }
    public func stage(_ change: GitChange) throws {
        var paths = [try checked(change.path)]
        if let original = change.originalPath { paths.append(try checked(original)) }
        _ = try run(["add","--"]+paths)
    }
    public func applyHunk(_ hunk: GitHunk,unstage: Bool) throws {
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/git"),arguments:["--no-pager","-C",root.path,"apply","--cached","--whitespace=nowarn"]+(unstage ? ["--reverse"] : [])+["-"],directory:root,input:Data(hunk.patch.utf8))
        guard result.succeeded else { throw GitError.command(result.output) }
    }
    public func unstage(_ change: GitChange) throws {
        let paths = try [change.path,change.originalPath].compactMap { $0 }.map(checked)
        if (try? run(["rev-parse","--verify","HEAD"])) != nil { _ = try run(["restore","--staged","--"]+paths) }
        else { _ = try run(["rm","--cached","--ignore-unmatch","--"]+paths) }
    }
    public func commit(_ message: String) throws {
        guard !message.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw GitError.emptyMessage }
        _ = try run(["commit","-m",message],timeout:120)
    }
    public func history() throws -> [GitCommit] {
        let text = try run(["log","-n","150","--all","--topo-order","--date=iso-strict","--format=%H%x00%P%x00%an%x00%ad%x00%s%x00%D%x00"])
        let parts = text.split(separator:"\0",omittingEmptySubsequences:false).map(String.init)
        return stride(from:0,to:max(0,parts.count-6),by:6).compactMap { i in
            let hash = parts[i].trimmingCharacters(in:.whitespacesAndNewlines)
            guard hash.count == 40 || hash.count == 64 else { return nil }
            return GitCommit(hash:hash,parents:parts[i+1].split(separator:" ").map(String.init),author:parts[i+2],date:parts[i+3],subject:parts[i+4],refs:parts[i+5])
        }
    }
    public func commitDiff(_ hash: String) throws -> String {
        guard [40,64].contains(hash.count),hash.allSatisfy(\.isHexDigit) else { throw GitError.invalidPath }
        return try run(["show","--first-parent","--format=","--stat","--patch","--no-ext-diff","--no-textconv",hash,"--"])
    }
}
