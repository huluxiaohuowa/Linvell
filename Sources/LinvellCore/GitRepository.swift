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
    public let email: String
    public let date: String
    public let subject: String
    public let message: String
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
    public var root: URL { URL(fileURLWithPath:directory,isDirectory:true) }
    public private(set) var directory: String
    public let remote: SSHRemote?
    typealias Executor = (String,[String],Data?,TimeInterval) throws -> String
    private let executor: Executor?
    public init(root: URL) { directory = root.path; remote = nil; executor = nil }
    public init(remote: SSHRemote,directory: String) {
        self.directory = directory; self.remote = remote
        executor = { try remote.git($1,directory:$0,input:$2,timeout:$3) }
    }
    init(directory: String,remote: SSHRemote?,executor: @escaping Executor) { self.directory = directory; self.remote = remote; self.executor = executor }
    func atWorktree(_ path: String) -> GitRepository {
        var copy = self
        copy.directory = path
        return copy
    }

    public func childRepository(_ path: String) throws -> GitRepository {
        let path = try checked(path)
        guard path != ".",!path.split(separator:"/").contains(".git") else { throw GitError.invalidPath }
        var child = self; child.directory = (directory as NSString).appendingPathComponent(path); return child
    }
    public func resolvedWorkingTree() throws -> GitRepository {
        var path = try run(["rev-parse","--show-toplevel"])
        if path.hasSuffix("\n") { path.removeLast() }
        var resolved = self; resolved.directory = path; return resolved
    }
    public var journalScope: String { (remote?.host ?? "local")+"\0"+directory }
    public func run(_ arguments: [String],timeout: TimeInterval = 30,input: Data? = nil) throws -> String {
        let started = Date()
        var succeeded = false
        let safeCommands: Set<String> = ["add","branch","checkout","clone","commit","diff","fetch","log","merge","pull","push","restore","show","stash","status","switch","tag","worktree"]
        let command = arguments.first.flatMap { safeCommands.contains($0) ? $0 : nil } ?? "operation"
        defer {
            GitCommandJournal.shared.append(.init(date:started,command:command,elapsed:Date().timeIntervalSince(started),succeeded:succeeded),scope:journalScope)
        }
        if let executor {
            let value = try executor(directory,arguments,input,timeout)
            succeeded = true
            return value
        }
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/git"),arguments:Self.arguments(directory:directory,arguments:arguments),directory:root,timeout:timeout,input:input,trimOutput:false,maximumOutputBytes:16*1024*1024)
        guard result.succeeded else { throw GitError.command(result.timedOut ? "Git operation timed out." : result.output) }
        succeeded = true
        return result.output
    }
    static func arguments(directory: String,arguments: [String]) -> [String] {
        ["--no-pager","--literal-pathspecs","-c","color.ui=false","-c","core.fsmonitor=false","-C",directory]+arguments
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
            if let remote {
                let reply = try remote.request("read",path:file.path)
                guard let content = reply.content,let data = Data(base64Encoded:content) else { throw GitError.command("The remote response is incomplete.") }
                guard data.count <= 1024*1024 else { return "File too large for an untracked-file preview." }
                guard !data.contains(0),let value = String(data:data,encoding:.utf8) else { return "Binary file" }
                return "+++ \(change.path)\n"+value.components(separatedBy:"\n").map { "+"+$0 }.joined(separator:"\n")
            }
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
        _ = try run(["apply","--cached","--whitespace=nowarn"]+(unstage ? ["--reverse"] : [])+["-"],input:Data(hunk.patch.utf8))
    }

    public func unstage(_ change: GitChange) throws {
        let paths = try [change.path,change.originalPath].compactMap { $0 }.map(checked)
        if (try? run(["rev-parse","--verify","HEAD"])) != nil { _ = try run(["restore","--staged","--"]+paths) }
        else { _ = try run(["rm","--cached","--ignore-unmatch","--"]+paths) }
    }
    public func unstageAll() throws {
        guard try !changes().contains(where:\.conflicted) else {
            throw GitError.command("Resolve all conflicts before unstaging.")
        }
        if (try? run(["rev-parse","--verify","HEAD"])) != nil {
            _ = try run(["restore","--staged","--","."])
        } else {
            _ = try run(["read-tree","--empty"])
        }
    }

    public func commit(_ message: String) throws {
        guard !message.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw GitError.emptyMessage }
        _ = try run(["commit","-m",message],timeout:120)
    }
    public func commitTemplate() throws -> String {
        guard let configured = try? run(["config","--path","--get","commit.template"]) else {
            throw GitError.command("No commit template is configured.")
        }
        let path = configured.hasSuffix("\n") ? String(configured.dropLast()) : configured
        guard !path.isEmpty else { throw GitError.command("No commit template is configured.") }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath:path) : root.appendingPathComponent(path)
        let data: Data
        if let remote {
            let reply = try remote.request("read",path:url.path)
            guard let content = reply.content,let decoded = Data(base64Encoded:content) else {
                throw GitError.command("The remote response is incomplete.")
            }
            data = decoded
        } else {
            let values = try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
            guard values.isRegularFile == true,(values.fileSize ?? 0) <= 65_536 else {
                throw GitError.command("The commit template must be a regular file no larger than 64 KiB.")
            }
            let handle = try FileHandle(forReadingFrom:url)
            defer { try? handle.close() }
            data = try handle.read(upToCount:65_537) ?? Data()
        }
        guard data.count <= 65_536,!data.contains(0),let text = String(data:data,encoding:.utf8) else {
            throw GitError.command("The commit template must be UTF-8 and no larger than 64 KiB.")
        }
        let comment = (try? run(["config","--get","core.commentChar"]))?.trimmingCharacters(in:.newlines) ?? "#"
        let prefix = comment.count == 1 ? comment : "#"
        return text.components(separatedBy:.newlines).filter { !$0.hasPrefix(prefix) }.joined(separator:"\n")
            .trimmingCharacters(in:.whitespacesAndNewlines)
    }

    public func history(allRefs: Bool = true,limit: Int = 150,offset: Int = 0,includeMessage: Bool = false,path: String? = nil) throws -> [GitCommit] {
        let scope = allRefs ? ["--all"] : ["HEAD"]
        let format = "%H%x00%P%x00%an%x00%ae%x00%ad%x00%s%x00%D%x00"+(includeMessage ? "%B%x00" : "")
        let paths = try path.map { ["--",try checked($0)] } ?? []
        let text = try run(["log","-n",String(limit),"--skip="+String(offset)]+scope+["--topo-order","--date=iso-strict","--format="+format]+paths)
        let fields = includeMessage ? 8 : 7
        let parts = text.split(separator:"\0",omittingEmptySubsequences:false).map(String.init)
        return stride(from:0,to:max(0,parts.count-fields),by:fields).compactMap { i in
            let hash = parts[i].trimmingCharacters(in:.whitespacesAndNewlines)
            guard hash.count == 40 || hash.count == 64 else { return nil }
            return GitCommit(hash:hash,parents:parts[i+1].split(separator:" ").map(String.init),author:parts[i+2],email:parts[i+3],date:parts[i+4],subject:parts[i+5],message:includeMessage ? parts[i+7] : parts[i+5],refs:parts[i+6])
        }
    }
    public func commitDiff(_ hash: String,path: String? = nil) throws -> String {
        guard [40,64].contains(hash.count),hash.allSatisfy(\.isHexDigit) else { throw GitError.invalidPath }
        return try run(["show","--first-parent","--format=","--stat","--patch","--no-ext-diff","--no-textconv",hash,"--"] + (try path.map { [try checked($0)] } ?? []))
    }
}
