import Foundation
import CryptoKit
import Darwin

/// A live SSHFS mount gives local CLIs normal filesystem access with no sync copy.
/// Linvell does not bundle or install SSHFS or a filesystem driver.
public struct AgentPathMapping: Codable, Equatable {
    public let host: String
    public let remoteRoot: String
    public let localRoot: String
    public init(host: String,remoteRoot: String,localRoot: String) {
        self.host = host; self.remoteRoot = remoteRoot; self.localRoot = localRoot
    }
    public func validate() throws {
        let count = getfsstat(nil,0,MNT_NOWAIT)
        guard count > 0 else { throw GitError.command("The mapped folder is unavailable.") }
        var volumes = Array<statfs>(repeating:statfs(),count:Int(count)+16)
        let found = volumes.withUnsafeMutableBufferPointer { getfsstat($0.baseAddress,Int32($0.count*MemoryLayout<statfs>.stride),MNT_NOWAIT) }
        guard found >= 0 else { throw GitError.command("The mapped folder is unavailable.") }
        let valid = volumes.prefix(Int(found)).contains { volume in
            var volume = volume
            let source = withUnsafeBytes(of:&volume.f_mntfromname) { String(decoding:$0.prefix(while:{ $0 != 0 }),as:UTF8.self) }
            let mount = withUnsafeBytes(of:&volume.f_mntonname) { String(decoding:$0.prefix(while:{ $0 != 0 }),as:UTF8.self) }
            return Self.matchesMount(source:source,mount:mount,host:host,remoteRoot:remoteRoot,localRoot:localRoot)
        }
        guard valid else {
            throw GitError.command("Choose the live SSHFS mount of this exact SSH host and project folder. A copied folder cannot be used as a live mapping.")
        }
        guard FileManager.default.isWritableFile(atPath:localRoot) else { throw GitError.command("The mapped folder is read-only.") }
    }
    public static func matchesMount(source: String,mount: String,host: String,remoteRoot: String,localRoot: String) -> Bool {
        let expected = host+":"+remoteRoot
        let validSource = source == expected || (!host.contains("@") && source.hasSuffix("@"+expected)) || source == "sshfs#"+expected
        return validSource && AgentCLI.sameProject(mount,localRoot)
    }
    public static func mount(remote: SSHRemote,directory: String) throws -> AgentPathMapping {
        guard directory.hasPrefix("/"),!directory.contains("\0") else { throw GitError.invalidPath }
        let candidates = (AgentCLI.environment["PATH"] ?? "").components(separatedBy:":").map { URL(fileURLWithPath:$0).appendingPathComponent("sshfs") }
        guard let executable = candidates.first(where:{ FileManager.default.isExecutableFile(atPath:$0.path) }) else {
            throw GitError.command("SSHFS is not installed. Install SSHFS with its macOS filesystem support, or choose an existing SSHFS mount. You can also run the agent on the SSH host.")
        }
        let key = SHA256.hash(data:Data((remote.host+"\n"+directory).utf8)).map { String(format:"%02x",$0) }.joined().prefix(24)
        let root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Linvell/AgentMounts/"+key)
        let mapping = AgentPathMapping(host:remote.host,remoteRoot:directory,localRoot:root.path)
        if (try? mapping.validate()) != nil { return mapping }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        guard (try FileManager.default.contentsOfDirectory(atPath:root.path)).isEmpty else { throw GitError.command("The agent mount folder is not empty.") }
        let result = try ToolCommand.run(executable,arguments:["-o","reconnect,ServerAliveInterval=15,ServerAliveCountMax=3",remote.host+":"+directory,root.path],directory:nil,timeout:30,environment:AgentCLI.environment)
        guard result.succeeded else { throw GitError.command(result.timedOut ? "SSHFS mount timed out." : result.output) }
        try mapping.validate(); return mapping
    }
    public func remotePath(for localPath: String) -> String? {
        let root = URL(fileURLWithPath:localRoot).standardizedFileURL.path
        let path = URL(fileURLWithPath:localPath).standardizedFileURL.path
        guard path == root || path.hasPrefix(root+"/") else { return nil }
        return remoteRoot+String(path.dropFirst(root.count))
    }
}
