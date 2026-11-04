import Foundation

public struct GitWorktreeEntry {
    public let path: String
    public private(set) var branch = ""
    public private(set) var locked = false
    public private(set) var prunable = false
    public private(set) var lockReason = ""
    public private(set) var pruneReason = ""

    public static func parse(_ output: String) -> [Self] {
        var entries: [Self] = []
        for field in output.split(separator:"\0") {
            if field.hasPrefix("worktree ") { entries.append(Self(path:String(field.dropFirst(9)))) }
            else if let index = entries.indices.last {
                if field.hasPrefix("branch refs/heads/") { entries[index].branch = String(field.dropFirst(18)) }
                if field == "locked" || field.hasPrefix("locked ") { entries[index].locked = true; entries[index].lockReason = String(field.dropFirst(min(field.count,7))) }
                if field == "prunable" || field.hasPrefix("prunable ") { entries[index].prunable = true; entries[index].pruneReason = String(field.dropFirst(min(field.count,9))) }
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
        let plan = try prepareWorktreeFinish(entry,into:target)
        if let pending = try mergeWorktree(plan) {
            return GitWorktreeMerge(source:pending.source,sourceCommit:pending.sourceCommit,targetBranch:pending.targetBranch,
                                    destination:pending.destination,removeAfterMerge:removeSource,deleteBranchAfterMerge:deleteBranch)
        }
        try cleanupWorktreeFinish(plan,removeFolder:removeSource,deleteBranch:deleteBranch)
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

    public var pending: Bool {
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
        try requireIntegrated()
        try removeSource()
    }

    public func continueWithoutCleanup() throws {
        try requirePending()
        guard try conflicts().isEmpty,try destination.run(["diff","--name-only","-z"]).isEmpty else { throw GitError.command("Resolve all conflicts before continuing.") }
        _ = try destination.run(["-c","core.editor=true","merge","--continue"],timeout:120)
        try requireIntegrated()
    }

    public func requireIntegrated() throws {
        guard !pending,try destination.currentBranch() == targetBranch else { throw GitError.command("The target branch changed or a merge is still in progress.") }
        _ = try destination.run(["merge-base","--is-ancestor",sourceCommit,"refs/heads/"+targetBranch])
    }

    fileprivate func removeSource() throws {
        guard removeAfterMerge else { return }
        do {
            let sourceRepo = destination.atWorktree(source.path)
            try sourceRepo.withLockedHead(sourceCommit) {
            guard try destination.currentBranch() == targetBranch,
                  try sourceRepo.currentBranch() == source.branch,
                  try sourceRepo.revision("HEAD") == sourceCommit,
                  try sourceRepo.run(["status","--porcelain=v1","--untracked-files=all","--ignored=matching"]).isEmpty,
                  try !sourceRepo.hasPendingWorktreeOperation(),
                  try destination.worktrees().contains(where:{ $0.path == source.path && !$0.locked && !$0.prunable }) else {
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
        if try repo.hasPendingWorktreeOperation() { return "In Progress" }
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
        let trunk = try resolvedTrunk(preferred:target)
        guard !trunk.references.isEmpty else { return [] }
        let targetHeads = try trunk.references.map { try revision($0) }
        return try worktrees().dropFirst().compactMap { entry in
            guard entry.path != directory,entry.branch != trunk.localBranch,!entry.locked,!entry.prunable else { return nil }
            let source = atWorktree(entry.path)
            guard let head = try? source.revision("HEAD"),
                  (try? source.worktreeState(entry)) == "Clean",
                  let ignored = try? source.run(["ls-files","-z","--others","--ignored","--exclude-standard"]) else { return nil }
            let ancestor = targetHeads.contains { (try? run(["merge-base","--is-ancestor",head,$0])) != nil }
            guard ancestor || targetHeads.contains(where:{ contentMerged(head,into:$0) }) else { return nil }
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

    public enum CleanupBranchOutcome {
        case kept, deleted, detached, keptContentMerged, keptChanged, failed(String)
    }

    @discardableResult
    public func removeCleanupCandidate(_ candidate: CleanupCandidate,into target: String,deleteBranch: Bool) throws -> CleanupBranchOutcome {
        try atWorktree(candidate.entry.path).withLockedHead(candidate.head) {
        guard let live = try cleanupCandidates(into:target).first(where:{
            $0.entry.path == candidate.entry.path && $0.entry.branch == candidate.entry.branch && $0.head == candidate.head
        }),Set(live.ignored).isSubset(of:Set(candidate.ignored)) else {
            throw GitError.command("This worktree changed after the cleanup preview.")
        }
        _ = try run(["worktree","remove","--",live.entry.path],timeout:60)
        }
        let live = candidate
        guard !live.entry.branch.isEmpty else { return .detached }
        guard deleteBranch else { return .kept }
        guard live.ancestor else { return .keptContentMerged }
        guard (try? revision("refs/heads/"+live.entry.branch)) == live.head,
              try resolvedTrunk(preferred:target).references.contains(where:{ (try? run(["merge-base","--is-ancestor",live.head,$0])) != nil }) else { return .keptChanged }
        do {
            _ = try run(["branch","-d","--",live.entry.branch])
            return .deleted
        } catch { return .failed(error.localizedDescription) }
    }

    public func worktreeDetail(_ entry: GitWorktreeEntry,against target: String) throws -> String {
        let repo = atWorktree(entry.path)
        let changes = try repo.changes()
        let staged = changes.filter(\.staged).count
        let unstaged = changes.filter { $0.unstaged && $0.index != "?" }.count
        let untracked = changes.filter { $0.index == "?" }.count
        let conflicts = changes.filter(\.conflicted).count
        var counts: [String] = ["Staged: \(staged)","Unstaged: \(unstaged)","Untracked: \(untracked)","Conflicts: \(conflicts)"]
        let trunk = try resolvedTrunk(preferred:target)
        let trees = try worktrees()
        let reference = trees.first?.path == entry.path || entry.branch == trunk.localBranch
            ? (try? repo.run(["rev-parse","--symbolic-full-name","@{upstream}"]).trimmingCharacters(in:.newlines)) ?? trunk.comparison
            : trunk.comparison
        let comparison = reference.flatMap { try? repo.run(["rev-list","--left-right","--count",$0+"...HEAD"]) }
        let sides = comparison?.split(whereSeparator:\.isWhitespace) ?? []
        if sides.count == 2 {
            counts.append("Ahead of "+(reference ?? "")+": "+String(sides[1]))
            counts.append("Behind "+(reference ?? "")+": "+String(sides[0]))
        }
        if let operation = try repo.pendingWorktreeOperation() { counts.insert(operation,at:0) }
        if trees.first?.path != entry.path,entry.branch != trunk.localBranch {
            let head = try repo.revision("HEAD")
            let ref = entry.branch.isEmpty ? "HEAD" : "refs/heads/"+entry.branch
            let log = (try? repo.run(["log","--walk-reflogs","--format=%H","-n","200",ref,"--"]))?.split(whereSeparator:\.isNewline).map(String.init) ?? []
            if !log.isEmpty,log.allSatisfy({ $0 == head }) { counts.append("No commits since this worktree was created") }
            else if let integrated = trunk.references.first(where:{ (try? run(["merge-base","--is-ancestor",head,$0])) != nil }) { counts.append("Merged into "+integrated) }
            else if let integrated = trunk.references.first(where:{ contentMerged(head,into:$0) }) { counts.append("Changes already in "+integrated+" (squash or rebase merge)") }
            else if let reference { counts.append("Not merged into "+reference) }
        }
        return counts.joined(separator:" · ")
    }

    public func worktreeHead(_ entry: GitWorktreeEntry) throws -> String { try atWorktree(entry.path).revision("HEAD") }
}

/// Native adaptation of FoldGit's review → merge → cleanup workflow (dufu, MIT).
public struct GitWorktreeCompletionPlan {
    public let merge: GitWorktreeMerge
    public let targetCommit: String
    public let originalTargetBranch: String
    public let commitCount: Int
    public var switchesBranch: Bool { originalTargetBranch != merge.targetBranch }
}

public struct GitTrunkReference {
    public let localBranch: String?
    public let references: [String]
    public let comparison: String?
}

extension GitRepository {
    public func metadataExists(_ name: String) throws -> Bool {
        let path = try run(["rev-parse","--path-format=absolute","--git-path",name]).trimmingCharacters(in:.newlines)
        if let remote { return (try? remote.request("read",path:path)) != nil || (try? remote.request("list",path:path)) != nil }
        return FileManager.default.fileExists(atPath:path)
    }
    public func hasPendingWorktreeOperation() throws -> Bool { try pendingWorktreeOperation() != nil }
    public func pendingWorktreeOperation() throws -> String? {
        for (name,title) in [("MERGE_HEAD","Merge in Progress"),("CHERRY_PICK_HEAD","Cherry-Pick in Progress"),("REVERT_HEAD","Revert in Progress"),("BISECT_LOG","Bisect in Progress"),("rebase-merge","Rebase in Progress"),("rebase-apply","Rebase in Progress")] {
            if try metadataExists(name) { return title }
        }
        if try metadataExists("sequencer") {
            let path = try run(["rev-parse","--path-format=absolute","--git-path","sequencer/todo"]).trimmingCharacters(in:.newlines)
            let text: String?
            if let remote { text = (try? remote.request("read",path:path).content).flatMap { $0 }.flatMap { Data(base64Encoded:$0) }.flatMap { String(data:$0,encoding:.utf8) } }
            else { text = try? String(contentsOfFile:path,encoding:.utf8) }
            return text?.hasPrefix("revert ") == true ? "Revert in Progress" : "Cherry-Pick in Progress"
        }
        return nil
    }
    public func resolvedTrunk(preferred: String = "") throws -> GitTrunkReference {
        let origin = (try? run(["for-each-ref","--format=%(symref)","refs/remotes/origin/HEAD"]).trimmingCharacters(in:.newlines)) ?? ""
        let primary = try worktrees().first?.branch ?? ""
        let short: (String) -> String = { value in
            for prefix in ["refs/heads/","refs/remotes/origin/","origin/"] where value.hasPrefix(prefix) { return String(value.dropFirst(prefix.count)) }
            return value
        }
        let names = [short(preferred),short(origin),"main","master",primary].filter { !$0.isEmpty }
        for name in names {
            let local = "refs/heads/"+name,remote = "refs/remotes/origin/"+name
            let localExists = (try? revision(local)) != nil
            var upstream: String?
            if localExists { upstream = (try? run(["for-each-ref","--format=%(upstream)",local]).trimmingCharacters(in:.newlines)) }
            if let value = upstream,value.isEmpty || (try? revision(value)) == nil { upstream = nil }
            if upstream == nil,(try? revision(remote)) != nil { upstream = remote }
            if localExists || upstream != nil {
                return GitTrunkReference(localBranch:localExists ? name : nil,references:([localExists ? local : nil,upstream].compactMap { $0 }),comparison:upstream ?? local)
            }
        }
        return GitTrunkReference(localBranch:nil,references:[],comparison:nil)
    }
    public func prepareWorktreeFinish(_ entry: GitWorktreeEntry,into target: String) throws -> GitWorktreeCompletionPlan {
        let trees = try worktrees()
        guard !target.isEmpty,!entry.branch.isEmpty,target != entry.branch,trees.first?.path != entry.path,
              trees.contains(where:{ $0.path == entry.path && $0.branch == entry.branch && !$0.prunable }) else {
            throw GitError.command("Choose a linked worktree on a different branch.")
        }
        let source = atWorktree(entry.path)
        guard try source.changes().isEmpty,!(try source.hasPendingWorktreeOperation()) else { throw GitError.command("Commit the source changes and finish its pending operation first.") }
        guard let targetTree = trees.first(where:{ $0.branch == target && !$0.prunable }) ?? trees.first(where:{ $0.path != entry.path && !$0.prunable }) else {
            throw GitError.command("Another worktree is required for the target branch.")
        }
        let destination = atWorktree(targetTree.path)
        let sourceCommit = try source.revision("HEAD"),targetCommit = try revision("refs/heads/"+target)
        let merge = GitWorktreeMerge(source:entry,sourceCommit:sourceCommit,targetBranch:target,destination:destination,removeAfterMerge:false,deleteBranchAfterMerge:false)
        guard try merge.pending || (destination.changes().isEmpty && !destination.hasPendingWorktreeOperation()) else { throw GitError.command("The target worktree must be clean and have no pending operation.") }
        return GitWorktreeCompletionPlan(merge:merge,targetCommit:targetCommit,originalTargetBranch:try destination.currentBranch(),
            commitCount:Int(try run(["rev-list","--count",targetCommit+".."+sourceCommit]).trimmingCharacters(in:.newlines)) ?? 0)
    }
    public func mergeWorktree(_ plan: GitWorktreeCompletionPlan) throws -> GitWorktreeMerge? {
        let merge = plan.merge,source = atWorktree(merge.source.path),destination = merge.destination
        guard try source.currentBranch() == merge.source.branch,try source.revision("HEAD") == merge.sourceCommit,
              try source.changes().isEmpty,try !source.hasPendingWorktreeOperation() else { throw GitError.command("The source worktree changed after the review.") }
        if merge.pending { return merge }
        guard try destination.currentBranch() == plan.originalTargetBranch,
              try destination.revision("refs/heads/"+merge.targetBranch) == plan.targetCommit,
              try destination.changes().isEmpty,try !destination.hasPendingWorktreeOperation() else { throw GitError.command("The target changed after the review. Refresh and try again.") }
        if plan.switchesBranch { _ = try destination.run(["switch","--",merge.targetBranch]) }
        do { _ = try destination.run(["merge","--no-edit","--commit","--no-squash","--",merge.sourceCommit],timeout:120) }
        catch { if merge.pending { return merge }; throw error }
        try merge.requireIntegrated()
        return nil
    }
    public func cleanupWorktreeFinish(_ plan: GitWorktreeCompletionPlan,removeFolder: Bool,deleteBranch: Bool) throws {
        let merge = plan.merge,destination = merge.destination
        try merge.requireIntegrated()
        guard removeFolder else { return }
        if let live = try destination.worktrees().first(where:{ $0.path == merge.source.path }) {
            guard !live.locked,!live.prunable,live.branch == merge.source.branch else { throw GitError.command("The source worktree changed or is locked.") }
            let source = atWorktree(live.path)
            try source.withLockedHead(merge.sourceCommit) {
                guard try source.currentBranch() == live.branch,try source.changes().isEmpty,try !source.hasPendingWorktreeOperation() else { throw GitError.command("The source worktree changed after merging.") }
                _ = try destination.run(["worktree","remove","--",live.path],timeout:60)
            }
        }
        if deleteBranch,(try? destination.revision("refs/heads/"+merge.source.branch)) != nil {
            guard try destination.revision("refs/heads/"+merge.source.branch) == merge.sourceCommit else { throw GitError.command("The source branch changed. It was kept.") }
            _ = try destination.run(["branch","-d","--",merge.source.branch])
        }
    }
}
