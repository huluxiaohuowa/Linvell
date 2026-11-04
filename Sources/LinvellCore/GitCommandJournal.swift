import Foundation

/// Session diagnostics omit arguments and output, which may contain credentials or file contents.
public final class GitCommandJournal: @unchecked Sendable {
    public struct Entry {
        public let operation: UUID?
        public let date: Date
        public let command: String
        public let elapsed: TimeInterval
        public let succeeded: Bool
        public var readOnly = false
    }

    @TaskLocal public static var operation: UUID?
    public static let shared = GitCommandJournal()
    private let lock = NSLock()
    private var records: [String:[Entry]] = [:]

    func append(_ entry: Entry,scope: String) {
        lock.lock()
        defer { lock.unlock() }
        records[scope,default:[]].insert(entry,at:0)
        if records[scope,default:[]].count > 200 { records[scope]?.removeLast() }
    }

    public func clear(scope: String) {
        lock.lock(); defer { lock.unlock() }
        records.removeValue(forKey:scope)
    }

    public func entries(for scope: String) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return records[scope] ?? []
    }
}
