import Foundation

/// Owns only UUID-named update jobs, never arbitrary application or user folders.
public enum UpdateStaging {
    public static func owns(candidate: URL, in directory: URL) -> Bool {
        let root = candidate.deletingLastPathComponent().deletingLastPathComponent()
        return candidate.standardizedFileURL.path == root.appendingPathComponent("extracted/Linvell.app").standardizedFileURL.path
            && root.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
            && UUID(uuidString:root.deletingPathExtension().lastPathComponent) != nil
            && (try? root.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true
            && (try? candidate.deletingLastPathComponent().resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true
            && candidate.resolvingSymlinksInPath().path == candidate.standardizedFileURL.path
    }

    public static func remove(_ root: URL, in directory: URL) {
        guard root.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
              UUID(uuidString:root.deletingPathExtension().lastPathComponent) != nil,
              (try? root.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == false else { return }
        RollbackArchive.unregister(root.appendingPathComponent("extracted/Linvell.app"))
        try? FileManager.default.removeItem(at:root)
    }

    public static func prune(in directory: URL, keeping candidate: URL?, now: Date = Date()) {
        let fm = FileManager.default
        for root in (try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey,.isSymbolicLinkKey])) ?? [] {
            guard candidate?.standardizedFileURL.path != root.appendingPathComponent("extracted/Linvell.app").standardizedFileURL.path,
                  let modified = try? root.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > 24*60*60 else { continue }
            remove(root,in:directory)
        }
    }
}
