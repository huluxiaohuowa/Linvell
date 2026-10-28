import Foundation

enum WorkspaceSession: Codable, Equatable {
    case local(path: String)
    case ssh(host: String,path: String)
    static let key = "lastWorkspaceSession"
    static let startupKey = "startupBehavior"
    static var shouldRestore: Bool { shouldRestore(defaults:.standard) }
    static func shouldRestore(defaults: UserDefaults) -> Bool { defaults.string(forKey:startupKey) != "empty" }
    static func save(_ location: Self,defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(location) { defaults.set(data,forKey:key) }
    }
    static func load(defaults: UserDefaults = .standard) -> Self? {
        if let data = defaults.data(forKey:key),let value = try? JSONDecoder().decode(Self.self,from:data) { return value }
        return defaults.string(forKey:"lastProject").map { .local(path:$0) }
    }
}
