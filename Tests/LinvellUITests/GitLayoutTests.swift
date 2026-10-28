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
        defer { Theme.profile = originalTheme }
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
            for label in [cell.name,cell.path,cell.badge] { XCTAssertTrue(cell.bounds.contains(label.frame)) }
        }
        if let path = ProcessInfo.processInfo.environment["LINVELL_SNAPSHOT_DIR"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds))
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path).appendingPathComponent("git-changes-"+profile.rawValue+".png"))
        }
        }
    }
}
