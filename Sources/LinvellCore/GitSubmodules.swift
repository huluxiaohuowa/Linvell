import Foundation

public struct GitSubmodule: Equatable {
    public let name: String,path: String,url: String,trackingBranch: String
    public let recordedCommit: String,currentCommit: String,currentBranch: String
    public let dirty: Bool,conflicted: Bool
    public var initialized: Bool { !currentCommit.isEmpty }
    public var changedCommit: Bool { initialized && recordedCommit != currentCommit }
    public var state: String { conflicted ? "Conflicted" : !initialized ? "Not initialized" : dirty ? "Local changes" : changedCommit ? "New commit" : "Up to date" }
}

extension GitRepository {
    public func submodules() throws -> [GitSubmodule] {
        let config: String
        do { config = try run(["config","--null","--file",".gitmodules","--get-regexp",#"^submodule\..*\.(path|url|branch)$"#]) }
        catch GitError.command(let error) where error.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return [] }
        var settings: [String:String] = [:]
        for field in config.split(separator:"\0") {
            guard let newline = field.firstIndex(of:"\n") else { continue }
            settings[String(field[..<newline])] = String(field[field.index(after:newline)...])
        }
        let names = settings.keys.filter { $0.hasSuffix(".path") }.map { String($0.dropFirst("submodule.".count).dropLast(".path".count)) }.sorted()
        guard !names.isEmpty else { return [] }
        let paths = try names.map { name -> String in let path = settings["submodule."+name+".path"]!; _ = try childRepository(path); return path }
        let index = try run(["ls-files","--stage","-z","--"]+paths)
        var commits: [String:String] = [:],conflicts = Set<String>()
        for entry in index.split(separator:"\0") {
            let parts = entry.split(separator:"\t",maxSplits:1,omittingEmptySubsequences:false)
            guard parts.count == 2 else { continue }
            let header = parts[0].split(separator:" ")
            guard header.count == 3,header[0] == "160000" else { continue }
            if header[2] == "0" { commits[String(parts[1])] = String(header[1]) } else { conflicts.insert(String(parts[1])) }
        }
        // One fixed remote invocation for all initialized modules, rather than an SSH handshake per row.
        let script = #"""
dirty=no
git -c core.fsmonitor=false diff --no-ext-diff --no-textconv --quiet --ignore-submodules=none || dirty=yes
git -c core.fsmonitor=false diff --no-ext-diff --no-textconv --cached --quiet --ignore-submodules=none || dirty=yes
test -z "$(git ls-files --others --exclude-standard)" || dirty=yes
printf '%s\0%s\0%s\0%s\0' "$sm_path" "$(git rev-parse --verify HEAD)" "$(git symbolic-ref -q --short HEAD)" "$dirty"
"""#
        let fields = try run(["submodule","foreach","--quiet",script]).split(separator:"\0",omittingEmptySubsequences:false).map(String.init)
        var live: [String:(String,String,Bool)] = [:]
        var i = 0
        while i+3 < fields.count { live[fields[i]] = (fields[i+1],fields[i+2],fields[i+3] == "yes"); i += 4 }
        return names.map { name in
            let prefix = "submodule."+name+".",path = settings[prefix+"path"]!,status = live[path]
            return GitSubmodule(name:name,path:path,url:settings[prefix+"url"] ?? "",trackingBranch:settings[prefix+"branch"] ?? "",recordedCommit:commits[path] ?? "",currentCommit:status?.0 ?? "",currentBranch:status?.1 ?? "",dirty:status?.2 ?? false,conflicted:conflicts.contains(path))
        }
    }
    private func submodulePath(_ path: String) throws -> String {
        _ = try childRepository(path)
        guard try submodules().contains(where:{ $0.path == path }) else { throw GitError.invalidPath }; return path
    }
    public func updateSubmodules(path: String? = nil,recursive: Bool = true,remoteTip: Bool = false) throws {
        let paths = try path.map { [try submodulePath($0)] } ?? []
        _ = try run(["submodule","update","--init","--checkout"]+(recursive ? ["--recursive"] : [])+(remoteTip ? ["--remote"] : [])+["--"]+paths,timeout:600)
    }
    public func syncSubmodules(path: String? = nil,recursive: Bool = true) throws {
        let paths = try path.map { [try submodulePath($0)] } ?? []
        _ = try run(["submodule","sync"]+(recursive ? ["--recursive"] : [])+["--"]+paths)
    }
    public func addSubmodule(url: String,path: String,branch: String = "") throws {
        _ = try childRepository(path)
        guard !url.isEmpty,!url.contains("\0"),!branch.contains("\0"),!branch.hasPrefix("-") else { throw GitError.invalidPath }
        _ = try run(["submodule","add"]+(branch.isEmpty ? [] : ["--branch",branch])+["--",url,path],timeout:600)
    }
    public func setSubmoduleURL(path: String,url: String) throws {
        guard !url.isEmpty,!url.contains("\0") else { throw GitError.invalidPath }
        _ = try run(["submodule","set-url","--",submodulePath(path),url])
    }
    public func setSubmoduleBranch(path: String,branch: String) throws {
        guard !branch.hasPrefix("-"),!branch.contains("\0") else { throw GitError.invalidPath }
        _ = try run(["submodule","set-branch"]+(branch.isEmpty ? ["--default"] : ["--branch",branch])+["--",submodulePath(path)])
    }
    public func stageSubmodule(path: String) throws { _ = try run(["add","--",submodulePath(path)]) }
    public func removeSubmodule(path: String) throws {
        guard let module = try submodules().first(where:{ $0.path == path }),!module.dirty,!module.changedCommit,!module.conflicted else { throw GitError.command("Commit or stash submodule changes and record its commit before removing it.") }
        _ = try run(["submodule","deinit","--",path]); _ = try run(["rm","--",path])
    }
}
