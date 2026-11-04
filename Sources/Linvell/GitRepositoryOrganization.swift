import AppKit
import LinvellCore

extension WorkspaceSession {
    var repositoryID: String {
        switch self {
        case .local(let path): return "local:"+path
        case .ssh(let host,let path): return "ssh:"+host+":"+path
        }
    }
}

enum GitRepositorySort: String, CaseIterable {
    case manual, name, recentlyOpened, recentlyModified, recentlyAdded
    var title: String {
        switch self {
        case .manual: return "Manual Order"
        case .name: return "Name"
        case .recentlyOpened: return "Recently Opened"
        case .recentlyModified: return "Recently Modified"
        case .recentlyAdded: return "Recently Added"
        }
    }
}

enum GitRepositoryOrganization {
    static func register(_ locations: [WorkspaceSession],defaults: UserDefaults = .standard) {
        var dates = defaults.dictionary(forKey:"git.repositoryAdded") as? [String:Double] ?? [:]
        for location in locations where dates[location.repositoryID] == nil {
            dates[location.repositoryID] = Date().timeIntervalSince1970
        }
        defaults.set(dates,forKey:"git.repositoryAdded")
    }

    static func sorted(_ locations: [WorkspaceSession],mode: GitRepositorySort,ascending: Bool,
                       aliases: [String:String],dates: [String:Double],order: [String]) -> [WorkspaceSession] {
        let ranks = Dictionary(order.enumerated().map { ($0.element,$0.offset) },uniquingKeysWith:min)
        return locations.enumerated().sorted { a,b in
            let left = a.element.repositoryID,right = b.element.repositoryID
            if mode == .manual {
                return (ranks[left] ?? order.count,a.offset) < (ranks[right] ?? order.count,b.offset)
            }
            if mode == .name {
                let comparison = (aliases[left] ?? a.element.title).localizedStandardCompare(aliases[right] ?? b.element.title)
                if comparison != .orderedSame { return ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
            } else if dates[left,default:0] != dates[right,default:0] {
                return ascending ? dates[left,default:0] < dates[right,default:0] : dates[left,default:0] > dates[right,default:0]
            }
            return a.offset < b.offset
        }.map(\.element)
    }
}

enum GitCommitTimeMode: String, CaseIterable {
    case relative, absolute, hybrid
    static var current: Self {
        if let value = UserDefaults.standard.string(forKey:"git.commitTimeMode"),let mode = Self(rawValue:value) { return mode }
        if UserDefaults.standard.object(forKey:"git.relativeCommitTimes") != nil {
            return UserDefaults.standard.bool(forKey:"git.relativeCommitTimes") ? .relative : .absolute
        }
        return .hybrid
    }
    func usesAbsolute(_ date: Date,now: Date) -> Bool {
        self == .absolute || (self == .hybrid && (date > now || now.timeIntervalSince(date) >= 7*24*60*60))
    }
    func display(_ value: String,now: Date = Date()) -> String {
        guard let date = ISO8601DateFormatter().date(from:value) else { return String(value.prefix(10)) }
        return usesAbsolute(date,now:now) ? DateFormatter.localizedString(from:date,dateStyle:.medium,timeStyle:.short)
            : RelativeDateTimeFormatter().localizedString(for:date,relativeTo:now)
    }
}


final class GitRepositoryPickerRefresh {
    private weak var picker: QuickPicker?
    private let locations: [WorkspaceSession]
    private let aliases: [String:String]
    private let ascending: Bool
    private let order: [String]
    private var timer: Timer?
    private var running = false
    init(picker: QuickPicker,locations: [WorkspaceSession],aliases: [String:String],ascending: Bool,order: [String]) {
        self.picker = picker; self.locations = locations; self.aliases = aliases; self.ascending = ascending; self.order = order
    }
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval:20,repeats:true) { [weak self] _ in
            if NSApp.isActive { self?.refresh() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; picker = nil }
    deinit { timer?.invalidate() }
    private func refresh() {
        guard !running,picker != nil else { return }; running = true
        DispatchQueue.global(qos:.utility).async { [weak self] in
            guard let self else { return }
            var dates: [String:Double] = [:]
            for location in self.locations {
                let repository: GitRepository
                switch location {
                case .local(let path): repository = GitRepository(root:URL(fileURLWithPath:path))
                case .ssh(let host,let path):
                    guard let remote = try? SSHRemote(host:host) else { continue }
                    repository = GitRepository(remote:remote,directory:path)
                }
                if let date = try? repository.modificationDate() { dates[location.repositoryID] = date.timeIntervalSince1970 }
            }
            DispatchQueue.main.async {
                self.running = false
                guard let picker = self.picker else { return }
                UserDefaults.standard.set(dates,forKey:"git.repositoryModified")
                let sorted = GitRepositoryOrganization.sorted(self.locations,mode:.recentlyModified,ascending:self.ascending,aliases:self.aliases,dates:dates,order:self.order)
                picker.updateRepositoryOrder(sorted.map(\.repositoryID))
            }
        }
    }
}

extension GitRepositoryOrganization {
    static func locations(defaults: UserDefaults = .standard) -> [WorkspaceSession] {
        let saved = defaults.data(forKey:"git.savedRepositories").flatMap { try? JSONDecoder().decode([WorkspaceSession].self,from:$0) } ?? []
        return saved+WorkspaceSession.recent(defaults:defaults).filter { !saved.contains($0) }
    }
    static func persist(_ locations: [WorkspaceSession],defaults: UserDefaults = .standard) {
        register(locations,defaults:defaults)
        if let data = try? JSONEncoder().encode(locations) { defaults.set(data,forKey:"git.savedRepositories") }
    }
    static func remove(_ ids: Set<String>,defaults: UserDefaults = .standard) {
        persist(locations(defaults:defaults).filter { !ids.contains($0.repositoryID) },defaults:defaults)
        let recent = WorkspaceSession.recent(defaults:defaults).filter { !ids.contains($0.repositoryID) }
        if let data = try? JSONEncoder().encode(recent) { defaults.set(data,forKey:WorkspaceSession.recentKey) }
        for key in ["git.repositoryAliases","git.repositoryGroups","git.repositoryAdded","git.repositoryOpened","git.repositoryModified"] {
            var values = defaults.dictionary(forKey:key) ?? [:]; for id in ids { values.removeValue(forKey:id) }; defaults.set(values,forKey:key)
        }
        defaults.set((defaults.stringArray(forKey:"git.archivedRepositories") ?? []).filter { !ids.contains($0) },forKey:"git.archivedRepositories")
        if let current = WorkspaceSession.load(defaults:defaults),ids.contains(current.repositoryID) { defaults.removeObject(forKey:WorkspaceSession.key); defaults.removeObject(forKey:"lastProject") }
    }
    @discardableResult
    static func relocate(_ location: WorkspaceSession,to path: String?,defaults: UserDefaults = .standard) -> String? {
        var persistenceError: String?
        do { try GitWorktreePersistence.relocate(location,to:path) } catch { persistenceError = error.localizedDescription }
        let replacement: WorkspaceSession? = path.map { switch location { case .local: return .local(path:$0); case .ssh(let host,_): return .ssh(host:host,path:$0) } }
        let id = location.repositoryID
        for key in ["git.savedRepositories",WorkspaceSession.recentKey] {
            let values = defaults.data(forKey:key).flatMap { try? JSONDecoder().decode([WorkspaceSession].self,from:$0) } ?? []
            let updated = values.compactMap { $0 == location ? replacement : $0 }
            if let data = try? JSONEncoder().encode(updated) { defaults.set(data,forKey:key) }
        }
        for key in ["git.repositoryAliases","git.repositoryGroups","git.repositoryAdded","git.repositoryOpened","git.repositoryModified","git.repositoryWorktreeVisibility"] {
            var values = defaults.dictionary(forKey:key) ?? [:]
            if let value = values.removeValue(forKey:id),let replacement { values[replacement.repositoryID] = value }; defaults.set(values,forKey:key)
        }
        for key in ["git.repositoryOrder","git.repositoryRootOrder","git.archivedRepositories"] { defaults.set((defaults.stringArray(forKey:key) ?? []).compactMap { $0 == id ? replacement?.repositoryID : $0 },forKey:key) }
        let oldKey = GitAutoFetchScheduler.key(location)
        for suffix in ["",".minutes",".lastSuccess",".error"] {
            if let value = defaults.object(forKey:oldKey+suffix),let replacement { defaults.set(value,forKey:GitAutoFetchScheduler.key(replacement)+suffix) }; defaults.removeObject(forKey:oldKey+suffix)
        }
        if WorkspaceSession.load(defaults:defaults) == location {
            if let replacement,let data = try? JSONEncoder().encode(replacement) { defaults.set(data,forKey:WorkspaceSession.key) }
            else { defaults.removeObject(forKey:WorkspaceSession.key) }
        }
        var families = defaults.dictionary(forKey:"git.repositoryWorktreeFamilies") as? [String:String] ?? [:]
        if let family = families.removeValue(forKey:id),let replacement { families[replacement.repositoryID] = family }
        if let replacement { families = families.mapValues { $0 == id ? replacement.repositoryID : $0 } }
        defaults.set(families,forKey:"git.repositoryWorktreeFamilies")
        var errors = defaults.dictionary(forKey:"git.autoFetchErrors") as? [String:String] ?? [:]
        if let error = errors.removeValue(forKey:oldKey),let replacement { errors[GitAutoFetchScheduler.key(replacement)] = error }; defaults.set(errors,forKey:"git.autoFetchErrors")
        return persistenceError
    }
    static func repository(_ location: WorkspaceSession) throws -> GitRepository {
        switch location { case .local(let path): return GitRepository(root:URL(fileURLWithPath:path))
        case .ssh(let host,let path): return GitRepository(remote:try SSHRemote(host:host),directory:path) }
    }
    static func showsWorktrees(_ location: WorkspaceSession,defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey:"git.enableWorktrees") as? Bool ?? true) && (defaults.dictionary(forKey:"git.repositoryWorktreeVisibility")?[worktreePreferenceKey(location,defaults:defaults)] as? Bool ?? true)
    }
}

