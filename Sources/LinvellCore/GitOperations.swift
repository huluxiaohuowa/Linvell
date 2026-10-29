import Foundation

public struct GitOperation {
    public let title: String
    public let template: [String]
    public let fields: [(String,String)]
    public let writes: Bool
    public init(_ title: String,_ template: [String],_ fields: [(String,String)] = [],writes: Bool = true) {
        self.title = title; self.template = template; self.fields = fields; self.writes = writes
    }
    public func arguments(_ values: [String:String]) throws -> [String] {
        try template.map { token in
            let value: String
            if token.hasPrefix("{"),token.hasSuffix("}") {
                let key = String(token.dropFirst().dropLast())
                guard let input = values[key],!input.isEmpty else { throw GitError.command("Complete every operation field.") }
                value = input
            } else { value = token }
            guard !value.contains("\0") else { throw GitError.invalidPath }; return value
        }
    }
    public static func customArguments(_ text: String) throws -> [String] {
        let arguments = try JSONDecoder().decode([String].self,from:Data(text.utf8))
        guard !arguments.isEmpty,arguments.allSatisfy({ !$0.contains("\0") }) else { throw GitError.invalidPath }
        return arguments
    }
    public static let all: [GitOperation] = [
        .init("Status",["status","--short","--branch"],writes:false),
        .init("Stage All",["add","--all"]),
        .init("Commit",["commit","-m","{Message}"],[("Message","")]),
        .init("Amend Commit",["commit","--amend","-m","{Message}"],[("Message","")]),
        .init("Create Branch",["branch","{Name}","{Revision}"],[("Name",""),("Revision","HEAD")]),
        .init("Switch Branch",["switch","{Branch}"],[("Branch","")]),
        .init("Rename Branch",["branch","-m","{Name}"],[("Name","")]),
        .init("Delete Merged Branch",["branch","-d","{Branch}"],[("Branch","")]),
        .init("Merge",["merge","--no-edit","{Revision}"],[("Revision","")]),
        .init("Abort Merge",["merge","--abort"]),
        .init("Continue Merge",["-c","core.editor=true","merge","--continue"]),
        .init("Rebase",["rebase","{Revision}"],[("Revision","")]),
        .init("Continue Rebase",["-c","core.editor=true","rebase","--continue"]),
        .init("Skip Rebase Commit",["rebase","--skip"]),
        .init("Abort Rebase",["rebase","--abort"]),
        .init("Cherry Pick",["cherry-pick","{Revision}"],[("Revision","")]),
        .init("Continue Cherry Pick",["-c","core.editor=true","cherry-pick","--continue"]),
        .init("Abort Cherry Pick",["cherry-pick","--abort"]),
        .init("Revert Commit",["revert","--no-edit","{Revision}"],[("Revision","")]),
        .init("Continue Revert",["-c","core.editor=true","revert","--continue"]),
        .init("Abort Revert",["revert","--abort"]),
        .init("Reset — Keep Files Staged",["reset","--soft","{Revision}"],[("Revision","HEAD~1")]),
        .init("Reset — Keep Working Files",["reset","--mixed","{Revision}"],[("Revision","HEAD~1")]),
        .init("Reset — Discard Working Changes",["reset","--hard","{Revision}"],[("Revision","HEAD")]),
        .init("Restore File",["restore","--worktree","--","{Path}"],[("Path","")]),
        .init("Use Current Side",["checkout","--ours","--","{Path}"],[("Path","")]),
        .init("Use Incoming Side",["checkout","--theirs","--","{Path}"],[("Path","")]),
        .init("Mark Conflict Resolved",["add","--","{Path}"],[("Path","")]),
        .init("Preview Untracked Cleanup",["clean","-nd"],writes:false),
        .init("Remove Untracked Files",["clean","-fd"]),
        .init("Stash Changes",["stash","push","--include-untracked","-m","{Message}"],[("Message","Linvell stash")]),
        .init("List Stashes",["stash","list"],writes:false),
        .init("Show Stash",["stash","show","--patch","{Stash}"],[("Stash","stash@{0}")],writes:false),
        .init("Apply Stash",["stash","apply","{Stash}"],[("Stash","stash@{0}")]),
        .init("Pop Stash",["stash","pop","{Stash}"],[("Stash","stash@{0}")]),
        .init("Drop Stash",["stash","drop","{Stash}"],[("Stash","stash@{0}")]),
        .init("List Tags",["tag","--list"],writes:false),
        .init("Create Tag",["tag","{Name}","{Revision}"],[("Name",""),("Revision","HEAD")]),
        .init("Delete Tag",["tag","-d","{Name}"],[("Name","")]),
        .init("List Remotes",["remote","-v"],writes:false),
        .init("Add Remote",["remote","add","{Name}","{URL}"],[("Name","origin"),("URL","")]),
        .init("Change Remote URL",["remote","set-url","{Name}","{URL}"],[("Name","origin"),("URL","")]),
        .init("Rename Remote",["remote","rename","{Name}","{New Name}"],[("Name","origin"),("New Name","")]),
        .init("Remove Remote",["remote","remove","{Name}"],[("Name","")]),
        .init("Fetch All Remotes",["fetch","--all","--prune"]),
        .init("Pull — Fast Forward",["pull","--ff-only"]),
        .init("Pull — Rebase",["pull","--rebase"]),
        .init("Push",["push"]),
        .init("Push With Upstream",["push","--set-upstream","{Remote}","{Branch}"],[("Remote","origin"),("Branch","")]),
        .init("Push Tags",["push","{Remote}","--tags"],[("Remote","origin")]),
        .init("Reflog",["reflog","--date=iso","-n","200"],writes:false),
        .init("List Worktrees",["worktree","list","--porcelain"],writes:false),
        .init("Add Worktree",["worktree","add","{Path}","{Branch}"],[("Path",""),("Branch","")]),
        .init("Move Worktree",["worktree","move","{Path}","{Destination}"],[("Path",""),("Destination","")]),
        .init("Remove Clean Worktree",["worktree","remove","{Path}"],[("Path","")]),
        .init("Lock Worktree",["worktree","lock","{Path}"],[("Path","")]),
        .init("Unlock Worktree",["worktree","unlock","{Path}"],[("Path","")]),
        .init("Prune Worktrees",["worktree","prune"]),
        .init("Submodule — Status",["submodule","status","--recursive"],writes:false),
        .init("Submodule — Initialize",["submodule","init","--","{Path}"],[("Path","")]),
        .init("Submodule — Deinitialize",["submodule","deinit","--","{Path}"],[("Path","")]),
        .init("Submodule — Update Recorded Commit",["submodule","update","--init","--recursive","--checkout","--","{Path}"],[("Path","")]),
        .init("Submodule — Update With Merge",["submodule","update","--init","--recursive","--merge","--","{Path}"],[("Path","")]),
        .init("Submodule — Update With Rebase",["submodule","update","--init","--recursive","--rebase","--","{Path}"],[("Path","")]),
        .init("Submodule — Sync All URLs",["submodule","sync","--recursive"]),
        .init("Submodule — Summary",["submodule","summary","--files"],writes:false),
        .init("Submodule — Absorb Git Directories",["submodule","absorbgitdirs","--","{Path}"],[("Path","")]),
        .init("Submodule — Run In Each Repository",["submodule","foreach","--recursive","{Command}"],[("Command","git status --short")]),
    ]
}
