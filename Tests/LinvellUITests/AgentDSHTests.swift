import XCTest
import AppKit
@testable import Linvell
@testable import LinvellCore

final class AgentDSHTests: XCTestCase {
    private func wait(_ seconds: TimeInterval = 20,until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(),Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        return condition()
    }
    private func output(_ view: AgentWorkspace) -> String {
        view.terminal.map { String(decoding:$0.getTerminal().getBufferAsData(),as:UTF8.self) } ?? ""
    }
    func testMissingTUIDoesNotSpawnRepeatedDesktopWebProcesses() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/agent-test-fixtures/missing-tui-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let view = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        view.kindPicker.selectItem(at:AgentKind.allCases.firstIndex(of:.dsh)!)
        view.path.stringValue = "/usr/bin/false"; view.agentHome.stringValue = root.path
        for _ in 0..<7 { view.newSession.performClick(nil) }
        XCTAssertTrue(view.runtimes.isEmpty)
        XCTAssertTrue(view.status.stringValue.contains("TUI"))
    }
    func testNewButtonUsesFullTerminalViewportAndCoalescesStartupClicks() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/agent-test-fixtures/tui-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let cli = root.appendingPathComponent("dsh-tui")
        let script = #"""
        #!/bin/sh
        sleep 0.2
        printf '\033]0;DSH TUI ready\007DSH_TUI_READY\n'
        cat
        """#
        try Data(script.utf8).write(to:cli)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        let workspace = WorkspaceController(),view = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        let keys = ["agentCLI.local.dsh.path","agentCLI.local.dsh.home"],saved = ["agentCLI.local.dsh.path","agentCLI.local.dsh.home"].map { UserDefaults.standard.object(forKey:$0) }
        defer { workspace.shutdownAgent(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil); for (k,v) in zip(keys,saved) { UserDefaults.standard.set(v,forKey:k) }; try? FileManager.default.removeItem(at:root) }
        view.kindPicker.selectItem(at:AgentKind.allCases.firstIndex(of:.dsh)!)
        view.path.stringValue = cli.path; view.agentHome.stringValue = root.path
        workspace.root = FileNode(root); workspace.agentWorkspace = view
        workspace.window?.setContentSize(NSSize(width:1500,height:900)); workspace.window?.makeKeyAndOrderFront(nil); workspace.showAgents()
        view.newSession.performClick(nil)
        for _ in 0..<7 { view.startNew() }
        XCTAssertEqual(view.runtimes.count,1)
        XCTAssertTrue(wait { self.output(view).contains("DSH_TUI_READY") && view.newSession.isEnabled })
        workspace.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.terminal?.superview === view.terminalHost)
        XCTAssertGreaterThan(view.terminalHost.frame.height,view.bounds.height*0.7)
        XCTAssertLessThan(view.openSessions.superview?.frame.height ?? 1000,40)
        XCTAssertFalse(view.activeRuntime?.starting ?? true)
        let ready = try XCTUnwrap(view.activeRuntime)
        ready.starting = true
        view.setTerminalTitle(source:ready.terminal,title:ready.title)
        XCTAssertFalse(ready.starting,"A resumed session can announce the same title and still be ready")
    }
    func testInstalledSourceTUIWithAccountAndHistory() throws {
        guard let executable = ProcessInfo.processInfo.environment["LINVELL_DSH_TUI_EXECUTABLE"] else { throw XCTSkip("Explicit source TUI acceptance required") }
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/agent-test-fixtures/live-tui-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let workspace = WorkspaceController(),view = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        let keys = ["agentCLI.local.dsh.path","agentCLI.local.dsh.home"],saved = ["agentCLI.local.dsh.path","agentCLI.local.dsh.home"].map { UserDefaults.standard.object(forKey:$0) }
        defer { workspace.shutdownAgent(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil); for (k,v) in zip(keys,saved) { UserDefaults.standard.set(v,forKey:k) } }
        view.kindPicker.selectItem(at:AgentKind.allCases.firstIndex(of:.dsh)!)
        view.path.stringValue = executable; view.agentHome.stringValue = ""
        workspace.root = FileNode(root); workspace.agentWorkspace = view
        workspace.window?.setContentSize(NSSize(width:1500,height:900)); workspace.window?.makeKeyAndOrderFront(nil); workspace.showAgents()
        view.newSession.performClick(nil)
        XCTAssertTrue(wait(40) { self.output(view).contains("Say something") || self.output(view).contains("输入") })
        XCTAssertGreaterThan(view.terminalHost.frame.height,view.bounds.height*0.7)
        let terminal = try XCTUnwrap(view.terminal)
        terminal.send(data:Array("Reply with exactly LINVELL_NATIVE_TUI_OK. Do not use tools.".utf8)[...])
        RunLoop.current.run(until:Date().addingTimeInterval(0.2)); terminal.send(data:[13][...])
        var discovered: AgentSession?,lastCheck = Date.distantPast
        XCTAssertTrue(wait(30) {
            if Date().timeIntervalSince(lastCheck) > 1 {
                lastCheck = Date()
                discovered = try? AgentDSHSessions.list(executable:executable,project:root.path).first
            }
            return discovered != nil
        })
        let session = try XCTUnwrap(discovered)
        let storage = try XCTUnwrap(AgentCLI.defaultStorage(.dsh).first)
        let files = FileManager.default.enumerator(at:storage,includingPropertiesForKeys:nil)
        var log: URL?
        while let file = files?.nextObject() as? URL {
            if file.deletingLastPathComponent().lastPathComponent == session.id,file.lastPathComponent == "session.v4.jsonl.zstd" { log = file; break }
        }
        let sessionLog = try XCTUnwrap(log),node = try XCTUnwrap(ToolCommand.executable("node"))
        let script = #"""
        const fs=require('fs'),z=require('zlib');let b=fs.readFileSync(process.argv[1]),s='';
        while(b.length){try{const r=z.zstdDecompressSync(b,{info:true});s+=r.buffer;b=b.subarray(r.engine.bytesWritten)}catch{break}}
        const complete=s.split('\n').some(line=>{try{const e=JSON.parse(line);return e.type==='assistant/message'&&!e.data.interrupted&&e.data.message.content.some(p=>p.type==='text'&&p.text.trim()==='LINVELL_NATIVE_TUI_OK')}catch{return false}});
        process.stdout.write(complete?'READY':'WAIT');
        """#
        var complete = false
        XCTAssertTrue(wait(90) {
            if Date().timeIntervalSince(lastCheck) > 1 {
                lastCheck = Date()
                complete = (try? ToolCommand.run(node,arguments:["-e",script,sessionLog.path],directory:root,timeout:5).output) == "READY"
            }
            return complete
        },"Wait for the persisted assistant answer, not repeated terminal redraws of the user prompt.")
        XCTAssertTrue(wait(10) { self.output(view).components(separatedBy:"LINVELL_NATIVE_TUI_OK").count >= 3 })
        view.stopAgent(); XCTAssertTrue(wait(5) { !view.running })
        view.filtered = [session]; view.table.reloadData(); view.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        NSApp.sendAction(try XCTUnwrap(view.table.doubleAction),to:view.table.target,from:view.table)
        XCTAssertTrue(wait(40) { self.output(view).components(separatedBy:"LINVELL_NATIVE_TUI_OK").count >= 3 })
        XCTAssertEqual(view.activeRuntime?.sessionID,session.id)
        XCTAssertGreaterThan(view.terminalHost.frame.height,view.bounds.height*0.7)
        view.terminal?.scroll(toPosition:1)
        workspace.window?.contentView?.layoutSubtreeIfNeeded(); workspace.window?.displayIfNeeded()
        RunLoop.current.run(until:Date().addingTimeInterval(0.3))
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
        view.cacheDisplay(in:view.bounds,to:image)
        try image.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/dsh-tui-native-accepted.png"))
    }
}
