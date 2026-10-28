import XCTest
import AppKit
import QuartzCore
@testable import Linvell
import SwiftTerm

final class RenderingTests: XCTestCase {
    func testResponsiveScrollingAndRefreshHintsCoverHighRefreshDisplays() {
        _ = NSApplication.shared
        let scroll = ResponsiveScrollView()
        XCTAssertTrue(type(of:scroll).isCompatibleWithResponsiveScrolling)
        XCTAssertTrue(type(of:scroll.contentView).isCompatibleWithResponsiveScrolling)
        XCTAssertTrue(ResponsiveTableView.isCompatibleWithResponsiveScrolling)
        XCTAssertTrue(ResponsiveOutlineView.isCompatibleWithResponsiveScrolling)
        XCTAssertTrue(EditorTextView.isCompatibleWithResponsiveScrolling)
        XCTAssertTrue(scroll.wantsLayer); XCTAssertTrue(scroll.contentView.wantsLayer)
        for maximum in [60,120,144,240] {
            let range = Rendering.frameRange(maximum:maximum)
            XCTAssertEqual(range.maximum,Float(maximum)); XCTAssertEqual(range.preferred,Float(maximum))
        }
    }
    func testTerminalUsesHostSchedulerInsteadOfFixedSixtyHzDelay() {
        _ = NSApplication.shared
        let view = DisplayPacedTerminalView(frame:NSRect(x:0,y:0,width:600,height:300))
        XCTAssertNotNil(view.displayUpdateScheduler)
        RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        var commits = 0
        view.displayUpdateScheduler = { work in commits += 1; work() }
        view.feed(text:"first\r\n"); view.feed(text:"second\r\n")
        XCTAssertEqual(commits,2,"Host scheduler controls the terminal/cursor update cadence.")
    }
    func testDisplayCadenceProbeWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["LINVELL_FRAME_PROBE"] == "1" else { throw XCTSkip("Physical display cadence probe is opt-in.") }
        _ = NSApplication.shared
        // Non-key, almost transparent test surface; never opens an editor or steals focus.
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:8,height:8),styleMask:.borderless,backing:.buffered,defer:false)
        window.alphaValue = 0.01; window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x:(NSScreen.main?.visibleFrame.minX ?? 0)+2,y:(NSScreen.main?.visibleFrame.minY ?? 0)+2)); window.orderBack(nil)
        let scheduler = WindowFrameScheduler(window:window)
        defer { scheduler.stop(); window.orderOut(nil) }
        var times: [Double] = []; scheduler.onFrame = { times.append($0) }; scheduler.pulse(duration:1.5)
        let deadline = Date().addingTimeInterval(1.3)
        while Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        let intervals = zip(times.dropFirst(),times).map { $0-$1 }.filter { $0 > 0 }.sorted()
        XCTAssertGreaterThan(intervals.count,10)
        if let path = ProcessInfo.processInfo.environment["LINVELL_FRAME_RESULT"],!intervals.isEmpty {
            let value: [String:Any] = ["maximumRefreshRate":window.screen?.maximumFramesPerSecond ?? 0,"callbacks":times.count,"medianCallbackMS":intervals[intervals.count/2]*1000,"p95CallbackMS":intervals[min(intervals.count-1,Int(Double(intervals.count)*0.95))]*1000,"scope":"Display-link callback cadence, not proof of every pixel being presented at this rate."]
            try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        }
    }
}
