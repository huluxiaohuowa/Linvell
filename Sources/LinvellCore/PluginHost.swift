import Foundation
import LinvellPluginKit

public struct PluginManifest: Codable, Equatable {
    public struct Command: Codable, Equatable {
        public let id: String
        public let title: String
    }
    public let id: String
    public let name: String
    public let version: String
    public let protocolVersion: Int
    public let executable: String
    public let permissions: [String]
    public let commands: [Command]
}

public enum PluginError: LocalizedError, Equatable {
    case invalidPackage, unsupportedProtocol, permissionDenied, staleDocument, unavailable, failed
    public var errorDescription: String? {
        switch self {
        case .invalidPackage: return "Invalid plugin package. Check plugin.json and the executable inside the selected folder."
        case .unsupportedProtocol: return "This plugin requires an unsupported protocol version."
        case .permissionDenied: return "The plugin has not declared the document permissions required for this operation."
        case .staleDocument: return "The document changed while the plugin was running. Run the command again."
        case .unavailable: return "The plugin is stopped or another command is running."
        case .failed: return "The plugin failed or timed out. Check its executable and protocol; load it again to restart."
        }
    }
}

/// User-selected development packages only; never discovered or executed from a project automatically.
public struct PluginPackage {
    public let directory: URL
    public let executableURL: URL
    public let manifest: PluginManifest
    public init(directory: URL) throws {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let file = directory.appendingPathComponent("plugin.json")
        guard let size = try file.resourceValues(forKeys:[.fileSizeKey]).fileSize,size <= 64*1024 else { throw PluginError.invalidPackage }
        let manifest = try JSONDecoder().decode(PluginManifest.self,from:Data(contentsOf:file))
        guard manifest.protocolVersion == 1 else { throw PluginError.unsupportedProtocol }
        let validID: (String) -> Bool = { value in
            !value.isEmpty && value.utf8.count <= 128 && value.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]*$",options:.regularExpression) != nil
        }
        let allowed = Set(["document.read","document.write"])
        guard validID(manifest.id),!manifest.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,manifest.name.count <= 100,
              !manifest.version.isEmpty,manifest.version.count <= 64,
              !manifest.executable.isEmpty,!manifest.executable.hasPrefix("/"),
              !manifest.executable.split(separator:"/").contains(".."),
              Set(manifest.permissions).isSubset(of:allowed),
              !manifest.permissions.contains("document.write") || manifest.permissions.contains("document.read"),
              !manifest.commands.isEmpty,manifest.commands.count <= 100,
              Set(manifest.commands.map(\.id)).count == manifest.commands.count,
              manifest.commands.allSatisfy({ validID($0.id) && !$0.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.title.count <= 200 }) else { throw PluginError.invalidPackage }
        let executable = directory.appendingPathComponent(manifest.executable).standardizedFileURL.resolvingSymlinksInPath()
        guard executable.path.hasPrefix(directory.path+"/"),
              (try? executable.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isExecutableFile(atPath:executable.path) else { throw PluginError.invalidPackage }
        self.directory = directory; self.executableURL = executable; self.manifest = manifest
    }
}

/// Owns one lazily started process. Calls run off the UI thread; stop can interrupt a pending request.
public final class PluginSession {
    public let package: PluginPackage
    private let lock = NSLock()
    private var rpc: LanguageRPC?
    private var stopped = false, busy = false
    public init(package: PluginPackage) { self.package = package }
    deinit { stop() }
    public func execute(command: String, document: PluginDocument? = nil, timeout: TimeInterval = 10) throws -> PluginCommandResult {
        lock.lock()
        guard !stopped,!busy else { lock.unlock(); throw PluginError.unavailable }
        busy = true; lock.unlock()
        defer { lock.lock(); busy = false; lock.unlock() }
        guard package.manifest.commands.contains(where: { $0.id == command }) else { throw PluginError.invalidPackage }
        let allowedDocument = package.manifest.permissions.contains("document.read") ? document : nil
        guard (allowedDocument?.text.utf8.count ?? 0) <= 2*1024*1024 else { throw PluginError.invalidPackage }
        do {
            let channel: LanguageRPC
            lock.lock()
            if stopped { lock.unlock(); throw PluginError.unavailable }
            if let existing = rpc { channel = existing; lock.unlock() }
            else {
                // Explicit executable path, no shell interpolation. Working directory is the package, not the workspace.
                do { channel = try LanguageRPC(executable:package.executableURL,arguments:[],directory:package.directory) }
                catch { lock.unlock(); throw error }
                rpc = channel; lock.unlock()
                let value = try channel.request("initialize",params:["protocolVersion":1],timeout:timeout)
                guard (value as? [String:Any])?["protocolVersion"] as? Int == 1 else { throw PluginError.unsupportedProtocol }
            }
            let params = try JSONSerialization.jsonObject(with:JSONEncoder().encode(PluginCommandContext(command:command,document:allowedDocument))) as! [String:Any]
            let raw = try channel.request("commands/execute",params:params,timeout:timeout)
            let result = try JSONDecoder().decode(PluginCommandResult.self,from:JSONSerialization.data(withJSONObject:raw))
            guard result.replacementText == nil || package.manifest.permissions.contains("document.write") && allowedDocument != nil else { throw PluginError.permissionDenied }
            guard (result.replacementText?.utf8.count ?? 0) <= 2*1024*1024,(result.message?.count ?? 0) <= 2000 else { throw PluginError.invalidPackage }
            lock.lock(); let cancelled = stopped; lock.unlock()
            guard !cancelled else { throw PluginError.unavailable }
            return result
        } catch {
            stop()
            if let error = error as? PluginError { throw error }
            throw PluginError.failed
        }
    }
    public func stop() {
        lock.lock(); stopped = true; let channel = rpc; rpc = nil; lock.unlock()
        channel?.stop()
    }
}
