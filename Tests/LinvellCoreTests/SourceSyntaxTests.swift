import XCTest
@testable import LinvellCore

final class SourceSyntaxTests: XCTestCase {
    func testBracesInCommentsAndStringsDoNotMatchOrFold() {
        for path in ["probe.swift","probe.cpp","probe.ts","probe.rs","probe.go","probe.java","probe.cs"] {
            let source = "class Probe {\n  // } ignored\n  func call() {\n    let value = \"[ } { ]\"\n    /* { \n       } */\n    return 42\n  }\n}\n"
            let syntax = SourceSyntax.analyze(source,path:path)
            XCTAssertEqual(syntax.pairs[(source as NSString).range(of:"{").location],(source as NSString).range(of:"}",options:.backwards).location,path)
            XCTAssertFalse(syntax.tokens.filter { $0.kind == .comment }.isEmpty,path)
            XCTAssertFalse(syntax.tokens.filter { $0.kind == .number }.isEmpty,path)
            XCTAssertTrue(syntax.folds.contains { $0.line == 0 && $0.endLine == 8 },path)
            let quoted = (source as NSString).range(of:"[ } { ]").location
            XCTAssertFalse(syntax.isCode(quoted)); XCTAssertNil(syntax.pairs[quoted])
        }
    }
    func testPythonIndentationAndMultilineString() {
        let source = "class Probe:\n    def call(self):\n        doc = \"\"\"{\n        }\"\"\"\n        return 1\n\ndef other():\n    pass\n"
        let syntax = SourceSyntax.analyze(source,path:"probe.py")
        XCTAssertNotNil(syntax.fold(atLine:0)); XCTAssertNotNil(syntax.fold(atLine:1))
        XCTAssertNil(syntax.pairs[(source as NSString).range(of:"{").location])
        XCTAssertEqual(syntax.tokens.filter { $0.kind == .string }.count,1)
    }
    func testMarkupAndLuaBlocks() {
        let html = SourceSyntax.analyze("<main>\n<section>\n<p>text</p>\n</section>\n</main>\n",path:"probe.html")
        XCTAssertEqual(html.fold(atLine:0)?.endLine,4); XCTAssertEqual(html.fold(atLine:1)?.endLine,3)
        let lua = SourceSyntax.analyze("function sample()\n--[[ } {\n ignored ]]\nreturn 1\nend\n",path:"probe.lua")
        XCTAssertEqual(lua.fold(atLine:0)?.endLine,4)
        XCTAssertEqual(lua.tokens.filter { $0.kind == .comment }.count,1)
    }
    func testIndentationPreservesStyleAndSeparatesMatchingClosers() {
        XCTAssertEqual(SourceSyntax.newline(in:"if ready:",at:9,path:"a.py",unit:"    ").0,"\n    ")
        XCTAssertEqual(SourceSyntax.newline(in:"\tfunc x() {}",at:11,path:"a.swift",unit:"\t").0,"\n\t\t\n\t")
        XCTAssertEqual(SourceSyntax.newline(in:"    // {",at:8,path:"a.swift",unit:"    ").0,"\n    ")
        XCTAssertEqual(SourceSyntax.newline(in:"value = \"{\"",at:11,path:"a.py",unit:"    ").0,"\n")
    }
    func testCancellationDoesNotPublishPartialStructure() {
        let source = String(repeating:"func x() { return 1 }\n",count:2000)
        XCTAssertTrue(SourceSyntax.analyze(source,path:"a.swift",cancelled:{ true }).tokens.isEmpty)
    }
}
