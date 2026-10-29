import AppKit
import CryptoKit
import Darwin
import LinvellCore
import LinvellPluginKit

/// Host-specific executable paths never enter preference synchronization.
enum LanguageTools {
    static let changed = Notification.Name("Linvell.LanguageToolsChanged")
    private struct Record { let snapshot: ProjectLanguageSettings; let profiles: [String:LanguageToolchain]; let associations: [String:String] }
    private static let lock = NSLock()
    private static let writeLock = NSLock()
    private static var records: [String:Record] = [:]
    static func scope(remote: SSHRemote?,root: String) -> String { (remote?.host ?? "local")+"|"+root }
    static func cached(_ language: CodeLanguage,remote: SSHRemote?,root: String) -> LanguageToolchain {
        lock.lock(); defer { lock.unlock() }; return records[scope(remote:remote,root:root)]?.profiles[language.id] ?? LanguageToolchain()
    }
    static func configuredLanguages(remote: SSHRemote?,root: String) -> [CodeLanguage] {
        lock.lock(); let ids = records[scope(remote:remote,root:root)]?.profiles.keys.map { $0 } ?? []; lock.unlock()
        return CodeLanguage.supported+ids.filter { id in !CodeLanguage.supported.contains { $0.id == id } }.sorted().map { CodeLanguage.custom(id:$0) }
    }
    static func language(path: String,remote: SSHRemote?,root: String) -> CodeLanguage? {
        lock.lock(); let associations = records[scope(remote:remote,root:root)]?.associations ?? [:]; lock.unlock()
        for pattern in associations.keys.sorted(by:{ $0.count > $1.count }) {
            let target = pattern.contains("/") ? (path.hasPrefix(root+"/") ? String(path.dropFirst(root.count+1)) : path) : URL(fileURLWithPath:path).lastPathComponent
            if fnmatch(pattern,target,0) == 0,let id = associations[pattern] { return CodeLanguage.supported.first { $0.id == id } ?? CodeLanguage.custom(id:id) }
        }
        return CodeLanguage.forPath(path)
    }
    static func refreshConfigurationIfChanged(remote: SSHRemote?,root: String) throws -> Bool {
        let snapshot = try ProjectLanguageSettings.read(root:root,remote:remote)
        let key = scope(remote:remote,root:root)
        lock.lock(); let previous = records[key]; lock.unlock()
        guard previous?.snapshot.data != snapshot.data else { return false }
        try remember(snapshot)
        lock.lock(); let current = records[key]; lock.unlock()
        return previous?.profiles.mapValues({ fingerprint($0)+"|"+$0.configurationJSON }) != current?.profiles.mapValues({ fingerprint($0)+"|"+$0.configurationJSON }) || previous?.associations != current?.associations
    }
    static func invalidate(remote: SSHRemote?,root: String) { lock.lock(); records.removeValue(forKey:scope(remote:remote,root:root)); lock.unlock() }
    private static func remember(_ snapshot: ProjectLanguageSettings) throws {
        let settings = try JSONCSettings(snapshot.data)
        let additional = settings.values.keys.filter { $0.hasPrefix("[") && $0.hasSuffix("]") && !$0.contains("][") }.map { String($0.dropFirst().dropLast()) }.filter { !$0.isEmpty }
        let associations = settings.values["files.associations"] as? [String:String] ?? [:]
        let ids = Set(CodeLanguage.supported.map(\.id)+additional+associations.values.filter { !$0.isEmpty })
        let profiles = Dictionary(uniqueKeysWithValues:ids.map { ($0,settings.setting($0)) })
        lock.lock(); records[scope(remote:snapshot.remote,root:snapshot.root)] = Record(snapshot:snapshot,profiles:profiles,associations:settings.values["files.associations"] as? [String:String] ?? [:])
        if records.count > 32,let first = records.keys.first { records.removeValue(forKey:first) }; lock.unlock()
    }
    private static func approvalKey(_ language: CodeLanguage,remote: SSHRemote?,root: String) -> String {
        "approvedProjectLanguageTools."+SHA256.hash(data:Data((scope(remote:remote,root:root)+"|"+language.id).utf8)).map { String(format:"%02x",$0) }.joined()
    }
    private static func fingerprint(_ profile: LanguageToolchain) -> String {
        // Installation preferences do not change approval of an existing executable.
        let value: [String:Any] = ["runtime":profile.runtime,"server":profile.server,"arguments":profile.arguments,"enabled":profile.enabled]
        return SHA256.hash(data:(try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys)) ?? Data()).map { String(format:"%02x",$0) }.joined()
    }
    static func approved(_ profile: LanguageToolchain,language: CodeLanguage,remote: SSHRemote?,root: String) -> Bool {
        if profile.runtime.isEmpty && profile.server.isEmpty && profile.arguments.isEmpty { return true }
        return UserDefaults.standard.string(forKey:approvalKey(language,remote:remote,root:root)) == fingerprint(profile)
    }
    static func load(_ language: CodeLanguage,remote: SSHRemote?,root: String,force: Bool = false) throws -> LanguageToolchain {
        lock.lock(); let exists = records[scope(remote:remote,root:root)] != nil; lock.unlock()
        if force || !exists { try remember(ProjectLanguageSettings.read(root:root,remote:remote)) }
        return cached(language,remote:remote,root:root)
    }
    static func save(_ profile: LanguageToolchain,language: CodeLanguage,remote: SSHRemote?,root: String) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        var portable = profile
        if let object = try JSONSerialization.jsonObject(with:Data(profile.configurationJSON.utf8)) as? [String:Any] { portable.configurationJSON = String(decoding:try JSONSerialization.data(withJSONObject:object,options:.sortedKeys),as:UTF8.self) }
        if portable.runtime.hasPrefix(root+"/") { portable.runtime = "${workspaceFolder}/"+portable.runtime.dropFirst(root.count+1) }
        if portable.server.hasPrefix(root+"/") { portable.server = "${workspaceFolder}/"+portable.server.dropFirst(root.count+1) }
        let original = try ProjectLanguageSettings.read(root:root,remote:remote)
        try remember(original.write(language:language.id,profile:portable))
        UserDefaults.standard.set(fingerprint(portable),forKey:approvalKey(language,remote:remote,root:root))
        DispatchQueue.main.async { NotificationCenter.default.post(name:changed,object:scope(remote:remote,root:root)) }
    }
    static func discover(remote: SSHRemote?,root: String) throws -> [String:String] {
        if let remote { return try remote.request("toolchains",path:root).tools ?? [:] }
        let names = Set(CodeLanguage.supported.flatMap { $0.runtimes+$0.servers })
        var result: [String:String] = [:]
        for name in names { if let path = ToolCommand.executable(name) { result[name] = path.path } }
        for relative in [".venv/bin/python","venv/bin/python"] {
            let path = URL(fileURLWithPath:root).appendingPathComponent(relative).path
            if FileManager.default.isExecutableFile(atPath:path) { result[relative] = path }
        }
        if result["sourcekit-lsp"] == nil {
            let found = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/xcrun"),arguments:["--find","sourcekit-lsp"],directory:nil,timeout:5)
            if found.succeeded { result["sourcekit-lsp"] = found.output }
        }
        result["__home"] = FileManager.default.homeDirectoryForCurrentUser.path
        return result
    }
    static func resolved(_ profile: LanguageToolchain,language: CodeLanguage,tools: [String:String],root: String) -> LanguageToolchain {
        var value = profile
        let home = tools["__home"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        func expand(_ input: String) -> String {
            var result = input.replacingOccurrences(of:"${workspaceFolder}",with:root).replacingOccurrences(of:"${userHome}",with:home)
            if result.hasPrefix("~/") { result = home+String(result.dropFirst()) }
            return result
        }
        if let raw = try? JSONSerialization.jsonObject(with:Data(value.configurationJSON.utf8)) {
            func expandValue(_ raw: Any) -> Any {
                if let text = raw as? String { return expand(text) }
                if let array = raw as? [Any] { return array.map(expandValue) }
                if let object = raw as? [String:Any] { return object.mapValues(expandValue) }
                return raw
            }
            if let data = try? JSONSerialization.data(withJSONObject:expandValue(raw),options:.sortedKeys) { value.configurationJSON = String(decoding:data,as:UTF8.self) }
        }
        value.runtime = expand(value.runtime); value.server = expand(value.server); value.arguments = value.arguments.map(expand)
        if let found = tools[value.runtime] { value.runtime = found }
        if let found = tools[value.server] { value.server = found }
        if value.runtime.isEmpty { value.runtime = (language.id == "python" ? [".venv/bin/python","venv/bin/python"]+language.runtimes : language.runtimes).compactMap { tools[$0] }.first ?? "" }
        if value.server.isEmpty { value.server = language.servers.compactMap { tools[$0] }.first ?? ""; value.arguments = language.arguments }
        if URL(fileURLWithPath:value.server).lastPathComponent == "pylsp",value.arguments == ["--stdio"] { value.arguments = [] }
        return value
    }
    static func launch(_ profile: LanguageToolchain,language: CodeLanguage,root: String,remote: SSHRemote?) throws -> LanguageSession {
        guard profile.enabled,!profile.server.isEmpty else { throw LanguageServiceError.message("Choose an installed language server in Language Tools.") }
        let id = SHA256.hash(data:Data(((remote?.host ?? "local")+root+language.id).utf8)).map { String(format:"%02x",$0) }.joined().prefix(16)
        var arguments = profile.arguments
        var executable = profile.server
        let serverName = URL(fileURLWithPath:profile.server).lastPathComponent
        if !profile.runtime.isEmpty,["ruby-lsp","phpactor"].contains(serverName) { arguments.insert(profile.server,at:0); executable = profile.runtime }
        if !profile.runtime.isEmpty,["R","dart"].contains(serverName) { executable = profile.runtime }
        if ["c","cpp","objective-c"].contains(language.id),!profile.runtime.isEmpty,!arguments.contains(where:{ $0.hasPrefix("--query-driver") }) { arguments.append("--query-driver="+profile.runtime) }
        let runtimeDirectory = profile.runtime.isEmpty ? nil : URL(fileURLWithPath:profile.runtime).deletingLastPathComponent().path
        let rpc: LanguageRPC
        if let remote {
            let cache = "$HOME/dev/build/linvell/language-services/"+id
            if language.id == "swift",!arguments.contains("--scratch-path") { arguments += ["--scratch-path","__LINVELL_CACHE__"] }
            let argv = ([executable]+arguments).map { $0 == "__LINVELL_CACHE__" ? "\""+cache+"\"" : SSHRemote.quote($0) }.joined(separator:" ")
            var environment = runtimeDirectory.map { "PATH="+SSHRemote.quote($0)+":\"$PATH\" " } ?? ""
            if language.id == "java",let runtimeDirectory { environment += "JAVA_HOME="+SSHRemote.quote(URL(fileURLWithPath:runtimeDirectory).deletingLastPathComponent().path)+" " }
            if language.id == "rust",!profile.runtime.isEmpty { environment += "RUSTC="+SSHRemote.quote(profile.runtime)+" " }
            if language.id == "csharp",let runtimeDirectory { environment += "DOTNET_ROOT="+SSHRemote.quote(runtimeDirectory)+" " }
            let command = "/bin/sh -c "+SSHRemote.quote("cd "+SSHRemote.quote(root)+" && exec env "+environment+argv)
            rpc = try LanguageRPC(executable:URL(fileURLWithPath:"/usr/bin/ssh"),arguments:remote.transportArguments(command:command),directory:nil)
        } else {
            let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/language-services/"+id)
            if language.id == "swift",!arguments.contains("--scratch-path") { arguments += ["--scratch-path",cache.path] }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = (runtimeDirectory.map { $0+":" } ?? "")+(environment["PATH"] ?? "/usr/bin:/bin")+":/opt/homebrew/bin:/usr/local/bin"
            if language.id == "java",let runtimeDirectory { environment["JAVA_HOME"] = URL(fileURLWithPath:runtimeDirectory).deletingLastPathComponent().path }
            if language.id == "rust",!profile.runtime.isEmpty { environment["RUSTC"] = profile.runtime }
            if language.id == "csharp",let runtimeDirectory { environment["DOTNET_ROOT"] = runtimeDirectory }
            rpc = try LanguageRPC(executable:URL(fileURLWithPath:executable),arguments:arguments,directory:URL(fileURLWithPath:root),environment:environment)
        }
        do { return try LanguageSession(rpc:rpc,root:root,runtime:profile.runtime,configuration:(try? JSONSerialization.jsonObject(with:Data(profile.configurationJSON.utf8))) as? [String:Any] ?? [:]) } catch { rpc.stop(); throw error }
    }
}

