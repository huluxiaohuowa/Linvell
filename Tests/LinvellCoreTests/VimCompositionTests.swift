import XCTest
@testable import LinvellCore

final class VimCompositionTests: XCTestCase {
    private func run(_ text: String,_ keys: String,cursor: Int = 0) -> VimEngine {
        let engine = VimEngine(); engine.sync(text:text,cursor:cursor)
        keys.forEach { engine.key(String($0)) }; return engine
    }
    func testOperatorAndMotionCountsMultiply() {
        XCTAssertEqual(run("a b c d e f g","2d3w").text,"g")
        XCTAssertEqual(run("a\nb\nc\nd\n","d2j").text,"d\n")
    }
    func testChangeWordDoesNotConsumeFollowingSpace() {
        let engine = run("first second","cw")
        XCTAssertEqual(engine.text," second"); XCTAssertEqual(engine.mode,.insert)
    }
    func testInnerAndAroundTextObjects() {
        XCTAssertEqual(run("hello, world","diw").text,", world")
        XCTAssertEqual(run("hello world","daw").text,"world")
        XCTAssertEqual(run("call(one, (two)) tail","di(",cursor:12).text,"call(one, ()) tail")
        XCTAssertEqual(run("say \"hello\" now","da\"",cursor:6).text,"say now")
        XCTAssertEqual(run("a [b] c","ci[",cursor:3).mode,.insert)
    }
    func testFindTillRepeatAndOperatorEndpoints() {
        XCTAssertEqual(run("abc, def, ghi","f,;").cursor,8)
        XCTAssertEqual(run("abc, def","dt,").text,", def")
        XCTAssertEqual(run("abc, def","df,").text," def")
        XCTAssertEqual(run("abcdef","dl").text,"bcdef")
        XCTAssertEqual(run("abcdef","d$").text,"")
    }
    func testWordAndWORDDistinguishPunctuation() {
        XCTAssertEqual(run("foo.bar baz","w").cursor,3)
        XCTAssertEqual(run("foo.bar baz","W").cursor,8)
        XCTAssertEqual(run("foo.bar baz","e").cursor,2)
        XCTAssertEqual(run("foo.bar baz","de").text,".bar baz")
    }
    func testNamedRegisterAndLinewisePutAtEndOfFile() {
        XCTAssertEqual(run("one\ntwo","\"ayyjp").text,"one\ntwo\none")
        XCTAssertEqual(run("one two","dw.").text,"")
    }
    func testReplaceJoinAndCaseAreUndoable() {
        XCTAssertEqual(run("ab","3rx").text,"ab")
        let replace = run("😀ab","2r中")
        XCTAssertEqual(replace.text,"中中b"); replace.key("u"); XCTAssertEqual(replace.text,"😀ab")
        XCTAssertEqual(run("one\n   two\n","J").text,"one two\n")
        XCTAssertEqual(run("Abc","2~").text,"aBc")
    }
    func testInsertSessionRepeatsAndUndoesAsOneChange() {
        let engine = run("one two three","cw")
        let base = engine.text
        engine.recordInsertion(before:base,cursor:1)
        engine.sync(text:"X two three",cursor:1); engine.escape()
        engine.key("w"); engine.key(".")
        XCTAssertEqual(engine.text,"X X three"); XCTAssertEqual(engine.mode,.normal)
        engine.key("u"); XCTAssertEqual(engine.text,"X two three")
        engine.key("u"); XCTAssertEqual(engine.text,"one two three")
    }
    func testRecordedMacroReplaysUnicodeInsertionAndRepeatsByRegister() {
        let engine = run("a\nb\nc\n","qaa")
        XCTAssertEqual(engine.recordingRegister,"a"); XCTAssertEqual(engine.mode,.insert)
        engine.recordNativeEdit(range:NSRange(location:1,length:0),replacement:"中",cursor:1)
        engine.sync(text:"a中\nb\nc\n",cursor:2); engine.key("Escape"); engine.key("j"); engine.key("q")
        XCTAssertNil(engine.recordingRegister)
        engine.key("@"); engine.key("a")
        XCTAssertEqual(engine.text,"a中\nb中\nc\n")
        engine.key("@"); engine.key("@")
        XCTAssertEqual(engine.text,"a中\nb中\nc中\n"); XCTAssertEqual(engine.mode,.normal)
    }
    func testFindBackwardsAndFailedMotionLeaveTextUntouched() {
        XCTAssertEqual(run("a,b,c","dF,",cursor:4).text,"a,bc")
        XCTAssertEqual(run("hello","dfz").text,"hello")
    }
}
