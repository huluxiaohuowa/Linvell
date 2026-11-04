import AppKit
import XCTest
@testable import LinvellCore
@testable import Linvell

final class GitWorkspaceParityTests: XCTestCase {
    private func wait(_ predicate: () -> Bool,file: StaticString = #filePath,line: UInt = #line) {
        let deadline = Date().addingTimeInterval(12)
        while !predicate(),Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.03)) }
        XCTAssertTrue(predicate(),file:file,line:line)
    }
    private func fixture() throws -> GitRepository {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/final-audit/workspace-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"]); _ = try repo.run(["config","user.name","Test"]); _ = try repo.run(["config","user.email","fixture@example.invalid"]); _ = try repo.run(["config","commit.gpgsign","false"])
        for i in 1...3 {
            try "let value = \(i)\n".write(to:root.appendingPathComponent("a.swift"),atomically:true,encoding:.utf8)
            _ = try repo.run(["add","."]); try repo.commit("Commit \(i)\n\nFull body \(i)")
        }
        return repo
    }
    private func descendants(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(descendants) }
    private func capture(_ view: NSView,_ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["LINVELL_SNAPSHOT_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds)); view.cacheDisplay(in:view.bounds,to:bitmap)
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path).appendingPathComponent(name+".png"))
        if ProcessInfo.processInfo.environment["LINVELL_WINDOW_SNAPSHOTS"] == "1",let window = view.window {
            (window.sheetParent ?? window).orderFront(nil); window.orderFront(nil); window.displayIfNeeded()
            RunLoop.current.run(until:Date().addingTimeInterval(0.15))
            let destination = URL(fileURLWithPath:path).appendingPathComponent(name+"-window.png")
            let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/sbin/screencapture"),arguments:["-x","-o","-l",String(window.windowNumber),destination.path],directory:nil,timeout:8)
            XCTAssertTrue(result.succeeded,"Native fixture window capture failed")
        }
    }
    func testHistoryOrderedAutomaticComparisonWorkingEndpointAndNavigation() throws {
        _ = NSApplication.shared; let repo = try fixture(); defer { try? FileManager.default.removeItem(at:repo.root) }
        try "let value = 99\n".write(to:repo.root.appendingPathComponent("a.swift"),atomically:true,encoding:.utf8)
        let view = GitWorkspace(repository:repo)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:900),styleMask:[.titled,.resizable],backing:.buffered,defer:false); window.contentView = view
        defer { view.shutdown(); window.orderOut(nil); window.contentView = nil }
        wait { view.commits.count == 3 && view.changes.count == 1 }
        view.showCommitGraph(); wait { view.table.numberOfRows == 4 }
        view.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        view.table.selectRowIndexes(IndexSet(integer:3),byExtendingSelection:true)
        wait { view.diff.string.contains("-let value = 3") && view.diff.string.contains("+let value = 1") }
        let swap = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == L.text("Swap Commits") })
        try capture(view,"git-history-comparison")
        swap.performClick(nil); wait { view.diff.string.contains("-let value = 1") && view.diff.string.contains("+let value = 3") }
        view.table.selectRowIndexes(IndexSet(integer:2),byExtendingSelection:false)
        view.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:true)
        wait { view.diff.string.contains("-let value = 2") && view.diff.string.contains("+let value = 99") }
        view.table.selectRowIndexes(IndexSet(integer:3),byExtendingSelection:true)
        XCTAssertEqual(view.table.selectedRowIndexes.count,2)
        view.navigateToCommit(view.commits[0].hash)
        wait { descendants(view).compactMap { $0 as? NSTextView }.contains { $0.string == "Full body 3" } }
        try capture(view,"git-commit-navigation")
        let parent = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.title.hasPrefix(L.text("Parent")+" ") })
        parent.performClick(nil)
        wait { descendants(view).compactMap { $0 as? NSTextView }.contains { $0.string == "Full body 2" } }
        let back = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == L.text("Back") })
        back.performClick(nil)
        wait { descendants(view).compactMap { $0 as? NSTextView }.contains { $0.string == "Full body 3" } }
    }
    func testStageRevealsDestinationAndExternalRefreshUpdatesSameRowContent() throws {
        _ = NSApplication.shared; let repo = try fixture(); defer { try? FileManager.default.removeItem(at:repo.root) }
        try "let value = 4\n".write(to:repo.root.appendingPathComponent("a.swift"),atomically:true,encoding:.utf8)
        let view = GitWorkspace(repository:repo)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:900),styleMask:[.titled,.resizable],backing:.buffered,defer:false); window.contentView = view
        defer { view.shutdown(); window.orderOut(nil); window.contentView = nil }
        wait { view.diff.string.contains("+let value = 4") }
        try "let value = 5\n".write(to:repo.root.appendingPathComponent("a.swift"),atomically:true,encoding:.utf8)
        view.refreshExternalState(); wait { view.diff.string.contains("+let value = 5") }
        view.stageFromMenu(); wait { view.otherChanges.numberOfRows == 1 && view.otherChanges.selectedRow == 0 }
        XCTAssertFalse(view.canPerformMenuAction("stageGitChanges"))
        view.side.selectedSegment = 1; view.side.sendAction(view.side.action,to:view.side.target)
        wait { view.diff.string.contains("+let value = 5") }
        view.unstageFromMenu(); wait { view.otherChanges.selectedRow == 0 && view.changes.first?.staged == false }
    }
    func testSettingsChildSheetsAppearImmediatelyAndPreviewHasSize() throws {
        _ = NSApplication.shared; let repo = try fixture(); defer { try? FileManager.default.removeItem(at:repo.root) }
        let view = GitWorkspace(repository:repo)
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:900),styleMask:[.titled,.resizable],backing:.buffered,defer:false); owner.contentView = view
        defer { view.shutdown(); owner.orderOut(nil); owner.contentView = nil }
        wait { view.commits.count == 3 }
        view.showGitSettings(); let settings = try XCTUnwrap(owner.attachedSheet)
        let appearance = try XCTUnwrap(descendants(try XCTUnwrap(settings.contentView)).compactMap { $0 as? NSButton }.first { $0.title == L.text("Diff Appearance…") })
        appearance.performClick(nil); wait { settings.attachedSheet != nil }
        let child = try XCTUnwrap(settings.attachedSheet)
        child.contentView?.layoutSubtreeIfNeeded()
        let preview = try XCTUnwrap(descendants(try XCTUnwrap(child.contentView)).first { $0 is GitReviewDiffView })
        XCTAssertGreaterThan(preview.bounds.width,600); XCTAssertGreaterThan(preview.bounds.height,150)
        try capture(try XCTUnwrap(child.contentView),"git-diff-appearance")
        try XCTUnwrap(descendants(try XCTUnwrap(child.contentView)).compactMap { $0 as? NSButton }.first { $0.title == L.text("Close") }).performClick(nil); wait { settings.attachedSheet == nil }
        let repositories = try XCTUnwrap(descendants(try XCTUnwrap(settings.contentView)).compactMap { $0 as? NSButton }.first { $0.title == L.text("Repository Settings…") })
        repositories.performClick(nil); wait { settings.attachedSheet != nil }
        if let child = settings.attachedSheet { try XCTUnwrap(descendants(try XCTUnwrap(child.contentView)).compactMap { $0 as? NSButton }.first { $0.title == L.text("Close") }).performClick(nil) }; owner.endSheet(settings)
    }
    func testNativeWatchRefreshesDirtyContentAndExternalHead() throws {
        _ = NSApplication.shared; let repo = try fixture(); defer { try? FileManager.default.removeItem(at:repo.root) }
        var changes = 0
        let watch = GitWorkspaceRefresh(repository:repo,isVisible:{ true },changed:{ changes += 1 })
        defer { watch.invalidate() }
        wait { changes > 0 }; let baseline = changes
        try "let value = 22\n".write(to:repo.root.appendingPathComponent("a.swift"),atomically:true,encoding:.utf8)
        wait { changes > baseline }; let dirty = changes
        try "let value = 23\n".write(to:repo.root.appendingPathComponent("a.swift"),atomically:true,encoding:.utf8)
        wait { changes > dirty }; let edited = changes
        _ = try repo.run(["add","."]); try repo.commit("External commit")
        wait { changes > edited }
    }

    func testLiveSSHFinishPanelSelectsTargetResolvesConflictAndSeparatesCleanup() throws {
        guard let fixture = ProcessInfo.processInfo.environment["LINVELL_SSH_FIXTURE"] else { throw XCTSkip("Disposable SSH fixture required") }
        _ = NSApplication.shared
        let config = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:fixture)))
        let remote = try SSHRemote(host:XCTUnwrap(config["host"]),configurationFile:XCTUnwrap(config["configurationFile"]))
        let base = URL(fileURLWithPath:try XCTUnwrap(config["root"])).deletingLastPathComponent().path
        let path = base+"/finish-ui-"+UUID().uuidString
        _ = try GitRepository(remote:remote,directory:config["root"]!).run(["init","-b","main",path])
        let repo = GitRepository(remote:remote,directory:path)
        _ = try repo.run(["config","user.name","Fixture"]); _ = try repo.run(["config","user.email","fixture@example.invalid"]); _ = try repo.run(["config","commit.gpgsign","false"])
        func write(_ repo: GitRepository,_ text: String) throws {
            let path = repo.directory+"/shared.txt"
            if (try? remote.request("read",path:path)) == nil { _ = try remote.request("create",path:path) }
            let before = try remote.request("read",path:path)
            _ = try remote.request("write",path:path,content:Data(text.utf8),digest:before.digest)
            _ = try repo.run(["add","shared.txt"]); try repo.commit(text)
        }
        try write(repo,"base\n")
        _ = try repo.run(["worktree","add","-b","feature","--",path+"-source"])
        _ = try repo.run(["worktree","add","-b","integration","--",path+"-target"])
        let source = GitRepository(remote:remote,directory:path+"-source"),target = GitRepository(remote:remote,directory:path+"-target")
        try write(source,"incoming\n"); try write(target,"current\n")
        let entry = try XCTUnwrap(repo.worktrees().first { $0.branch == "feature" })
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:900),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        var allowed = true
        let panel = GitWorktreeFinishPanel(entry:entry,repository:repo,owner:owner,canRemove:{ _ in allowed },onOpen:{ _ in },onOpenFile:{ _,_ in },onChanged:{})
        defer { panel.closeSheet(); owner.orderOut(nil) }
        wait { panel.plan != nil && !panel.working }
        panel.targets.selectItem(withTitle:"integration"); panel.preview()
        wait { panel.plan?.merge.targetBranch == "integration" && !panel.working }
        XCTAssertEqual(panel.plan?.merge.destination.directory,target.directory)
        panel.advance(); wait { panel.conflicts.count == 1 && !panel.working }
        try capture(try XCTUnwrap(panel.window?.contentView),"git-ssh-finish-conflicts")
        let incoming = NSButton(); incoming.tag = 0; panel.incoming(incoming)
        wait { panel.conflicts.isEmpty && !panel.working }
        panel.advance(); wait { panel.merged && !panel.working }
        XCTAssertTrue(try repo.worktrees().contains { $0.path == source.directory })
        XCTAssertEqual(try target.run(["rev-list","--parents","-1","HEAD"]).split(whereSeparator:\.isWhitespace).count,3)
        try capture(try XCTUnwrap(panel.window?.contentView),"git-ssh-finish-cleanup")
        allowed = false; panel.advance(); XCTAssertTrue(panel.message.stringValue.contains(L.text("Close the source worktree window and stop its agents, or keep its folder.")))
        allowed = true; panel.deleteBranch.state = .on; panel.advance()
        wait { panel.sourceRemoved && !panel.working }
        XCTAssertFalse(try repo.worktrees().contains { $0.path == source.directory })
        XCTAssertThrowsError(try repo.resolvedRevision("refs/heads/feature"))
        XCTAssertEqual(try target.workingFilePreview("shared.txt"),"incoming\n")
    }

    func testClosedWorkspaceRetargetsEditorBufferAfterWorktreeMove() throws {
        _ = NSApplication.shared; let repo = try fixture(); let destination = repo.root.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at:repo.root); try? FileManager.default.removeItem(at:destination) }
        let workspace = WorkspaceController(); defer { workspace.window?.orderOut(nil) }
        workspace.window?.orderOut(nil); workspace.root = FileNode(repo.root)
        let doc = OpenDocument(try DocumentBuffer(url:repo.root.appendingPathComponent("a.swift"))); workspace.documents = [doc]
        try FileManager.default.moveItem(at:repo.root,to:destination)
        workspace.worktreeDidRelocate(host:nil,from:repo.root.path,to:destination.path)
        XCTAssertEqual(workspace.root?.url,destination); XCTAssertEqual(doc.fileURL,destination.appendingPathComponent("a.swift"))
        doc.buffer.update("new content\n"); try doc.buffer.save()
        XCTAssertEqual(try String(contentsOf:destination.appendingPathComponent("a.swift"),encoding:.utf8),"new content\n")
        doc.buffer.update("unsaved\n")
        workspace.worktreeDidRelocate(host:nil,from:destination.path,to:nil)
        XCTAssertEqual(workspace.documents.count,1); XCTAssertEqual(doc.buffer.text,"unsaved\n")
    }

    func testDirectGitCommandsOpenTypedFormsAndRespectSelectionScope() throws {
        _ = NSApplication.shared; let repo = try fixture(); defer { try? FileManager.default.removeItem(at:repo.root) }
        let view = GitWorkspace(repository:repo)
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:900),styleMask:[.titled,.resizable],backing:.buffered,defer:false); owner.contentView = view
        defer { view.shutdown(); owner.orderOut(nil); owner.contentView = nil }
        wait { view.commits.count == 3 }
        XCTAssertFalse(view.canPerformMenuAction("checkoutGitCommit"))
        view.showCommitGraph(); view.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        XCTAssertTrue(view.canPerformMenuAction("checkoutGitCommit")); XCTAssertFalse(view.canPerformMenuAction("compareGitCommits"))
        view.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:true)
        XCTAssertFalse(view.canPerformMenuAction("checkoutGitCommit")); XCTAssertTrue(view.canPerformMenuAction("compareGitCommits"))
        view.newBranchFromMenu(); XCTAssertEqual(view.actionsPage?.operations.titleOfSelectedItem,L.text("Create Branch"))
        view.newTagFromMenu(); XCTAssertEqual(view.actionsPage?.operations.titleOfSelectedItem,L.text("Create Tag"))
        view.stashFromMenu(); XCTAssertEqual(view.actionsPage?.operations.titleOfSelectedItem,L.text("Stash Changes"))
        view.showCommitGraph(); view.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        view.checkoutCommitFromMenu(); XCTAssertEqual(view.actionsPage?.operations.titleOfSelectedItem,L.text("Checkout Commit"))
        XCTAssertTrue(view.actionsPage?.argv.stringValue.contains("--detach") == true)
    }

    func testScopedFolderCommandsExpandAndCollapseEveryAncestor() throws {
        _ = NSApplication.shared; let repo = try fixture(); defer { try? FileManager.default.removeItem(at:repo.root) }
        let defaults = UserDefaults.standard,previous = defaults.object(forKey:"git.groupChangedFiles")
        defaults.set(true,forKey:"git.groupChangedFiles"); defer { if let previous { defaults.set(previous,forKey:"git.groupChangedFiles") } else { defaults.removeObject(forKey:"git.groupChangedFiles") } }
        let folder = repo.root.appendingPathComponent("src/nested")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try "untracked\n".write(to:folder.appendingPathComponent("new.swift"),atomically:true,encoding:.utf8)
        let view = GitWorkspace(repository:repo)
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:900),styleMask:[.titled,.resizable],backing:.buffered,defer:false); owner.contentView = view
        defer { view.shutdown(); owner.orderOut(nil); owner.contentView = nil }
        wait { view.changes.count == 1 && view.table.numberOfRows == 3 }
        XCTAssertTrue(view.canPerformMenuAction("collapseGitDirectories"))
        view.expandDirectoriesFromMenu(false); XCTAssertEqual(view.table.numberOfRows,1)
        view.expandDirectoriesFromMenu(true); XCTAssertEqual(view.table.numberOfRows,3)
        view.showCommitGraph(); XCTAssertFalse(view.canPerformMenuAction("collapseGitDirectories"))
        view.showChangesFromMenu(); XCTAssertTrue(view.canPerformMenuAction("collapseGitDirectories"))
        var opened = false; view.onOpenTerminal = { opened = true }; view.openTerminalFromMenu(); XCTAssertTrue(opened)
    }

}
