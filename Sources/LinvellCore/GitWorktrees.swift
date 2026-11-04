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

    public func finishWorktree(_ entry: GitWorktreeEntry,into target: String) throws {
        let liveEntries = try worktrees()
        guard !target.isEmpty,!entry.branch.isEmpty,entry.path != directory,
              liveEntries.first?.path != entry.path,
              liveEntries.contains(where:{ $0.path == entry.path && $0.branch == entry.branch && !$0.locked && !$0.prunable }),
              try changes().isEmpty,
              try run(["branch","--show-current"]).trimmingCharacters(in:.whitespacesAndNewlines) == target,
              try run(["-C",entry.path,"status","--porcelain=v1","--untracked-files=all"]).isEmpty else {
            throw GitError.command("Both worktrees must be clean and on the selected branches.")
        }
        let source = try run(["-C",entry.path,"rev-parse","HEAD"]).trimmingCharacters(in:.whitespacesAndNewlines)
        _ = try run(["merge","--ff-only","--",source],timeout:120)
        do {
            let liveSource = try run(["-C",entry.path,"rev-parse","HEAD"]).trimmingCharacters(in:.whitespacesAndNewlines)
            guard source == liveSource else { throw GitError.command("The source worktree advanced during the merge.") }
            _ = try run(["worktree","remove","--",entry.path],timeout:60)
        } catch {
            throw GitError.command("The branch was fast-forwarded. The worktree was kept. "+error.localizedDescription)
        }
    }
}
