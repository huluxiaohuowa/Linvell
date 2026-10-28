import XCTest
@testable import LinvellCore

final class LineEditingTests: XCTestCase {
    func testMovingSelectedBlockPreservesItsSelectionAndUnicodeColumn() {
        let result = LineEditing.apply(.moveUp,text:"a\n中😀\nc\nd",selections:[NSRange(location:2,length:6)])
        XCTAssertEqual(result.text,"中😀\nc\na\nd")
        XCTAssertEqual(result.selections,[NSRange(location:0,length:6)])
        let caret = LineEditing.apply(.moveDown,text:"😀a\nb\nc",selections:[NSRange(location:2,length:0)])
        XCTAssertEqual(caret.text,"b\n😀a\nc"); XCTAssertEqual(caret.selections,[NSRange(location:4,length:0)])
    }
    func testNonAdjacentCaretsMoveAndCopyWithoutDuplicatingBlocks() {
        let up = LineEditing.apply(.moveUp,text:"a\nb\nc\nd\ne",selections:[NSRange(location:2,length:0),NSRange(location:6,length:0)])
        XCTAssertEqual(up.text,"b\na\nd\nc\ne")
        let copy = LineEditing.apply(.copyDown,text:"a\nb",selections:[NSRange(location:0,length:0)])
        XCTAssertEqual(copy.text,"a\na\nb"); XCTAssertEqual(copy.selections,[NSRange(location:2,length:0)])
    }
    func testDeleteLastAndOnlyLineKeepsAValidCaret() {
        let last = LineEditing.apply(.delete,text:"a\nb",selections:[NSRange(location:2,length:0)])
        XCTAssertEqual(last.text,"a"); XCTAssertEqual(last.selections,[NSRange(location:0,length:0)])
        let only = LineEditing.apply(.delete,text:"abc",selections:[NSRange(location:1,length:0)])
        XCTAssertEqual(only.text,""); XCTAssertEqual(only.selections,[NSRange(location:0,length:0)])
    }
    func testIndentAndCommentRoundTripMultipleRows() {
        let original = "  first\n\tsecond\nthird"
        let ranges = [NSRange(location:0,length:original.utf16.count)]
        let comment = LineEditing.apply(.comment("//"),text:original,selections:ranges)
        XCTAssertEqual(comment.text,"  // first\n\t// second\n// third")
        let uncomment = LineEditing.apply(.comment("//"),text:comment.text,selections:comment.selections)
        XCTAssertEqual(uncomment.text,original)
        let indent = LineEditing.apply(.indent,text:original,selections:ranges,indent:"  ")
        XCTAssertEqual(LineEditing.apply(.outdent,text:indent.text,selections:indent.selections,indent:"  ").text,original)
    }
}
