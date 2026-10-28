import Foundation

public enum PackageEcosystem: String, CaseIterable { case node,python,dotnet }
public enum PackageOperation { case list,install,update,remove,outdated,audit }
public struct PackageRecord {
    public let name: String
    public let version: String
    public let latest: String?
    public init(name: String,version: String,latest: String? = nil) { self.name = name; self.version = version; self.latest = latest }
}
public enum PackageToolFailure: LocalizedError {
    case invalidName,invalidVersion,unreadableResponse,missingRequirements
    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a package name, not a command, local path or URL."
        case .invalidVersion: return "The package version contains unsupported characters."
        case .unreadableResponse: return "The tool did not return a supported JSON response. See its output for details."
        case .missingRequirements: return "Choose a package or add requirements.txt before installing Python dependencies."
        }
    }
}
public enum PackageCommands {
    public static func arguments(ecosystem: PackageEcosystem,operation: PackageOperation,name: String = "",version: String = "",hasRequirements: Bool = false) throws -> [String] {
        let identifier = name.trimmingCharacters(in:.whitespacesAndNewlines),version = version.trimmingCharacters(in:.whitespacesAndNewlines)
        if !identifier.isEmpty {
            let pattern = ecosystem == .node ? #"^(?:@[A-Za-z0-9][A-Za-z0-9._~-]*/)?[A-Za-z0-9][A-Za-z0-9._~-]*$"# : #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#
            guard identifier.range(of:pattern,options:.regularExpression) != nil else { throw PackageToolFailure.invalidName }
        }
        guard version.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || Array(".+-_~^*<>=!,|".utf8).contains($0) }) else { throw PackageToolFailure.invalidVersion }
        switch ecosystem {
        case .node:
            switch operation {
            case .list: return ["ls","--depth=0","--json"]
            case .outdated: return ["outdated","--json"]
            case .audit: return ["audit","--json"]
            case .install: return ["install"]+(identifier.isEmpty ? [] : [identifier+(version.isEmpty ? "" : "@"+version)])
            case .update: return ["update"]+(identifier.isEmpty ? [] : [identifier])
            case .remove: guard !identifier.isEmpty else { throw PackageToolFailure.invalidName }; return ["uninstall",identifier]
            }
        case .python:
            switch operation {
            case .list: return ["-m","pip","list","--format=json"]
            case .outdated: return ["-m","pip","list","--outdated","--format=json"]
            case .audit: return ["-m","pip_audit","--format=json"]
            case .install,.update:
                let upgrade = operation == .update ? ["--upgrade"] : []
                if !identifier.isEmpty { return ["-m","pip","install"]+upgrade+[identifier+(version.isEmpty ? "" : "=="+version)] }
                guard hasRequirements else { throw PackageToolFailure.missingRequirements }
                return ["-m","pip","install"]+upgrade+["-r","requirements.txt"]
            case .remove: guard !identifier.isEmpty else { throw PackageToolFailure.invalidName }; return ["-m","pip","uninstall","--yes",identifier]
            }
        case .dotnet:
            switch operation {
            case .list: return ["list","package","--format","json"]
            case .outdated: return ["list","package","--outdated","--format","json"]
            case .audit: return ["list","package","--vulnerable","--include-transitive","--format","json"]
            case .install,.update:
                guard !identifier.isEmpty else { throw PackageToolFailure.invalidName }
                return ["add","package",identifier]+(version.isEmpty ? [] : ["--version",version])
            case .remove: guard !identifier.isEmpty else { throw PackageToolFailure.invalidName }; return ["remove","package",identifier]
            }
        }
    }
    public static func records(_ output: String,ecosystem: PackageEcosystem,outdated: Bool = false) throws -> [PackageRecord] {
        let object = try json(output)
        var values: [PackageRecord] = []
        switch ecosystem {
        case .node:
            guard let root = object as? [String:Any],root["error"] == nil || root["dependencies"] != nil else { throw PackageToolFailure.unreadableResponse }
            let packages = outdated ? root : root["dependencies"] as? [String:Any] ?? [:]
            for (name,value) in packages {
                guard let info = value as? [String:Any] else { continue }
                values.append(PackageRecord(name:name,version:(info[outdated ? "current" : "version"] as? String) ?? "—",latest:info["latest"] as? String))
            }
        case .python:
            guard let packages = object as? [[String:Any]] else { throw PackageToolFailure.unreadableResponse }
            values = packages.compactMap { p in guard let name = p["name"] as? String,let version = p["version"] as? String else { return nil }; return PackageRecord(name:name,version:version,latest:p["latest_version"] as? String) }
        case .dotnet:
            guard let root = object as? [String:Any],let projects = root["projects"] as? [[String:Any]],!projects.isEmpty else { throw PackageToolFailure.unreadableResponse }
            for project in projects {
                for framework in project["frameworks"] as? [[String:Any]] ?? [] {
                    for package in framework["topLevelPackages"] as? [[String:Any]] ?? [] {
                        guard let name = package["id"] as? String else { continue }
                        values.append(PackageRecord(name:name,version:package["resolvedVersion"] as? String ?? "—",latest:package["latestVersion"] as? String))
                    }
                }
            }
        }
        return values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    public static func vulnerabilityCount(_ output: String,ecosystem: PackageEcosystem) throws -> Int {
        let object = try json(output)
        switch ecosystem {
        case .node:
            guard let root = object as? [String:Any],let metadata = root["metadata"] as? [String:Any],let vulnerabilities = metadata["vulnerabilities"] as? [String:Any],let total = vulnerabilities["total"] as? Int else { throw PackageToolFailure.unreadableResponse }
            return total
        case .python:
            let packages = (object as? [[String:Any]]) ?? (object as? [String:Any])?["dependencies"] as? [[String:Any]]
            guard let packages else { throw PackageToolFailure.unreadableResponse }
            return packages.reduce(0) { $0+(($1["vulns"] as? [Any])?.count ?? 0) }
        case .dotnet:
            guard let root = object as? [String:Any],let projects = root["projects"] as? [[String:Any]],!projects.isEmpty else { throw PackageToolFailure.unreadableResponse }
            var total = 0
            for project in projects {
                let frameworks = project["frameworks"] as? [[String:Any]] ?? []
                for framework in frameworks {
                    for key in ["topLevelPackages","transitivePackages"] {
                        let packages = framework[key] as? [[String:Any]] ?? []
                        for package in packages { total += (package["vulnerabilities"] as? [Any])?.count ?? 0 }
                    }
                }
            }
            return total
        }
    }
    private static func json(_ source: String) throws -> Any {
        if let data = source.data(using:.utf8),let value = try? JSONSerialization.jsonObject(with:data) { return value }
        guard let start = source.firstIndex(where:{ $0 == "{" || $0 == "[" }),let end = source.lastIndex(where:{ $0 == "}" || $0 == "]" }),start <= end,
              let data = String(source[start...end]).data(using:.utf8),let value = try? JSONSerialization.jsonObject(with:data) else { throw PackageToolFailure.unreadableResponse }
        return value
    }
}
