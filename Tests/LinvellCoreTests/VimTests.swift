import XCTest
@testable import LinvellCore

final class VimTests: XCTestCase {
    func engine(_ text: String,_ keys: [String]) -> VimEngine { let v = VimEngine(); v.sync(text:text,cursor:0); keys.forEach(v.key); return v }
    func testDeleteUndoRedo() { let v = engine("one\ntwo\nthree\n",["d","d"]); XCTAssertEqual(v.text,"two\nthree\n"); v.key("u"); XCTAssertEqual(v.text,"one\ntwo\nthree\n"); v.key("Ctrl+r"); XCTAssertEqual(v.text,"two\nthree\n") }
    func testCountAndPendingCancel() { let v = engine("a\nb\nc\n",["2","d","d"]); XCTAssertEqual(v.text,"c\n"); v.key("d"); v.key("Escape"); v.key("j"); XCTAssertEqual(v.text,"c\n") }
    func testYankPut() { let v = engine("a\nb\n",["y","y","p"]); XCTAssertEqual(v.text,"a\na\nb\n") }
    func testGraphemeDeletion() { let v = engine("👩🏽‍💻中e\u{301}",["x"]); XCTAssertEqual(v.text,"中e\u{301}"); v.key("l"); v.key("x"); XCTAssertEqual(v.text,"中") }
    func testInsertEscape() { let v = engine("abc",["A"]); XCTAssertEqual(v.mode,.insert); XCTAssertEqual(v.cursor,3); v.escape(); XCTAssertEqual(v.mode,.normal); XCTAssertEqual(v.cursor,2) }
    func testUnknownPendingDoesNotEdit() { let v = engine("abc",["d","z"]); XCTAssertEqual(v.text,"abc"); XCTAssertEqual(v.pending,"") }
    func testWordMotionAndDelete() { let v = engine("one two three",["d","w"]); XCTAssertEqual(v.text,"two three"); XCTAssertEqual(v.register,"one ") }
}
