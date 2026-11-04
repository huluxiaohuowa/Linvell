import Foundation

public struct GitDiffStat: Equatable {
    public private(set) var files = 0
    public private(set) var insertions = 0
    public private(set) var deletions = 0
    public private(set) var binaryFiles = 0
    public init(numstat: String) {
        let records = numstat.split(separator:"\0",omittingEmptySubsequences:false)
        var index = 0
        while index < records.count {
            let parts = records[index].split(separator:"\t",maxSplits:2,omittingEmptySubsequences:false)
            index += 1
            guard parts.count == 3 else { continue }
            files += 1
            if let added = Int(parts[0]),let removed = Int(parts[1]) { insertions += added; deletions += removed }
            else { binaryFiles += 1 }
            if parts[2].isEmpty { index += 2 } // With -z, renames have two following path records.
        }
    }
}

extension GitRepository {
    public func stagedStat() throws -> GitDiffStat {
        GitDiffStat(numstat:try run(["diff","--cached","--numstat","-z","--no-ext-diff","--no-textconv","--"]))
    }
}
