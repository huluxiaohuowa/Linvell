import Foundation

public enum GitReviewRevision: Equatable {
    case commit(String),workingTree
}

extension GitRepository {
    struct RevisionChange { let status: String; let old: String; let new: String }
    func revisionChanges(_ arguments: [String]) throws -> [RevisionChange] {
        let records = try run(["diff","--name-status","-z","--find-renames","--no-ext-diff"]+arguments+["--"]).components(separatedBy:"\0")
        var result: [RevisionChange] = [],index = 0
        while index+1 < records.count,!records[index].isEmpty {
            let status = records[index],old = records[index+1]
            let rename = status.hasPrefix("R") || status.hasPrefix("C")
            guard !rename || index+2 < records.count else { throw GitError.command("Invalid changed paths from Git.") }
            result.append(.init(status:status,old:old,new:rename ? records[index+2] : old)); index += rename ? 3 : 2
        }
        return result
    }
    func revisionPatch(_ base: String,_ target: String,path: String) throws -> String {
        let left = try resolvedRevision(base),right = try resolvedRevision(target),path = try checked(path)
        let change = try revisionChanges([left,right]).first { $0.new == path || $0.old == path }
        let paths = change.map { Array(Set([$0.old,$0.new])).sorted() } ?? [path]
        return try run(["diff","--no-ext-diff","--no-textconv","--full-index","--find-renames",left,right,"--"]+paths)
    }
    private func comparisonArguments(_ base: GitReviewRevision,_ target: GitReviewRevision) throws -> [String] {
        switch (base,target) {
        case (.commit(let a),.commit(let b)): return try [resolvedRevision(a),resolvedRevision(b)]
        case (.commit(let a),.workingTree): return try [resolvedRevision(a)]
        case (.workingTree,.commit(let b)): return try ["-R",resolvedRevision(b)]
        case (.workingTree,.workingTree): return []
        }
    }
    public func comparisonPaths(base: GitReviewRevision,target: GitReviewRevision) throws -> [String] {
        guard base != target else { return [] }
        let changes = try revisionChanges(comparisonArguments(base,target))
        var paths = changes.map(\.new)
        if base == .workingTree || target == .workingTree {
            paths += try run(["ls-files","--others","--exclude-standard","-z"]).split(separator:"\0").map(String.init)
        }
        return Array(Set(paths)).sorted()
    }
    public func comparisonPatch(base: GitReviewRevision,target: GitReviewRevision,path: String) throws -> String {
        guard base != target else { return "" }
        let args = try comparisonArguments(base,target),path = try checked(path)
        let change = try revisionChanges(args).first { $0.new == path || $0.old == path }
        if change == nil,(base == .workingTree || target == .workingTree),
           try run(["ls-files","--others","--exclude-standard","-z","--",path]).split(separator:"\0").contains(Substring(path)) {
            try validateDiffFile(path)
            return try run(["diff","--no-index","--no-ext-diff","--no-textconv","--full-index"]+(base == .workingTree ? ["-R"] : [])+["--","/dev/null",path])
        }
        let paths = change.map { Array(Set([$0.old,$0.new])).sorted() } ?? [path]
        return try run(["diff","--no-ext-diff","--no-textconv","--full-index","--find-renames"]+args+["--"]+paths)
    }
    public func comparisonStat(base: GitReviewRevision,target: GitReviewRevision) throws -> GitDiffStat {
        guard base != target else { return GitDiffStat(numstat:"") }
        var records = try run(["diff","--numstat","-z","--no-ext-diff","--no-textconv"]+comparisonArguments(base,target)+["--"])
        if base == .workingTree || target == .workingTree {
            let paths = try run(["ls-files","--others","--exclude-standard","-z"]).split(separator:"\0").map(String.init)
            for path in paths {
                try validateDiffFile(path)
                records += try run(["diff","--no-index","--numstat","-z"]+(base == .workingTree ? ["-R"] : [])+["--","/dev/null",path])
            }
        }
        return GitDiffStat(numstat:records)
    }
    public func comparisonImages(base: GitReviewRevision,target: GitReviewRevision,path: String) throws -> (Data?,Data?) {
        if case .commit(let left) = base,case .commit(let right) = target { return try revisionImages(left,right,path:path) }
        let change = try revisionChanges(comparisonArguments(base,target)).first { $0.new == path || $0.old == path }
        func data(_ revision: GitReviewRevision,_ path: String,absent: Bool) throws -> Data? {
            if absent { return nil }
            switch revision {
            case .commit(let ref): return try? blobData(resolvedRevision(ref),path:path)
            case .workingTree: return try? workingFileData(path,largeFile:true)
            }
        }
        return try (data(base,change?.old ?? path,absent:change?.status.hasPrefix("A") == true),data(target,change?.new ?? path,absent:change?.status.hasPrefix("D") == true))
    }
    public func commitDetails(_ revision: String) throws -> GitCommit {
        let hash = try resolvedRevision(revision)
        let format = "%H%x00%P%x00%an%x00%ae%x00%ad%x00%s%x00%D%x00%B%x00"
        let fields = try run(["show","--no-patch","--date=iso-strict","--format="+format,hash,"--"]).components(separatedBy:"\0")
        guard fields.count >= 8 else { throw GitError.command("Invalid commit records from Git.") }
        return .init(hash:hash,parents:fields[1].split(separator:" ").map(String.init),author:fields[2],email:fields[3],date:fields[4],subject:fields[5],message:fields[7],refs:fields[6])
    }
    public func introducingMerge(_ revision: String) throws -> GitCommit? {
        let hash = try resolvedRevision(revision)
        let candidates = try run(["rev-list","--ancestry-path","--merges","--reverse",hash+"..HEAD","--"]).split(whereSeparator:\.isNewline)
        for candidate in candidates {
            let commit = try commitDetails(String(candidate))
            guard let first = commit.parents.first else { continue }
            if (try? run(["merge-base","--is-ancestor",hash,first])) == nil { return commit }
        }
        return nil
    }
}

extension GitRepository {
    private func uncommittedBase() throws -> String {
        if let head = try? resolvedRevision("HEAD") { return head }
        // Materialize Git's format-correct empty tree, including SHA-256 repositories.
        return try run(["hash-object","-t","tree","-w","--stdin"],input:Data()).trimmingCharacters(in:.newlines)
    }
    public func uncommittedPatch() throws -> String {
        let base = try uncommittedBase()
        var patch = try run(["diff","--no-ext-diff","--no-textconv","--full-index","--find-renames",base,"--"])
        let untracked = try run(["ls-files","--others","--exclude-standard","-z"]).split(separator:"\0").map(String.init)
        for path in untracked {
            try validateDiffFile(path)
            patch += try run(["diff","--no-index","--no-ext-diff","--no-textconv","--full-index","--","/dev/null",path])
        }
        return patch
    }
    public func uncommittedStat() throws -> GitDiffStat {
        let base = try uncommittedBase()
        var records = try run(["diff","--numstat","-z","--no-ext-diff","--no-textconv",base,"--"])
        let untracked = try run(["ls-files","--others","--exclude-standard","-z"]).split(separator:"\0").map(String.init)
        for path in untracked {
            try validateDiffFile(path)
            records += try run(["diff","--no-index","--numstat","-z","--","/dev/null",path])
        }
        return GitDiffStat(numstat:records)
    }
}
