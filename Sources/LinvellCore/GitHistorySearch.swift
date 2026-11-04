import Foundation

public struct GitHistorySearchPage {
    public let commits: [GitCommit]
    public let nextOffset: Int?
}

extension GitRepository {
    /// Scan bounded batches across all local refs, independent of the graph's scope and loaded rows.
    public func searchHistory(_ query: String,offset: Int = 0,limit: Int = 100,
                              isCancelled: () -> Bool = { false }) throws -> GitHistorySearchPage {
        precondition(limit > 0 && offset >= 0)
        var cursor = offset
        var matches: [GitCommit] = []
        let batchSize = 250
        while !isCancelled() {
            let batch = try history(limit:batchSize,offset:cursor,includeMessage:true)
            for commit in batch {
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
