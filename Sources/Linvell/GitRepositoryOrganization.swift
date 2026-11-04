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
