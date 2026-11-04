import XCTest
import AppKit
import LinvellCore
@testable import Linvell

final class GitLayoutTests: XCTestCase {
    func testGraphAndActionsFitInNativeWorkspace() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        _ = try repo.run(["config","commit.gpgsign","false"])
        _ = try repo.run(["config","user.name","Linvell Demo"]); _ = try repo.run(["config","user.email","demo@example.invalid"])
        let file = root.appendingPathComponent("hello.swift")
        try "print(\"Hello, Linvell\")\n".write(to:file,atomically:true,encoding:.utf8)
        try repo.stage(try XCTUnwrap(repo.changes().first)); try repo.commit("Create a small workspace")
        _ = try repo.run(["switch","-c","feature/preview"])
        try "print(\"Preview ready\")\n".write(to:file,atomically:true,encoding:.utf8)
        try repo.stage(try XCTUnwrap(repo.changes().first)); try repo.commit("Add a live preview")
        _ = try repo.run(["switch","main"])
        try "# Welcome\n".write(to:root.appendingPathComponent("README.md"),atomically:true,encoding:.utf8)
        try repo.stage(try XCTUnwrap(repo.changes().first)); try repo.commit("Document the project")
        _ = try repo.run(["merge","--no-ff","feature/preview","-m","Merge the preview branch"])
        try "print(\"Working change\")\n".write(to:file,atomically:true,encoding:.utf8)
        let nested = root.appendingPathComponent("docs/research/"+String(repeating:"long-folder-",count:8))
        try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        try "# New research\n".write(to:nested.appendingPathComponent("untracked-note.md"),atomically:true,encoding:.utf8)
        let originalTheme = Theme.profile
        let originalDiffMode = UserDefaults.standard.object(forKey:"git.diffMode")
        defer { Theme.profile = originalTheme; UserDefaults.standard.set(originalDiffMode,forKey:"git.diffMode") }
        for profile in [Theme.Profile.light,.dark] {
        Theme.profile = profile
        let view = GitWorkspace(project:root)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1240,height:780),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = view
        defer { window.orderOut(nil); window.contentView = nil }
        view.mode.selectedSegment = 1; view.reload()
        let deadline = Date().addingTimeInterval(5)
        while view.commits.count < 4,Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(view.commits.count,4); XCTAssertTrue(view.graph.contains { $0.width > 1 })
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.table.bounds.height,200)
        XCTAssertGreaterThanOrEqual(view.table.enclosingScrollView?.bounds.width ?? 0,280)
        let diffDeadline = Date().addingTimeInterval(3)
        while view.diff.string.isEmpty,Date() < diffDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        view.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["LINVELL_SNAPSHOT_DIR"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path).appendingPathComponent("git-graph-"+profile.rawValue+".png"))
        }
        view.mode.selectedSegment = 0
        if let action = view.mode.action { view.mode.sendAction(action,to:view.mode.target) }
        let changesDeadline = Date().addingTimeInterval(5)
        while view.changes.count < 2,Date() < changesDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(view.changes.count,2)
        let changeDiffDeadline = Date().addingTimeInterval(3)
        while !view.diff.string.contains("Working change"),Date() < changeDiffDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        view.layoutSubtreeIfNeeded(); view.table.layoutSubtreeIfNeeded()
        for row in 0..<view.changes.count {
            let cell = try XCTUnwrap(view.table.view(atColumn:0,row:row,makeIfNecessary:true) as? GitFileCell)
            cell.layoutSubtreeIfNeeded()
            let clip = try XCTUnwrap(view.table.enclosingScrollView?.contentView)
            for label in [cell.name,cell.path,cell.badge] {
                XCTAssertTrue(cell.bounds.contains(label.frame))
                XCTAssertLessThanOrEqual(cell.convert(label.frame,to:clip).maxX,clip.bounds.maxX)
            }
        }
        if let path = ProcessInfo.processInfo.environment["LINVELL_SNAPSHOT_DIR"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path).appendingPathComponent("git-changes-"+profile.rawValue+".png"))
            view.diffMode.selectedSegment = 2
            view.diffMode.sendAction(view.diffMode.action,to:view.diffMode.target)
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path).appendingPathComponent("git-split-"+profile.rawValue+".png"))
            view.diffMode.selectedSegment = 1
            view.diffMode.sendAction(view.diffMode.action,to:view.diffMode.target)
        }

        view.side.selectedSegment = 1
        view.side.sendAction(view.side.action,to:view.side.target)
        XCTAssertEqual(view.table.numberOfRows,0)
        XCTAssertTrue(view.diff.string.isEmpty)
        view.side.selectedSegment = 0
        view.side.sendAction(view.side.action,to:view.side.target)
        XCTAssertEqual(view.table.numberOfRows,2)
        }
    }

    func testPartiallyStagedFileUsesSelectedDiff() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        let file = root.appendingPathComponent("source.swift")
        try "staged content\n".write(to:file,atomically:true,encoding:.utf8)
        try repo.stage(try XCTUnwrap(repo.changes().first))
        try "working content\n".write(to:file,atomically:true,encoding:.utf8)
        try "untracked content\n".write(to:root.appendingPathComponent("z.txt"),atomically:true,encoding:.utf8)
        let view = GitWorkspace(repository:repo)
        func waitForDiff(_ line: String) {
            let deadline = Date().addingTimeInterval(5)
            while !view.diff.string.contains(line),Date() < deadline {
                RunLoop.current.run(until:Date().addingTimeInterval(0.05))
            }
            XCTAssertTrue(view.diff.string.contains(line))
        }
        XCTAssertEqual(view.mode.selectedSegment,0)
        waitForDiff("+working content")
        XCTAssertEqual(view.table.numberOfRows,2)
        XCTAssertEqual(view.otherChanges.numberOfRows,1)
        XCTAssertFalse(view.otherChanges.isHiddenOrHasHiddenAncestor)
        view.side.selectedSegment = 1
        view.side.sendAction(view.side.action,to:view.side.target)
        waitForDiff("+staged content")
        XCTAssertEqual(view.table.numberOfRows,1)
        XCTAssertFalse(view.diff.string.contains("working content"))
    }
    func testHistorySearchSelectsWholeRepositoryResults() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        _ = try repo.run(["config","user.name","Fixture"])
        _ = try repo.run(["config","user.email","fixture@example.invalid"])
        _ = try repo.run(["config","commit.gpgsign","false"])
        _ = try repo.run(["commit","--allow-empty","-m","Saved subject","-m","旧版完整说明"])
        _ = try repo.run(["switch","--orphan","other"])
        _ = try repo.run(["commit","--allow-empty","-m","Current branch"])
        let view = GitWorkspace(repository:repo)
        view.focusHistorySearch()
        func searchField(in parent: NSView) -> NSSearchField? {
            if let field = parent as? NSSearchField,
               field.placeholderString == L.text("Search hash, author, email, message or reference") { return field }
            return parent.subviews.lazy.compactMap { searchField(in:$0) }.first
        }
        let search = try XCTUnwrap(searchField(in:view))
        for query in ["query to cancel","旧版完整说明"] {
            search.stringValue = query
            view.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:search))
        }
        let deadline = Date().addingTimeInterval(5)
        while view.table.numberOfRows != 1,Date() < deadline {
            RunLoop.current.run(until:Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(view.table.numberOfRows,1)
        let cell = try XCTUnwrap(view.tableView(view.table,viewFor:view.table.tableColumns.first,row:0))
        XCTAssertTrue(cell.accessibilityLabel()?.contains("Saved subject") == true)
    }
    func testWrapAndCommitSnippetsAreAvailableFromGitControls() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        let defaults = UserDefaults.standard
        let oldWrap = defaults.object(forKey:"git.wrapDiff"),oldSnippets = defaults.object(forKey:"git.commitSnippets")
        defer { defaults.set(oldWrap,forKey:"git.wrapDiff"); defaults.set(oldSnippets,forKey:"git.commitSnippets") }
        defaults.set(false,forKey:"git.wrapDiff")
        defaults.set(["Review ready"],forKey:"git.commitSnippets")
        let view = GitWorkspace(repository:repo)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = view
        defer { view.gitPicker?.dismiss(); window.orderOut(nil); window.contentView = nil }
        func button(_ view: NSView,title: String) -> NSButton? {
            if let button = view as? NSButton,button.title == L.text(title) { return button }
            return view.subviews.lazy.compactMap { button($0,title:title) }.first
        }
        let wrap = try XCTUnwrap(button(view,title:"Wrap Lines"))
        wrap.sendAction(wrap.action,to:wrap.target)
        XCTAssertTrue(view.diff.textContainer?.widthTracksTextView == true)
        XCTAssertFalse(view.diff.enclosingScrollView?.hasHorizontalScroller == true)

        view.browseTools()
        let tools = try XCTUnwrap(view.gitPicker)
        let snippets = try XCTUnwrap(tools.options.first { $0.title == L.text("Commit Snippets…") })
        tools.dismiss()
        snippets.invoke()
        let picker = try XCTUnwrap(view.gitPicker)
        let insert = try XCTUnwrap(picker.options.first { $0.title == "Review ready" })
        picker.dismiss()
        insert.invoke()
        XCTAssertEqual(view.message.stringValue,"Review ready")
    }
    func testInlineHighlightUsesUTF16OffsetsWithoutChangingPatch() throws {
        let source = "@@ -1 +1 @@\n-let café = 12\n+let café = 13\n"
        let patch = NSMutableAttributedString(string:source)
        InlineDiff.highlight(patch,removed:.systemRed,added:.systemGreen)
        XCTAssertEqual(patch.string,source)
        let range = (source as NSString).range(of:"13")
        XCTAssertNotNil(patch.attribute(.backgroundColor,at:NSMaxRange(range)-1,effectiveRange:nil))
        XCTAssertNil(patch.attribute(.backgroundColor,at:(source as NSString).range(of:"café").location,effectiveRange:nil))
    }
}
