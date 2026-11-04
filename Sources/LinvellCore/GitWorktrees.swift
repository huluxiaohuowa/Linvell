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
    public func finishWorktree(_ entry: GitWorktreeEntry,into target: String,removeSource: Bool = true,deleteBranch: Bool = false) throws -> GitWorktreeMerge? {
        let liveEntries = try worktrees()
        guard !target.isEmpty,target != entry.branch,!entry.branch.isEmpty,entry.path != directory,
              liveEntries.first?.path != entry.path,
              liveEntries.contains(where:{ $0.path == entry.path && $0.branch == entry.branch && !$0.locked && !$0.prunable }) else {
            throw GitError.command("The source worktree must be clean, unlocked and on the selected branch.")
        }
        _ = try run(["show-ref","--verify","--","refs/heads/"+target])
        let source = try atWorktree(entry.path).revision("HEAD")
        let destination = liveEntries.first { $0.branch == target && !$0.prunable }.map { atWorktree($0.path) } ?? self
        let merge = GitWorktreeMerge(source:entry,sourceCommit:source,targetBranch:target,destination:destination,removeAfterMerge:removeSource,deleteBranchAfterMerge:deleteBranch)
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
    public let deleteBranchAfterMerge: Bool

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

    public func deleteConflict(_ path: String) throws {
        guard try conflicts().contains(where:{ $0.path == path }) else { throw GitError.command("This file no longer has a merge conflict.") }
        _ = try destination.run(["rm","-f","--",path])
    }

    public func markResolved(_ path: String) throws {
        guard try conflicts().contains(where:{ $0.path == path }) else {
            throw GitError.command("This file no longer has a merge conflict.")
        }
        let diff = try destination.run(["diff","--ours","--no-ext-diff","--no-textconv","--",path])
        let hasMarkers = diff.split(whereSeparator:\.isNewline).contains { line in
            guard line.hasPrefix("+") else { return false }
            let content = line.dropFirst()
            return content.hasPrefix("<<<<<<< ") || content.hasPrefix(">>>>>>> ") || content == "======="
        }
        guard !hasMarkers else { throw GitError.command("Remove conflict markers before marking this file resolved.") }
        _ = try destination.run(["add","--",path])
    }

    public func abort() throws {
        try requirePending()
        _ = try destination.run(["merge","--abort"],timeout:120)
    }

    public func complete() throws {
        try requirePending()
        guard try conflicts().isEmpty,try destination.run(["diff","--name-only","-z"]).isEmpty else { throw GitError.command("Resolve all conflicts before continuing.") }
        _ = try destination.run(["-c","core.editor=true","merge","--continue"],timeout:120)
        try removeSource()
    }

    fileprivate func removeSource() throws {
        guard removeAfterMerge else { return }
        do {
            let sourceRepo = destination.atWorktree(source.path)
            try sourceRepo.withLockedHead(sourceCommit) {
            guard try destination.currentBranch() == targetBranch,
                  try sourceRepo.currentBranch() == source.branch,
                  try sourceRepo.revision("HEAD") == sourceCommit,
                  try sourceRepo.run(["status","--porcelain=v1","--untracked-files=all","--ignored=matching"]).isEmpty else {
                throw GitError.command("A worktree changed during the merge or contains ignored files.")
            }
            _ = try destination.run(["merge-base","--is-ancestor",sourceCommit,"HEAD"])
            _ = try destination.run(["worktree","remove","--",source.path],timeout:60)
            }
            if deleteBranchAfterMerge,
               try destination.revision("refs/heads/"+source.branch) == sourceCommit {
                _ = try destination.run(["branch","-d","--",source.branch])
            }
        } catch {
            throw GitError.command("The merge succeeded, but source cleanup could not be completed. "+error.localizedDescription)
        }
    }

    private func requirePending() throws {
        guard pending else { throw GitError.command("The pending merge no longer matches this worktree.") }
    }
}

extension GitRepository {
    public func worktreeState(_ entry: GitWorktreeEntry) throws -> String {
        let repo = atWorktree(entry.path)
        let changes = try repo.changes()
        if changes.contains(where:\.conflicted) { return "Conflicts" }
        if ["MERGE_HEAD","REBASE_HEAD","CHERRY_PICK_HEAD","REVERT_HEAD","BISECT_HEAD"].contains(where:{ (try? repo.revision($0)) != nil }) { return "In Progress" }
        if !changes.isEmpty { return "Uncommitted Changes" }
        return "Clean"
    }

    public struct CleanupCandidate {
        public let entry: GitWorktreeEntry
        public let head: String
        public let ignored: [String]
        public let ancestor: Bool
        public var lastActivity: Date? = nil
        public var isUnstarted = false
        public var selectedByDefault: Bool {
            ignored.isEmpty && !isUnstarted && lastActivity.map { Date().timeIntervalSince($0) >= 15*60 } == true
        }
    }

