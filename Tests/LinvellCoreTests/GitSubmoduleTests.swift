import XCTest
@testable import LinvellCore

final class GitSubmoduleTests: XCTestCase {
    private func repository(_ url: URL) throws -> GitRepository {
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        let repo = GitRepository(directory:url.path,remote:nil) { path,args,input,timeout in
            let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/git"),arguments:["-c","protocol.file.allow=always"]+GitRepository.arguments(directory:path,arguments:args),directory:URL(fileURLWithPath:path),timeout:timeout,input:input,trimOutput:false)
            guard result.succeeded else { throw GitError.command(result.output) }; return result.output
        }
        _ = try repo.run(["init","-b","main"])
        _ = try repo.run(["config","user.name","Linvell Fixture"]); _ = try repo.run(["config","user.email","fixture@example.invalid"])
        _ = try repo.run(["config","commit.gpgsign","false"])
        return repo
    }
    func testAddInspectUpdateStageProtectDirtyAndRemoveSubmoduleWithSpaces() throws {
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = try repository(root.appendingPathComponent("library")),parent = try repository(root.appendingPathComponent("parent"))
        let file = source.root.appendingPathComponent("value.txt")
        try "one".write(to:file,atomically:true,encoding:.utf8); _ = try source.run(["add","."]); try source.commit("Initial library")
        XCTAssertTrue(try parent.submodules().isEmpty)
        try parent.addSubmodule(url:source.root.path,path:"vendor/a library")
        var module = try XCTUnwrap(parent.submodules().first)
        XCTAssertTrue(module.initialized); XCTAssertFalse(module.dirty); XCTAssertFalse(module.changedCommit)
        XCTAssertEqual(module.path,"vendor/a library"); XCTAssertEqual(module.currentBranch,"main")
        _ = try parent.run(["add","."]); try parent.commit("Add library")
        let deactivate = try XCTUnwrap(GitOperation.all.first { $0.title == "Submodule — Deinitialize" })
        _ = try parent.run(deactivate.arguments(["Path":module.path]))
        XCTAssertFalse(try XCTUnwrap(parent.submodules().first).initialized)
        try parent.updateSubmodules(path:module.path)
        XCTAssertTrue(try XCTUnwrap(parent.submodules().first).initialized)
        let absorb = try XCTUnwrap(GitOperation.all.first { $0.title == "Submodule — Absorb Git Directories" })
        _ = try parent.run(absorb.arguments(["Path":module.path]))
        _ = try parent.run(["submodule","summary","--files"])
        try "two".write(to:file,atomically:true,encoding:.utf8); _ = try source.run(["add","."]); try source.commit("Advance library")
        try parent.setSubmoduleBranch(path:module.path,branch:"main")
        try parent.updateSubmodules(path:module.path,remoteTip:true)
        module = try XCTUnwrap(parent.submodules().first); XCTAssertTrue(module.changedCommit)
        try parent.stageSubmodule(path:module.path)
        XCTAssertFalse(try XCTUnwrap(parent.submodules().first).changedCommit)
        let child = try parent.childRepository(module.path),childFile = child.root.appendingPathComponent("value.txt")
        try "local changes".write(to:childFile,atomically:true,encoding:.utf8)
        XCTAssertTrue(try XCTUnwrap(parent.submodules().first).dirty)
        XCTAssertThrowsError(try parent.removeSubmodule(path:module.path))
        XCTAssertEqual(try String(contentsOf:childFile,encoding:.utf8),"local changes")
        _ = try child.run(["restore","--","value.txt"])
        _ = try parent.run(["add","."]); try parent.commit("Record new library")
        try parent.syncSubmodules(path:module.path)
        try parent.removeSubmodule(path:module.path)
        XCTAssertTrue(try parent.submodules().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:childFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:parent.root.appendingPathComponent(".git/modules/vendor/a library").path))
    }
    func testRemoteSubmoduleReadsAreBatchedAndChildRepositoryKeepsTransport() throws {
        var calls: [(String,[String])] = []
        let remote = try SSHRemote(host:"fixture")
        let repo = GitRepository(directory:"/project",remote:remote) { directory,args,_,_ in
            calls.append((directory,args))
            if args.first == "config" { return "submodule.lib.path\nvendor/lib\0submodule.lib.url\nhttps://example.invalid/lib.git\0" }
            if args.first == "ls-files" { return "160000 abc123 0\tvendor/lib\0" }
            if args.first == "submodule",args.dropFirst().first == "foreach" { return "vendor/lib\0abc123\0main\0no\0" }
            return ""
        }
        XCTAssertEqual(try repo.submodules().first?.state,"Up to date")
        XCTAssertEqual(calls.count,3)
        let child = try repo.childRepository("vendor/lib"); _ = try child.run(["status","--porcelain"])
        XCTAssertEqual(calls.last?.0,"/project/vendor/lib"); XCTAssertEqual(child.remote?.host,"fixture")
        XCTAssertThrowsError(try repo.childRepository("../escape")); XCTAssertThrowsError(try repo.childRepository(".git/modules/lib"))
    }
}