final class WorkspaceLanguageServices {
    let queue = DispatchQueue(label:"top.fuluwa.linvell.language-services",qos:.userInitiated)
    var pluginProviders: [String:(PluginSession,PluginLanguageServer)] = [:]
    var didCreateSession: ((LanguageSession,CodeLanguage,String,SSHRemote?) -> Void)?
    private var sessions: [String:LanguageSession] = [:]
    private var backendIdentities: [String:String] = [:]
    var activeBackendCount: Int { Set(sessions.values.map(ObjectIdentifier.init)).count }
    var activeWatchCount: Int { fileWatches.count+remoteWatches.count }
    private var remoteWatches: [String:RemoteLanguageWorkspaceWatch] = [:]
    private var fileWatches: [String:LanguageWorkspaceWatch] = [:]
    private var tools: [String:[String:String]] = [:]
    private var failures: [String:(Date,Error)] = [:]
    func session(language: CodeLanguage,root: String,remote: SSHRemote?) throws -> LanguageSession {
        let key = (remote?.host ?? "local")+"|"+root+"|"+language.id
        if let (date,error) = failures[key],Date().timeIntervalSince(date) < 30 { throw error }
        do { let value = try makeSession(language:language,root:root,remote:remote); failures.removeValue(forKey:key); return value }
        catch { failures[key] = (Date(),error); throw error }
    }
    private func makeSession(language: CodeLanguage,root: String,remote: SSHRemote?) throws -> LanguageSession {
        let key = (remote?.host ?? "local")+"|"+root+"|"+language.id
        if let session = sessions[key] {
            if session.rpc.isRunning { return session }
            for alias in Array(sessions.keys) where sessions[alias] === session { sessions.removeValue(forKey:alias); backendIdentities.removeValue(forKey:alias) }
        }
        let scope = (remote?.host ?? "local")+"|"+root
        if let (owner,provider) = pluginProviders[language.id],!owner.isStopped {
            guard owner.runtime.remote?.host == remote?.host,owner.runtime.root == root else { throw PluginError.unavailable }
            let rpc = try owner.runtime.launch(provider.program,log:owner.logs.append)
            do {
                let settings = try JSONSerialization.jsonObject(with:JSONEncoder().encode(provider.settings ?? [:])) as? [String:Any] ?? [:]
                let session = try LanguageSession(rpc:rpc,root:root,runtime:"",configuration:settings)
                sessions[key] = session; backendIdentities[key] = owner.sessionID.uuidString+"/"+provider.id
                didCreateSession?(session,language,root,remote); return session
            } catch { rpc.stop(); throw error }
        }
        let available: [String:String]
        if let existing = tools[scope] { available = existing }
        else { available = try LanguageTools.discover(remote:remote,root:root); tools[scope] = available }
        let stored = try LanguageTools.load(language,remote:remote,root:root,force:true)
        guard LanguageTools.approved(stored,language:language,remote:remote,root:root) else { throw LanguageServiceError.message("Review this project’s executable paths in Project → Project Settings and apply them before running its language tools.") }
        let profile = LanguageTools.resolved(stored,language:language,tools:available,root:root)
        guard profile.enabled else { throw LanguageServiceError.message("Language intelligence is disabled for this language.") }
        let identity = String(decoding:try JSONSerialization.data(withJSONObject:["runtime":profile.runtime,"server":profile.server,"arguments":profile.arguments,"configuration":profile.configurationJSON],options:.sortedKeys),as:UTF8.self)
        if let existing = sessions.first(where:{ $0.key.hasPrefix(scope+"|") && backendIdentities[$0.key] == identity && $0.value.rpc.isRunning })?.value {
            sessions[key] = existing; backendIdentities[key] = identity; return existing
        }
        let session = try LanguageTools.launch(profile,language:language,root:root,remote:remote)
        sessions[key] = session; backendIdentities[key] = identity
        didCreateSession?(session,language,root,remote)
        if remote == nil,fileWatches[scope] == nil {
            fileWatches[scope] = LanguageWorkspaceWatch(root:root) { [weak self] paths,types in
                self?.queue.async { [weak self] in self?.filesChanged(paths,root:root,remote:nil,eventTypes:types) }
            }
        }
        if let remote,remoteWatches[scope] == nil {
            remoteWatches[scope] = RemoteLanguageWorkspaceWatch(remote:remote,root:root) { [weak self] paths,types in
                self?.queue.async { [weak self] in self?.filesChanged(paths,root:root,remote:remote,eventTypes:types) }
            }
        }
        return session
    }
    func releaseUnusedBackends(root: String,remote: SSHRemote?) {
        let scope = (remote?.host ?? "local")+"|"+root,prefix = scope+"|"
        for key in Array(sessions.keys) where key.hasPrefix(prefix) {
            guard let session = sessions[key],session.openDocumentCount == 0 else { continue }
            session.rpc.shutdown()
            for alias in Array(sessions.keys) where sessions[alias] === session { sessions.removeValue(forKey:alias); backendIdentities.removeValue(forKey:alias) }
        }
        if !sessions.keys.contains(where:{ $0.hasPrefix(prefix) }) { fileWatches.removeValue(forKey:scope); remoteWatches.removeValue(forKey:scope) }
    }
    func workspaceSymbols(query: String,root: String,remote: SSHRemote?,cancellation: LanguageRequestCancellation) throws -> [[String:Any]] {
        let prefix = (remote?.host ?? "local")+"|"+root+"|"
        var symbols: [[String:Any]] = []; var visited = Set<ObjectIdentifier>()
        for (key,session) in sessions.sorted(by:{ $0.key < $1.key }) where key.hasPrefix(prefix) && session.rpc.isRunning {
            if cancellation.isCancelled { throw CancellationError() }
            guard visited.insert(ObjectIdentifier(session)).inserted else { continue }
            guard session.capabilities["workspaceSymbolProvider"] != nil,session.capabilities["workspaceSymbolProvider"] as? Bool != false else { continue }
            do { symbols += try session.rpc.request("workspace/symbol",params:["query":query],timeout:8,cancellation:cancellation) as? [[String:Any]] ?? [] }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        return Array(symbols.prefix(10_000))
    }
    func filesChanged(_ paths: [String],root: String,remote: SSHRemote?,eventTypes: [Int]? = nil) {
        let scope = (remote?.host ?? "local")+"|"+root,prefix = scope+"|"
        if paths.contains(root+"/.linvell/settings.json"),(try? LanguageTools.refreshConfigurationIfChanged(remote:remote,root:root)) == true {
            for key in Array(sessions.keys) where key.hasPrefix(prefix) { sessions.removeValue(forKey:key)?.rpc.shutdown(); backendIdentities.removeValue(forKey:key); failures.removeValue(forKey:key) }
            tools.removeValue(forKey:scope); fileWatches.removeValue(forKey:scope); remoteWatches.removeValue(forKey:scope)
            DispatchQueue.main.async { NotificationCenter.default.post(name:LanguageTools.changed,object:LanguageTools.scope(remote:remote,root:root)) }; return
        }
        let events = paths.enumerated().filter { !$0.element.contains("/.git/") && !$0.element.contains("/.linvell/tools/") && !$0.element.contains("/node_modules/") }.map { index,path -> [String:Any] in
            let type = eventTypes.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? (FileManager.default.fileExists(atPath:path) || remote != nil ? 2 : 3)
            return ["uri":URL(fileURLWithPath:path).absoluteString,"type":type]
        }
        guard !events.isEmpty else { return }
        var visited = Set<ObjectIdentifier>()
        for (key,session) in sessions where key.hasPrefix(prefix) && visited.insert(ObjectIdentifier(session)).inserted { session.rpc.notify("workspace/didChangeWatchedFiles",params:["changes":events]) }
    }
    func close(_ snapshot: EditorCodeSnapshot) {
        queue.async { [self] in
            let key = (snapshot.remote?.host ?? "local")+"|"+snapshot.root+"|"+snapshot.language.id
            guard let session = sessions[key] else { return }; session.close(uri:snapshot.uri)
            if session.openDocumentCount == 0 {
                session.rpc.shutdown()
                for alias in Array(sessions.keys) where sessions[alias] === session { sessions.removeValue(forKey:alias); backendIdentities.removeValue(forKey:alias) }
                let scope = (snapshot.remote?.host ?? "local")+"|"+snapshot.root
                if !sessions.keys.contains(where:{ $0.hasPrefix(scope+"|") }) { fileWatches.removeValue(forKey:scope); remoteWatches.removeValue(forKey:scope) }
            }
        }
    }
    func saved(_ snapshot: EditorCodeSnapshot) {
        queue.async { [self] in sessions[(snapshot.remote?.host ?? "local")+"|"+snapshot.root+"|"+snapshot.language.id]?.saved(uri:snapshot.uri,text:snapshot.text) }
    }
    func stop() { queue.async { [self] in sessions.values.forEach { $0.rpc.stop() }; sessions.removeAll(); backendIdentities.removeAll(); fileWatches.removeAll(); remoteWatches.removeAll(); tools.removeAll(); failures.removeAll() } }
    deinit { sessions.values.forEach { $0.rpc.stop() } }
}
