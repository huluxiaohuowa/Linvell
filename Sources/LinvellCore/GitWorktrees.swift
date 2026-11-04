import Foundation

public struct GitWorktreeEntry {
    public let path: String
    public private(set) var branch = ""
    public private(set) var locked = false
    public private(set) var prunable = false

    public static func parse(_ output: String) -> [Self] {
        var entries: [Self] = []
        for field in output.split(separator:"\0") {
            if field.hasPrefix("worktree ") { entries.append(Self(path:String(field.dropFirst(9)))) }
            else if let index = entries.indices.last {
                if field.hasPrefix("branch refs/heads/") { entries[index].branch = String(field.dropFirst(18)) }
                if field == "locked" || field.hasPrefix("locked ") { entries[index].locked = true }
                if field == "prunable" || field.hasPrefix("prunable ") { entries[index].prunable = true }
            }
        }
        return entries
    }
}

extension GitRepository {
    public func worktrees() throws -> [GitWorktreeEntry] {
        GitWorktreeEntry.parse(try run(["worktree","list","--porcelain","-z"]))
    }

    @discardableResult
    public func finishWorktree(_ entry: GitWorktreeEntry,into target: String,removeSource: Bool = true) throws -> GitWorktreeMerge? {
        let liveEntries = try worktrees()
        guard !target.isEmpty,target != entry.branch,!entry.branch.isEmpty,entry.path != directory,
              liveEntries.first?.path != entry.path,
              liveEntries.contains(where:{ $0.path == entry.path && $0.branch == entry.branch && !$0.locked && !$0.prunable }) else {
            throw GitError.command("The source worktree must be clean, unlocked and on the selected branch.")
        }
        _ = try run(["show-ref","--verify","--","refs/heads/"+target])
        let source = try atWorktree(entry.path).revision("HEAD")
        let destination = liveEntries.first { $0.branch == target && !$0.prunable }.map { atWorktree($0.path) } ?? self
        let merge = GitWorktreeMerge(source:entry,sourceCommit:source,targetBranch:target,destination:destination,removeAfterMerge:removeSource)
        if merge.pending { return merge }
        guard try atWorktree(entry.path).changes().isEmpty else {
            throw GitError.command("The source worktree must be clean, unlocked and on the selected branch.")
        }
        guard try destination.changes().isEmpty else { throw GitError.command("The target worktree must be clean.") }
        if try destination.revision("HEAD") != destination.revision("refs/heads/"+target)
            || destination.currentBranch() != target {
            _ = try destination.run(["switch","--",target])
        }
        do {
            _ = try destination.run(["merge","--no-edit","--",source],timeout:120)
        } catch {
            if merge.pending { return merge }
            throw error
        }
        try merge.removeSource()
        return nil
    }

    fileprivate func revision(_ name: String) throws -> String {
        try run(["rev-parse","--verify",name]).trimmingCharacters(in:.newlines)
    }

    fileprivate func currentBranch() throws -> String {
        try run(["branch","--show-current"]).trimmingCharacters(in:.newlines)
    }
}

public struct GitWorktreeMerge {
    public let source: GitWorktreeEntry
    public let sourceCommit: String
    public let targetBranch: String
    public let destination: GitRepository
    public let removeAfterMerge: Bool

    fileprivate var pending: Bool {
        (try? destination.revision("MERGE_HEAD")) == sourceCommit && (try? destination.currentBranch()) == targetBranch
    }

    public func conflicts() throws -> [GitChange] {
        try requirePending()
        return try destination.changes().filter(\.conflicted)
    }

    public func versions(_ path: String) throws -> (current: String?,incoming: String?) {
        let stages = try conflictStages(path)
        func contents(_ stage: String) throws -> String? {
            guard stages.contains(stage) else { return nil }
            let value = try destination.run(["show",":\(stage):\(path)"])
            if value.contains("\0") { return "Binary file" }
            return String(value.prefix(100_000))
        }
        return try (contents("2"),contents("3"))
    }

    private func conflictStages(_ path: String) throws -> Set<String> {
        guard try conflicts().contains(where:{ $0.path == path }) else {
            throw GitError.command("This file no longer has a merge conflict.")
        }
        let entries = try destination.run(["ls-files","--unmerged","-z","--",path])
        return Set(entries.split(separator:"\0").compactMap { entry in
            entry.split(separator:"\t",maxSplits:1).first?.split(separator:" ").last.map(String.init)
        })
    }

    public func resolve(_ path: String,useIncoming: Bool) throws {
        let stage = useIncoming ? "3" : "2"
        let hasSide = try conflictStages(path).contains(stage)
        if hasSide {
            _ = try destination.run(["checkout",useIncoming ? "--theirs" : "--ours","--",path])
            _ = try destination.run(["add","--",path])
        } else {
            _ = try destination.run(["rm","--",path])
        }
    }

    public func markResolved(_ path: String) throws {
        guard try conflicts().contains(where:{ $0.path == path }) else {
            throw GitError.command("This file no longer has a merge conflict.")
        }
        _ = try destination.run(["add","--",path])
    }

    public func abort() throws {
        try requirePending()
        _ = try destination.run(["merge","--abort"],timeout:120)
    }

    public func complete() throws {
        try requirePending()
        guard try conflicts().isEmpty else { throw GitError.command("Resolve all conflicts before continuing.") }
        _ = try destination.run(["-c","core.editor=true","merge","--continue"],timeout:120)
        try removeSource()
    }

    fileprivate func removeSource() throws {
        guard removeAfterMerge else { return }
        do {
            let sourceRepo = destination.atWorktree(source.path)
            guard try destination.currentBranch() == targetBranch,
                  try sourceRepo.currentBranch() == source.branch,
                  try sourceRepo.revision("HEAD") == sourceCommit,
                  try sourceRepo.run(["status","--porcelain=v1","--untracked-files=all","--ignored=matching"]).isEmpty else {
                throw GitError.command("A worktree changed during the merge or contains ignored files.")
            }
            _ = try destination.run(["merge-base","--is-ancestor",sourceCommit,"HEAD"])
            _ = try destination.run(["worktree","remove","--",source.path],timeout:60)
        } catch {
            throw GitError.command("The merge succeeded. The source worktree was kept. "+error.localizedDescription)
        }
    }

    private func requirePending() throws {
        guard pending else { throw GitError.command("The pending merge no longer matches this worktree.") }
    }
}
