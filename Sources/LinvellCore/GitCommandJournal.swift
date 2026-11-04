import Foundation

/// Session diagnostics retain redacted argv and execution status, never stdin or source output.
public final class GitCommandJournal: @unchecked Sendable {
    public struct Entry {
        public let operation: UUID?
        public let date: Date
        public let command: String
        public let elapsed: TimeInterval
        public let succeeded: Bool
        public var readOnly = false
        public var arguments: [String] = []
        public var exitCode: Int32? = nil
        public var timedOut = false
        public var outputBytes = 0
        public var failure: String? = nil
        public var displayCommand: String { "git "+arguments.map { value in
            value.range(of:#"[^a-zA-Z0-9_./:=+@%-]"#,options:.regularExpression) == nil ? value : "'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"
        }.joined(separator:" ") }
        public var details: String {
            var status = timedOut ? "Timed out" : succeeded ? "Succeeded" : "Failed"
            if let exitCode { status += " · exit "+String(exitCode) }
            var lines = [displayCommand,status,String(outputBytes)+" output bytes (contents omitted)"]
            if let failure { lines.append(failure) }
            return lines.joined(separator:"\n")
        }
    }

    @TaskLocal public static var operation: UUID?
    public static let shared = GitCommandJournal()
    private let lock = NSLock()
    private var records: [String:[Entry]] = [:]

    func append(_ entry: Entry,scope: String) {
        lock.lock()
        defer { lock.unlock() }
        records[scope,default:[]].insert(entry,at:0)
        if records[scope,default:[]].count > 200 { records[scope]?.removeLast() }
    }

    public func clear(scope: String) {
        lock.lock(); defer { lock.unlock() }
        records.removeValue(forKey:scope)
    }

    public func entries(for scope: String) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return records[scope] ?? []
    }
}

extension GitCommandJournal {
    /// Classify failures without retaining potentially sensitive stderr or patch/source lines.
    static func failureSummary(_ output: String) -> String {
        let value = output.lowercased()
        if value.contains("patch failed") || value.contains("patch does not apply") { return "The selected patch no longer applies to the index. Refresh the diff and retry." }
        if value.contains("authentication failed") || value.contains("permission denied") || value.contains("could not read username") { return "Remote authentication or authorization failed." }
        if value.contains("could not resolve host") || value.contains("could not resolve hostname") || value.contains("connection refused") || value.contains("network is unreachable") { return "The remote host could not be reached." }
        if value.contains("cannot lock ref") || value.contains("index.lock") || value.contains("another git process") { return "A repository reference or index is locked by another operation." }
        if value.contains("no upstream") || value.contains("has no upstream") { return "This branch has no upstream. Use Push With Upstream to publish it." }
        if value.contains("non-fast-forward") || value.contains("fetch first") { return "The remote contains changes that must be integrated before pushing." }
        if value.contains("conflict") || value.contains("unmerged") { return "The operation requires resolving repository conflicts." }
        if value.contains("unknown revision") || value.contains("bad revision") || value.contains("ambiguous argument") { return "The requested revision or path is unavailable." }
        return "Git command failed; output contents are omitted for privacy."
    }

    static func redactedArguments(_ arguments: [String]) -> [String] {
        var hide = false
        return arguments.map { value in
            if hide { hide = false; return "[REDACTED]" }
            if ["-m","--message","--password","--token","--access-token","--exec","-x","--author","--upload-pack","--receive-pack","--config-env"].contains(value) { hide = true; return value }
            if value == "-c" || value.lowercased().contains("extraheader") { hide = true; return value == "-c" ? value : "[REDACTED]" }
            if value.hasPrefix("--message=") || value.hasPrefix("-m") && value.count > 2 && !value.hasPrefix("--") { return "[REDACTED MESSAGE]" }
            return String(value.prefix(8192))
                .replacingOccurrences(of:#"(\b[a-zA-Z][a-zA-Z0-9+.-]*://)[^\s/@]+@"#,with:"$1[REDACTED]@",options:.regularExpression)
                .replacingOccurrences(of:#"(?i)((?:authorization|proxy-authorization)\s*[:=]\s*)[^\r\n]+"#,with:"$1[REDACTED]",options:.regularExpression)
                .replacingOccurrences(of:#"(?i)((?:[?&]|--|\b)(?:access[_-]?token|password|token|private[_-]?token)=)[^\s&#]+"#,with:"$1[REDACTED]",options:.regularExpression)
                .replacingOccurrences(of:#"(?i)((?:http\.[^\s=]*extraheader|http\.extraheader)=).*"#,with:"$1[REDACTED]",options:.regularExpression)
        }
    }
}