    public func cleanupCandidates(into target: String) throws -> [CleanupCandidate] {
        let ref = "refs/heads/"+target
        let targetHead = try revision(ref)
        return try worktrees().dropFirst().compactMap { entry in
            guard entry.path != directory,entry.branch != target,!entry.locked,!entry.prunable else { return nil }
            let source = atWorktree(entry.path)
            guard let head = try? source.revision("HEAD"),
                  (try? source.worktreeState(entry)) == "Clean",
                  let ignored = try? source.run(["ls-files","-z","--others","--ignored","--exclude-standard"]) else { return nil }
            let ancestor = (try? run(["merge-base","--is-ancestor",head,targetHead])) != nil
            guard ancestor || contentMerged(head,into:targetHead) else { return nil }
            let ref = entry.branch.isEmpty ? "HEAD" : "refs/heads/"+entry.branch
            let reflog = (try? source.run(["log","--walk-reflogs","--format=%H","-n","200",ref,"--"]))?.split(whereSeparator:\.isNewline).map(String.init) ?? []
            let unstarted = ancestor && !reflog.isEmpty && reflog.allSatisfy { $0 == head }
            return CleanupCandidate(entry:entry,head:head,ignored:ignored.split(separator:"\0").map(String.init),ancestor:ancestor,lastActivity:try? source.lastActivity(),isUnstarted:unstarted)
        }
    }

    // Adapted from FoldGit WorktreeIntegrationCheck.contentMerged, copyright (c) 2026 dufu, MIT.
    private func contentMerged(_ head: String,into target: String) -> Bool {
        guard let merged = try? run(["merge-tree","--write-tree","--no-messages",target,head]),
              let tree = try? revision(target+"^{tree}") else { return false }
        return merged.trimmingCharacters(in:.whitespacesAndNewlines) == tree
    }

    public func mergedWorktrees(into target: String) throws -> [GitWorktreeEntry] {
        try cleanupCandidates(into:target).filter { $0.ignored.isEmpty }.map(\.entry)
    }

    public func removeMergedWorktree(_ entry: GitWorktreeEntry,into target: String,expectedHead: String) throws {
        guard let candidate = try cleanupCandidates(into:target).first(where:{
            $0.entry.path == entry.path && $0.entry.branch == entry.branch && $0.head == expectedHead && $0.ignored.isEmpty
        }) else { throw GitError.command("This worktree changed after the cleanup preview.") }
        try removeCleanupCandidate(candidate,into:target,deleteBranch:false)
    }

    public func removeCleanupCandidate(_ candidate: CleanupCandidate,into target: String,deleteBranch: Bool) throws {
        try atWorktree(candidate.entry.path).withLockedHead(candidate.head) {
        guard let live = try cleanupCandidates(into:target).first(where:{
            $0.entry.path == candidate.entry.path && $0.entry.branch == candidate.entry.branch && $0.head == candidate.head
        }),Set(live.ignored).isSubset(of:Set(candidate.ignored)) else {
            throw GitError.command("This worktree changed after the cleanup preview.")
        }
        _ = try run(["worktree","remove","--",live.entry.path],timeout:60)
        }
        let live = candidate
        if deleteBranch,live.ancestor,!live.entry.branch.isEmpty,
           (try? revision("refs/heads/"+live.entry.branch)) == live.head,
           (try? run(["merge-base","--is-ancestor",live.head,"refs/heads/"+target])) != nil {
            // Git checks the merged state and any other checkout. Never force branch deletion.
            _ = try run(["branch","-d","--",live.entry.branch])
        }
    }

    public func worktreeDetail(_ entry: GitWorktreeEntry,against target: String) throws -> String {
        let repo = atWorktree(entry.path)
        let changes = try repo.changes()
        let staged = changes.filter(\.staged).count
        let unstaged = changes.filter { $0.unstaged && $0.index != "?" }.count
        let untracked = changes.filter { $0.index == "?" }.count
        let conflicts = changes.filter(\.conflicted).count
        var counts: [String] = ["Staged: \(staged)","Unstaged: \(unstaged)","Untracked: \(untracked)","Conflicts: \(conflicts)"]
        let comparison = target.isEmpty ? nil : try? repo.run(["rev-list","--left-right","--count","refs/heads/"+target+"...HEAD"])
        let sides = comparison?.split(whereSeparator:\.isWhitespace) ?? []
        if sides.count == 2 {
            counts.append("Ahead: "+String(sides[1]))
            counts.append("Behind: "+String(sides[0]))
        }
        return counts.joined(separator:" · ")
    }

    public func worktreeHead(_ entry: GitWorktreeEntry) throws -> String { try atWorktree(entry.path).revision("HEAD") }
}
