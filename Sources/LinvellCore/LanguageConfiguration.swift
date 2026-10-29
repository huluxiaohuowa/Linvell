import Foundation

public enum LanguageConfiguration {
    public static func merge(_ base: [String:Any],_ overrides: [String:Any]) -> [String:Any] {
        var result = base
        for (key,value) in overrides {
            if let object = value as? [String:Any],let previous = result[key] as? [String:Any] { result[key] = merge(previous,object) }
            else { result[key] = value }
        }
        return result
    }
    public static func insert(_ value: Any,path: ArraySlice<String>,into object: inout [String:Any]) {
        guard let key = path.first else { return }
        if path.count == 1 { object[key] = value; return }
        var child = object[key] as? [String:Any] ?? [:]
        insert(value,path:path.dropFirst(),into:&child); object[key] = child
    }
}
