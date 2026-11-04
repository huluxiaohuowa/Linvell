import Foundation

extension GitRepository {
    public func changedPaths(in hash: String) throws -> [String] {
        guard [40,64].contains(hash.count),hash.allSatisfy(\.isHexDigit) else { throw GitError.invalidPath }
        return try run(["show","--format=","--first-parent","--find-renames","--name-only","-z",hash,"--"])
            .split(separator:"\0").map(String.init)
    }

    public func fileHistory(_ path: String,limit: Int = 100,offset: Int = 0) throws -> [GitCommit] {
        try fileHistoryEntries(path,limit:limit,offset:offset).map(\.commit)
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

extension GitRepository {
    public func reviewFiles() throws -> [String] {
        let output = try run(["ls-files","-z","--cached","--others","--exclude-standard"])
        return Set(output.split(separator:"\0").map(String.init)).sorted()
    }

    public func workingFilePreview(_ path: String,largeFile: Bool = false) throws -> String {
        try workingFilePreviewWithSize(path,largeFile:largeFile).text
    }

    public func workingFilePreviewWithSize(_ path: String,largeFile: Bool = false) throws -> (text: String,bytes: Int) {
        let data = try workingFileData(path,largeFile:largeFile)
        return (try GitPreviewText.decode(data,plain:largeFile),data.count)
    }

    func validateDiffFile(_ path: String) throws {
        let path = try checked(path)
        if let remote {
            _ = try remote.request("review-read",path:root.appendingPathComponent(path).path,digest:"diff",repositoryRoot:directory)
        } else {
            _ = try GitSourceReader.read(root:root,path:path,limit:16*1024*1024,allowSymbolicLink:true)
        }
    }

    public func workingFileData(_ path: String,largeFile: Bool = false) throws -> Data {
        let file = root.appendingPathComponent(try checked(path))
        let limit = largeFile ? 16*1024*1024 : 1_048_576
        let data: Data
        if let remote {
            let reply = try remote.request("review-read",path:file.path,digest:largeFile ? "large" : nil,repositoryRoot:directory)
            guard let encoded = reply.content,let decoded = Data(base64Encoded:encoded) else {
                throw GitError.command("The remote response is incomplete.")
            }
            data = decoded
        } else {
            data = try GitSourceReader.read(root:root,path:checked(path),limit:limit)
        }
        guard data.count <= limit else { throw GitError.command("File too large for a preview.") }
        return data
    }
}


extension GitRepository {
    public func resolvedRevision(_ ref: String) throws -> String {
        try run(["rev-parse","--verify","--end-of-options",ref+"^{commit}"]).trimmingCharacters(in:.newlines)
    }

    public func comparePaths(_ base: String,_ target: String) throws -> [String] {
        try run(["diff","--name-only","-z","--find-renames","--no-ext-diff",resolvedRevision(base),resolvedRevision(target),"--"])
            .split(separator:"\0").map(String.init)
    }

    public func comparisonPatch(_ base: String,_ target: String,path: String) throws -> String {
        try revisionPatch(base,target,path:path)
    }

    public func blobData(_ revision: String,path: String) throws -> Data {
        let path = try checked(path)
        guard revision == ":" || ([40,64].contains(revision.count) && revision.allSatisfy(\.isHexDigit)) else { throw GitError.invalidPath }
        let object = revision == ":" ? ":"+path : revision+":"+path
        return try objectData(object)
    }

    public func patchImages(_ patch: String) throws -> (Data?,Data?) {
        guard let line = patch.split(whereSeparator:\.isNewline).first(where:{ $0.hasPrefix("index ") }),
              let pair = line.split(separator:" ").dropFirst().first else { return (nil,nil) }
        let hashes = pair.components(separatedBy:"..")
        guard hashes.count == 2,hashes.allSatisfy({ [40,64].contains($0.count) && $0.allSatisfy(\.isHexDigit) }) else { throw GitError.invalidPath }
        func data(_ hash: String) throws -> Data? { hash.allSatisfy { $0 == "0" } ? nil : try objectData(hash) }
        return try (data(hashes[0]),data(hashes[1]))
    }

    private func objectData(_ object: String) throws -> Data {
        if let remote {
            let reply = try remote.request("review-blob",path:directory,digest:object)
            guard let encoded = reply.content,let data = Data(base64Encoded:encoded) else {
                throw GitError.command("The remote response is incomplete.")
            }
            return data
        }
        guard let count = Int(try run(["cat-file","-s",object]).trimmingCharacters(in:.whitespacesAndNewlines)),count <= 16*1024*1024 else {
            throw GitError.command("File too large for a preview.")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("linvell-blob-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:output) }
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/git"),
                                         arguments:Self.arguments(directory:directory,arguments:["cat-file","blob",object]),
                                         directory:root,outputFile:output,maximumOutputBytes:16*1024*1024)
        guard result.succeeded else { throw GitError.command("This file does not exist in the selected revision.") }
        return try Data(contentsOf:output)
    }
}

extension GitRepository {
    public func createAndPushTag(_ name: String,revision: String,remote: String) throws {
        _ = try run(["check-ref-format","refs/tags/"+name])
        let commit = try resolvedRevision(revision)
        _ = try run(["tag","--",name,commit])
        do { _ = try run(["push","--",remote,"refs/tags/"+name],timeout:120) }
        catch { throw GitError.command("The local tag was created, but the push failed. "+error.localizedDescription) }
    }
}

extension GitRepository {
    public func revisionImages(_ base: String,_ target: String,path: String) throws -> (Data?,Data?) {
        let left = try resolvedRevision(base),right = try resolvedRevision(target)
        let records = try run(["diff","--name-status","-z","--find-renames",left,right,"--"]).split(separator:"\0").map(String.init)
        var index = 0
        while index+1 < records.count {
            let status = records[index],old = records[index+1]
            let renamed = status.hasPrefix("R") || status.hasPrefix("C")
            let new = renamed && index+2 < records.count ? records[index+2] : old
            index += renamed ? 3 : 2
            guard new == path || old == path else { continue }
            return (status.hasPrefix("A") ? nil : try blobData(left,path:old),
                    status.hasPrefix("D") ? nil : try blobData(right,path:new))
        }
        return (try? blobData(left,path:path),try? blobData(right,path:path))
    }

    public func commitImages(_ hash: String,path: String) throws -> (Data?,Data?) {
        let commit = try resolvedRevision(hash)
        let parents = try run(["rev-list","--parents","-1",commit,"--"]).split(whereSeparator:\.isWhitespace).dropFirst()
        guard let parent = parents.first else { return (nil,try blobData(commit,path:path)) }
        return try revisionImages(String(parent),commit,path:path)
    }
}
