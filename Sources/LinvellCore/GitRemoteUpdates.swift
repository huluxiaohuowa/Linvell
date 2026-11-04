import Foundation

/// A shared fetch belongs to the repository, rather than any observing view.
private final class GitFetchCoordinator {
    static let shared = GitFetchCoordinator()
    final class Flight { var result: Result<Date,Error>? }
    let condition = NSCondition()
    var flights: [String:Flight] = [:]
    var successful: [String:Date] = [:]
    func fetch(key: String,repository: String,since: Date?,work: () throws -> Void) throws -> Date {
        condition.lock()
        if let since,let date = successful[key == repository+"\0default" ? repository : key],date >= since { condition.unlock(); return date }
        if let flight = flights[key] {
            while flight.result == nil { condition.wait() }
            let result = flight.result!; condition.unlock(); return try result.get()
        }
        let flight = Flight(); flights[key] = flight; condition.unlock()
        let result = Result { try work(); return Date() }
        condition.lock()
        flight.result = result
        if case .success(let date) = result { successful[repository] = date; successful[key] = date }
        flights.removeValue(forKey:key); condition.broadcast(); condition.unlock()
        return try result.get()
    }
}

public struct GitTrackingState {
    public let remote: String
    public let branch: String
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
}

extension GitRepository {
    @discardableResult
    public func fetch(tags: Bool = false,prune: Bool = false,scheduledSince: Date? = nil) throws -> Date {
        let repo = try resolvedWorkingTree()
        let path = remote == nil ? repo.root.resolvingSymlinksInPath().path : repo.directory
        let identity = (remote?.host ?? "local")+"\0"+path
        return try GitFetchCoordinator.shared.fetch(key:identity+(tags ? "\0tags" : "\0default")+(prune ? "\0prune" : ""),repository:identity,since:scheduledSince) {
            _ = try repo.run(["fetch","--all"]+(tags ? ["--tags"] : [])+(prune ? ["--prune"] : []),timeout:120)
        }
    }
    public func trackingState() throws -> GitTrackingState? {
        let branch = try run(["branch","--show-current"]).trimmingCharacters(in:.newlines)
        guard !branch.isEmpty else { return nil }
        let raw = try run(["for-each-ref","--format=%(upstream:remotename)%00%(upstream:remoteref)%00%(upstream)","refs/heads/"+branch]).trimmingCharacters(in:.newlines)
        let fields = raw.components(separatedBy:"\0")
        if fields.count == 3,!fields[0].isEmpty,!fields[2].isEmpty {
            let counts = try run(["rev-list","--left-right","--count","HEAD..."+fields[2],"--"]).split(whereSeparator:\.isWhitespace).compactMap { Int($0) }
            guard counts.count == 2 else { throw GitError.command("Invalid tracking counts from Git.") }
            return .init(remote:fields[0],branch:String(fields[1].dropFirst("refs/heads/".count)),upstream:fields[2],ahead:counts[0],behind:counts[1])
        }
        let remotes = try run(["remote"]).split(whereSeparator:\.isNewline).map(String.init)
        let configured = (try? run(["config","--get","branch."+branch+".pushRemote"])) ?? (try? run(["config","--get","remote.pushDefault"]))
        let name = configured?.trimmingCharacters(in:.newlines)
        let remote = name.flatMap { remotes.contains($0) ? $0 : nil } ?? (remotes.contains("origin") ? "origin" : remotes.count == 1 ? remotes[0] : nil)
        guard let remote else { return nil }
        guard let count = Int(try run(["rev-list","--count","HEAD","--not","--remotes="+remote,"--"]).trimmingCharacters(in:.whitespacesAndNewlines)) else { throw GitError.command("Invalid tracking counts from Git.") }
        return .init(remote:remote,branch:branch,upstream:nil,ahead:count,behind:0)
    }
    public func pushWithUpstream(remote: String,branch: String) throws {
        _ = try run(["check-ref-format","refs/heads/"+branch])
        _ = try run(["push","--set-upstream","--",remote,branch],timeout:120)
    }
    public func pushTrackingBranch() throws {
        guard let tracking = try trackingState() else { throw GitError.command("Choose a remote and branch in Push With Upstream.") }
        if tracking.upstream == nil { try pushWithUpstream(remote:tracking.remote,branch:tracking.branch) }
        else { _ = try run(["push","--",tracking.remote,"HEAD:refs/heads/"+tracking.branch],timeout:120) }
    }
}
