import XCTest
@testable import LinvellCore

/// The system executable is an oracle for development only, never an app dependency.
final class VimDifferentialTests: XCTestCase {
    func testSwiftCommandsMatchVimOnDisposableFixtures() throws {
        guard FileManager.default.isExecutableFile(atPath:"/usr/bin/vim") else { throw XCTSkip("System Vim is not available for differential tests") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Linvell-Vim-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let cases: [(String,String,Int)] = [
            ("one two three\n","dw",0),("one\ntwo\n","dw",0),("one two\nthree\n","dw",4),
            ("a\nb\nc\nd\n","d2j",0),("a\nb\nc\n","dk",2),("a\nb\nc\n","dG",2),("a\nb\nc\n","dgg",4),
            ("one two\nthree\n","d2w",0),("a one\ntwo\nthree\n","d2w",2),("one\ntwo\nthree\n","d2w",0),("one   \ntwo\n","dw",0),("one two three\n","2dw",0),("one two three\n","d2w",0),
            ("hello, world\n","diw",0),("hello world\n","daw",0),
            ("call(one, (two)) tail\n","di(",12),("call(one, (two)) tail\n","2di(",12),
            ("say \"hello\" now\n","da\"",6),("say \"hello\" now\n","di\"",6),
            ("a,b,c\n","dF,",4),("abc, def\n","dt,",0),("abc, def\n","df,",0),
            ("hello world\n","d$",0),("hello world\n","db",6),("hello world\n","de",0),
            ("abcdef\n","dl",0),("abcdef\n","dh",3),("abcdef\n","3rx",0),("ab\n","3rx",0),
            ("one\n   two\n","J",0),("Abc\n","2~",0),("one\ntwo\n","yyp",0),
            ("a\nb\nc\n","ddp",0),("one two three\n","dw.",0),
            ("(one) two\n","d%",0),("one\ntwo\n","dd",4)
        ]
        for (index,item) in cases.enumerated() {
            let (source,keys,cursor) = item
            let engine = VimEngine(); engine.sync(text:source,cursor:cursor); keys.forEach { engine.key(String($0)) }
            let prefix = (source as NSString).substring(to:cursor),rows = prefix.components(separatedBy:"\n")
            let file = root.appendingPathComponent("fixture.txt"),script = root.appendingPathComponent("commands.vim")
            try source.write(to:file,atomically:true,encoding:.utf8)
            try "set nomodeline\ncall cursor(\(rows.count),\((rows.last ?? "").utf8.count+1))\nnormal! \(keys)\nwrite!\nqa!\n".write(to:script,atomically:true,encoding:.utf8)
            let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/vim")
            process.arguments = ["-Nu","NONE","-n","-i","NONE","-es","-S",script.path,file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus,0,"Oracle fixture \(index)")
            XCTAssertEqual(engine.text,try String(contentsOf:file,encoding:.utf8),"Command \(keys), fixture \(index)")
        }
    }
}
