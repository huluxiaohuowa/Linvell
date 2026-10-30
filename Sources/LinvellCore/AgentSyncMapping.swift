import Foundation
import CryptoKit

/// A private local replica, never an arbitrary copied folder or filesystem mount.
public struct AgentSyncMapping: Codable, Equatable {
    public let host: String
    public let remoteRoot: String
    public let localRoot: String
    public init(host: String,remoteRoot: String,localRoot: String) {
        self.host = host; self.remoteRoot = remoteRoot; self.localRoot = localRoot
    }
    public var name: String { "linvell-"+SHA256.hash(data:Data((host+"\n"+remoteRoot).utf8)).map { String(format:"%02x",$0) }.joined().prefix(24) }
    public func validate() throws {
        let marker = URL(fileURLWithPath:localRoot).deletingLastPathComponent().appendingPathComponent("mapping.json")
        guard let data = try? Data(contentsOf:marker),let saved = try? JSONDecoder().decode(Self.self,from:data),saved == self,
              FileManager.default.isWritableFile(atPath:localRoot) else { throw GitError.command("Connect this project with Mutagen before starting a local agent.") }
    }
    public func remotePath(for localPath: String) -> String? {
        let root = URL(fileURLWithPath:localRoot).standardizedFileURL.path
        let path = URL(fileURLWithPath:localPath).standardizedFileURL.path
        guard path == root || path.hasPrefix(root+"/") else { return nil }
        if path == root { return remoteRoot }
        return (remoteRoot == "/" ? "" : remoteRoot)+String(path.dropFirst(root.count))
    }
}
