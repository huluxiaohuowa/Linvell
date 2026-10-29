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
    private func vimKey(_ key: String) {
        let escape = key == "Escape"
        let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:escape ? "\u{1b}" : key,charactersIgnoringModifiers:escape ? "\u{1b}" : key,isARepeat:false,keyCode:escape ? 53 : 0)!
        pane.textView.keyDown(with:event)
    }
    func testComposedVimChangeInsertionDotAndUndoReachNativeStorage() {
        let view = pane.textView; view.vimEnabled = true
        view.string = "one two three"; pane.document.buffer.update(view.string); view.setSelectedRange(NSRange(location:0,length:0))
        ["c","w"].forEach(vimKey)
        XCTAssertEqual(view.string," two three")
        view.insertText("中",replacementRange:view.selectedRange()); vimKey("Escape")
        vimKey("w"); vimKey(".")
        XCTAssertEqual(view.string,"中 中 three"); XCTAssertEqual(pane.document.buffer.text,view.string)
        vimKey("u"); XCTAssertEqual(view.string,"中 two three")
        vimKey("u"); XCTAssertEqual(view.string,"one two three")
    }
    func testVimMacroRecordsNativeTextInputAndReplaysWithoutExternalEngine() {
        let view = pane.textView; view.vimEnabled = true
        view.string = "a\nb\nc\n"; pane.document.buffer.update(view.string); view.setSelectedRange(NSRange(location:0,length:0))
        ["q","a","a"].forEach(vimKey)
        view.insertText("中",replacementRange:view.selectedRange()); vimKey("Escape")
        ["j","q","@","a"].forEach(vimKey)
        XCTAssertEqual(view.string,"a中\nb中\nc\n"); XCTAssertEqual(pane.document.buffer.text,view.string)
        XCTAssertNil(pane.document.vim.recordingRegister)
    }
    func testReplaceModeRestoresOverwrittenGraphemesWithBackspaceAndUndo() {
        let view = pane.textView; view.vimEnabled = true
        view.string = "😀abc"; pane.document.buffer.update(view.string); view.setSelectedRange(NSRange(location:0,length:0))
        vimKey("R"); XCTAssertEqual(pane.document.vim.mode,.replace)
        view.insertText("中",replacementRange:NSRange(location:NSNotFound,length:0))
        view.insertText("Z",replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertEqual(view.string,"中Zbc")
        view.deleteBackward(nil); XCTAssertEqual(view.string,"中abc"); XCTAssertEqual(view.selectedRange().location,1)
        vimKey("Escape"); vimKey("u"); XCTAssertEqual(view.string,"😀abc")
    }
    func testLineCommandsKeepMultipleCaretsAndUndoTheWholeOperation() {
        let view = pane.textView
        view.string = "a\nb\nc\nd"; pane.document.buffer.update(view.string)
        view.setSelections([NSRange(location:2,length:0),NSRange(location:6,length:0)])
        view.moveLinesUp(nil); XCTAssertEqual(view.string,"b\na\nd\nc"); XCTAssertEqual(view.editingSelections.count,2)
        view.undoManager?.undo(); XCTAssertEqual(view.string,"a\nb\nc\nd")
        view.toggleLineComment(nil); XCTAssertEqual(view.string,"a\n// b\nc\n// d")
        view.undoManager?.undo(); XCTAssertEqual(view.string,"a\nb\nc\nd")
        view.insertLineAbove(nil); XCTAssertEqual(view.editingSelections.count,2)
        view.undoManager?.undo(); XCTAssertEqual(view.string,"a\nb\nc\nd")
    }
    func testVisualTextObjectsCountsAndFindKeepNativeSelections() {
        let view = pane.textView; view.vimEnabled = true
        view.string = "call(one)\nsecond\nthird\n"; pane.document.buffer.update(view.string); view.setSelectedRange(NSRange(location:5,length:0))
        ["v","i","("].forEach(vimKey)
        XCTAssertEqual((view.string as NSString).substring(with:view.selectedRange()),"one")
        vimKey("v"); XCTAssertEqual(pane.document.vim.mode,.normal)
        view.setSelectedRange(NSRange(location:0,length:0))
        ["v","2","j"].forEach(vimKey)
        XCTAssertTrue((view.string as NSString).substring(with:view.selectedRange()).contains("\nsecond\nt"))
        vimKey("Escape"); view.setSelectedRange(NSRange(location:0,length:0))
        ["v","f","("].forEach(vimKey)
        XCTAssertEqual((view.string as NSString).substring(with:view.selectedRange()),"call(")
    }
    func testVimTextObjectsAndCountedDeletesApplyToEveryCaret() {
        let view = pane.textView; view.vimEnabled = true
        view.string = "call(one) call(two)"; pane.document.buffer.update(view.string)
        view.setSelections([NSRange(location:5,length:0),NSRange(location:15,length:0)])
        ["c","i","("].forEach(vimKey)
        XCTAssertEqual(view.string,"call() call()")
        view.insertText("中",replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertEqual(view.string,"call(中) call(中)"); vimKey("Escape")
        pane.document.vim.escape(); view.string = "a b c\nd e f\n"; pane.document.buffer.update(view.string)
        view.setSelections([NSRange(location:0,length:0),NSRange(location:6,length:0)])
        ["2","d","w"].forEach(vimKey)
        XCTAssertEqual(view.string,"c\nf\n")
    }
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
    func testWelcomeActionsKeepFullWidthInWideAndCompactLayouts() {
        let controller = WorkspaceController()
        let welcome = WelcomeView(owner:controller)
        defer { controller.window?.orderOut(nil) }
        window.contentView = welcome
        func buttons(_ view: NSView) -> [NSButton] {
            view.subviews.flatMap { child -> [NSButton] in
                if let button = child as? NSButton { return [button] }
                return buttons(child)
            }
        }
        for width: CGFloat in [480,1000] {
            window.setContentSize(NSSize(width:width,height:650)); window.contentView?.layoutSubtreeIfNeeded()
            let actions = buttons(welcome).filter { [#selector(WorkspaceController.openFolder),#selector(WorkspaceController.newFile),#selector(WorkspaceController.openFile)].contains($0.action) }
            XCTAssertEqual(actions.count,3)
            actions.forEach { XCTAssertGreaterThanOrEqual($0.bounds.width,320) }
        }
    }
    func testRemovingSplitPaneExpandsRemainingViewWithoutAResize() {
        let split = ResizablePanes(frame:NSRect(x:0,y:0,width:1000,height:600)),left = NSView(),right = NSView()
        split.addArrangedSubview(left); split.addArrangedSubview(right); split.setPosition(400,ofDividerAt:0)
        XCTAssertEqual(left.frame.width,400,accuracy:1)
        right.removeFromSuperview(); split.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.arrangedSubviews.count,1)
        XCTAssertEqual(left.frame,split.bounds)
    }
    func testLanguageRefreshPreservesIconOnlyControlsAndSearchValue() {
        let root = NSView(),icon = Theme.button("folder",help:"Open Folder…",target:self,action:#selector(NSResponder.cancelOperation(_:))),search = NSSearchField()
        search.stringValue = "my unmodified query"; search.placeholderString = "Filter files"
        root.addSubview(icon); root.addSubview(search)
        L.apply(to:root); L.apply(to:root)
        XCTAssertEqual(icon.title,""); XCTAssertEqual(icon.imagePosition,.imageOnly)
        XCTAssertEqual(search.stringValue,"my unmodified query")
    }
}
