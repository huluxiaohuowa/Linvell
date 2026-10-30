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
        XCTAssertTrue(view.usesSSH); XCTAssertTrue(view.newSession.isEnabled)
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
        try Data(("#!/bin/sh\n[ \"$1\" = --help ] && exit 0\nprintf '%s\\n' \"$PWD\" \"$@\" > "+SSHRemote.quote(capture.path)+"\nsleep 0.2\n").utf8).write(to:cli)
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

extension AgentWorkspaceTests {
    private func pump(_ seconds: TimeInterval = 0.1) { RunLoop.current.run(until:Date().addingTimeInterval(seconds)) }
    func testConcurrentSessionsSwitchProvidersAndStopOnlyCapturedSession() throws {
        _ = NSApplication.shared
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/agent-test-fixtures/multi-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let cli = root.appendingPathComponent("agent")
        try Data("#!/bin/sh\nif [ \"$1\" = app-server ]; then exit 0; fi\ntrap '' INT\nprintf 'ready\\n'\nsleep 0.3\nprintf 'background output\\n'\nwhile :; do sleep 1; done\n".utf8).write(to:cli)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        let view = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        let defaults = UserDefaults.standard
        let keys = ["agentCLI.local.codex.path","agentCLI.local.codex.home","agentCLI.local.pi.path","agentCLI.local.pi.home"]
        let previous = keys.map { defaults.object(forKey:$0) }
        defer { view.shutdown(); for (key,value) in zip(keys,previous) { defaults.set(value,forKey:key) }; try? FileManager.default.removeItem(at:root) }
        view.path.stringValue = cli.path; view.agentHome.stringValue = root.path
        let saved = AgentSession(id:"saved-a",title:"Named session",cwd:root.path,locator:"saved-a",updated:0)
        view.start(session:saved)
        let a = try XCTUnwrap(view.activeRuntime),pidA = a.terminal.process.shellPid
        XCTAssertTrue(a.terminal.process.running)
        let originalMenuItem = view.openSessions.item(at:0)
        view.setTerminalTitle(source:a.terminal,title:"Session A")
        view.setTerminalTitle(source:a.terminal,title:"Session A")
        XCTAssertTrue(view.openSessions.item(at:0) === originalMenuItem)
        XCTAssertTrue(view.table.isDescendant(of:view.configurationView)); XCTAssertTrue(view.search.isEnabled)
        XCTAssertTrue(view.newSession.isEnabled); XCTAssertTrue(view.kindPicker.isEnabled)
        view.startNew(); let b = try XCTUnwrap(view.activeRuntime),pidB = b.terminal.process.shellPid
        XCTAssertNotEqual(pidA,pidB); XCTAssertTrue(a.terminal.process.running)
        view.start(session:saved)
        XCTAssertTrue(view.activeRuntime === a); XCTAssertEqual(view.runtimes.count,2)
        view.kindPicker.selectItem(at:AgentKind.allCases.firstIndex(of:.pi)!)
        view.selectionChanged()
        XCTAssertEqual(view.kind,.pi); XCTAssertTrue(view.kindPicker.isEnabled); XCTAssertTrue(a.terminal.process.running); XCTAssertTrue(b.terminal.process.running)
        view.path.stringValue = cli.path; view.agentHome.stringValue = root.path
        // A metadata request does not prevent starting another provider.
        view.startNew(); let c = try XCTUnwrap(view.activeRuntime)
        XCTAssertEqual(c.context.kind,.pi); XCTAssertEqual(view.runtimes.count,3)
        pump(0.6)
        XCTAssertTrue(String(decoding:a.terminal.getTerminal().getBufferAsData(),as:UTF8.self).contains("background output"))
        view.activate(b); view.stopAgent(); view.activate(a)
        pump(1.3)
        XCTAssertFalse(b.terminal.process.running); XCTAssertTrue(a.terminal.process.running); XCTAssertTrue(c.terminal.process.running)
        XCTAssertTrue(view.terminal === a.terminal); XCTAssertEqual(view.terminal?.process.shellPid,pidA)
        view.openSessions.selectItem(at:2); view.selectOpenSession()
        XCTAssertTrue(view.activeRuntime === c)
        view.shutdown(); pump(0.2)
        XCTAssertFalse(view.running)
    }
    func testLinksUseOwningSessionDirectoryAndCurrentWorkspaceIncludingImages() throws {
        _ = NSApplication.shared
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/agent-test-fixtures/links-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file = root.appendingPathComponent("note.txt"),image = root.appendingPathComponent("picture.png")
        try Data("one\ntwo\nthree\n".utf8).write(to:file)
        let png = try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAGUlEQVR4nGP4z8DwnxLMMGrAqAGjBgwXAwAwxP4QHCfkAAAAAABJRU5ErkJggg=="))
        try png.write(to:image)
        let workspace = WorkspaceController(),view = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        workspace.root = FileNode(root); workspace.agentWorkspace = view
        workspace.window?.makeKeyAndOrderFront(nil); workspace.showAgents()
        let key = "agentCLI.local.codex.path",homeKey = "agentCLI.local.codex.home"
        let previous = UserDefaults.standard.object(forKey:key),previousHome = UserDefaults.standard.object(forKey:homeKey)
        defer { workspace.shutdownAgent(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil); UserDefaults.standard.set(previous,forKey:key); UserDefaults.standard.set(previousHome,forKey:homeKey); try? FileManager.default.removeItem(at:root) }
        view.path.stringValue = "/bin/cat"; view.agentHome.stringValue = root.path; view.startNew()
        let runtime = try XCTUnwrap(view.activeRuntime),pid = runtime.terminal.process.shellPid
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        // Exercise protocol dispatch rather than invoking a subclass lookalike.
        runtime.terminal.terminalDelegate?.requestOpenLink(source:runtime.terminal,link:"note.txt:2:1",params:[:])
        let deadline = Date().addingTimeInterval(4)
        while workspace.current?.fileURL != file,Date() < deadline { pump(0.02) }
        XCTAssertEqual(workspace.current?.fileURL,file)
        XCTAssertEqual(workspace.activePane?.textView.selectedRange().location,4)
        runtime.terminal.terminalDelegate?.requestOpenLink(source:runtime.terminal,link:image.absoluteString,params:[:])
        XCTAssertEqual(workspace.current?.fileURL,image)
        XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)),windows)
        workspace.showAgents(); XCTAssertEqual(view.terminal?.process.shellPid,pid); XCTAssertTrue(view.running)
        runtime.terminal.feed(text:"\u{1b}]1337;File=inline=1;width=32px;height=32px:"+png.base64EncodedString()+"\u{7}")
        pump(0.1)
        XCTAssertTrue(runtime.terminal.getTerminal().buffer.hasAnyImages)
        view.startNew(); view.activate(runtime)
        XCTAssertTrue(runtime.terminal.getTerminal().buffer.hasAnyImages)
        // Give the detached rendering check a stable viewport; AppKit can leave
        // a terminal at its fitting size while test windows exchange key status.
        runtime.terminal.removeFromSuperview(); runtime.terminal.translatesAutoresizingMaskIntoConstraints = true
        runtime.terminal.frame = NSRect(x:0,y:0,width:800,height:600)
        runtime.terminal.layoutSubtreeIfNeeded()
        runtime.terminal.getTerminal().resize(cols:80,rows:24)
        runtime.terminal.scroll(toPosition:1)
        runtime.terminal.feed(text:"\u{1b}[2J\u{1b}[H\u{1b}]1337;File=inline=1;width=32px;height=32px:"+png.base64EncodedString()+"\u{7}")
        pump(0.1)
        runtime.terminal.scroll(toPosition:1)
        let rendered = NSImage(size:runtime.terminal.bounds.size)
        rendered.lockFocus()
        runtime.terminal.draw(runtime.terminal.bounds)
        rendered.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(rendered.tiffRepresentation)))
        let redPixels = (0..<min(96,bitmap.pixelsWide)).contains { x in
            (0..<bitmap.pixelsHigh).contains { y in
                guard let color = bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB) else { return false }
                return color.redComponent > 0.65 && color.redComponent > color.greenComponent+0.3 && color.redComponent > color.blueComponent+0.3
            }
        }
        XCTAssertTrue(redPixels,"The terminal must draw the inline image, not merely retain its metadata.")
        try bitmap.representation(using:.png,properties:[:])?.write(to:root.deletingLastPathComponent().appendingPathComponent("inline-image.png"))
    }
    func testFileLinkParsingAndRemoteNamespace() throws {
        XCTAssertEqual(AgentFileLink.resolve("../file name.swift:12:3",directory:"/work/src")?.path,"/work/file name.swift")
        XCTAssertEqual(AgentFileLink.resolve("file:///work/a%20b.swift#L20",directory:"/elsewhere")?.line,20)
        XCTAssertNil(AgentFileLink.resolve("ssh://host/work/file",directory:"/work"))
        XCTAssertNil(AgentFileLink.resolve("a\nb",directory:"/work"))
        let view = AgentWorkspace(project:"/remote/work",remote:try SSHRemote(host:"fixture"),autoLoad:false)
        let terminal = DisplayPacedTerminalView(frame:NSRect(x:0,y:0,width:400,height:300))
        let runtime = AgentRuntime(context:.init(kind:.codex,host:"fixture",executable:"/bin/cat",home:""),session:nil,directory:"/remote/work",remote:view.remote,mapping:nil,terminal:terminal)
        var opened: (String,String?,Int?)?
        view.onOpenFile = { opened = ($0,$1?.host,$2) }
        view.openLink("relative.swift:9",in:runtime)
        XCTAssertEqual(opened?.0,"/remote/work/relative.swift"); XCTAssertEqual(opened?.1,"fixture"); XCTAssertEqual(opened?.2,9)
    }
}
