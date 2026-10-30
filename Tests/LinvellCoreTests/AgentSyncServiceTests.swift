import XCTest
@testable import LinvellCore

final class AgentSyncServiceTests: XCTestCase {
    private func fixture() throws -> URL {
        // Mutagen's Unix socket path must fit Darwin's sockaddr_un limit.
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/lvsync/"+UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    func testMissingOptionalDependencyDoesNotCreateSynchronizationState() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let state = root.appendingPathComponent("sync"),service = AgentSyncService(root:state,environment:["PATH":""]),client = UUID()
        defer { service.release(client:client) }
        XCTAssertThrowsError(try service.prepare(remote:SSHRemote(host:"example"),directory:"/work/project",client:client)) { error in
            XCTAssertTrue(error.localizedDescription.contains(AgentSyncSupport.installCommand))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:state.path))
    }
    func testConflictsAndTransitionProblemsNeverReportReady() {
        XCTAssertTrue(AgentSyncService.snapshot(from:["status":"watching"]).ready)
        XCTAssertFalse(AgentSyncService.snapshot(from:["status":"disconnected"]).ready)
        XCTAssertFalse(AgentSyncService.snapshot(from:["status":"watching","paused":true]).ready)
        let conflict = AgentSyncService.snapshot(from:["status":"watching","conflicts":[["root":"file.swift"]]])
        XCTAssertEqual(conflict.conflicts,1); XCTAssertFalse(conflict.ready)
        XCTAssertFalse(AgentSyncService.snapshot(from:["status":"watching","beta":["transitionProblems":[["path":"file.swift"]]]]).ready)
        XCTAssertFalse(AgentSyncService.snapshot(from:["status":"watching","lastError":"Disconnected"]).ready)
    }
    func testMappingIdentityAndSSHUserAreNotInterchangeable() {
        let a = AgentSyncMapping(host:"one",remoteRoot:"/project",localRoot:"/tmp/local")
        XCTAssertNotEqual(a.name,AgentSyncMapping(host:"two",remoteRoot:"/project",localRoot:"/tmp/local").name)
        XCTAssertNotEqual(a.name,AgentSyncMapping(host:"one",remoteRoot:"/project2",localRoot:"/tmp/local").name)
        XCTAssertTrue(AgentSyncService.matchesSSH(["host":"example","user":"dev"],host:"dev@example"))
        XCTAssertFalse(AgentSyncService.matchesSSH(["host":"example","user":"other"],host:"dev@example"))
        XCTAssertFalse(AgentSyncService.matchesSSH(["host":"other"],host:"example"))
    }
    func testLiveSSHReplicaWritesBothWaysPreservesConflictsAndStopsWhenIdle() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let executable = environment["LINVELL_MUTAGEN_TEST_EXECUTABLE"],let host = environment["LINVELL_MUTAGEN_TEST_HOST"],let base = environment["LINVELL_MUTAGEN_TEST_ROOT"] else { throw XCTSkip("Optional Mutagen and disposable SSH fixture required") }
        let root = try fixture(),client = UUID(),second = UUID(),remoteRoot = base+"/project with spaces-"+UUID().uuidString
        var env = AgentCLI.environment; env["PATH"] = (executable as NSString).deletingLastPathComponent+":"+(env["PATH"] ?? "")
        let service = AgentSyncService(root:root.appendingPathComponent("sync"),environment:env)
        func ssh(_ script: String) throws -> String {
            let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:["-o","BatchMode=yes","--",host,"/bin/sh -c "+SSHRemote.quote(script)],directory:nil,timeout:20)
            guard result.succeeded else { throw GitError.command(result.output) }; return result.output
        }
        let q = SSHRemote.quote(remoteRoot)
        defer {
            service.release(client:client); service.release(client:second)
            _ = try? ssh("rm -rf -- "+q); try? FileManager.default.removeItem(at:root)
        }
        _ = try ssh("mkdir -p "+q+"; printf seed > "+q+"/seed.txt")
        let mapping = try service.prepare(remote:SSHRemote(host:host),directory:remoteRoot,client:client)
        let files = URL(fileURLWithPath:mapping.localRoot)
        XCTAssertEqual(try String(contentsOf:files.appendingPathComponent("seed.txt"),encoding:.utf8),"seed")
        try Data("local-edit".utf8).write(to:files.appendingPathComponent("local.txt"))
        try service.flush(mapping)
        XCTAssertEqual(try ssh("cat "+q+"/local.txt"),"local-edit")
        _ = try ssh("printf remote-edit > "+q+"/seed.txt; mv "+q+"/local.txt "+q+"/renamed.txt")
        try service.flush(mapping)
        XCTAssertEqual(try String(contentsOf:files.appendingPathComponent("seed.txt"),encoding:.utf8),"remote-edit")
        XCTAssertTrue(FileManager.default.fileExists(atPath:files.appendingPathComponent("renamed.txt").path))
        try FileManager.default.removeItem(at:files.appendingPathComponent("renamed.txt")); try service.flush(mapping)
        XCTAssertEqual(try ssh("test ! -e "+q+"/renamed.txt && printf deleted"),"deleted")
        // Pausing the last client stops the owned daemon; reusing the same client
        // restores the same replica and session without launching a global daemon.
        XCTAssertNil(service.suspend(client:client))
        XCTAssertEqual(try service.snapshot(mapping).status,"paused")
        XCTAssertEqual(try service.prepare(remote:SSHRemote(host:host),directory:remoteRoot,client:client),mapping)
        XCTAssertEqual(try service.prepare(remote:SSHRemote(host:host),directory:remoteRoot,client:second),mapping)
        service.release(client:second)
        XCTAssertNotEqual(try service.snapshot(mapping).status,"paused","Another client still needs synchronization")
        XCTAssertNil(service.suspend(client:client))
        try Data("local-conflict".utf8).write(to:files.appendingPathComponent("seed.txt"))
        _ = try ssh("printf remote-conflict > "+q+"/seed.txt")
        XCTAssertThrowsError(try service.prepare(remote:SSHRemote(host:host),directory:remoteRoot,client:client))
        XCTAssertGreaterThan(try service.snapshot(mapping).conflicts,0)
        XCTAssertEqual(try service.snapshot(mapping).conflictPaths,["seed.txt"])
        XCTAssertEqual(try String(contentsOf:files.appendingPathComponent("seed.txt"),encoding:.utf8),"local-conflict")
        XCTAssertEqual(try ssh("cat "+q+"/seed.txt"),"remote-conflict")
        // Explicitly saving the reviewed merge to both versions resolves the
        // conflict without choosing a destructive automatic precedence rule.
        try Data("reviewed-merge".utf8).write(to:files.appendingPathComponent("seed.txt"))
        _ = try ssh("printf reviewed-merge > "+q+"/seed.txt")
        try service.flush(mapping)
        XCTAssertEqual(try service.snapshot(mapping).conflicts,0)
        service.release(client:client)
        XCTAssertEqual(try service.snapshot(mapping).status,"paused")
    }
}
