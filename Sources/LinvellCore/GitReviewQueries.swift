import Foundation

extension GitRepository {
    public func changedPaths(in hash: String) throws -> [String] {
        guard [40,64].contains(hash.count),hash.allSatisfy(\.isHexDigit) else { throw GitError.invalidPath }
        return try run(["show","--format=","--first-parent","--name-only","-z",hash,"--"])
            .split(separator:"\0").map(String.init)
    }

    public func fileHistory(_ path: String,limit: Int = 100,offset: Int = 0) throws -> [GitCommit] {
        try history(allRefs:false,limit:limit,offset:offset,path:path)
    }

    public func setFolderStaged(_ folder: String,staged: Bool) throws {
        let prefix = folder+"/"
        let matching = try changes().filter { change in
            [change.path,change.originalPath].compactMap { $0 }.contains { $0.hasPrefix(prefix) }
                && (staged ? change.unstaged : change.staged)
        }
        guard !matching.contains(where:\.conflicted) else { throw GitError.command("Resolve conflicts before staging a folder.") }
        let paths = Set(matching.flatMap { [$0.path,$0.originalPath].compactMap { $0 } }).sorted()
        guard !paths.isEmpty else { return }
        let input = Data((paths.joined(separator:"\0")+"\0").utf8)
        if staged {
            _ = try run(["add","--pathspec-from-file=-","--pathspec-file-nul"],input:input)
        } else if (try? run(["rev-parse","--verify","HEAD"])) != nil {
            _ = try run(["restore","--staged","--pathspec-from-file=-","--pathspec-file-nul"],input:input)
        } else {
            _ = try run(["rm","--cached","-f","--pathspec-from-file=-","--pathspec-file-nul"],input:input)
        }
    }
}
