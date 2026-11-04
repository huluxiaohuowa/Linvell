import Foundation
import LinvellCore

final class GitAutoFetchScheduler {
    struct Event {
        let key: String
        let operation: UUID
        let error: String?
    }
    static let shared = GitAutoFetchScheduler()
    static let finished = Notification.Name("Linvell.AutoFetchFinished")
    private let defaults: UserDefaults
    private let fetch: (WorkspaceSession) throws -> Void
    private let queue = OperationQueue()
    private var timer: Timer?
    private var attempts: [String:Date] = [:]
    private var running: Set<String> = []

    init(defaults: UserDefaults = .standard,fetch: ((WorkspaceSession) throws -> Void)? = nil) {
        self.defaults = defaults
        self.fetch = fetch ?? { location in
            let repo: GitRepository
            switch location {
            case .local(let path): repo = GitRepository(root:URL(fileURLWithPath:path))
            case .ssh(let host,let path): repo = GitRepository(remote:try SSHRemote(host:host),directory:path)
            }
            _ = try repo.resolvedWorkingTree().run(["fetch","--all"],timeout:120)
        }
        queue.maxConcurrentOperationCount = 2
    }
    static func key(_ location: WorkspaceSession) -> String {
        switch location {
        case .local(let path): return "git.autoFetch.local:"+path
        case .ssh(let host,let path): return "git.autoFetch."+host+":"+path
        }
    }
    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval:15,repeats:true) { [weak self] _ in self?.tick() }
    }
    func stop() { timer?.invalidate(); timer = nil; queue.cancelAllOperations() }
    deinit { timer?.invalidate() }

    /// All scheduling state is main-thread owned. Disabled and archived repositories never fetch.
    func tick(now: Date = Date()) {
        let saved = defaults.data(forKey:"git.savedRepositories").flatMap { try? JSONDecoder().decode([WorkspaceSession].self,from:$0) } ?? []
        var locations = saved
        for value in WorkspaceSession.recent(defaults:defaults) where !locations.contains(value) { locations.append(value) }
        let archived = Set(defaults.stringArray(forKey:"git.archivedRepositories") ?? [])
        for location in locations where !archived.contains(location.repositoryID) {
            let key = Self.key(location)
            let enabled = defaults.object(forKey:key) as? Bool ?? defaults.bool(forKey:"git.defaultAutoFetch")
            guard enabled,!running.contains(key) else { continue }
            let minutes = defaults.object(forKey:key+".minutes") as? Int ?? defaults.object(forKey:"git.defaultFetchMinutes") as? Int ?? 5
            let last = max(attempts[key] ?? now,defaults.object(forKey:key+".lastSuccess") as? Date ?? .distantPast)
            if attempts[key] == nil { attempts[key] = now }
            guard now.timeIntervalSince(last) >= Double(min(1440,max(1,minutes)))*60 else { continue }
            attempts[key] = now; running.insert(key)
            let operation = UUID()
            queue.addOperation { [weak self] in
                guard let self else { return }
                let result = Result { try GitCommandJournal.$operation.withValue(operation) { try self.fetch(location) } }
                DispatchQueue.main.async {
                    self.running.remove(key)
                    let error: String?
                    switch result {
                    case .success: self.defaults.set(Date(),forKey:key+".lastSuccess"); error = nil
                    case .failure(let value): error = value.localizedDescription
                    }
                    NotificationCenter.default.post(name:Self.finished,object:Event(key:key,operation:operation,error:error))
                }
            }
        }
    }
}
