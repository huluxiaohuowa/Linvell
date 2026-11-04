import Foundation

struct GitCommitSnippet: Codable, Identifiable {
    var id = UUID()
    var text: String
    var favorite = true
    static func load(defaults: UserDefaults = .standard) -> [Self] {
        if let data = defaults.data(forKey:"git.commitSnippetEntries"),let values = try? JSONDecoder().decode([Self].self,from:data) { return values }
        let values = (defaults.stringArray(forKey:"git.commitSnippets") ?? []).map { Self(text:$0) }
        if !values.isEmpty { save(values,defaults:defaults) }
        return values
    }
    static func save(_ values: [Self],defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(values) { defaults.set(data,forKey:"git.commitSnippetEntries") }
    }
}
