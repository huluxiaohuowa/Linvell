import XCTest
import AppKit
import LinvellCore
@testable import Linvell

final class SelectionTests: XCTestCase {
    func event(_ value: String,control: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:control ? .control : [],timestamp:0,windowNumber:0,context:nil,characters:value,charactersIgnoringModifiers:value,isARepeat:false,keyCode:0)!
    }
    func testVimBlockChangeAndUndoPreservesAllRows() {
        _ = NSApplication.shared
        let doc = OpenDocument(DocumentBuffer(text:"abcd\naXYZ\na123"))
        let pane = EditorPane(document:doc,vim:true),window = NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = pane; window.makeFirstResponder(pane.textView)
        defer { window.orderOut(nil); window.contentView = nil }
        let view = pane.textView
        view.setSelectedRange(NSRange(location:1,length:0))
        XCTAssertTrue(view.handleVisualKey(event("v",control:true)))
        XCTAssertEqual(doc.vim.mode,.visualBlock)
        _ = view.handleVisualKey(event("j")); _ = view.handleVisualKey(event("j")); _ = view.handleVisualKey(event("l"))
        XCTAssertEqual(view.editingSelections.count,3)
        _ = view.handleVisualKey(event("c")); XCTAssertEqual(doc.vim.mode,.insert)
        view.insertText("!",replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertEqual(view.string,"a!d\na!Z\na!3")
        view.undoManager?.undo(); XCTAssertEqual(view.string,"abcd\naXYZ\na123")
        view.undoManager?.redo(); XCTAssertEqual(view.string,"a!d\na!Z\na!3")
    }
    func testMultiVimChangeWordAndDistributedReplacement() {
        _ = NSApplication.shared
        let pane = EditorPane(document:OpenDocument(DocumentBuffer(text:"one two\none two")),vim:true)
        let text = pane.textView
        text.setSelections([NSRange(location:0,length:0),NSRange(location:8,length:0)])
        text.handleMultiVim(key:"c"); text.handleMultiVim(key:"w")
        XCTAssertEqual(text.document?.vim.mode,.insert)
        text.insertText("X ",replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertEqual(text.string,"X two\nX two")
        text.setSelections([NSRange(location:0,length:1),NSRange(location:6,length:1)])
        text.performMultiEdit(text.editingSelections,replacements:["first","second"])
        XCTAssertEqual(text.string,"first two\nsecond two")
    }
}
