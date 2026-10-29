import Foundation

/// Names and paths only. File reads and conflict-checked writes never use this cache.
public final class RemoteDirectoryCache {
    public static let shared = RemoteDirectoryCache()
    private struct Key: Hashable { let host: String; let path: String }
    private struct Record { let reply: RemoteReply; let date: Date; var access: UInt64 }
    private let condition = NSCondition()
    private var records: [Key: Record] = [:]
    private var pending: Set<Key> = []
    private var revision: UInt64 = 0
    private var clock: UInt64 = 0
    private let lifetime: TimeInterval
    private let maximumDirectories: Int
    private let maximumEntries: Int
    public init(lifetime: TimeInterval = 30,maximumDirectories: Int = 128,maximumEntries: Int = 50_000) {
        self.lifetime = lifetime; self.maximumDirectories = maximumDirectories; self.maximumEntries = maximumEntries
    }
    public func snapshot(host: String,path: String) -> RemoteReply? {
        condition.lock(); defer { condition.unlock() }
        let key = Key(host:host,path:path)
        guard var record = records[key] else { return nil }
        clock &+= 1; record.access = clock; records[key] = record
        return record.reply
    }
    public func invalidate(host: String) {
        condition.lock(); defer { condition.unlock() }
        records = records.filter { $0.key.host != host }; revision &+= 1
    }
    public func list(host: String,path: String,force: Bool = false,load: () throws -> RemoteReply) throws -> RemoteReply {
        let key = Key(host:host,path:path)
        condition.lock()
        while pending.contains(key) { condition.wait() }
        if !force,let record = records[key],Date().timeIntervalSince(record.date) < lifetime {
            clock &+= 1; records[key]?.access = clock
            condition.unlock(); return record.reply
        }
        let started = revision
        pending.insert(key); condition.unlock()
        let result = Result { try load() }
        condition.lock()
        if case .success(let reply) = result,started == revision {
            clock &+= 1
            let record = Record(reply:reply,date:Date(),access:clock)
            records[key] = record
            if let canonical = reply.path { records[Key(host:host,path:canonical)] = record }
            while records.count > maximumDirectories || records.values.reduce(0,{ $0 + ($1.reply.entries?.count ?? 0) }) > maximumEntries {
                guard let oldest = records.min(by:{ $0.value.access < $1.value.access })?.key else { break }
                records.removeValue(forKey:oldest)
            }
        }
        pending.remove(key); condition.broadcast(); condition.unlock()
        return try result.get()
    }
}

extension SSHRemote {
    public func cachedDirectory(_ path: String) -> RemoteReply? { RemoteDirectoryCache.shared.snapshot(host:host,path:path) }
    public func listDirectory(_ path: String,force: Bool = false) throws -> RemoteReply {
        try RemoteDirectoryCache.shared.list(host:host,path:path,force:force) { try request("list",path:path) }
    }
}
