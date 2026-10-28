import XCTest
import AppKit
@testable import Linvell

final class ReportedRegressionTests: XCTestCase {
    func testProjectToolsRefreshBuildsAttachedCardsWithoutConstraintException() throws {
        _ = NSApplication.shared
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:fixture,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:fixture) }
        let view = ProjectTools(project:fixture)
        func cards(_ root: NSView) -> [NSView] {
            (String(describing:type(of:root)) == "ToolCard" ? [root] : [])+root.subviews.flatMap(cards)
        }
        let deadline = Date().addingTimeInterval(20)
        while cards(view).isEmpty,Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(cards(view).isEmpty,"Asynchronous refresh must attach its cards without throwing an Auto Layout exception.")
        func segmented(_ root: NSView) -> NSSegmentedControl? { (root as? NSSegmentedControl) ?? root.subviews.compactMap(segmented).first }
        let tabs = try XCTUnwrap(segmented(view)); tabs.selectedSegment = 3
        if let action = tabs.action { tabs.sendAction(action,to:tabs.target) }
        func heatmap(_ root: NSView) -> Bool { String(describing:type(of:root)) == "CoreHeatmap" || root.subviews.contains(where:heatmap) }
        let systemDeadline = Date().addingTimeInterval(15)
        while !heatmap(view),Date() < systemDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(heatmap(view),"System cards must attach before their constraints are activated.")
    }
}
