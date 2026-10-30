import Foundation
import CryptoKit
import Darwin

public struct InstalledPlugin: Codable, Equatable {
    public let id: String
    public var name: String,version: String,revision: String
    public var enabled: Bool
    public var previous: String?,sourceID: String?,downloadURL: URL?,sourceURL: URL?
}
public struct PluginSource: Codable, Equatable {
    public let id: String
    public var url: URL,name: String
}
public struct PluginCatalog: Codable {
    public struct Entry: Codable, Equatable {
        public let id: String,name: String,version: String,url: URL,sha256: String
        public let description: String?
    }
    public let schemaVersion: Int,name: String,plugins: [Entry]
}
public struct PluginRegistry: Codable {
    public init() {}
    public var schemaVersion = 1
    public var installed: [InstalledPlugin] = []
    public var sources: [PluginSource] = []
    public var themePlugin: String?,themeID: String?,iconPlugin: String?
}
public final class PluginCandidate {
    public let package: PluginPackage,downloadURL: URL?,sourceID: String?
    let staging: URL
    init(package: PluginPackage,staging: URL,downloadURL: URL?,sourceID: String?) { self.package = package;self.staging = staging;self.downloadURL = downloadURL;self.sourceID = sourceID }
    deinit { try? FileManager.default.removeItem(at:staging) }
}

