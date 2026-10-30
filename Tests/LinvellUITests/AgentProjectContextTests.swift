import XCTest
import AppKit
@testable import Linvell
@testable import LinvellCore

final class AgentProjectContextTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while !predicate(),Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        return predicate()
    }
    func testProjectSwitchReplacesHistoryAndLocationWithoutStoppingPreviousPTY() throws {
        _ = NSApplication.shared
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/agent-test-fixtures/context-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let workspace = WorkspaceController(),local = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        let connection = try SSHRemote(host:"fixture-context-host")
        let remote = AgentWorkspace(project:"/remote/project",remote:connection,autoLoad:false)
        let defaults = UserDefaults.standard,keys = ["agentCLI.local.codex.path","agentCLI.local.codex.home",WorkspaceSession.key,"lastProject"]
        let saved = keys.map { defaults.object(forKey:$0) }
        defer {
            workspace.shutdownAgent(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil)
            for (key,value) in zip(keys,saved) { defaults.set(value,forKey:key) }
            try? FileManager.default.removeItem(at:root)
        }
        workspace.root = FileNode(root); workspace.agentWorkspace = local; workspace.agentWorkspaces = [remote]
        local.path.stringValue = "/bin/cat"; local.agentHome.stringValue = root.path
        local.startNew(); workspace.showAgents()
        let original = try XCTUnwrap(local.terminal),pid = original.process.shellPid
        remote.sessions = [.init(id:"remote-only",title:"Remote history",cwd:"/remote/project",locator:"remote-only",updated:0)]
        remote.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:remote.search))
        // This is also invoked by connectToSSH, folder selection and canonical-root callbacks.
        workspace.remoteConnection = connection; workspace.remoteDirectory = "/remote/project"; workspace.root = nil
        workspace.agentProjectDidChange()
        XCTAssertTrue(workspace.agentWorkspace === remote)
        XCTAssertTrue(workspace.editors.arrangedSubviews.first === remote)
        XCTAssertEqual(remote.filtered.map(\.id),["remote-only"])
        XCTAssertFalse(remote.location.isHidden); XCTAssertTrue(remote.location.isEnabled); XCTAssertTrue(remote.usesSSH)
        XCTAssertTrue(remote.configurationView.isDescendant(of:workspace.sidebar))
        XCTAssertTrue(original.process.running); XCTAssertEqual(original.process.shellPid,pid)
        // A second SSH host with the same path is a different project context.
        workspace.remoteConnection = try SSHRemote(host:"other-fixture-host")
        let other = try XCTUnwrap(workspace.synchronizeAgentWorkspace(autoLoad:false))
        XCTAssertFalse(other === remote); XCTAssertTrue(other.sessions.isEmpty); XCTAssertTrue(other.usesSSH)
        workspace.setProject(root)
        XCTAssertTrue(workspace.agentWorkspace === local)
        XCTAssertTrue(workspace.editors.arrangedSubviews.first === local)
        XCTAssertTrue(local.location.isHidden); XCTAssertTrue(local.terminal === original)
        XCTAssertTrue(workspace.agentsRunning)
        workspace.shutdownAgent(); XCTAssertTrue(waitUntil { !workspace.agentsRunning })
    }
    func testLiveSSHProjectListsRemoteSessionsAndKeepsLocalAndRemoteProcessesIndependent() throws {
        guard let file = ProcessInfo.processInfo.environment["LINVELL_SSH_FIXTURE"] else { throw XCTSkip("Disposable SSH Agent fixture required") }
        _ = NSApplication.shared
        let fixture = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as! [String:String]
        let host = try XCTUnwrap(fixture["host"]),remoteRoot = try XCTUnwrap(fixture["root"])
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/agent-test-fixtures/ssh-context-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let workspace = WorkspaceController(),local = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        let defaults = UserDefaults.standard,keys = ["agentCLI.local.codex.path","agentCLI.local.codex.home","agentCLI."+host+".codex.path","agentCLI."+host+".codex.home",WorkspaceSession.key,"lastProject"]
        let saved = keys.map { defaults.object(forKey:$0) }
        defer {
            workspace.shutdownAgent(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil)
            for (key,value) in zip(keys,saved) { defaults.set(value,forKey:key) }
            try? FileManager.default.removeItem(at:root)
        }
        workspace.root = FileNode(root); workspace.agentWorkspace = local
        local.path.stringValue = "/bin/cat"; local.agentHome.stringValue = root.path
        local.startNew(); workspace.showAgents()
        let localTerminal = try XCTUnwrap(local.terminal),localPID = localTerminal.process.shellPid
        defaults.set(remoteRoot+"/fixture-codex",forKey:"agentCLI."+host+".codex.path")
        defaults.set("",forKey:"agentCLI."+host+".codex.home")
        workspace.connectToSSH(host,folder:remoteRoot); workspace.showAgents()
        let remote = try XCTUnwrap(workspace.agentWorkspace)
        XCTAssertFalse(remote === local); XCTAssertEqual(remote.remote?.host,host); XCTAssertEqual(remote.project,remoteRoot)
        XCTAssertFalse(remote.location.isHidden); XCTAssertTrue(remote.usesSSH)
        XCTAssertTrue(waitUntil { remote.refresh.isEnabled && remote.filtered.count == 1 })
        XCTAssertEqual(remote.filtered.first?.id,"agent-ssh-acceptance"); XCTAssertEqual(remote.filtered.first?.cwd,remoteRoot)
        XCTAssertTrue(localTerminal.process.running); XCTAssertEqual(localTerminal.process.shellPid,localPID)
        remote.path.stringValue = remoteRoot+"/fixture-running-agent"; remote.start(session:remote.filtered.first)
        defaults.set(remoteRoot+"/fixture-codex",forKey:"agentCLI."+host+".codex.path")
        let remoteTerminal = try XCTUnwrap(remote.terminal)
        XCTAssertTrue(waitUntil { String(decoding:remoteTerminal.getTerminal().getBufferAsData(),as:UTF8.self).contains("REMOTE_PTY_READY:"+remoteRoot) })
        remote.location.selectedSegment = 0; remote.selectionChanged()
        XCTAssertFalse(remote.usesSSH); XCTAssertTrue(remote.location.isEnabled)
        XCTAssertTrue(remote.newSession.isEnabled,"New Session must explain and connect missing prerequisites instead of silently disabling.")
        XCTAssertNil(remote.activeRuntime); XCTAssertNil(remote.terminal)
        XCTAssertNil(remoteTerminal.superview); XCTAssertFalse(remote.stop.isEnabled)
        XCTAssertTrue(remote.scope.stringValue.hasPrefix(L.text("This Mac")))
        XCTAssertTrue(remote.openSessions.titleOfSelectedItem?.contains(L.text("No open session for this agent and location")) == true)
        XCTAssertTrue(localTerminal.process.running); XCTAssertTrue(remoteTerminal.process.running)
        remote.location.selectedSegment = 1; remote.selectionChanged()
        XCTAssertTrue(remote.usesSSH); XCTAssertTrue(waitUntil { remote.refresh.isEnabled && remote.filtered.count == 1 })
        XCTAssertTrue(remote.terminal === remoteTerminal); XCTAssertTrue(remoteTerminal.superview === remote.terminalHost)
        // The open-session menu must synchronize the provider and execution selector too.
        remote.kindPicker.selectItem(at:AgentKind.allCases.firstIndex(of:.dsh)!); remote.selectionChanged()
        XCTAssertEqual(remote.kind,.dsh); XCTAssertNil(remote.terminal); XCTAssertTrue(remoteTerminal.process.running)
        remote.path.stringValue = ""; let before = remote.runtimes.count; remote.startNew()
        XCTAssertEqual(remote.runtimes.count,before); XCTAssertTrue(remote.status.stringValue.contains(L.text("Choose an agent CLI in Agent Settings, then create a session.")))
        remote.openSessions.selectItem(at:0); remote.selectOpenSession()
        XCTAssertEqual(remote.kind,.codex); XCTAssertTrue(remote.usesSSH); XCTAssertTrue(remote.terminal === remoteTerminal)
        workspace.setProject(root); workspace.showAgents()
        XCTAssertTrue(workspace.agentWorkspace === local); XCTAssertTrue(local.terminal === localTerminal)
        XCTAssertTrue(remoteTerminal.process.running)
        workspace.shutdownAgent(); XCTAssertTrue(waitUntil { !workspace.agentsRunning })
    }
}
