import XCTest
@testable import LinvellCore

final class VimSearchTests: XCTestCase {
    func testSearchWrapsAndNRetainsOriginalDirection() throws {
        let engine = VimEngine(); engine.sync(text:"one two one two one",cursor:0)
        XCTAssertTrue(try engine.search("one")); XCTAssertEqual(engine.cursor,8)
        engine.key("n"); XCTAssertEqual(engine.cursor,16)
        engine.key("N"); XCTAssertEqual(engine.cursor,8)
        engine.key("n"); XCTAssertEqual(engine.cursor,16)
        engine.key("n"); XCTAssertEqual(engine.cursor,0)
    }
    func testWordSearchUsesWholeWordsAndEscapesPunctuation() throws {
        let engine = VimEngine(); engine.sync(text:"word words word",cursor:0)
        engine.key("*"); XCTAssertEqual(engine.cursor,11)
        engine.key("#"); XCTAssertEqual(engine.cursor,0)
        engine.sync(text:"a.b a.b",cursor:0)
        XCTAssertTrue(try engine.search(#"\Va.b"#)); XCTAssertEqual(engine.cursor,4)
    }
    func testSearchMotionComposesWithDeleteAndUndo() throws {
        let engine = VimEngine(); engine.sync(text:"one two three",cursor:0)
        engine.key("d"); XCTAssertTrue(try engine.search("three"))
        XCTAssertEqual(engine.text,"three"); engine.key("u"); XCTAssertEqual(engine.text,"one two three")
    }
    func testSubstituteDefaultsToFirstMatchPerLineAndSupportsGlobalCaptures() throws {
        let engine = VimEngine(); engine.sync(text:"foo foo\nfoo foo\n",cursor:0)
        try engine.executeEx(":%s/foo/bar/"); XCTAssertEqual(engine.text,"bar foo\nbar foo\n")
        engine.key("u"); XCTAssertEqual(engine.text,"foo foo\nfoo foo\n")
        try engine.executeEx(#":%s/\(foo\)/[\1]/g"#)
        XCTAssertEqual(engine.text,"[foo] [foo]\n[foo] [foo]\n")
    }
    func testSubstituteRangesMagicCaseAndEscapedDelimiter() throws {
        let engine = VimEngine(); engine.sync(text:"FOO foo\nfoo foo\nfoo\n",cursor:0)
        try engine.executeEx(":2,3s/foo/X/g"); XCTAssertEqual(engine.text,"FOO foo\nX X\nX\n")
        try engine.executeEx(":1s/foo/bar/i"); XCTAssertEqual(engine.text,"bar foo\nX X\nX\n")
        engine.sync(text:"a/b a/b\n",cursor:0)
        try engine.executeEx(#":s/a\/b/\&/g"#); XCTAssertEqual(engine.text,"& &\n")
    }
    func testUnsupportedRegexAndConfirmationFailWithoutMutatingText() throws {
        let engine = VimEngine(); engine.sync(text:"foo\n",cursor:0)
        XCTAssertThrowsError(try engine.executeEx(":s/foo/bar/c"))
        XCTAssertThrowsError(try engine.search(#"foo\zs"#))
        XCTAssertEqual(engine.text,"foo\n")
        XCTAssertFalse(try engine.search("missing"))
    }
    func testExDeleteYankAndJumpAddressTheRequestedLines() throws {
        let engine = VimEngine(); engine.sync(text:"a\nb\nc\n",cursor:0)
        try engine.executeEx(":2,3y"); XCTAssertEqual(engine.register,"b\nc\n")
        try engine.executeEx(":2d"); XCTAssertEqual(engine.text,"a\nc\n")
        try engine.executeEx(":2"); XCTAssertEqual(engine.cursor,2)
    }
}
