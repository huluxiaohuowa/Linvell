import Foundation
import Darwin

/// Adapted from FoldGit WorktreeCleanup.withLockedHead, copyright (c) 2026 dufu, MIT.
/// A prepared update-ref transaction keeps HEAD and its referent locked through removal.
final class GitHeadLease {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var closed = false

    init(repository: GitRepository,head: String) throws {
        guard head.count >= 40,head.allSatisfy(\.isHexDigit) else { throw GitError.invalidPath }
        if let remote = repository.remote {
            process.executableURL = URL(fileURLWithPath:"/usr/bin/ssh")
            process.arguments = remote.transportArguments(command:SSHRemote.gitCommand(["update-ref","--stdin"],directory:repository.directory))
        } else {
            process.executableURL = URL(fileURLWithPath:"/usr/bin/git")
            process.arguments = GitRepository.arguments(directory:repository.directory,arguments:["update-ref","--stdin"])
        }
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf:Data("start\nverify HEAD \(head)\nprepare\n".utf8))
            guard try response() == "start: ok",try response() == "prepare: ok" else {
                throw GitError.command("The worktree changed before its references could be locked.")
            }
        } catch { close(); throw error }
    }

    private func response() throws -> String {
        let deadline = Date().addingTimeInterval(15)
        var bytes = Data()
        while Date() < deadline,bytes.count < 1024 {
            var descriptor = pollfd(fd:output.fileHandleForReading.fileDescriptor,events:Int16(POLLIN),revents:0)
            let ready = poll(&descriptor,1,100)
            if ready > 0 {
                guard let byte = try output.fileHandleForReading.read(upToCount:1),!byte.isEmpty else { break }
                if byte == Data([10]) { return String(decoding:bytes,as:UTF8.self) }
                bytes.append(byte)
            } else if ready < 0 { break }
        }
        throw GitError.command("Unable to lock the worktree references. Refresh and try again.")
    }

    func close() {
        guard !closed else { return }; closed = true
        // EOF aborts a transaction, including after the linked worktree's metadata has been removed.
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning,Date() < deadline { Thread.sleep(forTimeInterval:0.01) }
        if process.isRunning { process.terminate() }
    }
    deinit { close() }
}

extension GitRepository {
    func withLockedHead<T>(_ head: String,_ action: () throws -> T) throws -> T {
        let lease = try GitHeadLease(repository:self,head:head)
        defer { lease.close() }
        return try action()
    }

    public func lastActivity() throws -> Date {
        if let remote {
            let value = try remote.request("git-activity",path:directory)
            guard let seconds = value.digest.flatMap(Double.init) else { throw GitError.invalidPath }
            return Date(timeIntervalSince1970:seconds)
        }
        var dates: [Date] = []
        for name in ["HEAD","index","logs/HEAD"] {
            let path = try run(["rev-parse","--path-format=absolute","--git-path",name]).trimmingCharacters(in:.newlines)
            if let attributes = try? FileManager.default.attributesOfItem(atPath:path),let date = attributes[.modificationDate] as? Date { dates.append(date) }
        }
        return dates.max() ?? .distantPast
    }
}

extension GitRepository {
    /// Adapted from FoldGit RepositoryActivity, copyright (c) 2026 dufu, MIT.
    /// Tracks working files, including nonignored untracked files and removals.
    public func modificationDate() throws -> Date {
        if let remote {
            let reply = try remote.request("git-modification",path:directory)
            guard let time = reply.digest.flatMap(Double.init) else { throw GitError.invalidPath }
            return Date(timeIntervalSince1970:time)
        }
        let paths = try reviewFiles()
        return paths.compactMap { path -> Date? in
            let file = root.appendingPathComponent(path)
            return (try? file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate)
                ?? (try? file.deletingLastPathComponent().resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate)
        }.max() ?? .distantPast
    }
}
