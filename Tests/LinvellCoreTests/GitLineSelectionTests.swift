import XCTest
@testable import LinvellCore

final class GitLineSelectionTests: XCTestCase {
    func testSelectedLinesStageAndReverseWithoutIncludingAdjacentEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        _ = try repo.run(["config","user.name","Test"]); _ = try repo.run(["config","user.email","test@example.invalid"])
        _ = try repo.run(["config","commit.gpgsign","false"])
        let file = root.appendingPathComponent("a.txt")
        let original = "one\ntwo\nthree\nfour\nfive\n"
        try original.write(to:file,atomically:true,encoding:.utf8)
        _ = try repo.run(["add","."]); try repo.commit("base")
        let edited = "one\n二 changed\nthree\n四 changed\nfive\n"
        try edited.write(to:file,atomically:true,encoding:.utf8)
        var patch = try repo.diff(XCTUnwrap(repo.changes().first),staged:false)
        let range = (patch as NSString).range(of:"-two\n+二 changed")
        try repo.applyHunk(GitHunk.selection(in:patch,range:range,unstage:false),unstage:false)
        XCTAssertEqual(try repo.run(["show",":a.txt"]),"one\n二 changed\nthree\nfour\nfive\n")
        _ = try repo.run(["add","."])
        patch = try repo.diff(XCTUnwrap(repo.changes().first),staged:true)
        try repo.applyHunk(GitHunk.selection(in:patch,range:(patch as NSString).range(of:"-two\n+二 changed"),unstage:true),unstage:false)
        XCTAssertEqual(try repo.run(["show",":a.txt"]),"one\ntwo\nthree\n四 changed\nfive\n")
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),edited)
        // The saved patch must fail after the index changes instead of applying another edit.
        let stale = try GitHunk.selection(in:patch,range:(patch as NSString).range(of:"-two\n+二 changed"),unstage:true)
        XCTAssertThrowsError(try repo.applyHunk(stale,unstage:false))
    }

    func testInsertionAndDeletionInSeparateHunks() throws {
        let patch = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,2 +1,3 @@\n a\n+insert\n b\n@@ -20,3 +21,2 @@\n x\n-deleted\n z\n"
        let range = (patch as NSString).range(of:"-deleted")
        let selected = try GitHunk.selection(in:patch,range:range,unstage:false)
        XCTAssertTrue(selected.patch.contains("@@ -20,3 +20,2 @@"))
        XCTAssertFalse(selected.patch.contains("insert"))
        let reversed = try GitHunk.selection(in:patch,range:range,unstage:true)
        XCTAssertTrue(reversed.patch.contains("@@ -21,2 +21,3 @@"))
        XCTAssertTrue(reversed.patch.contains("+deleted"))
    }

    func testPreparedHeadLockRejectsConcurrentReferenceUpdateAndReleases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        _ = try repo.run(["config","user.name","Test"]); _ = try repo.run(["config","user.email","test@example.invalid"])
        _ = try repo.run(["-c","commit.gpgsign=false","commit","--allow-empty","-m","base"])
        let head = try repo.resolvedRevision("HEAD")
        try repo.withLockedHead(head) {
            XCTAssertThrowsError(try repo.run(["update-ref","HEAD",head]))
            XCTAssertThrowsError(try repo.run(["update-ref","refs/heads/main",head]))
        }
        XCTAssertNoThrow(try repo.run(["update-ref","HEAD",head]))
        XCTAssertThrowsError(try repo.withLockedHead(String(repeating:"0",count:40)) { XCTFail("Stale head acquired") })
        XCTAssertNoThrow(try repo.run(["update-ref","HEAD",head]))
    }
}

extension GitLineSelectionTests {
    func testNewFilePartialStageAndUnstagePreserveMissingFinalNewline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        let file = root.appendingPathComponent("new 中文.txt")
        try "first\nsecond".write(to:file,atomically:true,encoding:.utf8)
        let change = try XCTUnwrap(repo.changes().first)
        var patch = try repo.diff(change,staged:false)
        try repo.applyHunk(GitHunk.selection(in:patch,range:(patch as NSString).range(of:"+first"),unstage:false),unstage:false)
        XCTAssertEqual(try repo.run(["show",":new 中文.txt"]),"first\n")
        _ = try repo.run(["add","."])
        patch = try repo.diff(XCTUnwrap(repo.changes().first),staged:true)
        try repo.applyHunk(GitHunk.selection(in:patch,range:(patch as NSString).range(of:"+second"),unstage:true),unstage:false)
        XCTAssertEqual(try repo.run(["show",":new 中文.txt"]),"first\n")
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"first\nsecond")
    }
}
