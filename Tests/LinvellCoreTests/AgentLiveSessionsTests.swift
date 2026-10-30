import XCTest
@testable import LinvellCore

final class AgentLiveSessionsTests: XCTestCase {
    func testIsolatedCodexLaunchIsCapabilityChecked() throws {
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/agent-test-fixtures/capability-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let cli = root.appendingPathComponent("codex")
        for (help,supported) in [("Usage: codex\n  --no-daemon\n",true),("Usage: old codex\n",false)] {
            try Data(("#!/bin/sh\ncat <<'HELP'\n"+help+"HELP\n").utf8).write(to:cli)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
            XCTAssertEqual(AgentCLI.supportsIsolatedCodex(cli.path,environment:AgentCLI.environment),supported)
        }
    }
    func testSessionIdentityComesFromTheOwningProcessAndProject() throws {
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/agent-test-fixtures/bind-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let id = UUID().uuidString,log = root.appendingPathComponent("rollout-"+id+".jsonl")
        try Data("fixture".utf8).write(to:log)
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/bin/sh")
        process.arguments = ["-c","exec 3<\"$1\"; exec sleep 30","fixture",log.path]
        try process.run(); defer { process.terminate(); process.waitUntilExit() }
        let key = UUID(),snapshot = AgentLiveSessions.ProcessSnapshot(id:key,pid:process.processIdentifier,directory:root.path)
        let session = AgentSession(id:id,title:"Same title",cwd:root.path,locator:id,updated:1)
        var binding: String?
        let deadline = Date().addingTimeInterval(3)
        repeat { binding = AgentLiveSessions.bindings([snapshot],sessions:[session])[key] } while binding == nil && Date() < deadline
        XCTAssertEqual(binding,id)
        let other = AgentSession(id:id,title:"Same title",cwd:"/different/project",locator:id,updated:1)
        XCTAssertTrue(AgentLiveSessions.bindings([snapshot],sessions:[other]).isEmpty)
    }
}
