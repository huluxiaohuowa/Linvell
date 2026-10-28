import XCTest
import AppKit
import WebKit
import LinvellCore
@testable import Linvell

final class MarkdownScrollTests: XCTestCase {
    func evaluate(_ script: String,in web: WKWebView) throws -> Any? {
        let done = expectation(description:"WebKit evaluation")
        var outcome: Result<Any,Error>?
        web.evaluateJavaScript(script,in:nil,in:.defaultClient) { result in outcome = result; done.fulfill() }
        wait(for:[done],timeout:10); return try XCTUnwrap(outcome).get()
    }
    func testSourceAndPreviewScrollTogetherInBothDirections() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("scroll.md")
        let content = (1...100).map { "# Section \($0)\n\n"+String(repeating:"Paragraph text for the native scrolling test. ",count:$0%6+1)+"\n\n" }.joined()
        try content.write(to:file,atomically:true,encoding:.utf8)
        let workspace = WorkspaceController(),doc = OpenDocument(try DocumentBuffer(url:file)); doc.markdownPreview = true
        defer { workspace.window?.orderOut(nil); workspace.recoveryTimer?.invalidate() }
        workspace.activate(doc); workspace.window?.contentView?.layoutSubtreeIfNeeded(); workspace.editors.adjustSubviews()
        let pane = try XCTUnwrap(workspace.activePane),preview = try XCTUnwrap(workspace.markdownView)
        let limit = Date().addingTimeInterval(10)
        while (preview.webView.url == nil || preview.webView.isLoading),Date() < limit { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        RunLoop.current.run(until:Date().addingTimeInterval(0.2))
        pane.scroll.contentView.scroll(to:NSPoint(x:0,y:1200)); pane.scroll.reflectScrolledClipView(pane.scroll.contentView)
        RunLoop.current.run(until:Date().addingTimeInterval(0.25))
        let y = (try evaluate("window.scrollY",in:preview.webView) as? NSNumber)?.doubleValue ?? 0
        XCTAssertGreaterThan(y,100,"Scrolling source must move the rendered preview.")
        _ = try evaluate("window.scrollTo(0,0)",in:preview.webView)
        RunLoop.current.run(until:Date().addingTimeInterval(0.25))
        XCTAssertLessThan(pane.scroll.contentView.bounds.minY,5,"Scrolling preview back to top must move the source too.")
    }
}
