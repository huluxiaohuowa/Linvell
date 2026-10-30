import Foundation

public enum AgentKind: String, Codable, CaseIterable {
    case codex, opencode, pi, claude, dsh
    public var title: String { switch self { case .codex: return "Codex"; case .opencode: return "OpenCode"; case .pi: return "Pi"; case .claude: return "Claude Code"; case .dsh: return "DeepSeek Harness" } }
    public var homeVariable: String? { switch self { case .codex: return "CODEX_HOME"; case .claude: return "CLAUDE_CONFIG_DIR"; case .pi: return "PI_CODING_AGENT_DIR"; case .dsh: return "DSH_HOME"; case .opencode: return nil } }
    public func arguments(session: AgentSession? = nil) -> [String] {
        switch self {
        case .codex: return session.map { ["resume",$0.id] } ?? []
        case .opencode: return session.map { ["--session",$0.id] } ?? []
        case .pi: return session.map { ["--session",$0.locator] } ?? []
        case .claude: return session.map { ["--resume",$0.id] } ?? []
        case .dsh: return ["web","--no-open","--host","127.0.0.1","--port","0"]
        }
    }
}

public struct AgentInstallation: Codable, Equatable {
    public let kind: AgentKind
    public let path: String
    public let source: String
    public init(kind: AgentKind,path: String,source: String) { self.kind = kind; self.path = path; self.source = source }
}

public struct AgentSession: Codable, Equatable {
    public let id: String
    public var title: String
    public let cwd: String
    public let locator: String
    public let updated: Double
    public init(id: String,title: String,cwd: String,locator: String,updated: Double) {
        self.id = id; self.title = title; self.cwd = cwd; self.locator = locator; self.updated = updated
    }
}

