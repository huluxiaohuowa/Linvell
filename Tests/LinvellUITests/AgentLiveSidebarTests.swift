import XCTest
import AppKit
@testable import Linvell
@testable import LinvellCore

final class AgentLiveSidebarTests: XCTestCase {
    func testEveryProviderCreatesSidebarRowsBeforeSendingAPromptAndReusesTheirPTYs() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/agent-test-fixtures/sidebar-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let cli = root.appendingPathComponent("dsh-tui")
        let script = #"""
        #!/bin/sh
        printf '\033]0;Interactive session ready\007'
        cat
        """#
        try Data(script.utf8).write(to:cli); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        let view = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        let keys = AgentKind.allCases.flatMap { ["agentCLI.local."+$0.rawValue+".path","agentCLI.local."+$0.rawValue+".home"] },saved = keysSnapshot()
        defer { view.shutdown(); for (key,value) in zip(keys,saved) { UserDefaults.standard.set(value,forKey:key) }; try? FileManager.default.removeItem(at:root) }
        for (index,kind) in AgentKind.allCases.enumerated() {
            view.kindPicker.selectItem(at:index); view.sessions = []; view.path.stringValue = cli.path; view.agentHome.stringValue = root.path
            view.newSession.performClick(nil)
            XCTAssertEqual(view.filtered.count,1,"\(kind.title) must appear before the provider saves anything")
            let first = try XCTUnwrap(view.activeRuntime),firstID = try XCTUnwrap(view.filtered.first?.id)
            XCTAssertTrue(firstID.hasPrefix("linvell-open:")); XCTAssertEqual(view.table.selectedRow,0)
            let deadline = Date().addingTimeInterval(3)
            while first.starting,Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
            view.newSession.performClick(nil)
            XCTAssertEqual(view.filtered.count,2)
            let second = try XCTUnwrap(view.activeRuntime),count = view.runtimes.count
            XCTAssertFalse(first === second)
            let row = try XCTUnwrap(view.filtered.firstIndex(where:{ $0.id == firstID }))
            view.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
            XCTAssertTrue(view.activeRuntime === first)
            view.resumeSelected(); XCTAssertTrue(view.activeRuntime === first); XCTAssertEqual(view.runtimes.count,count)
            XCTAssertTrue(first.terminal.process.running); XCTAssertTrue(second.terminal.process.running)
            first.sessionID = "saved-"+kind.rawValue
            view.sessions = [AgentSession(id:first.sessionID!,title:"Saved title",cwd:root.path,locator:first.sessionID!,updated:Date().timeIntervalSince1970)]
            view.activate(first)
            XCTAssertEqual(view.filtered.count,2,"Saving must merge with the live row instead of duplicating it")
        }
    }
    func testMissingCLIShowsProviderInstallationGuidanceBeforeStarting() {
        _ = NSApplication.shared
        let view = AgentWorkspace(project:"/",remote:nil,autoLoad:false)
        defer { view.shutdown() }
        for (index,kind) in AgentKind.allCases.enumerated() {
            view.kindPicker.selectItem(at:index); view.path.stringValue = "/not-installed/"+kind.rawValue
            view.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:view.path))
            XCTAssertFalse(view.installationHint.isHiddenOrHasHiddenAncestor)
            XCTAssertFalse(view.installationGuide.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(view.installationHint.stringValue.contains(kind.title))
            XCTAssertTrue(view.runtimes.isEmpty)
        }
        view.path.stringValue = "/bin/cat"; view.agentHome.stringValue = "/not-installed/dsh-home"
        view.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:view.path))
        XCTAssertTrue(view.installationHint.stringValue.contains("TUI"))
        XCTAssertFalse(view.installationHint.isHiddenOrHasHiddenAncestor)
        view.kindPicker.selectItem(at:0)
        view.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:view.path))
        XCTAssertTrue(view.installationHint.isHiddenOrHasHiddenAncestor)
    }
    private func keysSnapshot() -> [Any?] {
        AgentKind.allCases.flatMap { [UserDefaults.standard.object(forKey:"agentCLI.local."+$0.rawValue+".path"),UserDefaults.standard.object(forKey:"agentCLI.local."+$0.rawValue+".home")] }
    }
}
