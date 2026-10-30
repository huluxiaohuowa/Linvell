import Foundation

/// Optional Mutagen integration. All methods perform I/O and must run off the UI thread.
/// Its isolated daemon belongs to Linvell; it never registers a login item or uses ~/.mutagen.
public final class AgentSyncService {
    public static let shared = AgentSyncService()
    public struct Snapshot: Equatable {
        public let status: String
        public let conflicts: Int
        public let problem: String?
        public let conflictPaths: [String]
        public var ready: Bool { status == "watching" && conflicts == 0 && problem == nil }
    }
    private let root: URL
    private let environment: [String:String]
    private let lock = NSRecursiveLock()
    private var daemon: Process?
    private var daemonLog: FileHandle?
    private var clients: [UUID:String] = [:]
    private var closed = Set<UUID>()
    public init(root: URL? = nil,environment: [String:String] = AgentCLI.environment) {
        self.root = root ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Linvell/AgentSync")
        self.environment = environment
    }
    private var cli: URL? { AgentSyncSupport.detect(environment:environment).executable.map { URL(fileURLWithPath:$0) } }
    public var support: AgentSyncSupport { AgentSyncSupport.detect(environment:environment) }
    private var env: [String:String] {
        var result = environment
        result["MUTAGEN_DATA_DIRECTORY"] = root.appendingPathComponent("state").path
        result["MUTAGEN_DISABLE_AUTOSTART"] = "1"
        // Authentication is delegated to the existing SSH configuration/agent, never a hidden prompt.
        result["SSH_ASKPASS_REQUIRE"] = "never"
        return result
    }
    @discardableResult private func command(_ args: [String],timeout: TimeInterval = 15) throws -> String {
        guard let cli else { throw GitError.command("Mutagen is not installed. Run: "+AgentSyncSupport.installCommand) }
        let result: ToolResult
        do { result = try ToolCommand.run(cli,arguments:args,directory:nil,timeout:timeout,environment:env) }
        catch { throw GitError.command("Mutagen "+args.prefix(2).joined(separator:" ")+": "+error.localizedDescription) }
        guard result.succeeded else { throw GitError.command(result.timedOut ? "Mutagen timed out. Check the SSH connection and synchronization status before retrying." : result.output) }
        return result.output
    }
    private func startDaemon() throws {
        if daemon?.isRunning == true { return }
        guard let cli else { throw GitError.command("Mutagen is not installed. Run: "+AgentSyncSupport.installCommand) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let process = Process()
        // The supervisor also stops the daemon if Linvell crashes or is force-quit.
        process.executableURL = URL(fileURLWithPath:"/bin/sh")
        process.arguments = ["-c", "\"$1\" daemon run & child=$!; trap 'kill -TERM \"$child\" 2>/dev/null' TERM INT HUP; while kill -0 \"$2\" 2>/dev/null && kill -0 \"$child\" 2>/dev/null; do sleep 1; done; kill -TERM \"$child\" 2>/dev/null; wait \"$child\"", "linvell-mutagen", cli.path, String(ProcessInfo.processInfo.processIdentifier)]
        process.environment = env; process.standardInput = FileHandle.nullDevice
        let logURL = root.appendingPathComponent("daemon.log")
        FileManager.default.createFile(atPath:logURL.path,contents:nil,attributes:[.posixPermissions:0o600])
        let log = try FileHandle(forWritingTo:logURL); daemonLog = log
        process.standardOutput = log; process.standardError = log
        do { try process.run(); daemon = process }
        catch { try? log.close(); daemonLog = nil; throw error }
        for _ in 0..<20 {
            if (try? command(["sync","list","--template","{{ json . }}"],timeout:2)) != nil { return }
            Thread.sleep(forTimeInterval:0.1)
        }
        let detail = (try? String(contentsOf:logURL,encoding:.utf8)).map { String($0.suffix(1200)) } ?? ""
        stopDaemon(); throw GitError.command("Unable to start Linvell’s isolated Mutagen synchronization process. "+detail)
    }
    private func stopDaemon() {
        guard let daemon else { return }
        _ = try? command(["daemon","stop"],timeout:3)
        if daemon.isRunning { daemon.terminate() }
        daemon.waitUntilExit()
        self.daemon = nil
        try? daemonLog?.close(); daemonLog = nil
    }
    private func records(_ name: String) throws -> [[String:Any]] {
        let output = try command(["sync","list","--template","{{ json . }}"])
        if output == "null" { return [] }
        guard let array = try JSONSerialization.jsonObject(with:Data(output.utf8)) as? [[String:Any]] else { throw GitError.command("Invalid Mutagen synchronization status.") }
        return array.filter { $0["name"] as? String == name }
    }
    public static func snapshot(from record: [String:Any]) -> Snapshot {
        let conflicts = ((record["conflicts"] as? [Any])?.count ?? 0)+(record["excludedConflicts"] as? Int ?? 0)
        let alpha = record["alpha"] as? [String:Any] ?? [:], beta = record["beta"] as? [String:Any] ?? [:]
        let errors = [record["lastError"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
        let problems = [alpha,beta].reduce(0) { count,endpoint in count+((endpoint["transitionProblems"] as? [Any])?.count ?? 0)+((endpoint["scanProblems"] as? [Any])?.count ?? 0) }
        let paths = (record["conflicts"] as? [[String:Any]] ?? []).compactMap { $0["root"] as? String }
        return Snapshot(status:record["paused"] as? Bool == true ? "paused" : (record["status"] as? String ?? "unknown"),conflicts:conflicts,problem:errors.first ?? (problems > 0 ? "Mutagen reported file synchronization problems." : nil),conflictPaths:paths)
    }
    public func mapping(remote: SSHRemote,directory: String) -> AgentSyncMapping {
        let identity = AgentSyncMapping(host:remote.host,remoteRoot:directory,localRoot:"")
        return AgentSyncMapping(host:remote.host,remoteRoot:directory,localRoot:root.appendingPathComponent("projects/"+identity.name+"/files").path)
    }
    public func prepare(remote: SSHRemote,directory: String,client: UUID) throws -> AgentSyncMapping {
        lock.lock(); defer { lock.unlock() }
        guard !closed.contains(client) else { throw GitError.command("This agent workspace has closed.") }
        guard directory.hasPrefix("/"),!directory.contains("\0"),!directory.contains("\n") else { throw GitError.invalidPath }
        guard cli != nil else { throw GitError.command("Mutagen is not installed. Run: "+AgentSyncSupport.installCommand) }
        let mapping = mapping(remote:remote,directory:directory)
        let folder = URL(fileURLWithPath:mapping.localRoot).deletingLastPathComponent()
        try FileManager.default.createDirectory(atPath:mapping.localRoot,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try JSONEncoder().encode(mapping).write(to:folder.appendingPathComponent("mapping.json"),options:.atomic)
        do {
            try startDaemon()
            let existing = try records(mapping.name)
            if existing.isEmpty {
                try command(["sync","create","--name",mapping.name,"--no-global-configuration","--mode","two-way-safe","--ignore-vcs","--ignore",".DS_Store",mapping.localRoot,remote.host+":"+directory],timeout:30)
            } else {
                guard existing.count == 1,existing[0]["mode"] as? String == "two-way-safe",let alpha = existing[0]["alpha"] as? [String:Any],let beta = existing[0]["beta"] as? [String:Any],
                      alpha["protocol"] as? String == "local",alpha["path"] as? String == mapping.localRoot,
                      beta["protocol"] as? String == "ssh",beta["path"] as? String == directory,Self.matchesSSH(beta,host:remote.host) else {
                    throw GitError.command("Mutagen session endpoints do not match this SSH project.")
                }
                try command(["sync","resume",mapping.name])
            }
            clients[client] = mapping.name
            try command(["sync","flush",mapping.name],timeout:60)
            let state = try snapshot(mapping)
            guard state.conflicts == 0,state.problem == nil else { throw GitError.command(state.problem ?? "Mutagen synchronization has conflicts. Resolve them before launching a local agent.") }
            try mapping.validate(); return mapping
        } catch {
            let message = error.localizedDescription
            // Keep sessions/replicas for recovery; no global daemon or login service is left behind.
            if clients.isEmpty { stopDaemon() }
            throw GitError.command(message)
        }
    }
    public static func matchesSSH(_ endpoint: [String:Any],host: String) -> Bool {
        let parts = host.split(separator:"@",maxSplits:1).map(String.init)
        return endpoint["host"] as? String == parts.last && (parts.count == 1 || endpoint["user"] as? String == parts.first)
    }
    public func snapshot(_ mapping: AgentSyncMapping) throws -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        guard daemon?.isRunning == true else { return Snapshot(status:"paused",conflicts:0,problem:nil,conflictPaths:[]) }
        guard let record = try records(mapping.name).first else { throw GitError.command("The Mutagen session is unavailable. Reconnect this project.") }
        return Self.snapshot(from:record)
    }
    public func flush(_ mapping: AgentSyncMapping) throws {
        lock.lock(); defer { lock.unlock() }
        guard daemon?.isRunning == true else { throw GitError.command("Mutagen synchronization is stopped. Reconnect this project.") }
        try command(["sync","flush",mapping.name],timeout:60)
        let state = try snapshot(mapping)
        guard state.conflicts == 0,state.problem == nil else { throw GitError.command(state.problem ?? "Mutagen synchronization has conflicts. Changes need review.") }
    }
    public func release(client: UUID) {
        lock.lock(); defer { lock.unlock() }
        closed.insert(client)
        suspend(client:client)
    }
    @discardableResult public func suspend(client: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        var problem: String?
        if let name = clients.removeValue(forKey:client),!clients.values.contains(name) {
            do {
                try command(["sync","flush",name],timeout:10)
                if let record = try records(name).first {
                    let state = Self.snapshot(from:record)
                    if state.conflicts > 0 || state.problem != nil { problem = state.problem ?? "Synchronization conflicts require review." }
                }
            } catch { problem = error.localizedDescription }
            _ = try? command(["sync","pause",name],timeout:3)
        }
        if clients.isEmpty { stopDaemon() }
        return problem
    }
    deinit { stopDaemon() }
}
