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
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path).appendingPathComponent("git-graph-native.png"))
        }
    }
}
