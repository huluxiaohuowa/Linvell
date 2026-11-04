import AppKit
import XCTest
@testable import LinvellCore
@testable import Linvell

final class GitRemainingInteractionsTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(descendants) }
    private func wait(_ predicate: () -> Bool) {
        let until = Date().addingTimeInterval(8)
        while !predicate(),Date() < until { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(predicate())
    }
    func testGroupImportFiltersCandidatesAndSelectsDiscoveredRoots() throws {
        _ = NSApplication.shared
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/git-interaction-tests/"+UUID().uuidString).resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("a repo")
        try FileManager.default.createDirectory(at:repo,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        _ = try GitRepository(root:repo).run(["init","-b","main"])
        try FileManager.default.createDirectory(at:root.appendingPathComponent("not git"),withIntermediateDirectories:true)
        let editor = GitRepositoryGroupEditor(name:"Batch",candidates:[],selected:[])
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:500),styleMask:.titled,backing:.buffered,defer:false)
        owner.contentView = editor
        defer { owner.orderOut(nil) }
        let imported = expectation(description:"Finder directories imported")
        editor.importDirectories([root,repo]) { imported.fulfill() }
        wait(for:[imported],timeout:8)
        XCTAssertEqual(editor.candidates,[.local(path:repo.path)])
        XCTAssertEqual(editor.selectedLocations,editor.candidates)
        editor.filter.stringValue = "no matching item"; editor.filter.sendAction(editor.filter.action,to:editor.filter.target)
        XCTAssertFalse(descendants(editor).compactMap { $0 as? NSButton }.contains { $0.toolTip == repo.path })
        XCTAssertEqual(editor.selectedLocations.count,1)
    }
    func testPickerGroupsMultipleRepositoriesWithoutLosingDragOrder() throws {
        _ = NSApplication.shared
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:.titled,backing:.buffered,defer:false)
        let options = (0..<100).map { i in PickerOption(title:"Repo \(i)",detail:"",reorderID:String(i)) {} }
        let picker = QuickPicker(title:"Repositories",options:options,owner:owner)
        defer { picker.dismiss(); owner.orderOut(nil) }
        var selected: [String] = []
        picker.selectionActions = [("New Group with Selection",{ selected = $0 })]
        picker.onReorder = { _ in }
        XCTAssertEqual(picker.results.count,100)
        XCTAssertTrue(picker.moveRepositories(["1","2"],before:"0"))
        XCTAssertEqual(picker.options.prefix(3).compactMap(\.reorderID),["1","2","0"])
        picker.table.selectRowIndexes(IndexSet([0,1]),byExtendingSelection:false)
        let button = try XCTUnwrap(descendants(try XCTUnwrap(picker.window?.contentView)).compactMap { $0 as? NSButton }.first { $0.title == L.text("New Group with Selection") })
        button.performClick(nil)
        XCTAssertEqual(selected,["1","2"])
    }
    func testFavoriteButtonsAndStagedSummaryAndMessageVisibility() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["git.commitSnippetEntries","git.showCommitMessageArea"]
        let old = keys.map { ($0,defaults.object(forKey:$0)) }
        defer { for (key,value) in old { defaults.set(value,forKey:key) } }
        GitCommitSnippet.save([.init(text:"Review ready\n\nBody",favorite:true),.init(text:"Not favorite",favorite:false)])
        defaults.set(true,forKey:"git.showCommitMessageArea")
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/git-interaction-tests/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        try "one\ntwo\n".write(to:root.appendingPathComponent("staged.txt"),atomically:true,encoding:.utf8)
        _ = try repo.run(["add","."])
        let workspace = GitWorkspace(repository:repo)
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:1300,height:850),styleMask:.titled,backing:.buffered,defer:false)
        owner.contentView = workspace
        defer { workspace.shutdown(); if let sheet = owner.attachedSheet { owner.endSheet(sheet) }; owner.orderOut(nil) }
        wait { workspace.stagedSummary.stringValue.contains("+2") }
        let button = try XCTUnwrap(descendants(workspace).compactMap { $0 as? NSButton }.first { $0.toolTip == "Review ready\n\nBody" })
        button.performClick(nil)
        XCTAssertEqual(workspace.message.stringValue,"Review ready\n\nBody")
        XCTAssertFalse(descendants(workspace).compactMap { $0 as? NSButton }.contains { $0.toolTip == "Not favorite" })
        workspace.showGitSettings()
        let sheet = try XCTUnwrap(owner.attachedSheet)
        let controls = descendants(try XCTUnwrap(sheet.contentView))
        let visibility = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == L.text("Show Commit Message Area") })
        visibility.state = .off
        let save = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == L.text("Save") })
        save.performClick(nil)
        wait { workspace.message.isHiddenOrHasHiddenAncestor }
        XCTAssertEqual(workspace.message.stringValue,"Review ready\n\nBody")
    }
}
