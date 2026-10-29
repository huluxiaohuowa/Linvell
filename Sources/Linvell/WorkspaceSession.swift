import Foundation

enum WorkspaceSession: Codable, Equatable {
    case local(path: String)
    case ssh(host: String,path: String)
    static let recentKey = "recentWorkspaceSessions"
    static let changed = Notification.Name("Linvell.RecentWorkspacesChanged")
    static let key = "lastWorkspaceSession"
    static let startupKey = "startupBehavior"
    static var shouldRestore: Bool { shouldRestore(defaults:.standard) }
    static func shouldRestore(defaults: UserDefaults) -> Bool { defaults.string(forKey:startupKey) != "empty" }
    static func save(_ location: Self,defaults: UserDefaults = .standard) {
        var locations = recent(defaults:defaults)
        if let data = try? JSONEncoder().encode(location) { defaults.set(data,forKey:key) }
         locations.removeAll { $0 == location }; locations.insert(location,at:0)
        if let data = try? JSONEncoder().encode(Array(locations.prefix(12))) { defaults.set(data,forKey:recentKey) }
        NotificationCenter.default.post(name:changed,object:nil)
    }
    static func recent(defaults: UserDefaults = .standard) -> [Self] {
        if let data = defaults.data(forKey:recentKey),let values = try? JSONDecoder().decode([Self].self,from:data) { return Array(values.prefix(12)) }
        return load(defaults:defaults).map { [$0] } ?? []
    }
    var path: String { switch self { case .local(let path),.ssh(_,let path): return path } }
    var title: String {
        let name = URL(fileURLWithPath:path).lastPathComponent
        switch self { case .local: return name; case .ssh(let host,_): return L.text("Remote")+" · "+host+" · "+name }
    }
    static func load(defaults: UserDefaults = .standard) -> Self? {
        if let data = defaults.data(forKey:key),let value = try? JSONDecoder().decode(Self.self,from:data) { return value }
        return defaults.string(forKey:"lastProject").map { .local(path:$0) }
    }
}
