import XCTest
import AppKit
@testable import Linvell
@testable import LinvellCore

final class AgentWorkspaceTests: XCTestCase {
    func testRepeatedReopenSharesPendingDiscoveryAndAllowsRefreshAfterCompletion() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let view = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        defer { view.removeFromSuperview() }
        view.path.stringValue = "/usr/bin/false"; view.agentHome.stringValue = root.path
        view.reload(); let request = view.generation
        for _ in 0..<100 { view.reload() }
        XCTAssertEqual(view.generation,request)
        let deadline = Date().addingTimeInterval(5)
        while !view.refresh.isEnabled,Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(view.refresh.isEnabled)
        view.reload(); XCTAssertNotEqual(view.generation,request)
        while !view.refresh.isEnabled,Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
    }
    func testSidebarToolbarAndCommandPaletteOpenTheMainWorkspace() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let workspace = WorkspaceController(),agent = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        defer {
            workspace.picker?.dismiss(); workspace.agentFileMonitor?.stop(); agent.shutdown()
            workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil); try? FileManager.default.removeItem(at:root)
        }
        workspace.root = FileNode(root); workspace.agentWorkspace = agent
        agent.path.stringValue = "/usr/bin/false"; agent.agentHome.stringValue = root.path
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        let content = try XCTUnwrap(workspace.window?.contentView)
        XCTAssertTrue(buttons(content).contains { $0.action == #selector(WorkspaceController.showAgents) })
        let entry = try XCTUnwrap(buttons(workspace.activity).first { $0.identifier?.rawValue == "Linvell.AgentsActivity" })
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        entry.performClick(nil)
        XCTAssertTrue(agent.window === workspace.window); XCTAssertTrue(workspace.editors.arrangedSubviews.first === agent)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)),windows)
        XCTAssertEqual(workspace.activeActivity,5)
        workspace.commandPalette()
        XCTAssertTrue(workspace.picker?.options.contains { $0.title == "Agents" } == true)
        let deadline = Date().addingTimeInterval(5)
        while !agent.refresh.isEnabled,Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
    }
    func testSessionFilteringRetainsTheSelectedSessionByIdentity() {
        _ = NSApplication.shared
        let view = AgentWorkspace(project:"/fixture/project",remote:nil,autoLoad:false)
        defer { view.removeFromSuperview() }
        view.sessions = [AgentSession(id:"first",title:"Task one",cwd:"/fixture/project",locator:"first",updated:1),AgentSession(id:"second",title:"Task two",cwd:"/fixture/project",locator:"second",updated:2)]
        let notification = Notification(name:NSControl.textDidChangeNotification,object:view.search)
        view.controlTextDidChange(notification); view.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        view.search.stringValue = "Task two"; view.controlTextDidChange(notification)
        XCTAssertEqual(view.filtered[view.table.selectedRow].id,"second")
    }
    func testRemoteProjectDefaultsToSSHAndLocalRequiresMapping() throws {
        _ = NSApplication.shared
        let view = AgentWorkspace(project:"/fixture/project",remote:try SSHRemote(host:"fixture-host"),autoLoad:false)
        defer { view.removeFromSuperview() }
        XCTAssertTrue(view.usesSSH); XCTAssertFalse(view.newSession.isEnabled)
        view.location.selectedSegment = 0
        view.path.stringValue = "/usr/bin/true"
        view.startNew()
        XCTAssertNil(view.terminal)
        XCTAssertFalse(view.usesSSH)
    }
    func testNativeLayoutKeepsSessionListAndTerminalVisible() throws {
        _ = NSApplication.shared
        let view = AgentWorkspace(project:"/fixture/project",remote:nil,autoLoad:false)
        defer { view.removeFromSuperview() }
        let content = view
        content.frame = NSRect(x:0,y:0,width:900,height:650); content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.terminalHost.frame.height,200)
        XCTAssertGreaterThan(view.terminalHost.frame.width,350)
        view.configurationView.frame = NSRect(x:0,y:0,width:280,height:700); view.configurationView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.table.enclosingScrollView?.frame.height ?? 0,150)
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/agent-ui")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in:content.bounds))
        content.cacheDisplay(in:content.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("native-panel.png"))
    }
    func testNativeTerminalResumesOriginalSessionInProjectWithoutShellInterpolation() throws {
        _ = NSApplication.shared
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/agent-test-fixtures/ui-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let cli = root.appendingPathComponent("fixture agent"),capture = root.appendingPathComponent("capture")
        try Data(("#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > "+SSHRemote.quote(capture.path)+"\nsleep 0.2\n").utf8).write(to:cli)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        let view = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        let key = "agentCLI.local.codex.path",previous = UserDefaults.standard.object(forKey:key)
        let homeKey = "agentCLI.local.codex.home",previousHome = UserDefaults.standard.object(forKey:homeKey)
        defer { view.shutdown(); view.removeFromSuperview(); UserDefaults.standard.set(previous,forKey:key); UserDefaults.standard.set(previousHome,forKey:homeKey) }
        view.path.stringValue = cli.path; view.agentHome.stringValue = ""
        view.start(session:AgentSession(id:"id;$(literal)",title:"Fixture",cwd:root.path,locator:"id;$(literal)",updated:0))
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath:capture.path),Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        let result = try String(contentsOf:capture,encoding:.utf8)
        XCTAssertEqual(result,root.path+"\nresume\nid;$(literal)\n")
        XCTAssertNotNil(view.terminal)
    }
}
