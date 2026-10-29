import Foundation
import CryptoKit
import Darwin
import LinvellPluginKit

public struct PluginWorkspace {
    public let root: String
    public let remote: SSHRemote?
    public init(root: String,remote: SSHRemote? = nil) { self.root = remote == nil ? URL(fileURLWithPath:root).standardizedFileURL.resolvingSymlinksInPath().path : root; self.remote = remote }
    public var identityKey: String { (remote.map { "ssh:"+$0.host } ?? "local")+"\n"+root }
}

/// Local, non-secret per-plugin state. Workspace overrides use the existing conflict-checked JSONC settings file.
public final class PluginPersistence {
    private static let lock = NSLock()
    public let directory: URL
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Linvell/Plugins",isDirectory:true)
    }
    public func environment(package: PluginPackage,workspace: PluginWorkspace?) throws -> PluginEnvironment {
        var configuration = package.manifest.configuration ?? [:]
        let local: ([String:PluginValue],[String:PluginValue],[String:PluginValue]) = try locked {
            let folder = try pluginFolder(package.manifest.id)
            let user = try read(folder.appendingPathComponent("configuration.json"))
            let storage = package.manifest.permissions.contains("storage")
            return (user,storage ? try read(folder.appendingPathComponent("global-state.json")) : [:],storage && workspace != nil ? try read(stateURL(folder:folder,workspace:workspace!)) : [:])
        }
        configuration.merge(local.0,uniquingKeysWith:{ _,new in new })
        if let workspace {
            let settings = try ProjectLanguageSettings.read(root:workspace.root,remote:workspace.remote)
            let values = try JSONCSettings(settings.data).values
            if let plugins = values["plugins"] {
                guard let plugins = plugins as? [String:Any] else { throw PluginError.invalidState }
                if let raw = plugins[package.manifest.id] {
                    let data = try JSONSerialization.data(withJSONObject:raw,options:.fragmentsAllowed)
                    guard data.count <= 256*1024 else { throw PluginError.invalidState }
                    let overrides = try JSONDecoder().decode([String:PluginValue].self,from:data)
                    configuration.merge(overrides,uniquingKeysWith:{ _,new in new })
                }
            }
        }
        return PluginEnvironment(configuration:configuration,globalState:local.1,workspaceState:local.2)
    }
    public func apply(_ updates: [PluginStateUpdate],pluginID: String,workspace: PluginWorkspace?) throws {
        guard !updates.isEmpty else { return }
        guard updates.count <= 1000,updates.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 128 }),
              workspace != nil || !updates.contains(where:{ $0.scope == .workspace }) else { throw PluginError.invalidState }
        try locked {
            let folder = try pluginFolder(pluginID)
            var pending: [(URL,Data)] = []
            for scope in [PluginStateUpdate.Scope.global,.workspace] {
                let changes = updates.filter { $0.scope == scope }; if changes.isEmpty { continue }
                let file = scope == .global ? folder.appendingPathComponent("global-state.json") : stateURL(folder:folder,workspace:workspace!)
                var state = try read(file)
                for update in changes { state[update.key] = update.value }
                pending.append((file,try encode(state)))
            }
            // Validate every namespace before writing. Each file replacement is atomic, not a cross-file transaction.
            for (file,data) in pending { try write(data,to:file) }
        }
    }
    public func userConfiguration(package: PluginPackage) throws -> URL {
        try locked {
            let file = try pluginFolder(package.manifest.id).appendingPathComponent("configuration.json")
            if !FileManager.default.fileExists(atPath:file.path) { try write(encode([:]),to:file) }
            _ = try read(file); return file
        }
    }
    private func stateURL(folder: URL,workspace: PluginWorkspace) -> URL {
        let key = SHA256.hash(data:Data(workspace.identityKey.utf8)).map { String(format:"%02x",$0) }.joined()
        return folder.appendingPathComponent("workspace-"+key+".json")
    }
    private func pluginFolder(_ id: String) throws -> URL {
        guard id.utf8.count <= 128,id.range(of:"\\A[A-Za-z0-9][A-Za-z0-9._-]*\\z",options:.regularExpression) != nil else { throw PluginError.invalidState }
        // The digest keeps differently cased IDs isolated on case-insensitive filesystems.
        let digest = SHA256.hash(data:Data(id.utf8)).map { String(format:"%02x",$0) }.joined()
        let folder = directory.appendingPathComponent(id+"-"+digest,isDirectory:true)
        try check(folder); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]); return folder
    }
    private func read(_ file: URL) throws -> [String:PluginValue] {
        try check(file)
        guard FileManager.default.fileExists(atPath:file.path) else { return [:] }
        guard let size = try file.resourceValues(forKeys:[.fileSizeKey]).fileSize,size <= 256*1024 else { throw PluginError.invalidState }
        let data = try Data(contentsOf:file)
        let values = try JSONCSettings(data).values
        return try JSONDecoder().decode([String:PluginValue].self,from:JSONSerialization.data(withJSONObject:values))
    }
    private func encode(_ value: [String:PluginValue]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 256*1024 else { throw PluginError.invalidState }
        return data
    }
    private func check(_ file: URL) throws {
        guard (try? file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else { throw PluginError.invalidState }
    }
    private func write(_ data: Data,to file: URL) throws {
        try check(file); try data.write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    private func locked<T>(_ action: () throws -> T) throws -> T {
        Self.lock.lock(); defer { Self.lock.unlock() }
        try check(directory)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd = Darwin.open(directory.appendingPathComponent(".state.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd >= 0,flock(fd,LOCK_EX) == 0 else { if fd >= 0 { Darwin.close(fd) }; throw PluginError.invalidState }
        defer { flock(fd,LOCK_UN); Darwin.close(fd) }
        return try action()
    }
}
