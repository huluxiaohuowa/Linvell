import XCTest
@testable import LinvellCore

final class ReviewCommentTests: XCTestCase {
    func testEditorUTF16SelectionAndImmutableSnapshot() throws {
        let text = "第一行😀\nsecond\nthird\n",range = (text as NSString).range(of:"second\n")
        var comment = try ReviewComment.editor(path:"文件 name.swift",text:text,range:range)
        comment.note = "Check the second line"
        XCTAssertEqual(comment.lines.map(\.new),[2]); XCTAssertEqual(comment.lines.map(\.text),["second"])
        XCTAssertEqual(comment.location,"文件 name.swift · Editor snapshot · L2")
        XCTAssertTrue(ReviewComment.prompt([comment],directory:"/work").contains("[old:- new:2] second"))
        XCTAssertThrowsError(try ReviewComment.editor(path:"x",text:text,range:NSRange(location:NSNotFound,length:0)))
    }
    func testDiffAnchorsDeletedAddedContextAndUntrackedLines() throws {
        let patch = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -20,2 +30,3 @@\n keep\n-old\n+new\n+more\n"
        let range = (patch as NSString).range(of:"-old\n+new\n+more")
        let comment = try ReviewComment.diff(path:"new file",originalPath:"old file",text:patch,range:range,staged:true)
        XCTAssertEqual(comment.lines.map(\.old),[21,nil,nil]); XCTAssertEqual(comment.lines.map(\.new),[nil,31,32])
        XCTAssertEqual(comment.source,"HEAD → index snapshot"); XCTAssertEqual(comment.originalPath,"old file")
        XCTAssertThrowsError(try ReviewComment.diff(path:"a",text:patch,range:NSRange(location:0,length:1),staged:false))
        let untracked = "+++ new.txt\n+first\n+second\n+"
        XCTAssertEqual(try ReviewComment.diff(path:"new.txt",text:untracked,range:(untracked as NSString).range(of:"+second"),staged:false,untracked:true).lines.first?.new,2)
    }
    func testPersistenceIsScopedToWorktreeAndHostAndDraftStripsTerminalControls() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/review-fixtures/"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        var comment = try ReviewComment.editor(path:"a.swift",text:"code\u{1b}[201~\r",range:NSRange(location:0,length:0)); comment.note = "feedback\u{1b}[201~\u{0}\r\nnext"
        let store = ReviewCommentStore(project:"/repo",host:nil,directory:directory)
        try store.save([comment]); XCTAssertEqual(try store.load(),[comment])
        XCTAssertEqual(try ReviewCommentStore(project:"/other",host:nil,directory:directory).load(),[])
        XCTAssertEqual(try ReviewCommentStore(project:"/repo",host:"remote",directory:directory).load(),[])
        let prompt = ReviewComment.prompt([comment],directory:"/repo")
        XCTAssertFalse(prompt.contains("\u{1b}")); XCTAssertFalse(prompt.contains("\r")); XCTAssertFalse(prompt.contains("\u{0}"))
        try store.save([]); XCTAssertEqual(try store.load(),[])
    }
}
