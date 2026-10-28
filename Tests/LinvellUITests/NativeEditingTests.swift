import XCTest
import AppKit
import LinvellCore
@testable import Linvell

final class NativeEditingTests: XCTestCase {
    var window: NSWindow!
    var pane: EditorPane!
    override func setUp() {
        _ = NSApplication.shared
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:600),styleMask:[.titled],backing:.buffered,defer:false)
        pane = EditorPane(document:OpenDocument(DocumentBuffer(text:"alpha alpha\nalpha end\n")),vim:false)
        window.contentView = pane; window.makeFirstResponder(pane.textView); window.contentView?.layoutSubtreeIfNeeded()
    }
    override func tearDown() { window.orderOut(nil); window.contentView = nil; pane = nil; window = nil }
    func testMultipleInsertIsOneUndoAndRedo() {
        let view = pane.textView,original = view.string
        view.setSelections([NSRange(location:0,length:5),NSRange(location:12,length:5)])
        view.insertText("β",replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertEqual(view.string,"β alpha\nβ end\n"); XCTAssertEqual(view.editingSelections.count,2)
        XCTAssertNotNil(view.undoManager); view.undoManager?.undo()
        XCTAssertEqual(view.string,original); XCTAssertEqual(view.editingSelections.count,2)
        view.undoManager?.redo(); XCTAssertEqual(view.string,"β alpha\nβ end\n")
    }
    func testMultipleBackwardDeletePreservesUnicodeAndUndo() {
        pane.textView.string = "😀x 😀x"; pane.document.buffer.update(pane.textView.string)
        let view = pane.textView; view.setSelections([NSRange(location:2,length:0),NSRange(location:6,length:0)])
        view.deleteBackward(nil); XCTAssertEqual(view.string,"x x")
        view.undoManager?.undo(); XCTAssertEqual(view.string,"😀x 😀x")
    }
    func testFinderFileURLPasteboardDecoding() {
        let board = NSPasteboard(name:NSPasteboard.Name("Linvell-Drop-Test-\(UUID().uuidString)"))
        let file = URL(fileURLWithPath:"/tmp/Linvell-中文-test.txt")
        board.writeObjects([file as NSURL]); XCTAssertEqual(FileDrop.urls(board),[file]); board.clearContents()
    }
    func testLineIndexTracksNativeStorageEdits() {
        let view = pane.textView
        view.setSelectedRange(NSRange(location:0,length:0)); view.insertText("中\n",replacementRange:view.selectedRange())
        XCTAssertEqual(pane.document.lines.starts,LineIndex(view.string).starts)
        XCTAssertEqual(pane.document.buffer.text,view.string)
    }
    func testNormalCaretFollowsNativeSelectionWithoutEscape() throws {
        let view = pane.textView
        view.vimEnabled = true
        view.setSelectedRange(NSRange(location:0,length:0))
        let before = try XCTUnwrap(view.normalCaretRect)
        view.needsDisplay = false
        view.setSelectedRange(NSRange(location:14,length:0))
        let after = try XCTUnwrap(view.normalCaretRect)
        XCTAssertEqual(pane.document.vim.cursor,14)
        XCTAssertEqual(pane.document.vim.mode,.normal)
        XCTAssertTrue(view.needsDisplay)
        XCTAssertGreaterThan(after.minY,before.minY)
        pane.document.vim.key("i")
        XCTAssertNil(view.normalCaretRect)
    }
    func testConsecutiveMultipleCaretInputAndNavigation() {
        let view = pane.textView; view.string = "ab ab"
        view.setSelections([NSRange(location:1,length:0),NSRange(location:4,length:0)])
        view.insertText("X",replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertEqual(view.string,"aXb aXb"); XCTAssertEqual(view.editingSelections.count,2)
        let left = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:String(UnicodeScalar(NSLeftArrowFunctionKey)!),charactersIgnoringModifiers:String(UnicodeScalar(NSLeftArrowFunctionKey)!),isARepeat:false,keyCode:123)!
        view.keyDown(with:left)
        view.insertText("Y",replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertEqual(view.string,"aYXb aYXb"); XCTAssertEqual(view.editingSelections.count,2)
    }
    func testLongLinesWrapAtResizedViewport() {
        let defaults = UserDefaults.standard,previous = defaults.object(forKey:"wordWrap")
        defaults.set(true,forKey:"wordWrap")
        defer { if let previous { defaults.set(previous,forKey:"wordWrap") } else { defaults.removeObject(forKey:"wordWrap") } }
        pane.textView.string = String(repeating:"long-line ",count:200)
        window.setContentSize(NSSize(width:420,height:600)); window.contentView?.layoutSubtreeIfNeeded(); pane.updatePreferences()
        let manager = pane.textView.layoutManager!,container = pane.textView.textContainer!
        manager.ensureLayout(for:container)
        var fragments = 0
        manager.enumerateLineFragments(forGlyphRange:NSRange(location:0,length:manager.numberOfGlyphs)) { rect,_,_,_,_ in
            fragments += 1; XCTAssertLessThanOrEqual(rect.width,container.containerSize.width+1)
        }
        XCTAssertGreaterThan(fragments,1)
    }
}
