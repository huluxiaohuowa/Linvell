import Foundation

public struct GitHistorySearchPage {
    public let commits: [GitCommit]
    public let nextOffset: Int?
}

extension GitRepository {
    /// Scan bounded batches across all local refs, independent of the graph's scope and loaded rows.
    public func searchHistory(_ query: String,offset: Int = 0,limit: Int = 100,
                              index: GitHistoryIndex? = nil,isCancelled: () -> Bool = { false }) throws -> GitHistorySearchPage {
        precondition(limit > 0 && offset >= 0)
        var cursor = offset
        var matches: [GitCommit] = []
        let batchSize = 250
        while !isCancelled() {
            let start = cursor / batchSize * batchSize
            func load() throws -> [GitCommit] { try history(limit:batchSize,offset:start,includeMessage:true) }
            let batch = try index?.batch(scope:journalScope,at:start,load:load) ?? load()
            for commit in batch.dropFirst(cursor-start) {
                cursor += 1
                if [commit.hash,commit.author,commit.email,commit.message,commit.refs].contains(where:{ $0.localizedStandardContains(query) }) {
                    matches.append(commit)
                    if matches.count == limit { return GitHistorySearchPage(commits:matches,nextOffset:cursor) }
                }
            }
            if batch.count < batchSize { return GitHistorySearchPage(commits:matches,nextOffset:nil) }
        }
        throw CancellationError()
    }
}

/// A workspace keeps one index for its current repository snapshot.
public final class GitHistoryIndex: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var batches: [String:[Int:[GitCommit]]] = [:]

    fileprivate func batch(scope: String,at offset: Int,load: () throws -> [GitCommit]) rethrows -> [GitCommit] {
        lock.lock()
        let cached = batches[scope]?[offset]
        lock.unlock()
        if let cached { return cached }
        let commits = try load()
        lock.lock()
        batches[scope,default:[:]][offset] = commits
        lock.unlock()
        return commits
    }
}
