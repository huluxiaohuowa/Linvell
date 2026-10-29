import Foundation

public struct CodeSymbol {
    public let name: String,container: String,kind: Int,location: CodeLocation
    public static func parse(_ value: Any,documentURI: String? = nil) throws -> [CodeSymbol] {
        var results: [CodeSymbol] = []; var seen = Set<String>()
        func visit(_ values: [[String:Any]],container: String,depth: Int) throws {
            guard depth < 32 else { return }
            for value in values.prefix(10_000-results.count) {
                guard let name = value["name"] as? String else { continue }
                let scope = value["containerName"] as? String ?? container
                let raw = value["location"] as? [String:Any] ?? documentURI.map { ["uri":$0,"range":value["selectionRange"] ?? value["range"] ?? NSNull()] }
                if let raw,let location = try? CodeLocation.locations(raw).first,seen.insert(location.uri+"|\(location.range.start.line)|\(location.range.start.character)|"+name).inserted {
                    results.append(CodeSymbol(name:name,container:scope,kind:value["kind"] as? Int ?? 0,location:location))
                }
                if let children = value["children"] as? [[String:Any]] { try visit(children,container:scope.isEmpty ? name : scope+"."+name,depth:depth+1) }
                if results.count >= 10_000 { return }
            }
        }
        try visit(value as? [[String:Any]] ?? [],container:"",depth:0); return results
    }
}
