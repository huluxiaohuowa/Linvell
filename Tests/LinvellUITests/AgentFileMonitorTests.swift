import XCTest
import AppKit
@testable import Linvell
@testable import LinvellCore

final class AgentFileMonitorTests: XCTestCase {
    func testAgentEditsRefreshFilesWhileBrowsingKeepsOriginalProcess() throws {
        _ = NSApplication.shared
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/agent-test-fixtures/live-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file = root.appendingPathComponent("source.txt"),created = root.appendingPathComponent("created.txt"),cli = root.appendingPathComponent("fixture-agent")
        try Data("before\n".utf8).write(to:file)
        try Data(("#!/bin/sh\nprintf 'agent edit\\n' > "+SSHRemote.quote(file.path)+"\nprintf 'new\\n' > "+SSHRemote.quote(created.path)+"\nsleep 30\n").utf8).write(to:cli)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        let workspace = WorkspaceController(),agent = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        workspace.recoveryTimer?.invalidate()
        let pathKey = "agentCLI.local.codex.path",homeKey = "agentCLI.local.codex.home"
        let oldPath = UserDefaults.standard.object(forKey:pathKey),oldHome = UserDefaults.standard.object(forKey:homeKey)
        defer {
            workspace.agentFileMonitor?.stop(); agent.shutdown(); workspace.window?.orderOut(nil); workspace.recoveryTimer?.invalidate()
            UserDefaults.standard.set(oldPath,forKey:pathKey); UserDefaults.standard.set(oldHome,forKey:homeKey); try? FileManager.default.removeItem(at:root)
        }
        workspace.root = FileNode(root); workspace.outline.reloadData()
        let document = OpenDocument(try DocumentBuffer(url:file)); workspace.activate(document)
        workspace.agentWorkspace = agent; workspace.agentFileMonitor = AgentFileMonitor(workspace:workspace)
        agent.path.stringValue = cli.path; agent.agentHome.stringValue = ""; agent.startNew()
        let terminal = try XCTUnwrap(agent.terminal),pid = terminal.process.shellPid
        workspace.showAgents()
        XCTAssertTrue(workspace.editors.arrangedSubviews.first === agent)
        XCTAssertTrue(agent.window === workspace.window)
        workspace.activate(OpenDocument(DocumentBuffer(text:"another file"))); workspace.activate(document)
        let deadline = Date().addingTimeInterval(6)
        while (document.buffer.text != "agent edit\n" || workspace.root?.children.contains(where:{ $0.url == created }) != true),Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(document.buffer.text,"agent edit\n"); XCTAssertEqual(document.storage.string,"agent edit\n")
        XCTAssertFalse(document.buffer.isModified); XCTAssertTrue(workspace.root?.children.contains(where:{ $0.url == created }) == true)
        workspace.showSidebar("files"); workspace.showAgents()
        XCTAssertTrue(workspace.editors.arrangedSubviews.first === agent)
        XCTAssertTrue(agent.window === workspace.window)
        XCTAssertTrue(agent.terminal === terminal); XCTAssertEqual(terminal.process.shellPid,pid); XCTAssertTrue(agent.running)
        document.storage.replaceCharacters(in:NSRange(location:0,length:document.storage.length),with:"unsaved local edit\n"); document.buffer.update("unsaved local edit\n")
        try Data("second agent edit\n".utf8).write(to:file,options:.atomic)
        let conflictDeadline = Date().addingTimeInterval(5)
        while !document.externalChange,Date() < conflictDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(document.externalChange); XCTAssertEqual(document.buffer.text,"unsaved local edit\n")
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"second agent edit\n"); XCTAssertThrowsError(try document.buffer.save())
        XCTAssertTrue(agent.running); XCTAssertEqual(terminal.process.shellPid,pid)
    }
    func testExternalRemoteSnapshotUpdatesDigestButNeverOverwritesUnsavedText() throws {
        _ = NSApplication.shared
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/agent-test-fixtures/remote-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let remote = try RemoteDocument(connection:SSHRemote(host:"fixture-host"),path:"/project/file.txt",digest:"old-digest",data:Data("before".utf8),cacheRoot:root)
        let document = OpenDocument(try DocumentBuffer(url:remote.localURL)); document.remote = remote
        let workspace = WorkspaceController(); workspace.recoveryTimer?.invalidate(); defer { workspace.window?.orderOut(nil) }
        workspace.documents = [document]
        let update = try DocumentBuffer(data:Data("remote agent edit".utf8),url:remote.localURL)
        workspace.applyExternalFile(update,to:document,revision:0,remoteDigest:"new-digest")
        XCTAssertEqual(document.buffer.text,"remote agent edit"); XCTAssertEqual(remote.digest,"new-digest")
        document.buffer.update("local unsaved")
        workspace.applyExternalFile(try DocumentBuffer(data:Data("later remote edit".utf8),url:remote.localURL),to:document,revision:document.buffer.revision,remoteDigest:"later-digest")
        XCTAssertEqual(document.buffer.text,"local unsaved"); XCTAssertEqual(remote.digest,"new-digest"); XCTAssertTrue(document.externalChange)
    }
}
