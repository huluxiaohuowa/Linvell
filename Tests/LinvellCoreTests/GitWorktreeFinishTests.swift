import Foundation
import XCTest
@testable import LinvellCore

final class GitWorktreeFinishTests: XCTestCase {
    func testFinishKeepsDirtyWorktreeThenFastForwardsAndKeepsBranch() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = fixture.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:fixture) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        _ = try repo.run(["config","user.name","Fixture"])
        _ = try repo.run(["config","user.email","fixture@example.invalid"])
        _ = try repo.run(["config","commit.gpgsign","false"])
        _ = try repo.run(["commit","--allow-empty","-m","Initial"])
        let worktree = fixture.appendingPathComponent("linked worktree")
        _ = try repo.run(["worktree","add","-b","review/feature","--",worktree.path])
        let entry = try XCTUnwrap(repo.worktrees().first { $0.branch == "review/feature" })
        let file = worktree.appendingPathComponent("change.txt")
        try "worktree change\n".write(to:file,atomically:true,encoding:.utf8)
        let originalHead = try repo.run(["rev-parse","HEAD"])
        XCTAssertThrowsError(try repo.finishWorktree(entry,into:"main"))
        XCTAssertEqual(try repo.run(["rev-parse","HEAD"]),originalHead)
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        let child = GitRepository(root:worktree)
        try child.stage(try XCTUnwrap(child.changes().first))
        try child.commit("Worktree change")
        let expected = try child.run(["rev-parse","HEAD"])
        try repo.finishWorktree(entry,into:"main")
        XCTAssertEqual(try repo.run(["rev-parse","HEAD"]),expected)
        XCTAssertEqual(try repo.run(["rev-parse","refs/heads/review/feature"]),expected)
        XCTAssertEqual(try repo.worktrees().count,1)
    }
}
