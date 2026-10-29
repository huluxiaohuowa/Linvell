import Foundation
import CryptoKit
import Darwin

enum NativeToolRelay {
    static func safe(_ path: URL) throws {
        if (try? path.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true { throw LanguageServiceError.message("Language tool directories cannot be symlinks.") }
    }
    static func base(root: URL,storage: LanguageToolStorage,home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let parent = (storage == .project ? root : home.resolvingSymlinksInPath()).appendingPathComponent(".linvell")
        try safe(parent); let tools = parent.appendingPathComponent(storage == .project ? "tools" : "language-services")
        try safe(tools); return tools
    }
    static func addIgnore(root: URL) throws {
        let path = root.appendingPathComponent(".gitignore"); try safe(path)
        let data = FileManager.default.fileExists(atPath:path.path) ? try Data(contentsOf:path) : Data()
        guard let text = String(data:data,encoding:.utf8) else { throw LanguageServiceError.message("The Git ignore file is not UTF-8. Add the rule manually.") }
        let rules = Set(text.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespaces) })
        guard rules.isDisjoint(with:["/.linvell/tools/",".linvell/tools/","/.linvell/tools/**",".linvell/tools/**","/.linvell/",".linvell/"]) else { return }
        let updated = text+(text.isEmpty || text.hasSuffix("\n") ? "" : "\n")+"\n# Linvell project language services\n/.linvell/tools/\n"
        guard ((try? Data(contentsOf:path)) ?? Data()) == data else { throw DocumentError.externalChange }
        try Data(updated.utf8).write(to:path,options:.atomic)
    }
    static func probe(root: String,storage: LanguageToolStorage) throws -> LanguageInstallTarget {
        let tools = try base(root:URL(fileURLWithPath:root).resolvingSymlinksInPath(),storage:storage)
        _ = tools
        let node = ToolCommand.executable("node")?.path ?? ""
        let version = node.isEmpty ? "" : (try? ToolCommand.run(URL(fileURLWithPath:node),arguments:["--version"],directory:nil).output) ?? ""
        let arch = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/uname"),arguments:["-m"],directory:nil).output
        return LanguageInstallTarget(platform:"darwin",architecture:arch,libc:"",node:node,nodeVersion:version)
    }
    static func marker(_ folder: URL) throws -> [String:Any] {
        try safe(folder); let path = folder.appendingPathComponent(".linvell-managed.json"); try safe(path)
        guard let data = try? Data(contentsOf:path),let value = try JSONSerialization.jsonObject(with:data) as? [String:Any],value["managed"] as? String == "linvell-language-tool" else { throw LanguageServiceError.message("This directory is not managed by Linvell; nothing was removed.") }; return value
    }
    static func writeMarker(_ folder: URL,_ value: [String:Any]) throws {
        try JSONSerialization.data(withJSONObject:value,options:.sortedKeys).write(to:folder.appendingPathComponent(".linvell-managed.json"),options:.atomic)
    }
    static func locked<T>(_ tools: URL,_ work: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at:tools,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd = open(tools.appendingPathComponent(".install.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }; defer { close(fd) }
        guard flock(fd,LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }; defer { flock(fd,LOCK_UN) }
        return try work()
    }
    static func remove(language: String,root: String,storage: LanguageToolStorage,home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard let recipe = ManagedLanguageRecipe.forLanguage(language) else { throw LanguageServiceError.message("This language service is not managed by Linvell.") }
        let root = URL(fileURLWithPath:root).resolvingSymlinksInPath(),tools = try base(root:root,storage:storage,home:home)
        try locked(tools) {
            let folder = tools.appendingPathComponent(recipe.provider)
            if FileManager.default.fileExists(atPath:folder.path) {
                var value = try marker(folder),projects = Set(value["projects"] as? [String] ?? [])
                projects.remove(root.path)
                if projects.isEmpty { try FileManager.default.removeItem(at:folder) }
                else { value["projects"] = projects.sorted(); try writeMarker(folder,value) }
            }
            let remaining = ["pyright","typescript"].contains { FileManager.default.fileExists(atPath:tools.appendingPathComponent($0).path) }
            let runtime = tools.appendingPathComponent(".runtime")
            if !remaining,FileManager.default.fileExists(atPath:runtime.path) { _ = try marker(runtime); try FileManager.default.removeItem(at:runtime) }
        }
    }
    static func install(spec: [String:Any],work: URL,home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> ManagedLanguageResult {
        guard let language = spec["provider"] as? String,["pyright","typescript"].contains(language),let rootString = spec["root"] as? String,let artifacts = spec["artifacts"] as? [[String:String]],let version = spec["version"] as? String else { throw UpdateFailure.invalidArchive }
        let root = URL(fileURLWithPath:rootString).resolvingSymlinksInPath(),storage = LanguageToolStorage(rawValue:spec["storage"] as? String ?? "project") ?? .project,tools = try base(root:root,storage:storage,home:home)
        return try locked(tools) {
            let fm = FileManager.default,folder = tools.appendingPathComponent(language)
            let previous = fm.fileExists(atPath:folder.path) ? try marker(folder) : nil
            let stage = tools.appendingPathComponent(".install-"+UUID().uuidString)
            try fm.createDirectory(at:stage,withIntermediateDirectories:true); defer { try? fm.removeItem(at:stage) }
            let package = stage.appendingPathComponent("service"); try fm.createDirectory(at:package,withIntermediateDirectories:true)
            var node = spec["node"] as? String ?? ""
            for artifact in artifacts {
                guard let name = artifact["file"],URL(fileURLWithPath:name).lastPathComponent == name,let expected = artifact["sha256"] else { throw UpdateFailure.invalidArchive }
                let archive = work.appendingPathComponent(name)
                guard SHA256.hash(data:try Data(contentsOf:archive,options:.mappedIfSafe)).map({ String(format:"%02x",$0) }).joined() == expected else { throw UpdateFailure.untrustedPackage }
                if artifact["kind"] == "node" {
                    let runtime = tools.appendingPathComponent(".runtime"); try safe(runtime)
                    if fm.fileExists(atPath:runtime.path) { _ = try marker(runtime) }
                    else { try fm.createDirectory(at:runtime,withIntermediateDirectories:true); try writeMarker(runtime,["managed":"linvell-language-tool"]) }
                    let name = "node-"+(spec["nodeVersion"] as? String ?? "")+"-darwin-"+(spec["architecture"] as? String ?? "")
                    let target = runtime.appendingPathComponent(name); try safe(target)
                    let extracted = stage.appendingPathComponent("runtime")
                    try ManagedToolArchive.extract(archive,to:extracted,member:artifact["member"])
                    let oldNode = stage.appendingPathComponent("old-runtime")
                    if fm.fileExists(atPath:target.path) { try fm.moveItem(at:target,to:oldNode) }
                    do { try fm.moveItem(at:extracted,to:target) }
                    catch { if fm.fileExists(atPath:oldNode.path) { try? fm.moveItem(at:oldNode,to:target) }; throw error }
                    node = target.appendingPathComponent("bin/node").path
                } else {
                    guard let packageName = artifact["package"],["pyright","typescript-language-server","typescript"].contains(packageName) else { throw UpdateFailure.invalidArchive }
                    try ManagedToolArchive.extract(archive,to:package.appendingPathComponent("node_modules/"+packageName))
                }
            }
            let probe = try ToolCommand.run(URL(fileURLWithPath:node),arguments:["--version"],directory:nil)
            guard probe.succeeded,probe.output.hasPrefix("v") else { throw LanguageServiceError.message("The runtime cannot run on this host.") }
            let entry = language == "pyright" ? "pyright/dist/pyright-langserver.js" : "typescript-language-server/lib/cli.mjs"
            guard fm.fileExists(atPath:package.appendingPathComponent("node_modules/"+entry).path) else { throw LanguageServiceError.message("The language service entry point is missing.") }
            let bin = package.appendingPathComponent("bin"); try fm.createDirectory(at:bin,withIntermediateDirectories:true)
            let launcher = bin.appendingPathComponent(language+"-language-server")
            let script = "#!/bin/sh\nexec "+SSHRemote.quote(node)+" "+SSHRemote.quote(folder.appendingPathComponent("node_modules/"+entry).path)+" \"$@\"\n"
            try Data(script.utf8).write(to:launcher); try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:launcher.path)
            var projects = Set(previous?["projects"] as? [String] ?? []); projects.insert(root.path)
            try writeMarker(package,["managed":"linvell-language-tool","provider":language,"version":version,"projects":projects.sorted(),"storage":storage.rawValue])
            if storage == .project,spec["addIgnore"] as? Bool ?? true { try addIgnore(root:root) }
            let backup = stage.appendingPathComponent("previous")
            if previous != nil { try fm.moveItem(at:folder,to:backup) }
            do { try fm.moveItem(at:package,to:folder) }
            catch { if previous != nil { try? fm.moveItem(at:backup,to:folder) }; throw error }
            let server = storage == .project ? folder.appendingPathComponent("bin/"+language+"-language-server").path : "${userHome}/.linvell/language-services/"+language+"/bin/"+language+"-language-server"
            return ManagedLanguageResult(root:root.path,server:server,arguments:["--stdio"])
        }
    }
}
