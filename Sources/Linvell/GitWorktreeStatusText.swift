import Foundation

/// Core status facts remain host-independent; localize their labels at the UI boundary.
enum GitWorktreeStatusText {
    static func localized(_ text: String) -> String {
        text.components(separatedBy:" · ").map { fact in
            for prefix in ["Staged: ","Unstaged: ","Untracked: ","Conflicts: "] where fact.hasPrefix(prefix) {
                return L.format(prefix+"%@",String(fact.dropFirst(prefix.count)))
            }
            for (prefix,key) in [("Ahead of ","Ahead of %@: %@"),("Behind ","Behind %@: %@")] where fact.hasPrefix(prefix) {
                let fields = String(fact.dropFirst(prefix.count)).components(separatedBy:": ")
                if fields.count == 2 { return L.format(key,fields[0],fields[1]) }
            }
            for (prefix,key) in [("Merged into ","Merged into %@"),("Not merged into ","Not merged into %@")] where fact.hasPrefix(prefix) { return L.format(key,String(fact.dropFirst(prefix.count))) }
            let prefix = "Changes already in ",suffix = " (squash or rebase merge)"
            if fact.hasPrefix(prefix),fact.hasSuffix(suffix) { return L.format("Changes already in %@ (squash or rebase merge)",String(fact.dropFirst(prefix.count).dropLast(suffix.count))) }
            return L.text(fact)
        }.joined(separator:" · ")
    }
}
