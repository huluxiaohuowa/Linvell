import XCTest
@testable import LinvellCore

final class GitHunkTests: XCTestCase {
    func testStageAndUnstageOneHunkWithoutChangingWorkingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"]); _ = try repo.run(["config","user.name","Test"]); _ = try repo.run(["config","user.email","test@example.invalid"]); _ = try repo.run(["config","commit.gpgsign","false"])
        let file = root.appendingPathComponent("sample.txt")
        let original = (1...50).map { "line \($0)" }.joined(separator:"\n")+"\n"
        try original.write(to:file,atomically:true,encoding:.utf8)
        try repo.stage(try XCTUnwrap(repo.changes().first)); try repo.commit("Base")
        let updated = original.replacingOccurrences(of:"line 2\n",with:"first edit\n").replacingOccurrences(of:"line 48\n",with:"second edit\n")
        try updated.write(to:file,atomically:true,encoding:.utf8)
        let change = try XCTUnwrap(repo.changes().first),hunks = GitHunk.parse(try repo.diff(change,staged:false))
        XCTAssertEqual(hunks.count,2)
        try repo.applyHunk(hunks[0],unstage:false)
        let indexed = try repo.run(["show",":sample.txt"])
        XCTAssertTrue(indexed.contains("first edit")); XCTAssertFalse(indexed.contains("second edit"))
        let staged = GitHunk.parse(try repo.diff(try XCTUnwrap(repo.changes().first),staged:true))
        try repo.applyHunk(try XCTUnwrap(staged.first),unstage:true)
        XCTAssertEqual(try repo.run(["show",":sample.txt"]),original)
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),updated)
        let child = root.appendingPathComponent("child"); try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true)
        XCTAssertEqual(try GitRepository(root:child).resolvedWorkingTree().root.resolvingSymlinksInPath(),root.resolvingSymlinksInPath())
    }
}
