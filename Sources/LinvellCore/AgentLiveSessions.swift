import Foundation

/// Match a live CLI to its own session file. Titles and recency are not identities.
public enum AgentLiveSessions {
    public struct ProcessSnapshot {
        public let id: UUID
        public let pid: Int32
        public let directory: String
        public init(id: UUID,pid: Int32,directory: String) { self.id = id; self.pid = pid; self.directory = directory }
    }
    public static func bindings(_ processes: [ProcessSnapshot],sessions: [AgentSession]) -> [UUID:String] {
        guard !processes.isEmpty,!sessions.isEmpty,
              let listing = try? ToolCommand.run(URL(fileURLWithPath:"/bin/ps"),arguments:["-axo","pid=,ppid="],directory:nil,timeout:3),listing.succeeded else { return [:] }
        let edges = listing.output.split(separator:"\n").compactMap { line -> (Int32,Int32)? in
            let parts = line.split(whereSeparator:{ $0.isWhitespace })
            guard parts.count == 2,let pid = Int32(parts[0]),let parent = Int32(parts[1]) else { return nil }
            return (pid,parent)
        }
        var result: [UUID:String] = [:]
        for process in processes {
            var pids: Set<Int32> = [process.pid],previous = 0
            while previous != pids.count { previous = pids.count; for (pid,parent) in edges where pids.contains(parent) { pids.insert(pid) } }
            guard let files = try? ToolCommand.run(URL(fileURLWithPath:"/usr/sbin/lsof"),arguments:["-a","-p",pids.sorted().map(String.init).joined(separator:","),"-Fn"],directory:nil,timeout:3) else { continue }
            let names = files.output.split(separator:"\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }.filter { $0.hasSuffix(".jsonl") || $0.hasSuffix(".zstd") || $0.hasSuffix("/session.lock") }
            let matches = sessions.filter { session in
                AgentCLI.sameProject(session.cwd,process.directory) && names.contains { name in
                    name == session.locator || name.contains(session.id)
                }
            }
            if Set(matches.map(\.id)).count == 1 { result[process.id] = matches.first!.id }
        }
        return result
    }
}
