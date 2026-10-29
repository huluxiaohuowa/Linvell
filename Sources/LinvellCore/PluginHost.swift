import Foundation
import LinvellPluginKit

public struct PluginManifest: Codable, Equatable {
    public struct Command: Codable, Equatable {
        public let id: String
        public let title: String
        public let menu: String?
        public let keybinding: String?
    }
    public let id: String
    public let name: String
    public let version: String
    public let protocolVersion: Int
    public let executable: String
    public let permissions: [String]
    public let commands: [Command]
    public let events: [PluginDocumentEvent.Kind]?
    public let configuration: [String:PluginValue]?
}

public enum PluginError: LocalizedError, Equatable {
    case invalidPackage, unsupportedProtocol, permissionDenied, staleDocument, unavailable, failed, shortcutConflict, invalidState
    public var errorDescription: String? {
        switch self {
        case .invalidPackage: return "Invalid plugin package. Check plugin.json and the executable inside the selected folder."
        case .unsupportedProtocol: return "This plugin requires an unsupported protocol version."
        case .permissionDenied: return "The plugin has not declared the permissions required for this operation."
        case .staleDocument: return "The document changed while the plugin was running. Run the command again."
        case .unavailable: return "The plugin is stopped or another command is running."
        case .shortcutConflict: return "This plugin shortcut conflicts with an existing command. Change its keybinding before loading."
        case .invalidState: return "Plugin configuration or state is invalid, too large, or unavailable for this workspace."
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
            !value.isEmpty && value.utf8.count <= 128 && value.range(of:"\\A[A-Za-z0-9][A-Za-z0-9._-]*\\z",options:.regularExpression) != nil
        }
        let allowed = Set(["document.read","document.write","storage"])
        guard validID(manifest.id),!manifest.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,manifest.name.count <= 100,
              !manifest.version.isEmpty,manifest.version.count <= 64,
              !manifest.executable.isEmpty,!manifest.executable.hasPrefix("/"),
              !manifest.executable.split(separator:"/").contains(".."),
              Set(manifest.permissions).isSubset(of:allowed),
              !manifest.permissions.contains("document.write") || manifest.permissions.contains("document.read"),
              !manifest.commands.isEmpty,manifest.commands.count <= 100,
              (manifest.events ?? []).isEmpty || manifest.permissions.contains("document.read"),
              Set(manifest.commands.map(\.id)).count == manifest.commands.count,
              manifest.commands.allSatisfy({ validID($0.id) && !$0.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.title.count <= 200 }) else { throw PluginError.invalidPackage }
        for command in manifest.commands {
            guard command.menu == nil || command.menu == "plugins" else { throw PluginError.invalidPackage }
            if let keybinding = command.keybinding {
                guard command.menu == "plugins" else { throw PluginError.invalidPackage }
                _ = try PluginKeybinding(keybinding)
            }
        }
        let executable = directory.appendingPathComponent(manifest.executable).standardizedFileURL.resolvingSymlinksInPath()
        guard executable.path.hasPrefix(directory.path+"/"),
              (try? executable.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isExecutableFile(atPath:executable.path) else { throw PluginError.invalidPackage }
        self.directory = directory; self.executableURL = executable; self.manifest = manifest
    }
}

/// Owns a lazily started process. Commands and acknowledged events share a serial queue.
public final class PluginSession {
    public let package: PluginPackage
    public let persistence: PluginPersistence
    private let lock = NSLock()
    private let queue = DispatchQueue(label:"top.fuluwa.linvell.plugin",qos:.userInitiated)
    private var rpc: LanguageRPC?
    private var stopped = false, draining = false, commandPending = false
    private var events: [(PluginDocumentEvent,PluginWorkspace?)] = []
    public var eventFailure: ((Error) -> Void)?
    public init(package: PluginPackage,persistence: PluginPersistence = PluginPersistence()) { self.package = package; self.persistence = persistence }
    deinit { stop() }
    public func execute(command: String, document: PluginDocument? = nil, workspace: PluginWorkspace? = nil, timeout: TimeInterval = 10) throws -> PluginCommandResult {
        lock.lock()
        guard !stopped,!commandPending else { lock.unlock(); throw PluginError.unavailable }
        commandPending = true; lock.unlock()
        defer { lock.lock(); commandPending = false; lock.unlock() }
        return try queue.sync {
            lock.lock(); let pending = events; events.removeAll(); lock.unlock()
            for (event,workspace) in pending { try processEvent(event,workspace:workspace) }
            guard package.manifest.commands.contains(where: { $0.id == command }) else { throw PluginError.invalidPackage }
            let allowedDocument = package.manifest.permissions.contains("document.read") ? document : nil
            guard (allowedDocument?.text.utf8.count ?? 0) <= 2*1024*1024 else { throw PluginError.invalidPackage }
            let environment = try persistence.environment(package:package,workspace:workspace)
            let context = PluginCommandContext(command:command,document:allowedDocument,environment:environment)
            let raw = try request("commands/execute",params:context,timeout:timeout)
            do {
                let result = try JSONDecoder().decode(PluginCommandResult.self,from:JSONSerialization.data(withJSONObject:raw))
                let editsDocument = result.replacementText != nil || result.edits != nil
                guard !editsDocument || package.manifest.permissions.contains("document.write") && allowedDocument != nil else { throw PluginError.permissionDenied }
                guard result.replacementText == nil || result.edits == nil else { throw PluginError.invalidPackage }
                if let edits = result.edits,let document = allowedDocument {
                    guard result.documentRevision == document.revision else { throw PluginError.staleDocument }
                    _ = try PluginEdits.apply(edits,to:document.text)
                }
                guard (result.replacementText?.utf8.count ?? 0) <= 2*1024*1024,(result.message?.count ?? 0) <= 2000 else { throw PluginError.invalidPackage }
                try persist(result.stateUpdates ?? [],workspace:workspace)
                try checkRunning()
                return result
            } catch { stop(); throw error }
        }
    }
    /// Bounded queue; pending changes for the same document are coalesced between lifecycle boundaries.
    public func enqueue(_ event: PluginDocumentEvent,workspace: PluginWorkspace? = nil) {
        guard package.manifest.events?.contains(event.kind) == true else { return }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        if event.kind == .change,let last = events.lastIndex(where:{ $0.0.documentID == event.documentID }),events[last].0.kind == .change {
            events[last] = (event,workspace)
        } else { events.append((event,workspace)) }
        guard events.count <= 256 else { lock.unlock(); stop(); eventFailure?(PluginError.invalidState); return }
        let start = !draining; draining = true; lock.unlock()
        if start { queue.async { [weak self] in self?.drainEvent() } }
    }
    private func drainEvent() {
        lock.lock()
        guard !stopped,!events.isEmpty else { draining = false; lock.unlock(); return }
        let (event,workspace) = events.removeFirst(); lock.unlock()
        do { try processEvent(event,workspace:workspace) }
        catch { stop(); eventFailure?(error) }
        queue.async { [weak self] in self?.drainEvent() }
    }
    private func processEvent(_ event: PluginDocumentEvent,workspace: PluginWorkspace?) throws {
        do {
            let environment = try persistence.environment(package:package,workspace:workspace)
            let value = PluginDocumentEvent(kind:event.kind,documentID:event.documentID,revision:event.revision,document:event.document,environment:environment)
            let raw = try request("documents/event",params:value,timeout:10)
            let result = try JSONDecoder().decode(PluginCommandResult.self,from:JSONSerialization.data(withJSONObject:raw))
            guard result.edits == nil,result.replacementText == nil else { throw PluginError.permissionDenied }
            try persist(result.stateUpdates ?? [],workspace:workspace)
        } catch { stop(); throw error }
    }
    private func request<T: Encodable>(_ method: String,params: T,timeout: TimeInterval) throws -> Any {
        do {
            try checkRunning()
            let channel: LanguageRPC
            lock.lock()
            if stopped { lock.unlock(); throw PluginError.unavailable }
            if let existing = rpc { channel = existing; lock.unlock() }
            else {
                do { channel = try LanguageRPC(executable:package.executableURL,arguments:[],directory:package.directory) }
                catch { lock.unlock(); throw error }
                rpc = channel; lock.unlock()
                let raw = try channel.request("initialize",params:["protocolVersion":1],timeout:timeout)
                guard let value = raw as? [String:Any],value["protocolVersion"] as? Int == 1 else { throw PluginError.unsupportedProtocol }
                if !(package.manifest.events ?? []).isEmpty {
                    guard (value["capabilities"] as? [String] ?? []).contains("documentEvents") else { throw PluginError.unsupportedProtocol }
                }
            }
            let object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(params)) as! [String:Any]
            return try channel.request(method,params:object,timeout:timeout)
        } catch {
            stop()
            if let error = error as? PluginError { throw error }
            throw PluginError.failed
        }
    }
    private func checkRunning() throws { lock.lock(); defer { lock.unlock() }; if stopped { throw PluginError.unavailable } }
    private func persist(_ updates: [PluginStateUpdate],workspace: PluginWorkspace?) throws {
        guard updates.isEmpty || package.manifest.permissions.contains("storage") else { throw PluginError.permissionDenied }
        try checkRunning()
        try persistence.apply(updates,pluginID:package.manifest.id,workspace:workspace)
    }
    public func stop() {
        lock.lock(); stopped = true; let channel = rpc; rpc = nil; events.removeAll(); lock.unlock()
        channel?.stop()
    }
}