/// Registry commits atomically select immutable package copies. Installed and previous versions remain intact until commit succeeds.
public final class PluginStore {
    private static let mutex = NSLock()
    public static let willChange = Notification.Name("Linvell.PluginStoreWillChange")
    public static let changed = Notification.Name("Linvell.PluginStoreChanged")
    public static let shared = PluginStore()
    public let directory: URL
    private let allowLoopback: Bool
    public init(directory: URL? = nil,allowLoopback: Bool = false) {
        self.directory = directory ?? ProcessInfo.processInfo.environment["LINVELL_PLUGIN_HOME"].map { URL(fileURLWithPath:$0) } ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Linvell/InstalledPlugins",isDirectory:true)
        self.allowLoopback = allowLoopback
    }
    private func checked(_ file: URL) throws {
        var cursor = file.standardizedFileURL
        while cursor.path != "/" {
            if (try? cursor.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true { throw PluginError.invalidState }
            cursor.deleteLastPathComponent()
        }
    }
    private func locked<T>(_ body: () throws -> T) throws -> T {
        Self.mutex.lock();defer { Self.mutex.unlock() }
        try checked(directory)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd = Darwin.open(directory.appendingPathComponent(".registry.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd >= 0,flock(fd,LOCK_EX) == 0 else { if fd >= 0 { Darwin.close(fd) };throw PluginError.invalidState }
        defer { flock(fd,LOCK_UN);Darwin.close(fd) };return try body()
    }
    private func read() throws -> PluginRegistry {
        let file = directory.appendingPathComponent("registry.json");try checked(file)
        guard FileManager.default.fileExists(atPath:file.path) else {
            var value = PluginRegistry();value.sources = [PluginSource(id:"F886480C-7FF0-4A37-9F7A-7D87A57277F1",url:URL(string:"https://linvell.fuluwa.top/plugins/catalog.json")!,name:"Linvell Examples")];return value
        }
        guard (try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 2*1024*1024 else { throw PluginError.invalidState }
        let value = try JSONDecoder().decode(PluginRegistry.self,from:Data(contentsOf:file))
        guard value.schemaVersion == 1,value.installed.count <= 500,value.sources.count <= 50,Set(value.installed.map(\.id)).count == value.installed.count,Set(value.sources.map(\.id)).count == value.sources.count else { throw PluginError.invalidState }
        for record in value.installed { guard PluginContributions.validID(record.id),UUID(uuidString:record.revision) != nil,record.previous == nil || UUID(uuidString:record.previous!) != nil else { throw PluginError.invalidState } }
        return value
    }
    private func write(_ value: PluginRegistry) throws {
        let file = directory.appendingPathComponent("registry.json");try checked(file)
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let data = try encoder.encode(value);guard data.count <= 2*1024*1024 else { throw PluginError.invalidState }
        try data.write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    public func registry() throws -> PluginRegistry { try locked { try read() } }
    private func revision(_ token: String) throws -> URL {
        guard UUID(uuidString:token) != nil else { throw PluginError.invalidState }
        let file = directory.appendingPathComponent("packages/"+token,isDirectory:true);try checked(file);return file
    }
    public func package(_ record: InstalledPlugin) throws -> PluginPackage {
        try locked {
            let package = try PluginPackage(directory:revision(record.revision))
            guard package.manifest.id == record.id,package.manifest.version == record.version else { throw PluginError.invalidState };return package
        }
    }
    private func staging() throws -> URL {
        try locked { let path = directory.appendingPathComponent("staging/"+UUID().uuidString,isDirectory:true);try checked(path);try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true);return path }
    }
    private func validateFiles(_ folder: URL) throws {
        var total = 0,count = 0
        guard let files = FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey]) else { throw PluginError.invalidPackage }
        while let file = files.nextObject() as? URL {
            count += 1;let values = try file.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey])
            guard values.isSymbolicLink != true,count <= 4000 else { throw PluginError.invalidPackage }
            if values.isRegularFile == true { let size = values.fileSize ?? Int.max;guard size <= 64*1024*1024 else { throw PluginError.invalidPackage };total += size;guard total <= 256*1024*1024 else { throw PluginError.invalidPackage } }
            else { guard (try file.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true else { throw PluginError.invalidPackage } }
        }
    }
    /// A selected folder or ZIP is copied to a disposable private staging area before trust review.
    public func prepare(file: URL) throws -> PluginCandidate { try prepare(file:file,downloadURL:nil,sourceID:nil) }
    private func prepare(file: URL,downloadURL: URL?,sourceID: String?) throws -> PluginCandidate {
        let stage = try staging()
        do {
            let packageRoot: URL
            if (try? file.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true {
                try validateFiles(file);packageRoot = stage.appendingPathComponent("package");try FileManager.default.copyItem(at:file,to:packageRoot)
            } else { packageRoot = try PluginArchives.extract(file,to:stage.appendingPathComponent("expanded")) }
            try validateFiles(packageRoot)
            let package = try PluginPackage(directory:packageRoot)
            guard ReleaseVersion(package.manifest.version) != nil else { throw LanguageServiceError.message("Installable plugins need a three-part version, for example 1.0.0.") }
            return PluginCandidate(package:package,staging:stage,downloadURL:downloadURL,sourceID:sourceID)
        } catch { try? FileManager.default.removeItem(at:stage);throw error }
    }
    public func prepare(url: URL,entry: PluginCatalog.Entry? = nil,sourceID: String? = nil) throws -> PluginCandidate {
        let bytes = try PluginDownloads.fetch(url,maximum:128*1024*1024,allowLoopback:allowLoopback)
        if let entry { guard entry.url == url,Self.digest(bytes) == entry.sha256.lowercased() else { throw LanguageServiceError.message("Plugin checksum mismatch. The installed version was kept.") } }
        let download = try staging();defer { try? FileManager.default.removeItem(at:download) }
        let archive = download.appendingPathComponent("package.zip");try bytes.write(to:archive)
        let candidate = try prepare(file:archive,downloadURL:url,sourceID:sourceID)
        if let entry { guard candidate.package.manifest.id == entry.id,candidate.package.manifest.version == entry.version else { throw PluginError.invalidPackage } }
        return candidate
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    /// Must be called after the user reviews/trusts this exact candidate. No code runs during preparation.
    @discardableResult public func install(_ candidate: PluginCandidate,expectedRevision: String?,enabled: Bool = true) throws -> InstalledPlugin {
        try locked {
            var registry = try read();let package = try PluginPackage(directory:candidate.package.directory),manifest = package.manifest
            let old = registry.installed.first { $0.id == manifest.id }
            if let sourceID = candidate.sourceID { guard registry.sources.contains(where:{ $0.id == sourceID }) else { throw PluginError.unavailable } }
            guard old?.revision == expectedRevision else { throw DocumentError.externalChange }
            guard registry.installed.count < 500 || old != nil else { throw PluginError.invalidState }
            let token = UUID().uuidString,target = try revision(token)
            try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
            do {
                try FileManager.default.copyItem(at:package.directory,to:target)
                let record = InstalledPlugin(id:manifest.id,name:manifest.name,version:manifest.version,revision:token,enabled:enabled,previous:old?.revision,sourceID:candidate.sourceID ?? (candidate.downloadURL == nil ? old?.sourceID : nil),downloadURL:candidate.downloadURL ?? old?.downloadURL,sourceURL:candidate.sourceID.flatMap { id in registry.sources.first { $0.id == id }?.url } ?? (candidate.downloadURL == nil ? old?.sourceURL : nil))
                registry.installed.removeAll { $0.id == manifest.id };registry.installed.append(record);try write(registry)
                if let retired = old?.previous { try? FileManager.default.removeItem(at:revision(retired)) }
                return record
            } catch { try? FileManager.default.removeItem(at:target);throw error }
        }
    }
    public func setEnabled(_ id: String,_ enabled: Bool,expectedRevision: String? = nil) throws { try locked { var r = try read();guard let index = r.installed.firstIndex(where:{ $0.id == id }) else { throw PluginError.unavailable };if let expectedRevision { guard r.installed[index].revision == expectedRevision else { throw DocumentError.externalChange } };r.installed[index].enabled = enabled;try write(r) } }
    @discardableResult public func rollback(_ id: String,expectedRevision: String) throws -> InstalledPlugin {
        try locked {
            var r = try read();guard let index = r.installed.firstIndex(where:{ $0.id == id }),r.installed[index].revision == expectedRevision,let previous = r.installed[index].previous else { throw PluginError.unavailable }
            let package = try PluginPackage(directory:revision(previous));guard package.manifest.id == id else { throw PluginError.invalidState }
            let current = r.installed[index].revision;r.installed[index].revision = previous;r.installed[index].previous = current;r.installed[index].version = package.manifest.version;r.installed[index].name = package.manifest.name
            try write(r);return r.installed[index]
        }
    }
    public func uninstall(_ id: String,expectedRevision: String) throws {
        try locked {
            var r = try read();guard let record = r.installed.first(where:{ $0.id == id }),record.revision == expectedRevision else { throw DocumentError.externalChange }
            r.installed.removeAll { $0.id == id }
            if r.themePlugin == id { r.themePlugin = nil;r.themeID = nil };if r.iconPlugin == id { r.iconPlugin = nil };try write(r)
            // Retire package bytes after the registry commit. Running sessions must be stopped by the UI coordinator.
            for token in [record.revision,record.previous].compactMap({ $0 }) { try? FileManager.default.removeItem(at:revision(token)) }
        }
    }
    public func selectTheme(plugin: String?,id: String?) throws { try locked { var r = try read();r.themePlugin = plugin;r.themeID = id;try write(r) } }
    public func selectIcons(plugin: String?) throws { try locked { var r = try read();r.iconPlugin = plugin;try write(r) } }
    @discardableResult public func saveSource(url: URL,id: String? = nil) throws -> PluginSource {
        guard PluginDownloads.valid(url,allowLoopback:allowLoopback) else { throw PluginError.invalidPackage }
        return try locked {
            var r = try read();guard r.sources.count < 50 || id != nil else { throw PluginError.invalidState }
            if let id { guard let index = r.sources.firstIndex(where:{ $0.id == id }) else { throw PluginError.unavailable };r.sources[index].url = url;for n in r.installed.indices where r.installed[n].sourceID == id { r.installed[n].sourceURL = url };try write(r);return r.sources[index] }
            guard !r.sources.contains(where:{ $0.url == url }) else { throw LanguageServiceError.message("This plugin source is already configured.") }
            let restoredID = r.installed.first { record in record.sourceURL == url && record.sourceID != nil && !r.sources.contains(where:{ $0.id == record.sourceID }) }?.sourceID
            let source = PluginSource(id:restoredID ?? UUID().uuidString,url:url,name:url.host ?? "Source");r.sources.append(source);try write(r);return source
        }
    }
    public func removeSource(_ id: String) throws { try locked { var r = try read();r.sources.removeAll { $0.id == id };try write(r) } }
    public func catalog(_ source: PluginSource) throws -> PluginCatalog {
        let value = try JSONDecoder().decode(PluginCatalog.self,from:PluginDownloads.fetch(source.url,maximum:1024*1024,allowLoopback:allowLoopback))
        guard value.schemaVersion == 1,!value.name.isEmpty,value.name.count <= 200,value.plugins.count <= 1000,Set(value.plugins.map(\.id)).count == value.plugins.count else { throw PluginError.invalidPackage }
        for entry in value.plugins { guard PluginContributions.validID(entry.id),ReleaseVersion(entry.version) != nil,!entry.name.isEmpty,entry.name.count <= 200,(entry.description?.count ?? 0) <= 2000,PluginDownloads.valid(entry.url,allowLoopback:allowLoopback),entry.sha256.range(of:"\\A[0-9a-fA-F]{64}\\z",options:.regularExpression) != nil else { throw PluginError.invalidPackage } }
        return value
    }
    public func availableUpdate(_ record: InstalledPlugin) throws -> String? {
        guard let old = ReleaseVersion(record.version) else { throw PluginError.invalidState }
        if let sourceID = record.sourceID {
            guard let source = try registry().sources.first(where:{ $0.id == sourceID }),let entry = try catalog(source).plugins.first(where:{ $0.id == record.id }) else { throw LanguageServiceError.message("The plugin's update source is unavailable.") }
            return ReleaseVersion(entry.version)! > old ? entry.version : nil
        }
        guard let url = record.downloadURL else { return nil }
        let value = try prepare(url:url)
        guard value.package.manifest.id == record.id,let version = ReleaseVersion(value.package.manifest.version) else { throw PluginError.invalidPackage }
        return version > old ? value.package.manifest.version : nil
    }
    public func updateCandidate(_ record: InstalledPlugin) throws -> PluginCandidate {
        if let sourceID = record.sourceID {
            guard let source = try registry().sources.first(where:{ $0.id == sourceID }),let entry = try catalog(source).plugins.first(where:{ $0.id == record.id }) else { throw LanguageServiceError.message("The plugin's update source is unavailable.") }
            guard let next = ReleaseVersion(entry.version),let old = ReleaseVersion(record.version),next > old else { throw LanguageServiceError.message("This plugin is up to date.") }
            return try prepare(url:entry.url,entry:entry,sourceID:sourceID)
        }
        guard let url = record.downloadURL else { throw LanguageServiceError.message("Install a newer package manually; this plugin has no update URL.") }
        let value = try prepare(url:url)
        guard value.package.manifest.id == record.id,let next = ReleaseVersion(value.package.manifest.version),let old = ReleaseVersion(record.version),next > old else { throw LanguageServiceError.message("No newer matching plugin version was found.") };return value
    }
}
