import XCTest
import AppKit
import LinvellCore
@testable import Linvell

final class RemoteListPerformanceTests: XCTestCase {
    func testLargeFolderMaterializesVisibleRowsWithinMeasuredBudget() throws {
        _ = NSApplication.shared
        let browser = RemoteBrowser(connection:try SSHRemote(host:"example"),directoriesOnly:true,initialPath:"/fixture",autoLoad:false)
        let entries = (0..<20_000).map { ["name":"folder-\($0)","path":"/fixture/folder-\($0)","directory":true] as [String:Any] }
        browser.entries = try JSONDecoder().decode([RemoteEntry].self,from:JSONSerialization.data(withJSONObject:entries))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:520),styleMask:.titled,backing:.buffered,defer:false)
        window.contentView = browser
        defer { window.orderOut(nil); window.contentView = nil }
        browser.table.reloadData(); browser.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(browser.table.enclosingScrollView)
        var samples: [Double] = []
        for frame in 0..<120 {
            let start = ProcessInfo.processInfo.systemUptime
            scroll.contentView.scroll(to:NSPoint(x:0,y:CGFloat(frame*200))); scroll.reflectScrolledClipView(scroll.contentView)
            browser.table.prepareContent(in:browser.table.visibleRect)
            let rows = browser.table.rows(in:browser.table.visibleRect)
            if rows.location != NSNotFound {
                for row in rows.location..<min(browser.entries.count,NSMaxRange(rows)) { _ = browser.table.view(atColumn:0,row:row,makeIfNecessary:true) }
            }
            browser.table.layoutSubtreeIfNeeded()
            if frame > 5 { samples.append((ProcessInfo.processInfo.systemUptime-start)*1000) }
        }
        samples.sort(); XCTAssertEqual(browser.table.numberOfRows,20_000)
        if let path = ProcessInfo.processInfo.environment["LINVELL_LIST_RESULT"] {
            let result: [String:Any] = ["entries":20_000,"medianLayoutMS":samples[samples.count/2],"p95LayoutMS":samples[Int(Double(samples.count)*0.95)],"scope":"CPU time for native visible-row materialization/layout; excludes display presentation."]
            try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:path))
        }
    }
}
