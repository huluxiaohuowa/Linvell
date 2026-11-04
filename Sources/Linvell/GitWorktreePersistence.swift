import Foundation
import LinvellCore

/// Moves application metadata only after Git has moved the worktree. Removed worktree
/// task/review records remain historical records; no user snapshots are deleted.
enum GitWorktreePersistence {
    static func relocate(_ location: WorkspaceSession,to path: String?,support: URL = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Linvell")) throws {
        guard let path else { return }
        let old = location.path
        let host: String?; switch location { case .local: host = nil; case .ssh(let value,_): host = value }
        let reviews = support.appendingPathComponent("Reviews",isDirectory:true)
        let from = ReviewCommentStore(project:old,host:host,directory:reviews).file,to = ReviewCommentStore(project:path,host:host,directory:reviews).file
        if from != to,FileManager.default.fileExists(atPath:from.path) {
            let values = try JSONSerialization.jsonObject(with:Data(contentsOf:from)) as? [[String:Any]] ?? []
            var destination = FileManager.default.fileExists(atPath:to.path) ? try JSONSerialization.jsonObject(with:Data(contentsOf:to)) as? [[String:Any]] ?? [] : []
            var ids = Set(destination.compactMap { $0["id"] as? String })
            for var value in values {
                for key in ["path","originalPath"] { if let previous = value[key] as? String,previous == old || previous.hasPrefix(old+"/") { value[key] = path+String(previous.dropFirst(old.count)) } }
                if let id = value["id"] as? String,ids.insert(id).inserted { destination.append(value) }
            }
            try write(destination,to:to); try FileManager.default.removeItem(at:from)
        }
        guard host == nil else { return }
        try AgentTaskStore(directory:support.appendingPathComponent("Tasks",isDirectory:true)).relocateWorktree(from:old,to:path)
    }

    private static func write(_ value: Any,to file: URL) throws {
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
}
