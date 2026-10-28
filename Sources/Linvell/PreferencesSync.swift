import Foundation
import AppKit

/// Only an explicit preference allowlist enters iCloud Drive. Documents, paths and secrets never do.
final class PreferencesSync {
    static let shared = PreferencesSync()
    static let didApply = Notification.Name("Linvell.PreferencesApplied")
    struct Record: Codable { var value: String; var modified: TimeInterval }
    struct Snapshot: Codable { var version = 1; var settings: [String:Record] = [:] }
    static let defaults: [String:String] = ["theme":"Linvell Dark","editorFontSize":"15","editorFontFamily":"SF Mono","vimEnabled":"false","lineNumbers":"true","wordWrap":"true","tabWidth":"4","useSpaces":"true"]
    private(set) var status = "Local preferences"
    private var records = Snapshot()
    private var timer: Timer?
    private let queue = DispatchQueue(label:"top.fuluwa.linvell.preferences-sync",qos:.utility)
    private var inFlight = false
    private var drive: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs",isDirectory:true) }
    var available: Bool { var directory: ObjCBool = false; return FileManager.default.fileExists(atPath:drive.path,isDirectory:&directory) && directory.boolValue }
    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey:"iCloudSyncEnabled") }
        set { UserDefaults.standard.set(newValue,forKey:"iCloudSyncEnabled"); if newValue { sync() } else { status = "Sync is off. Preferences stay on this Mac." } }
    }
    private init() {
        if let data = UserDefaults.standard.data(forKey:"preferenceSyncRecords"),let stored = try? JSONDecoder().decode(Snapshot.self,from:data) { records = stored }
    }
    func start() {
        if UserDefaults.standard.object(forKey:"iCloudSyncEnabled") == nil { UserDefaults.standard.set(available,forKey:"iCloudSyncEnabled") }
        sync()
        timer = Timer.scheduledTimer(withTimeInterval:10,repeats:true) { [weak self] _ in self?.sync() }
    }
    static func value(_ key: String) -> String {
        guard let object = UserDefaults.standard.object(forKey:key) else { return defaults[key] ?? "" }
        if let value = object as? String { return value }
        if ["vimEnabled","lineNumbers","wordWrap","useSpaces"].contains(key) { return UserDefaults.standard.bool(forKey:key) ? "true" : "false" }
        return String(describing:object)
    }
    func changed() {
        let now = Date().timeIntervalSince1970
        for key in Self.defaults.keys {
            let value = Self.value(key)
            if value != records.settings[key]?.value { records.settings[key] = Record(value:value,modified:now) }
        }
        persist(); NotificationCenter.default.post(name:Self.didApply,object:nil); sync()
    }
    private func persist() { UserDefaults.standard.set(try? JSONEncoder().encode(records),forKey:"preferenceSyncRecords") }
    func sync() {
        guard enabled else { status = "Sync is off. Preferences stay on this Mac."; return }
        guard available else { status = "iCloud Drive is unavailable. Local preferences are safe."; return }
        guard !inFlight else { return }
        inFlight = true; status = "Syncing with iCloud Drive…"
        let file = drive.appendingPathComponent("Linvell/Preferences.json"), local = records
        let initial = Dictionary(uniqueKeysWithValues:Self.defaults.keys.map { ($0,Self.value($0)) })
        queue.async { [weak self] in
            var merged = local
            var failure: Error?
            do {
                try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
                let coordinator = NSFileCoordinator(filePresenter:nil)
                var coordinationError: NSError?
                coordinator.coordinate(writingItemAt:file,options:.forMerging,error:&coordinationError) { url in
                    do {
                        if FileManager.default.fileExists(atPath:url.path) {
                            let remote = try JSONDecoder().decode(Snapshot.self,from:Data(contentsOf:url))
                            guard remote.version == 1 else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                            for (key,record) in remote.settings where Self.defaults[key] != nil {
                                if let current = merged.settings[key] {
                                    if record.modified > current.modified || record.modified == current.modified && record.value > current.value { merged.settings[key] = record }
                                } else { merged.settings[key] = record }
                            }
                        }
                        for (key,defaultValue) in initial where merged.settings[key] == nil {
                            // New installations accept existing cloud values before supplying defaults.
                            merged.settings[key] = Record(value:defaultValue,modified:0)
                        }
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
                        let data = try encoder.encode(merged)
                        if (try? Data(contentsOf:url)) != data { try data.write(to:url,options:.atomic) }
                    } catch { failure = error }
                }
                if let coordinationError { failure = coordinationError }
            } catch { failure = error }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.inFlight = false
                guard failure == nil else { self.status = "iCloud sync could not finish. Local preferences are safe."; return }
                guard self.enabled else { return }
                var applied = false
                for (key,record) in merged.settings {
                    if let newer = self.records.settings[key],newer.modified > record.modified { continue }
                    guard Self.valid(key,record.value) else { continue }
                    self.records.settings[key] = record
                    if Self.value(key) != record.value { UserDefaults.standard.set(record.value,forKey:key); applied = true }
                }
                self.persist(); self.status = "Preferences saved to iCloud Drive. Delivery to other Macs is managed by iCloud."
                if applied { NotificationCenter.default.post(name:Self.didApply,object:nil) }
            }
        }
    }
    static func valid(_ key: String,_ value: String) -> Bool {
        switch key {
        case "theme": return Theme.Profile(rawValue:value) != nil
        case "editorFontSize": return Double(value).map { (11...30).contains($0) } ?? false
        case "editorFontFamily": return ["SF Mono","Menlo","Monaco"].contains(value)
        case "tabWidth": return ["2","4","8"].contains(value)
        case "vimEnabled","lineNumbers","wordWrap","useSpaces": return value == "true" || value == "false"
        default: return false
        }
    }
}
