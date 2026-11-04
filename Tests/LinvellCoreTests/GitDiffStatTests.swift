import XCTest
@testable import LinvellCore

final class GitDiffStatTests: XCTestCase {
    func testNumstatHandlesRenamesBinaryAndTabNames() {
        let stat = GitDiffStat(numstat:"2\t1\tsource.txt\0-\t-\timage.png\00\t0\t\0old path\0new path\03\t4\tfile\twithtab\0")
        XCTAssertEqual(stat.files,4); XCTAssertEqual(stat.insertions,5); XCTAssertEqual(stat.deletions,5); XCTAssertEqual(stat.binaryFiles,1)
    }
    func testRealIndexStatsExcludeUnstagedEdits() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/git-interaction-tests/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        let file = root.appendingPathComponent("file.txt")
        try "one\ntwo\n".write(to:file,atomically:true,encoding:.utf8)
        _ = try repo.run(["add","."])
        try "one\ntwo\nworking only\n".write(to:file,atomically:true,encoding:.utf8)
        let stat = try repo.stagedStat()
        XCTAssertEqual(stat.files,1); XCTAssertEqual(stat.insertions,2); XCTAssertEqual(stat.deletions,0)
    }
}
