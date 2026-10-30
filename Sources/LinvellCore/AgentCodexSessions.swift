import Foundation
import Darwin

/// Uses the same thread/list API as Codex's resume picker, without creating a turn.
public enum AgentCodexSessions {
    public static func list(executable: String,project: String,environment: [String:String] = AgentCLI.environment,remote: SSHRemote? = nil,projects: [String]? = nil) throws -> [AgentSession] {
        let projects = projects ?? (remote == nil ? AgentCLI.projectDirectories(project) : [project])
        let process = Process(),input = Pipe(),output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = remote == nil ? URL(fileURLWithPath:project) : FileManager.default.homeDirectoryForCurrentUser
        var environment = environment
        environment["PATH"] = (executable as NSString).deletingLastPathComponent+":"+(environment["PATH"] ?? "")
        process.environment = environment
        if let remote {
            var command = "PATH="+SSHRemote.quote((executable as NSString).deletingLastPathComponent)+":\"$PATH\"; export PATH; "
            if let home = environment["CODEX_HOME"] { command += "export CODEX_HOME="+SSHRemote.quote(home)+"; " }
            command += "exec "+SSHRemote.quote(executable)+" app-server"
            process.executableURL = URL(fileURLWithPath:"/usr/bin/ssh")
            process.arguments = remote.transportArguments(command:RunTasks.remoteCommand(directory:project,command:"/bin/sh -c "+SSHRemote.quote(command)))
        } else { process.executableURL = URL(fileURLWithPath:executable); process.arguments = ["app-server"] }
        let mailbox = Mailbox()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1)
        try process.run()
        DispatchQueue.global(qos:.utility).async {
            var pending = Data()
            var buffer = [UInt8](repeating:0,count:64*1024)
            while true {
                let count = Darwin.read(output.fileHandleForReading.fileDescriptor,&buffer,buffer.count)
                guard count > 0 else { break }
                pending.append(contentsOf:buffer.prefix(count))
                guard pending.count <= 16*1024*1024 else { break }
                while let end = pending.firstIndex(of:10) {
                    let line = Data(pending[..<end]); pending.removeSubrange(...end)
                    if let value = try? JSONSerialization.jsonObject(with:line) as? [String:Any],let id = value["id"] as? Int { mailbox.receive(id,value) }
                }
            }
            try? output.fileHandleForReading.close()
            mailbox.finish()
        }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval:0.01) }
            if process.isRunning { kill(process.processIdentifier,SIGKILL) }
        }
        var nextID = 0
        func send(_ value: [String:Any]) throws { var bytes = try JSONSerialization.data(withJSONObject:value); bytes.append(10); try input.fileHandleForWriting.write(contentsOf:bytes) }
        func request(_ method: String,_ params: [String:Any]) throws -> [String:Any] {
            nextID += 1; try send(["id":nextID,"method":method,"params":params])
            let response = try mailbox.wait(nextID)
            if response["error"] != nil { throw GitError.command("The Codex CLI could not list sessions through its app-server API.") }
            guard let result = response["result"] as? [String:Any] else { throw GitError.command("Unsupported Codex session response.") }; return result
        }
        _ = try request("initialize",["clientInfo":["name":"linvell","version":"1"]])
        try send(["method":"initialized"])
        var sessions: [String:AgentSession] = [:]
        for archived in [false,true] {
            var cursor: String?,seen = Set<String>()
            repeat {
                var params: [String:Any] = ["cwd":projects.count == 1 ? projects[0] as Any : projects as Any,"limit":100,"archived":archived,"modelProviders":[],"sourceKinds":["cli","vscode","appServer","exec","unknown"],"sortKey":"updated_at"]
                params["cursor"] = cursor
                let page = try request("thread/list",params)
                for thread in page["data"] as? [[String:Any]] ?? [] {
                    if let cwd = thread["cwd"] as? String,projects.contains(where:{ AgentCLI.sameProject(cwd,$0) }),let session = parseThread(thread,project:cwd) { sessions[session.id] = session }
                }
                cursor = page["nextCursor"] as? String
                if let cursor,!seen.insert(cursor).inserted { throw GitError.command("Codex returned a repeated session page.") }
            } while cursor != nil
        }
        return sessions.values.sorted { $0.updated > $1.updated }
    }
    public static func parseThread(_ thread: [String:Any],project: String) -> AgentSession? {
        guard let id = thread["id"] as? String,!id.isEmpty,!id.hasPrefix("-"),let cwd = thread["cwd"] as? String,AgentCLI.sameProject(cwd,project) else { return nil }
        let title = [thread["name"],thread["title"],thread["preview"]].compactMap { $0 as? String }.first { !$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty } ?? "Untitled session"
        return AgentSession(id:id,title:title.replacingOccurrences(of:"\n",with:" "),cwd:cwd,locator:id,updated:thread["updatedAt"] as? Double ?? 0)
    }
    private final class Mailbox {
        let condition = NSCondition()
        var replies: [Int:[String:Any]] = [:]
        var ended = false
        func receive(_ id: Int,_ value: [String:Any]) { condition.lock(); replies[id] = value; condition.broadcast(); condition.unlock() }
        func finish() { condition.lock(); ended = true; condition.broadcast(); condition.unlock() }
        func wait(_ id: Int) throws -> [String:Any] {
            condition.lock(); defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(20)
            while replies[id] == nil && !ended {
                if !condition.wait(until:deadline) { throw GitError.command("Codex session discovery timed out.") }
            }
            guard let reply = replies.removeValue(forKey:id) else { throw GitError.command("The Codex app-server session API is unavailable.") }; return reply
        }
    }
}
