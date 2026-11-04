import Foundation
import XCTest
@testable import LinvellCore

final class GitHistorySearchTests: XCTestCase {
    func testSearchFindsUnloadedCommitOnAnotherBranchByBodyAndEmail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        _ = try repo.run(["config","user.name","Fixture"])
        _ = try repo.run(["config","user.email","ancient@example.invalid"])
        _ = try repo.run(["-c","commit.gpgsign=false","commit","--allow-empty","-m","Old subject","-m","旧功能索引"])
        let old = try XCTUnwrap(repo.history().first?.hash)
        _ = try repo.run(["switch","-c","archive"])
        _ = try repo.run(["config","user.email","recent@example.invalid"])
        // Build enough real commits to cross both the displayed limit and the first scan batch.
        let script = """
        set -eu
        head=$(git rev-parse HEAD)
        tree=$(git rev-parse HEAD^{tree})
        i=0
        while [ "$i" -lt 260 ]; do
            head=$(git -c commit.gpgsign=false commit-tree "$tree" -p "$head" -m "New entry $i")
            i=$((i+1))
        done
        git update-ref refs/heads/archive "$head"
        """
        let result = try ToolCommand.run(URL(fileURLWithPath:"/bin/sh"),arguments:["-c",script],directory:root,timeout:45)
        XCTAssertTrue(result.succeeded)
        _ = try repo.run(["switch","--orphan","other"])
        _ = try repo.run(["-c","commit.gpgsign=false","commit","--allow-empty","-m","Unrelated head"])
        XCTAssertFalse(try repo.history().contains { $0.hash == old })
        XCTAssertFalse(try repo.history(allRefs:false).contains { $0.hash == old })
        XCTAssertEqual(try repo.searchHistory("旧功能索引").commits.map(\.hash),[old])
        XCTAssertEqual(try repo.searchHistory("ANCIENT@example.invalid").commits.map(\.hash),[old])
        let first = try repo.searchHistory("New entry",limit:10)
        let next = try repo.searchHistory("New entry",offset:try XCTUnwrap(first.nextOffset),limit:10)
        XCTAssertEqual(first.commits.count,10)
        XCTAssertEqual(next.commits.count,10)
        XCTAssertTrue(Set(first.commits.map(\.hash)).isDisjoint(with:next.commits.map(\.hash)))
        XCTAssertThrowsError(try repo.searchHistory("unused",isCancelled:{ true }))
    }
    func testIndexReusesBatchesAcrossQueriesOnSSHTransport() throws {
        let remote = try SSHRemote(host:"git-fixture.invalid")
        var calls = 0
        let repo = GitRepository(directory:"/fixture/repo",remote:remote) { directory,args,input,_ in
            XCTAssertEqual(directory,"/fixture/repo")
            XCTAssertEqual(args.first,"log")
            XCTAssertTrue(args.contains("--all"))
            XCTAssertNil(input)
            calls += 1
            let hash = String(repeating:"a",count:40)
            return [hash,"","Fixture","fixture@example.invalid","2026-11-04","Subject","","Searchable body",""].joined(separator:"\0")
        }
        let index = GitHistoryIndex()
        XCTAssertEqual(try repo.searchHistory("searchable",index:index).commits.count,1)
        XCTAssertEqual(try repo.searchHistory("fixture@example",index:index).commits.count,1)
        XCTAssertEqual(calls,1)
    }
}
