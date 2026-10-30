import XCTest
import AppKit
@testable import Linvell
@testable import LinvellCore

final class AgentSyncLifecycleTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(90)
        while !predicate(),Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        return predicate()
    }
    func testLiveLocalAgentStartsSyncOnDemandAndLastStopRemovesDaemon() throws {
        let env = ProcessInfo.processInfo.environment
        guard let executable = env["LINVELL_MUTAGEN_TEST_EXECUTABLE"],let host = env["LINVELL_MUTAGEN_TEST_HOST"],let base = env["LINVELL_MUTAGEN_TEST_ROOT"] else { throw XCTSkip("Optional Mutagen and disposable SSH fixture required") }
        _ = NSApplication.shared
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/lvui/"+UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let cli = root.appendingPathComponent("fixture-agent")
        try Data("#!/bin/sh\nprintf 'LOCAL_SYNC_READY\\n'\nexec /bin/cat\n".utf8).write(to:cli)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        var environment = AgentCLI.environment
        environment["PATH"] = (executable as NSString).deletingLastPathComponent+":"+(environment["PATH"] ?? "")
        let state = root.appendingPathComponent("sync"),service = AgentSyncService(root:state,environment:environment)
        let directory = base+"/ui-"+UUID().uuidString
        func ssh(_ script: String) throws -> String {
            let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:["-o","BatchMode=yes","--",host,"/bin/sh -c "+SSHRemote.quote(script)],directory:nil,timeout:20)
            guard result.succeeded else { throw GitError.command(result.output) }; return result.output
        }
        let quoted = SSHRemote.quote(directory)
        _ = try ssh("mkdir -p "+quoted+"; printf seed > "+quoted+"/seed.txt")
        let view = AgentWorkspace(project:directory,remote:try SSHRemote(host:host),autoLoad:false,syncService:service)
        let defaults = UserDefaults.standard,keys = ["agentCLI.local.codex.path","agentCLI.local.codex.home","agentSyncMapping."+host+":"+directory]
        let saved = keys.map { defaults.object(forKey:$0) }
        let container = NSView(frame:NSRect(x:0,y:0,width:1280,height:860))
        view.frame = NSRect(x:320,y:0,width:960,height:860); view.configurationView.frame = NSRect(x:0,y:0,width:320,height:860)
        container.addSubview(view); container.addSubview(view.configurationView)
        let window = NSWindow(contentRect:container.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = container
        window.setFrameOrigin(NSPoint(x:-10000,y:-10000)); window.orderFrontRegardless()
        defer {
            view.shutdown(); window.close()
            for (key,value) in zip(keys,saved) { defaults.set(value,forKey:key) }
            _ = try? ssh("rm -rf -- "+quoted); try? FileManager.default.removeItem(at:root)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:state.path),"Opening an SSH project must not start Mutagen")
        view.location.selectedSegment = 0; view.selectionChanged()
        XCTAssertEqual(view.syncAvailability.textColor,NSColor.systemGreen)
        XCTAssertFalse(FileManager.default.fileExists(atPath:state.path),"Installation detection must not start Mutagen")
        view.path.stringValue = cli.path; view.agentHome.stringValue = root.path
        view.startNew()
        XCTAssertTrue(waitUntil { view.terminal?.process.running == true },view.status.stringValue)
        let first = try XCTUnwrap(view.terminal),mapping = try XCTUnwrap(view.mapping)
        XCTAssertEqual(try String(contentsOf:URL(fileURLWithPath:mapping.localRoot).appendingPathComponent("seed.txt"),encoding:.utf8),"seed")
        view.startNew()
        XCTAssertTrue(waitUntil { view.runtimes.count == 2 && view.newSession.isEnabled })
        let second = try XCTUnwrap(view.terminal)
        XCTAssertFalse(first === second); XCTAssertTrue(first.process.running)
        try Data("last-write".utf8).write(to:URL(fileURLWithPath:mapping.localRoot).appendingPathComponent("last.txt"))
        view.stopAgent()
        XCTAssertTrue(waitUntil { !second.process.running })
        XCTAssertTrue(first.process.running)
        XCTAssertNotEqual(try service.snapshot(mapping).status,"paused","The other local agent still needs synchronization")
        view.openSessions.selectItem(at:0); view.selectOpenSession(); view.stopAgent()
        XCTAssertTrue(waitUntil { !first.process.running && view.syncStatus.stringValue.contains("Mutagen stopped") })
        XCTAssertEqual(try service.snapshot(mapping).status,"paused")
        XCTAssertEqual(try ssh("cat "+quoted+"/last.txt"),"last-write")
        try Data("local-conflict".utf8).write(to:URL(fileURLWithPath:mapping.localRoot).appendingPathComponent("seed.txt"))
        _ = try ssh("printf remote-conflict > "+quoted+"/seed.txt")
        view.connectSync.performClick(nil)
        XCTAssertTrue(waitUntil { !view.reviewConflicts.isHidden && view.connectSync.isEnabled && view.syncStatus.stringValue.contains("Mutagen stopped") })
        XCTAssertEqual(view.runtimes.count,2,"A conflict must not launch a new local agent")
        XCTAssertEqual(try service.snapshot(mapping).status,"paused","A failed connection check must not leave a daemon running")
        // The owned supervisor is reaped after the last session; no login service is used.
        let processes = try ToolCommand.run(URL(fileURLWithPath:"/bin/ps"),arguments:["-axo","args"],directory:nil).output
        XCTAssertFalse(processes.split(separator:"\n").contains { $0.contains("linvell-mutagen") && $0.contains(String(ProcessInfo.processInfo.processIdentifier)) })
        XCTAssertFalse(processes.contains(executable+" daemon run"),"The owned Mutagen daemon must exit along with its supervisor")
    }
}
