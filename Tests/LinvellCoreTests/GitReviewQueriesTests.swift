import Foundation
import XCTest
@testable import LinvellCore

final class GitReviewQueriesTests: XCTestCase {
    func testFolderIndexActionsAndFileHistoryPreserveOtherChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("sub dir/nested"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        _ = try repo.run(["config","user.name","Fixture"])
        _ = try repo.run(["config","user.email","fixture@example.invalid"])
        _ = try repo.run(["config","commit.gpgsign","false"])
        let path = "sub dir/nested/a[1].txt"
        let file = root.appendingPathComponent(path)
        try "original\n".write(to:file,atomically:true,encoding:.utf8)
        try "outside\n".write(to:root.appendingPathComponent("other.txt"),atomically:true,encoding:.utf8)
        try repo.setFolderStaged("sub dir",staged:true)
        XCTAssertEqual(try repo.changes().filter(\.staged).map(\.path),[path])
        try repo.setFolderStaged("sub dir",staged:false)
        XCTAssertTrue(try repo.changes().filter(\.staged).isEmpty)
        try repo.setFolderStaged("sub dir",staged:true)
        try repo.commit("first")
        try "second\n".write(to:file,atomically:true,encoding:.utf8)
        _ = try repo.run(["add","--",path,"other.txt"])
        try repo.setFolderStaged("sub dir",staged:false)
        XCTAssertEqual(try repo.changes().filter(\.staged).map(\.path),["other.txt"])
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"second\n")
        try repo.setFolderStaged("sub dir",staged:true)
        try repo.commit("second")
        let history = try repo.fileHistory(path)
        XCTAssertEqual(history.map(\.subject),["second","first"])
        let hash = try XCTUnwrap(history.first?.hash)
        XCTAssertEqual(Set(try repo.changedPaths(in:hash)),Set([path,"other.txt"]))
        let diff = try repo.commitDiff(hash,path:path)
        XCTAssertTrue(diff.contains("+second"))
        XCTAssertFalse(diff.contains("other.txt"))
        XCTAssertEqual(GitCommandJournal.shared.entries(for:repo.journalScope).first?.command,"show")
    }
}
