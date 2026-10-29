import AppKit
import XCTest
@testable import Linvell
@testable import LinvellCore

final class SourceEditingTests: XCTestCase {
    func testRelativeNumbersUseAbsoluteCurrentLineAndRealSourceDistances() {
        let old = UserDefaults.standard.object(forKey:"relativeLineNumbers")
        defer { UserDefaults.standard.set(old,forKey:"relativeLineNumbers") }
        let gutter = LineNumbers()
        UserDefaults.standard.set(true,forKey:"relativeLineNumbers")
        XCTAssertEqual(gutter.numberLabel(row:8,current:8),"9")
        XCTAssertEqual(gutter.numberLabel(row:3,current:8),"5")
        XCTAssertEqual(gutter.numberLabel(row:20,current:8),"12")
        UserDefaults.standard.set(false,forKey:"relativeLineNumbers")
        XCTAssertEqual(gutter.numberLabel(row:3,current:8),"4")
    }
    func testFoldingChangesGeometryWithoutChangingFileOrUndo() throws {
        _ = NSApplication.shared
        let source = "struct Sample {\n"+String(repeating:"    let value = 123\n",count:100)+"}\n"
        let doc = OpenDocument(DocumentBuffer(text:source)),pane = EditorPane(document:doc,vim:false)
        let modifiedBefore = doc.buffer.isModified
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:600),styleMask:.titled,backing:.buffered,defer:false)
        window.contentView = pane; pane.layoutSubtreeIfNeeded()
        defer { window.contentView = nil; window.orderOut(nil) }
        let deadline = Date().addingTimeInterval(5)
        while doc.syntax.version != doc.buffer.revision,Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        let container = try XCTUnwrap(pane.textView.textContainer)
        pane.folding.ensureLayout(for:container)
        let original = pane.folding.usedRect(for:container).height
        pane.toggleFold(line:0); pane.folding.ensureLayout(for:container)
        let collapsed = pane.folding.usedRect(for:container).height
        XCTAssertLessThan(collapsed,original/2)
        XCTAssertEqual(doc.storage.string,source); XCTAssertEqual(doc.buffer.text,source); XCTAssertEqual(doc.buffer.isModified,modifiedBefore)
        pane.unfoldAll(); pane.folding.ensureLayout(for:container)
        XCTAssertEqual(pane.folding.usedRect(for:container).height,original,accuracy:1)
        pane.toggleFold(line:0)
        pane.textView.setSelectedRange(NSRange(location:0,length:0))
        pane.textView.performMultiEdit([NSRange(location:0,length:0)],replacement:"// added header\n")
        XCTAssertTrue(pane.folding.hidden.isEmpty)
        XCTAssertEqual(doc.storage.string,"// added header\n"+source)
    }
    func testNewlineIsNativeUndoableAndUsesLanguageIndentation() throws {
        _ = NSApplication.shared
        let doc = OpenDocument(DocumentBuffer(text:"func sample() {}")),pane = EditorPane(document:doc,vim:false)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:.titled,backing:.buffered,defer:false)
        window.contentView = pane; defer { window.contentView = nil; window.orderOut(nil) }
        let old = UserDefaults.standard.object(forKey:"useSpaces"); UserDefaults.standard.set(true,forKey:"useSpaces"); defer { UserDefaults.standard.set(old,forKey:"useSpaces") }
        pane.textView.setSelectedRange(NSRange(location:15,length:0)); pane.textView.insertNewline(nil)
        XCTAssertTrue(pane.textView.string.contains("{\n    \n}")); XCTAssertTrue(doc.buffer.isModified)
        window.undoManager?.undo(); XCTAssertEqual(pane.textView.string,"func sample() {}")
    }
}