/// Discovery never starts an agent or reads its authentication files.
public enum AgentCLI {
    public static var environment: [String:String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [home+"/.local/bin",home+"/.npm-global/bin",home+"/.opencode/bin",home+"/.bun/bin",home+"/dev/envs/conda/bin","/opt/homebrew/bin","/usr/local/bin","/usr/bin","/bin"]
        env["PATH"] = ((env["PATH"] ?? "").components(separatedBy:":")+extra).filter { !$0.isEmpty }.joined(separator:":")
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"; env["TERM_PROGRAM"] = "Linvell"
        return env
    }
    public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,applicationDirectories: [URL]? = nil) -> [AgentInstallation] {
        let fm = FileManager.default
        var result: [AgentInstallation] = []
        var seen = Set<String>()
        func add(_ kind: AgentKind,_ url: URL,_ source: String) {
            guard fm.isExecutableFile(atPath:url.path),!((try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) ?? true),seen.insert(kind.rawValue+":"+url.resolvingSymlinksInPath().path).inserted else { return }
            result.append(AgentInstallation(kind:kind,path:url.path,source:source))
        }
        let directories = (environment["PATH"] ?? "").components(separatedBy:":")
        for kind in AgentKind.allCases { for directory in directories { add(kind,URL(fileURLWithPath:directory).appendingPathComponent(kind.rawValue),"CLI") } }
        // Common version-manager locations are not normally in a GUI app's PATH.
        for base in [home.appendingPathComponent(".nvm/versions/node"),home.appendingPathComponent(".local/share/mise/installs/node")] {
            for version in (try? fm.contentsOfDirectory(at:base,includingPropertiesForKeys:nil)) ?? [] {
                for kind in AgentKind.allCases { add(kind,version.appendingPathComponent("bin/"+kind.rawValue),"CLI") }
            }
        }
        let roots = applicationDirectories ?? [URL(fileURLWithPath:"/Applications"),home.appendingPathComponent("Applications")]
        for root in roots {
            for app in (try? fm.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)) ?? [] where app.pathExtension == "app" {
                let name = app.lastPathComponent.lowercased()
                for kind in AgentKind.allCases where name.contains(kind == .claude ? "claude" : kind == .dsh ? "deepseek" : kind.rawValue) {
                    // Only known CLI names, never the desktop GUI executable.
                    for relative in ["Contents/Resources/"+kind.rawValue,"Contents/Resources/bin/"+kind.rawValue]+(kind == .dsh ? ["Contents/Resources/runtime/cli/bin/dsh"] : []) {
                        add(kind,app.appendingPathComponent(relative),app.lastPathComponent)
                    }
                }
            }
        }
        return result
    }
    public static func defaultStorage(_ kind: AgentKind,home: URL = FileManager.default.homeDirectoryForCurrentUser,environment: [String:String] = ProcessInfo.processInfo.environment) -> [URL] {
        switch kind {
        case .codex:
            let base = environment["CODEX_HOME"].map { URL(fileURLWithPath:$0) } ?? home.appendingPathComponent(".codex")
            return [base.appendingPathComponent("sessions"),base.appendingPathComponent("archived_sessions")]
        case .claude: return [(environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath:$0) } ?? home.appendingPathComponent(".claude")).appendingPathComponent("projects")]
        case .pi: return [environment["PI_CODING_AGENT_SESSION_DIR"].map { URL(fileURLWithPath:$0) } ?? (environment["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath:$0) } ?? home.appendingPathComponent(".pi/agent")).appendingPathComponent("sessions")]
        case .opencode: return [] // Ask the CLI; never depend on its private SQLite schema.
        case .dsh: return [(environment["DSH_HOME"].map { URL(fileURLWithPath:$0) } ?? home.appendingPathComponent(".dsh")).appendingPathComponent("sessions")]
        }
    }
    public static func sameProject(_ lhs: String,_ rhs: String) -> Bool {
        URL(fileURLWithPath:lhs).standardizedFileURL.resolvingSymlinksInPath().path == URL(fileURLWithPath:rhs).standardizedFileURL.resolvingSymlinksInPath().path
    }
    /// Git's registered worktrees, including desktop-created worktrees. Reads
    /// metadata only; no Git process is required on either execution machine.
    public static func projectDirectories(_ project: String) -> [String] {
        let root = URL(fileURLWithPath:project).resolvingSymlinksInPath(),fm = FileManager.default
        func text(_ file: URL) -> String? { (try? String(contentsOf:file,encoding:.utf8))?.trimmingCharacters(in:.whitespacesAndNewlines) }
        func resolve(_ path: String,relativeTo base: URL) -> URL { URL(fileURLWithPath:path,relativeTo:base).standardizedFileURL.resolvingSymlinksInPath() }
        func gitDir(_ root: URL) -> URL? {
            let marker = root.appendingPathComponent(".git")
            if (try? marker.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true { return marker }
            guard let line = text(marker),line.hasPrefix("gitdir: ") else { return nil }
            return resolve(String(line.dropFirst(8)),relativeTo:root)
        }
        guard var common = gitDir(root) else { return [root.path] }
        if let relative = text(common.appendingPathComponent("commondir")) { common = resolve(relative,relativeTo:common) }
        let directory = common.appendingPathComponent("worktrees")
        var roots = Set([root.path])
        for entry in (try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? [] {
            guard let pointer = text(entry.appendingPathComponent("gitdir")) else { continue }
            let candidate = resolve(pointer,relativeTo:entry).deletingLastPathComponent()
            if gitDir(candidate)?.resolvingSymlinksInPath() == entry.resolvingSymlinksInPath() { roots.insert(candidate.path) }
        }
        // A linked worktree's common directory normally is the main checkout's .git.
        if common.lastPathComponent == ".git",let main = gitDir(common.deletingLastPathComponent()),main.resolvingSymlinksInPath() == common.resolvingSymlinksInPath() { roots.insert(common.deletingLastPathComponent().path) }
        return roots.sorted()
    }
    public static func sessions(kind: AgentKind,project: String,storage: [URL]? = nil,executable: String? = nil,environment overrides: [String:String]? = nil) throws -> [AgentSession] {
        if kind == .codex,let executable {
            if let sessions = try? AgentCodexSessions.list(executable:executable,project:project,environment:overrides ?? environment) { return sessions }
        }
        if kind == .dsh,let executable { return try AgentDSHSessions.list(executable:executable,project:project,environment:overrides ?? environment) }
        if kind == .opencode {
            guard let executable else { return [] }
            let result = try ToolCommand.run(URL(fileURLWithPath:executable),arguments:["session","list","--format","json"],directory:URL(fileURLWithPath:project),timeout:30,environment:environment,maximumOutputBytes:16*1024*1024)
            guard result.succeeded else { throw GitError.command(result.timedOut ? "Agent session discovery timed out." : result.output) }
            return try openCodeSessions(Data(result.output.utf8),project:project)
        }
        let roots = storage ?? defaultStorage(kind)
        let projects = projectDirectories(project)
        var sessions: [String:AgentSession] = [:]
        for root in roots {
            guard let files = FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.contentModificationDateKey,.isRegularFileKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles]) else { continue }
            for case let file as URL in files {
                let info = try? file.resourceValues(forKeys:[.contentModificationDateKey,.isRegularFileKey,.isSymbolicLinkKey])
                if info?.isSymbolicLink == true { files.skipDescendants(); continue }
                // Claude subagents are owned by their parent session, not independently resumable.
                if file.lastPathComponent == "subagents" { files.skipDescendants(); continue }
                guard file.pathExtension == "jsonl",info?.isRegularFile == true else { continue }
                guard let handle = try? FileHandle(forReadingFrom:file) else { continue }
                let data = (try? handle.read(upToCount:256*1024)) ?? Data(); try? handle.close()
                if var session = parseSession(data,kind:kind,file:file.path,updated:info?.contentModificationDate?.timeIntervalSince1970 ?? 0),projects.contains(where:{ sameProject(session.cwd,$0) }) {
                    if kind == .claude || kind == .pi {
                        readJSONLines(file) { value in
                            let type = value["type"] as? String
                            let name = type == "custom-title" ? value["customTitle"] as? String : type == "session_info" ? value["name"] as? String : nil
                            if let name,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { session.title = name.replacingOccurrences(of:"\n",with:" ") }
                            else if session.title == session.id,let message = value["message"] as? [String:Any],type == "user" || message["role"] as? String == "user",let text = userText(message["content"]) { session.title = text.replacingOccurrences(of:"\n",with:" ") }
                        }
                    }
                    if sessions[session.id].map({ $0.updated < session.updated }) ?? true { sessions[session.id] = session }
                }
            }
        }
        if kind == .codex {
            for base in Set(roots.map { $0.deletingLastPathComponent() }) {
                readJSONLines(base.appendingPathComponent("session_index.jsonl")) { value in
                    guard let id = value["id"] as? String,var session = sessions[id],let title = value["thread_name"] as? String,!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
                    session.title = title.replacingOccurrences(of:"\n",with:" "); sessions[id] = session
                }
            }
        }
        return sessions.values.sorted { $0.updated > $1.updated }
    }
    private static func readJSONLines(_ file: URL,body: ([String:Any]) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom:file) else { return }; defer { try? handle.close() }
        var pending = Data()
        func consume(_ line: Data) { if let value = try? JSONSerialization.jsonObject(with:line) as? [String:Any] { body(value) } }
        while let chunk = try? handle.read(upToCount:64*1024),!chunk.isEmpty {
            pending.append(chunk)
            while let newline = pending.firstIndex(of:10) {
                consume(Data(pending[..<newline])); pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty { consume(pending) }
    }
    public static func parseSession(_ data: Data,kind: AgentKind,file: String,updated: Double) -> AgentSession? {
        var id: String?,cwd: String?,title: String?
        for line in data.split(separator:10) {
            guard let value = try? JSONSerialization.jsonObject(with:Data(line)) as? [String:Any] else { continue }
            let type = value["type"] as? String
            if kind == .codex,type == "session_meta",let payload = value["payload"] as? [String:Any] {
                id = payload["id"] as? String; cwd = payload["cwd"] as? String
            } else if kind == .pi,type == "session" {
                id = value["id"] as? String; cwd = value["cwd"] as? String
            } else if kind == .claude,value["isSidechain"] as? Bool != true {
                id = id ?? value["sessionId"] as? String; cwd = cwd ?? value["cwd"] as? String
            }
            if type == "custom-title" { title = value["customTitle"] as? String }
            if type == "session_info" { title = value["name"] as? String }
            if title == nil,(type == "user" || type == "message"),let message = value["message"] as? [String:Any],type == "user" || message["role"] as? String == "user" { title = userText(message["content"]) }
            if title == nil,kind == .codex,type == "event_msg",let payload = value["payload"] as? [String:Any],payload["type"] as? String == "user_message" { title = (payload["message"] as? String).map { String($0.prefix(120)) } }
            if title == nil,kind == .codex,type == "response_item",let payload = value["payload"] as? [String:Any],payload["role"] as? String == "user" {
                let text = userText(payload["content"])
                if let text,!text.hasPrefix("# AGENTS.md"),!text.hasPrefix("<environment_context>"),!text.hasPrefix("<permissions instructions>"),!text.hasPrefix("<INSTRUCTIONS>") { title = text }
            }
        }
        guard let id,!id.isEmpty,let cwd,cwd.hasPrefix("/"),!id.hasPrefix("-"),!id.contains("\0") else { return nil }
        return AgentSession(id:id,title:title?.replacingOccurrences(of:"\n",with:" ") ?? id,cwd:cwd,locator:kind == .pi ? file : id,updated:updated)
    }
    private static func userText(_ content: Any?) -> String? {
        if let text = content as? String,!text.isEmpty { return String(text.trimmingCharacters(in:.whitespacesAndNewlines).prefix(120)) }
        if let blocks = content as? [[String:Any]],let text = blocks.compactMap({ $0["text"] as? String }).first(where:{ !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }) { return String(text.trimmingCharacters(in:.whitespacesAndNewlines).prefix(120)) }
        return nil
    }
    public static func openCodeSessions(_ data: Data,project: String) throws -> [AgentSession] {
        let values = try JSONSerialization.jsonObject(with:data) as? [[String:Any]]
        guard let values else { throw GitError.command("Unsupported OpenCode session list format.") }
        let projects = projectDirectories(project)
        return values.compactMap { value -> AgentSession? in
            guard let id = value["id"] as? String,!id.isEmpty,!id.hasPrefix("-"),let cwd = value["directory"] as? String,projects.contains(where:{ sameProject(cwd,$0) }) else { return nil }
            let time = value["time"] as? [String:Any]
            let updated = (time?["updated"] as? Double ?? value["updated"] as? Double ?? 0)/1000
            return AgentSession(id:id,title:value["title"] as? String ?? id,cwd:cwd,locator:id,updated:updated)
        }.sorted { $0.updated > $1.updated }
    }
    public static func command(executable: String,kind: AgentKind,session: AgentSession? = nil) -> String {
        ([executable]+kind.arguments(session:session)).map(SSHRemote.quote).joined(separator:" ")
    }
}
