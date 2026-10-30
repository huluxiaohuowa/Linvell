import XCTest
import AppKit
@testable import Linvell
@testable import LinvellCore

final class InteractivePerformanceTests: XCTestCase {
    func testTabRefreshPreservesRowsAcrossSelectionSaveAndReorder() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceController()
        defer { workspace.resetLanguageServices(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil) }
        let a = OpenDocument(DocumentBuffer()),b = OpenDocument(DocumentBuffer())
        workspace.documents = [a,b]; workspace.current = a; workspace.renderTabs()
        let first = workspace.tabs.arrangedSubviews[0],second = workspace.tabs.arrangedSubviews[1]
        workspace.current = b; workspace.renderTabs()
        XCTAssertTrue(workspace.tabs.arrangedSubviews[0] === first)
        XCTAssertTrue(workspace.tabs.arrangedSubviews[1] === second)
        workspace.documents = [b,a]; workspace.renderTabs()
        XCTAssertTrue(workspace.tabs.arrangedSubviews[0] === second)
        XCTAssertTrue(workspace.tabs.arrangedSubviews[1] === first)
        let button = try XCTUnwrap((second as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }.first)
        XCTAssertEqual(button.tag,0)
        workspace.documents = [a]; workspace.renderTabs()
        XCTAssertTrue(workspace.tabs.arrangedSubviews[0] === first)
    }
    func testTypingImmediatelyCancelsObsoleteInteractiveRequests() {
        _ = NSApplication.shared
        let workspace = WorkspaceController(),document = OpenDocument(DocumentBuffer())
        defer { workspace.resetLanguageServices(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil) }
        let completion = LanguageQueryTicket(),signature = LanguageQueryTicket(),hover = LanguageQueryTicket()
        workspace.languageQueries = ["textDocument/completion":completion,"textDocument/signatureHelp":signature,"textDocument/hover":hover]
        workspace.languageDocumentChanged(document)
        XCTAssertTrue(completion.cancelled); XCTAssertTrue(signature.cancelled); XCTAssertTrue(hover.cancelled)
    }
    func testCompletionDebounceAndDiagnosticsAreCoalescedSeparately() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceController(),document = OpenDocument(DocumentBuffer())
        defer { workspace.resetLanguageServices(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil) }
        let pane = EditorPane(document:document,vim:false)
        workspace.current = document; workspace.activePane = pane
        pane.textView.string = "os."; pane.textView.setSelectedRange(NSRange(location:3,length:0))
        XCTAssertEqual(workspace.completionDelay(document),0.035,accuracy:0.001)
        pane.textView.string = "identifier"; pane.textView.setSelectedRange(NSRange(location:10,length:0))
        XCTAssertEqual(workspace.completionDelay(document),0.12,accuracy:0.001)
        workspace.languageDocumentChanged(document)
        let edit = try XCTUnwrap(workspace.languageEdits[document.buffer.id])
        let diagnostic = try XCTUnwrap(workspace.languageDiagnostics[document.buffer.id])
        workspace.languageDocumentChanged(document)
        XCTAssertTrue(edit.isCancelled); XCTAssertTrue(diagnostic.isCancelled)
        XCTAssertFalse(try XCTUnwrap(workspace.languageEdits[document.buffer.id]).isCancelled)
        workspace.resetLanguageServices()
        XCTAssertTrue(workspace.languageEdits.isEmpty); XCTAssertTrue(workspace.languageDiagnostics.isEmpty)
    }
    func testTabRefreshBenchmark() {
        _ = NSApplication.shared
        let workspace = WorkspaceController()
        defer { workspace.resetLanguageServices(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil) }
        workspace.documents = (0..<30).map { _ in OpenDocument(DocumentBuffer()) }
        workspace.renderTabs()
        func run(recreate: Bool) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<100 {
                if recreate { workspace.tabs.arrangedSubviews.forEach { $0.removeFromSuperview() }; workspace.tabRows.removeAll(); workspace.tabIconURLs.removeAll() }
                workspace.renderTabs()
            }
            return (ProcessInfo.processInfo.systemUptime-start)*1000/100
        }
        let reuse = run(recreate:false),recreate = run(recreate:true)
        print("TAB_BENCHMARK rows=30 iterations=100 reused_ms=\(reuse) recreated_ms=\(recreate) scope=CPU_refresh_only")
        XCTAssertEqual(workspace.tabs.arrangedSubviews.count,30)
    }

}
