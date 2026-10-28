import Foundation

public struct GitGraphRow {
    public struct Edge { public let from: Int; public let to: Int; public let hash: String }
    public let lane: Int
    public let incoming: Bool
    public let upper: [Edge]
    public let lower: [Edge]
    public let width: Int
}
public enum GitGraph {
    public static func layout(_ commits: [GitCommit]) -> [GitGraphRow] {
        var active: [String] = []
        return commits.map { commit in
            let before = active
            if !active.contains(commit.hash) { active.append(commit.hash) }
            let lane = active.firstIndex(of:commit.hash)!
            active.remove(at:lane)
            for (offset,parent) in commit.parents.enumerated() where !active.contains(parent) { active.insert(parent,at:min(lane+offset,active.count)) }
            var upper: [GitGraphRow.Edge] = [],lower: [GitGraphRow.Edge] = []
            for (index,hash) in before.enumerated() {
                if hash == commit.hash { upper.append(.init(from:index,to:lane,hash:hash)) }
                else if let bottom = active.firstIndex(of:hash) {
                    upper.append(.init(from:index,to:index,hash:hash)); lower.append(.init(from:index,to:bottom,hash:hash))
                }
            }
            for parent in commit.parents { if let bottom = active.firstIndex(of:parent) { lower.append(.init(from:lane,to:bottom,hash:parent)) } }
            return GitGraphRow(lane:lane,incoming:before.contains(commit.hash),upper:upper,lower:lower,width:max(lane+1,max(before.count,active.count)))
        }
    }
}
