import AppKit
import CryptoKit
import Darwin
import LinvellCore

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
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data:(try? encoder.encode(profile)) ?? Data()).map { String(format:"%02x",$0) }.joined()
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
        do { return try LanguageSession(rpc:rpc,root:root,runtime:profile.runtime) } catch { rpc.stop(); throw error }
    }
}

final class WorkspaceLanguageServices {
    let queue = DispatchQueue(label:"top.fuluwa.linvell.language-services",qos:.userInitiated)
    private var sessions: [String:LanguageSession] = [:]
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
        if let session = sessions[key],session.rpc.isRunning { return session }
        let scope = (remote?.host ?? "local")+"|"+root
        let available: [String:String]
        if let existing = tools[scope] { available = existing }
        else { available = try LanguageTools.discover(remote:remote,root:root); tools[scope] = available }
        let stored = try LanguageTools.load(language,remote:remote,root:root,force:true)
        guard LanguageTools.approved(stored,language:language,remote:remote,root:root) else { throw LanguageServiceError.message("Review this project’s executable paths in Settings → Language Tools and apply them before running its language tools.") }
        let profile = LanguageTools.resolved(stored,language:language,tools:available,root:root)
        let session = try LanguageTools.launch(profile,language:language,root:root,remote:remote)
        sessions[key] = session; return session
    }
    func close(_ snapshot: EditorCodeSnapshot) {
        queue.async { [self] in sessions[(snapshot.remote?.host ?? "local")+"|"+snapshot.root+"|"+snapshot.language.id]?.close(uri:snapshot.uri) }
    }
    func saved(_ snapshot: EditorCodeSnapshot) {
        queue.async { [self] in sessions[(snapshot.remote?.host ?? "local")+"|"+snapshot.root+"|"+snapshot.language.id]?.saved(uri:snapshot.uri,text:snapshot.text) }
    }
    func stop() { queue.async { [self] in sessions.values.forEach { $0.rpc.stop() }; sessions.removeAll(); tools.removeAll(); failures.removeAll() } }
    deinit { sessions.values.forEach { $0.rpc.stop() } }
}
