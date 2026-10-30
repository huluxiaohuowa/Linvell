import XCTest
import AppKit
@testable import Linvell
@testable import LinvellCore

final class AgentFileMonitorTests: XCTestCase {
    func testLiveMutagenChangesRefreshRemoteEditorAndProtectUnsavedManualChanges() throws {
        let env = ProcessInfo.processInfo.environment
        guard let executable = env["LINVELL_MUTAGEN_TEST_EXECUTABLE"],let host = env["LINVELL_MUTAGEN_TEST_HOST"],let base = env["LINVELL_MUTAGEN_TEST_ROOT"] else { throw XCTSkip("Optional Mutagen and disposable SSH fixture required") }
        _ = NSApplication.shared
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/lvedit/"+UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var environment = AgentCLI.environment
        environment["PATH"] = (executable as NSString).deletingLastPathComponent+":"+(environment["PATH"] ?? "")
        let service = AgentSyncService(root:root.appendingPathComponent("sync"),environment:environment),client = UUID()
        let directory = base+"/editor-"+UUID().uuidString,connection = try SSHRemote(host:host)
        let q = SSHRemote.quote(directory)
        func ssh(_ script: String) throws {
            let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:["-o","BatchMode=yes","--",host,"/bin/sh -c "+SSHRemote.quote(script)],directory:nil,timeout:20)
            guard result.succeeded else { throw GitError.command(result.output) }
        }
        let workspace = WorkspaceController(); workspace.recoveryTimer?.invalidate()
        let oldAutoSave = UserDefaults.standard.object(forKey:"autoSave")
        defer {
            UserDefaults.standard.set(oldAutoSave,forKey:"autoSave")
            workspace.agentFileMonitor?.stop(); workspace.window?.orderOut(nil)
            service.release(client:client); try? ssh("rm -rf -- "+q); try? FileManager.default.removeItem(at:root)
        }
        try ssh("mkdir -p "+q+"; printf before > "+q+"/source.txt")
        let mapping = try service.prepare(remote:connection,directory:directory,client:client)
        let reply = try connection.request("read",path:directory+"/source.txt")
        let remote = try RemoteDocument(connection:connection,path:directory+"/source.txt",digest:XCTUnwrap(reply.digest),data:XCTUnwrap(Data(base64Encoded:XCTUnwrap(reply.content))),cacheRoot:root)
        let document = OpenDocument(try DocumentBuffer(url:remote.localURL)); document.remote = remote
        workspace.remoteConnection = connection; workspace.remoteDirectory = directory; workspace.activate(document)
        workspace.agentFileMonitor = AgentFileMonitor(workspace:workspace)
        func waitUntil(_ predicate: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while !predicate(),Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.03)) }; return predicate()
        }
        let localFile = URL(fileURLWithPath:mapping.localRoot).appendingPathComponent("source.txt")
        try Data("agent-first".utf8).write(to:localFile,options:.atomic); try service.flush(mapping)
        XCTAssertTrue(waitUntil { document.buffer.text == "agent-first" })
        XCTAssertEqual(document.storage.string,"agent-first"); XCTAssertFalse(document.buffer.isModified)
        try remote.save(Data("manual-saved".utf8)); try service.flush(mapping)
        XCTAssertEqual(try String(contentsOf:localFile,encoding:.utf8),"manual-saved")
        XCTAssertTrue(waitUntil { document.buffer.text == "manual-saved" })
        document.storage.replaceCharacters(in:NSRange(location:0,length:document.storage.length),with:"my unsaved edit")
        document.buffer.update("my unsaved edit")
        try Data("agent-second".utf8).write(to:localFile,options:.atomic); try service.flush(mapping)
        XCTAssertTrue(waitUntil { document.externalChange })
        XCTAssertEqual(document.buffer.text,"my unsaved edit"); XCTAssertEqual(document.storage.string,"my unsaved edit")
        XCTAssertTrue(document.buffer.isModified)
        UserDefaults.standard.set("true",forKey:"autoSave")
        workspace.scheduleAutoSave(document)
        XCTAssertNil(workspace.autoSaveWork[document.buffer.id],"Known external conflicts must suspend automatic saves even if the user keeps editing")
        XCTAssertThrowsError(try remote.save(Data(document.buffer.text.utf8)),"A stale manual save must not overwrite the agent's newer remote content")
        let latest = try connection.request("read",path:remote.path)
        XCTAssertEqual(String(data:try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(latest.content))),encoding:.utf8),"agent-second")
    }
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
        workspace.shutdownAgent()
        let stopDeadline = Date().addingTimeInterval(3)
        while agent.running,Date() < stopDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(agent.running); XCTAssertNil(workspace.agentFileMonitor)
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
