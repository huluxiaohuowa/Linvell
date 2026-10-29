import XCTest
import AppKit
@testable import Linvell
@testable import LinvellCore

final class PluginEditingTests: XCTestCase {
    func testPluginEditIsUndoableAndRejectsStaleResult() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceController(),document = OpenDocument(DocumentBuffer(text:"hello 🐱"))
        defer { workspace.stopPlugins(); workspace.resetLanguageServices(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil) }
        workspace.documents = [document]; workspace.activate(document)
        let pane = try XCTUnwrap(workspace.activePane),revision = document.buffer.revision
        try workspace.applyPluginReplacement("HELLO 🐱",document:document,pane:pane,revision:revision,original:"hello 🐱")
        XCTAssertEqual(pane.textView.string,"HELLO 🐱")
        pane.textView.undoManager?.undo()
        XCTAssertEqual(pane.textView.string,"hello 🐱")
        XCTAssertThrowsError(try workspace.applyPluginReplacement("lost",document:document,pane:pane,revision:revision,original:"hello 🐱"))
        XCTAssertEqual(pane.textView.string,"hello 🐱")
        workspace.current = nil
        XCTAssertThrowsError(try workspace.applyPluginReplacement("lost",document:document,pane:pane,revision:document.buffer.revision,original:pane.textView.string))
    }
}
