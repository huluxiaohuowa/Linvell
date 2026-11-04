import Foundation

public struct GitFileHistoryEntry {
    public let commit: GitCommit
    public let oldPath: String?
    public let newPath: String?
}

extension GitRepository {
    /// Adapted from FoldGit GitFileHistory, copyright (c) 2026 dufu, MIT.
    /// Grow a prefix at a pinned tip: --skip before --follow loses rename transitions.
    public func fileHistoryEntries(_ path: String,revision: String? = nil,limit: Int = 100,offset: Int = 0) throws -> [GitFileHistoryEntry] {
        guard limit > 0,offset >= 0 else { throw GitError.invalidPath }
        let tip = try resolvedRevision(revision ?? "HEAD")
        let format = "%H%x00%P%x00%an%x00%ae%x00%ad%x00%s%x00%x00%B%x00"
        let output = try run(["log","--follow","--find-renames","--diff-merges=first-parent","--name-status","-z","--date=iso-strict","--format="+format,"--max-count="+String(offset+limit),tip,"--",checked(path)])
        let fields = output.components(separatedBy:"\0")
        var index = 0,entries: [GitFileHistoryEntry] = []
        while index < fields.count {
            while index < fields.count,fields[index].trimmingCharacters(in:.newlines).isEmpty { index += 1 }
            if index == fields.count { break }
            guard index+8 <= fields.count else { throw GitError.command("Invalid file history records from Git.") }
            let hash = fields[index].trimmingCharacters(in:.newlines)
            guard [40,64].contains(hash.count),hash.allSatisfy(\.isHexDigit) else { throw GitError.command("Invalid file history records from Git.") }
            let commit = GitCommit(hash:hash,parents:fields[index+1].split(separator:" ").map(String.init),author:fields[index+2],email:fields[index+3],date:fields[index+4],subject:fields[index+5],message:fields[index+7],refs:fields[index+6])
            index += 8
            if index < fields.count,fields[index].isEmpty { index += 1 }
            guard index+1 < fields.count else { throw GitError.command("Invalid file history records from Git.") }
            let status = fields[index].trimmingCharacters(in:.newlines),first = fields[index+1]
            index += 2
            let renamed = status.hasPrefix("R") || status.hasPrefix("C")
            let old: String?,new: String?
            if renamed {
                guard index < fields.count else { throw GitError.command("Invalid file history records from Git.") }
                old = first; new = fields[index]; index += 1
            } else {
                guard status.first.map({ "AMDT".contains($0) }) == true else { throw GitError.command("Invalid file history records from Git.") }
                old = status.hasPrefix("A") ? nil : first
                new = status.hasPrefix("D") ? nil : first
            }
            entries.append(.init(commit:commit,oldPath:old,newPath:new))
        }
        return Array(entries.dropFirst(offset).prefix(limit))
    }

    public func fileHistoryDiff(_ entry: GitFileHistoryEntry) throws -> String {
        let paths = Array(Set([entry.oldPath,entry.newPath].compactMap { $0 })).sorted()
        let options = ["--no-ext-diff","--no-textconv","--find-renames","--full-index","--src-prefix=a/","--dst-prefix=b/"]
        if let parent = entry.commit.parents.first {
            return try run(["diff"]+options+[parent,entry.commit.hash,"--"]+paths)
        }
        return try run(["diff-tree","--root","--no-commit-id","-p"]+options+[entry.commit.hash,"--"]+paths)
    }

    public func fileHistoryImages(_ entry: GitFileHistoryEntry) throws -> (Data?,Data?) {
        let before: Data?
        if let parent = entry.commit.parents.first,let path = entry.oldPath { before = try blobData(parent,path:path) } else { before = nil }
        let after = try entry.newPath.map { try blobData(entry.commit.hash,path:$0) }
        return (before,after)
    }
}