extension GitRepositoryOrganization {
    static func registerWorktreeFamily(_ worktrees: [GitWorktreeEntry],location: WorkspaceSession,defaults: UserDefaults = .standard) {
        guard let primary = worktrees.first else { return }
        func locationAt(_ path: String) -> WorkspaceSession { switch location { case .local: return .local(path:path); case .ssh(let host,_): return .ssh(host:host,path:path) } }
        let family = locationAt(primary.path).repositoryID
        var families = defaults.dictionary(forKey:"git.repositoryWorktreeFamilies") as? [String:String] ?? [:]
        let before = families
        for tree in worktrees { families[locationAt(tree.path).repositoryID] = family }; families[location.repositoryID] = family
        if families != before { defaults.set(families,forKey:"git.repositoryWorktreeFamilies") }
        var preferences = defaults.dictionary(forKey:"git.repositoryWorktreeVisibility") as? [String:Bool] ?? [:]
        let previous = preferences
        if preferences[family] == nil,let inherited = preferences[location.repositoryID] ?? worktrees.compactMap({ preferences[locationAt($0.path).repositoryID] }).first { preferences[family] = inherited }
        for tree in worktrees { let id = locationAt(tree.path).repositoryID; if id != family { preferences.removeValue(forKey:id) } }
        if preferences != previous { defaults.set(preferences,forKey:"git.repositoryWorktreeVisibility") }
    }
    static func worktreePreferenceKey(_ location: WorkspaceSession,defaults: UserDefaults = .standard) -> String {
        (defaults.dictionary(forKey:"git.repositoryWorktreeFamilies") as? [String:String])?[location.repositoryID] ?? location.repositoryID
    }
    static func setWorktreesEnabled(_ enabled: Bool,for location: WorkspaceSession,defaults: UserDefaults = .standard) {
        var values = defaults.dictionary(forKey:"git.repositoryWorktreeVisibility") as? [String:Bool] ?? [:]
        values[worktreePreferenceKey(location,defaults:defaults)] = enabled; defaults.set(values,forKey:"git.repositoryWorktreeVisibility")
    }
}
