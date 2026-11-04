import AppKit
import XCTest
import LinvellCore
@testable import Linvell

final class GitReviewPanelTests: XCTestCase {
    func testReviewPanelShowsSourceAndExpandsMultiplePatches() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try "working source\n".write(to:root.appendingPathComponent("a.txt"),atomically:true,encoding:.utf8)
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:720),styleMask:[.titled],backing:.buffered,defer:false)
        let controller = GitReviewPanel(repository:GitRepository(root:root),files:[
            .init(path:"a.txt",patch:{ "first patch" }),
            .init(path:"b.txt",patch:{ "second patch" })
        ],owner:owner)
        let sheet = try XCTUnwrap(controller.window)
        defer { owner.endSheet(sheet); owner.orderOut(nil) }
        let content = try XCTUnwrap(sheet.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(descendants) }
        func waitForText(_ value: String) {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if descendants(content).compactMap({ $0 as? NSTextView }).contains(where:{ $0.string.contains(value) }) { return }
                RunLoop.current.run(until:Date().addingTimeInterval(0.02))
            }
            XCTFail("Missing preview: "+value)
        }
        let modes = try XCTUnwrap(descendants(content).compactMap { $0 as? NSSegmentedControl }.first)
        modes.selectedSegment = 0
        modes.sendAction(modes.action,to:modes.target)
        waitForText("working source")
        let expand = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == L.text("Expand Diffs") })
        expand.sendAction(expand.action,to:expand.target)
        waitForText("first patch")
        waitForText("second patch")
        if let path = ProcessInfo.processInfo.environment["LINVELL_SNAPSHOT_DIR"] {
            content.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in:content.bounds))
            content.cacheDisplay(in:content.bounds,to:bitmap)
            let data = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
            try data.write(to:URL(fileURLWithPath:path).appendingPathComponent("git-review.png"))
        }
        let collapse = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == L.text("Collapse Diffs") })
        collapse.sendAction(collapse.action,to:collapse.target)
        XCTAssertFalse(descendants(content).compactMap { $0 as? NSTextView }.contains { $0.string.contains("second patch") })
    }
    func testGitLogAndSettingsOpenFromWorkspace() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        XCTAssertThrowsError(try repo.run(["show","missing"]))
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:720),styleMask:[.titled],backing:.buffered,defer:false)
        let workspace = GitWorkspace(repository:repo)
        owner.contentView = workspace
        defer {
            if let sheet = owner.attachedSheet { owner.endSheet(sheet) }
            owner.orderOut(nil)
        }
        workspace.openGitJournal()
        let log = try XCTUnwrap(workspace.gitPicker)
        XCTAssertTrue(log.options.contains { $0.title == "git show" })
        let filter = try XCTUnwrap(log.options.first { $0.title == L.text("Show Failed Commands") })
        log.dismiss()
        filter.invoke()
        let filtered = try XCTUnwrap(workspace.gitPicker)
        XCTAssertTrue(filtered.options.contains { $0.title == "git show" })
        XCTAssertFalse(filtered.options.contains { $0.title == "git operation" && $0.detail.contains(L.text("Succeeded")) })
        filtered.dismiss()
        workspace.showGitSettings()
        let sheet = try XCTUnwrap(owner.attachedSheet)
        func descendants(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(descendants) }
        let controls = descendants(try XCTUnwrap(sheet.contentView))
        XCTAssertTrue(controls.compactMap { $0 as? NSButton }.contains { $0.title == L.text("Show Commit Graph") })
        XCTAssertTrue(controls.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(L.text("Last successful Fetch")) })
    }
    func testImageComparisonDisplaysBothRevisions() throws {
        _ = NSApplication.shared
        let png = try XCTUnwrap(Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAGUlEQVR4nGP4z8DwnxLMMGrAqAGjBgwXAwAwxP4QHCfkAAAAAABJRU5ErkJggg=="))
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:720),styleMask:[.titled],backing:.buffered,defer:false)
        let controller = GitReviewPanel(repository:GitRepository(root:FileManager.default.temporaryDirectory),
                                        files:[.init(path:"image.png",patch:{ "Binary files differ" },images:{ (png,png) })],
                                        owner:owner)
        let sheet = try XCTUnwrap(controller.window)
        defer { owner.endSheet(sheet); owner.orderOut(nil) }
        func descendants(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(descendants) }
        let content = try XCTUnwrap(sheet.contentView)
        let deadline = Date().addingTimeInterval(5)
        var images: [NSImageView] = []
        while Date() < deadline {
            images = descendants(content).compactMap { $0 as? NSImageView }.filter { $0.image != nil }
            if images.count == 2 { break }
            RunLoop.current.run(until:Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(images.count,2)
    }
}
