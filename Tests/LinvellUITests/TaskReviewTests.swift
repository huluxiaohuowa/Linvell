import XCTest
import AppKit
@testable import Linvell
@testable import LinvellCore

final class TaskReviewTests: XCTestCase {
    func testIsolatedTaskRejectsSessionsFromAnotherWorktree() {
        _ = NSApplication.shared
        let view = AgentWorkspace(project:"/fixture/task",remote:nil,autoLoad:false)
        defer { view.shutdown() }
        view.isolatesProject = true
        let main = AgentSession(id:"main",title:"Main work",cwd:"/fixture/main",locator:"main",updated:1)
        let task = AgentSession(id:"task",title:"Task work",cwd:"/fixture/task",locator:"task",updated:2)
        view.sessions = [main,task]; view.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:view.search))
        XCTAssertEqual(view.filtered.map(\.id),["task"])
        view.start(session:main); XCTAssertTrue(view.runtimes.isEmpty)
        XCTAssertEqual(view.status.stringValue,"Open the session's own task workspace to resume it.")
    }
    func testGitDiffReviewUsesDisplayedSideAndOldNewLineNumbers() throws {
        _ = NSApplication.shared
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/review-diff-ui/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"]); _ = try repo.run(["config","user.name","Fixture"]); _ = try repo.run(["config","user.email","fixture@example.invalid"])
        let file = root.appendingPathComponent("a.swift")
        try "original\n".write(to:file,atomically:true,encoding:.utf8); _ = try repo.run(["add","."]); _ = try repo.run(["commit","-m","Initial"])
        try "replacement\n".write(to:file,atomically:true,encoding:.utf8)
        let view = GitWorkspace(repository:repo); view.mode.selectedSegment = 0; view.reload()
        let deadline = Date().addingTimeInterval(5)
        while !view.diff.string.contains("+replacement"),Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        var captured: ReviewComment?; view.onReview = { captured = $0 }
        let selection = (view.diff.string as NSString).range(of:"+replacement")
        XCTAssertNotEqual(selection.location,NSNotFound); view.diff.setSelectedRange(selection); view.addReviewComment()
        XCTAssertEqual(captured?.lines.first?.new,1); XCTAssertNil(captured?.lines.first?.old)
        XCTAssertEqual(captured?.source,"Index → working tree snapshot"); XCTAssertEqual(captured?.path,"a.swift")
        func stageAllButton(in parent: NSView) -> NSButton? {
            if let button = parent as? NSButton,button.title == L.text("Stage All") { return button }
            return parent.subviews.lazy.compactMap { stageAllButton(in:$0) }.first
        }
        let stageAll = try XCTUnwrap(stageAllButton(in:view))
        XCTAssertTrue(stageAll.isEnabled)
        stageAll.performClick(nil)
        let refreshDeadline = Date().addingTimeInterval(5)
        while !view.changes.contains(where:\.staged),Date() < refreshDeadline {
            RunLoop.current.run(until:Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(view.changes.contains(where:\.staged))
        XCTAssertEqual(view.table.numberOfRows,0)
        view.side.selectedSegment = 1; view.side.sendAction(view.side.action,to:view.side.target)
        let stagedDeadline = Date().addingTimeInterval(5)
        while !view.diff.string.contains("-original"),Date() < stagedDeadline {
            RunLoop.current.run(until:Date().addingTimeInterval(0.02))
        }
        let stagedSelection = (view.diff.string as NSString).range(of:"-original")
        XCTAssertNotEqual(stagedSelection.location,NSNotFound)
        view.diff.setSelectedRange(stagedSelection); view.addReviewComment()
        XCTAssertEqual(captured?.source,"HEAD → index snapshot"); XCTAssertEqual(captured?.lines.first?.old,1); XCTAssertNil(captured?.lines.first?.new)

        let previousDiffMode = UserDefaults.standard.object(forKey:"git.diffMode")
        defer { UserDefaults.standard.set(previousDiffMode,forKey:"git.diffMode") }
        view.diffMode.selectedSegment = 2
        view.diffMode.sendAction(view.diffMode.action,to:view.diffMode.target)
        func diffColumn(_ parent: NSView,label: String) -> NSTextView? {
            if let text = parent as? NSTextView,text.accessibilityLabel() == L.text(label) { return text }
            return parent.subviews.lazy.compactMap { diffColumn($0,label:label) }.first
        }
        let before = try XCTUnwrap(diffColumn(view,label:"Before"))
        let after = try XCTUnwrap(diffColumn(view,label:"After"))
        XCTAssertTrue(before.string.contains("-original"))
        XCTAssertFalse(before.string.contains("+replacement"))
        XCTAssertTrue(after.string.contains("+replacement"))
        XCTAssertFalse(after.string.contains("-original"))
        after.setSelectedRange((after.string as NSString).range(of:"+replacement"))
        view.addReviewComment()
        XCTAssertEqual(captured?.source,"HEAD → index snapshot")
        XCTAssertEqual(captured?.lines.first?.new,1)
        XCTAssertNil(captured?.lines.first?.old)
    }
    func testReviewDraftGoesOnlyToSelectedLiveSessionInExactWorktreeWithoutSubmitting() throws {
        _ = NSApplication.shared
        let fm = FileManager.default,root = fm.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/task-review-ui/"+UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let cli = root.appendingPathComponent("agent"),capture = root.appendingPathComponent("capture")
        try ("#!/bin/sh\nstty -echo -icanon min 1 time 0\nprintf '\\033[?2004h'\ncat > "+SSHRemote.quote(capture.path)+"\n").write(to:cli,atomically:true,encoding:.utf8)
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        let workspace = WorkspaceController(),agent = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        workspace.root = FileNode(root); workspace.agentWorkspace = agent
        let keys = ["agentCLI.local.pi.path","agentCLI.local.pi.home"],previous = ["agentCLI.local.pi.path","agentCLI.local.pi.home"].map { UserDefaults.standard.object(forKey:$0) }
        defer { workspace.shutdownAgent(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil); for (key,value) in zip(keys,previous) { UserDefaults.standard.set(value,forKey:key) }; try? fm.removeItem(at:root) }
        agent.kindPicker.selectItem(at:AgentKind.allCases.firstIndex(of:.pi)!); agent.path.stringValue = cli.path; agent.agentHome.stringValue = root.path
        agent.startNew(); let runtime = try XCTUnwrap(agent.activeRuntime)
        let deadline = Date().addingTimeInterval(5)
        while !runtime.terminal.getTerminal().bracketedPasteMode,Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(runtime.terminal.getTerminal().bracketedPasteMode)
        var comment = try ReviewComment.editor(path:"a.swift",text:"hello",range:NSRange(location:0,length:0)); comment.note = "Fix\nthis"
        XCTAssertEqual(workspace.reviewTargets(project:root.path,host:nil).count,1)
        XCTAssertTrue(workspace.reviewTargets(project:root.path+"/different-worktree",host:nil).isEmpty)
        XCTAssertThrowsError(try workspace.pasteReview([comment],project:root.path,host:"other",workspace:agent,runtime:runtime))
        try workspace.pasteReview([comment],project:root.path,host:nil,workspace:agent,runtime:runtime)
        let expected = "\u{1b}[200~"+ReviewComment.prompt([comment],directory:root.path)+"\u{1b}[201~"
        var received = ""
        while Date() < deadline {
            received = (try? String(contentsOf:capture,encoding:.utf8)) ?? ""
            if received == expected { break }; RunLoop.current.run(until:Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(received,expected); XCTAssertFalse(received.hasSuffix("\n")); XCTAssertEqual(runtime.directory,root.path)
        XCTAssertTrue(workspace.editors.arrangedSubviews.first === agent)
    }
    func testReviewPanelRetainsSnapshotAndRemovesOnlySelectedComment() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/review-panel/"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = ReviewCommentStore(project:"/fixture",host:nil,directory:directory)
        var a = try ReviewComment.editor(path:"one.swift",text:"first",range:NSRange(location:0,length:0)); a.note = "change first"
        var b = try ReviewComment.editor(path:"two.swift",text:"second",range:NSRange(location:0,length:0)); b.note = "change second"
        try store.save([a,b])
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        let panel = try ReviewCommentsPanel(store:store,owner:owner)
        defer { panel.closePanel(); owner.orderOut(nil) }
        XCTAssertTrue(panel.preview.string.contains("first"))
        panel.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false); panel.removeComment()
        XCTAssertEqual(try store.load(),[a]); XCTAssertEqual(panel.comments,[a])
    }
}
