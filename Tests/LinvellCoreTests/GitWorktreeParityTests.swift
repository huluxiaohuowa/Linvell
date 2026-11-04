import Foundation
import XCTest
@testable import LinvellCore

final class GitWorktreeParityTests: XCTestCase {
    func fixture() throws -> (URL,GitRepository,GitRepository,GitWorktreeEntry) {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/final-audit/workspace-fixtures").appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("main"),linked = base.appendingPathComponent("feature")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"]); _ = try repo.run(["config","user.name","Fixture"]); _ = try repo.run(["config","user.email","fixture@example.invalid"]); _ = try repo.run(["config","commit.gpgsign","false"])
        for n in 0..<4 { _ = try repo.run(["commit","--allow-empty","-m","Commit \(n)"]) }
        _ = try repo.run(["worktree","add","-b","feature","--",linked.path])
        return (base,repo,GitRepository(root:linked),try XCTUnwrap(repo.worktrees().first { $0.branch == "feature" }))
    }
    func testBisectWithoutPseudoRefIsNotEligibleForCleanup() throws {
        let (base,repo,source,entry) = try fixture(); defer { try? FileManager.default.removeItem(at:base) }
        XCTAssertTrue(try repo.worktreeDetail(entry,against:"").contains("No commits since this worktree was created"))
        _ = try source.run(["bisect","start","HEAD","HEAD~3"])
        XCTAssertThrowsError(try source.run(["rev-parse","--verify","BISECT_HEAD"]))
        XCTAssertEqual(try repo.worktreeState(entry),"In Progress")
        XCTAssertFalse(try repo.cleanupCandidates(into:"main").contains { $0.entry.path == entry.path })
        XCTAssertThrowsError(try repo.prepareWorktreeFinish(entry,into:"main"))
        _ = try source.run(["bisect","reset"])
        let sequence = try source.run(["rev-parse","--path-format=absolute","--git-path","sequencer"]).trimmingCharacters(in:.newlines)
        try FileManager.default.createDirectory(atPath:sequence,withIntermediateDirectories:true)
        try "revert deadbeef example\n".write(toFile:(sequence as NSString).appendingPathComponent("todo"),atomically:true,encoding:.utf8)
        XCTAssertEqual(try source.pendingWorktreeOperation(),"Revert in Progress")
        XCTAssertFalse(try repo.cleanupCandidates(into:"main").contains { $0.entry.path == entry.path })
    }
    func testCurrentLinkedSourceCanMergeThenCleanupSeparatelyAndRetry() throws {
        let (base,repo,source,entry) = try fixture(); defer { try? FileManager.default.removeItem(at:base) }
        _ = try source.run(["commit","--allow-empty","-m","Work"])
        _ = try repo.run(["config","branch.main.mergeOptions","--squash"])
        let plan = try source.prepareWorktreeFinish(entry,into:"main")
        XCTAssertEqual(plan.commitCount,1)
        XCTAssertNil(try source.mergeWorktree(plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath:source.directory))
        XCTAssertTrue(try repo.changes().isEmpty)
        try plan.merge.requireIntegrated()
        // Merge-only keeps the source; later cleanup removes it and can retry branch deletion.
        try source.cleanupWorktreeFinish(plan,removeFolder:false,deleteBranch:false)
        try source.cleanupWorktreeFinish(plan,removeFolder:true,deleteBranch:false)
        XCTAssertFalse(FileManager.default.fileExists(atPath:source.directory))
        try repo.cleanupWorktreeFinish(plan,removeFolder:true,deleteBranch:true)
        XCTAssertThrowsError(try repo.run(["rev-parse","--verify","refs/heads/feature"]))
    }
    func testSourceOrTargetChangedSinceReviewIsRejected() throws {
        let (base,repo,source,entry) = try fixture(); defer { try? FileManager.default.removeItem(at:base) }
        let plan = try repo.prepareWorktreeFinish(entry,into:"main")
        _ = try source.run(["commit","--allow-empty","-m","Changed"])
        XCTAssertThrowsError(try repo.mergeWorktree(plan))
        let next = try repo.prepareWorktreeFinish(entry,into:"main")
        _ = try repo.run(["commit","--allow-empty","-m","Changed target"])
        XCTAssertThrowsError(try repo.mergeWorktree(next))
        XCTAssertTrue(FileManager.default.fileExists(atPath:source.directory))
    }
    func testFetchedRemoteTrunkQualifiesWhenLocalMainIsBehind() throws {
        let (base,repo,source,entry) = try fixture(); defer { try? FileManager.default.removeItem(at:base) }
        try "work\n".write(to:source.root.appendingPathComponent("work.txt"),atomically:true,encoding:.utf8)
        _ = try source.run(["add","work.txt"]); try source.commit("Work")
        _ = try repo.run(["update-ref","refs/remotes/origin/main",try source.run(["rev-parse","HEAD"]).trimmingCharacters(in:.newlines)])
        _ = try repo.run(["symbolic-ref","refs/remotes/origin/HEAD","refs/remotes/origin/main"])
        let trunk = try repo.resolvedTrunk()
        XCTAssertEqual(trunk.comparison,"refs/remotes/origin/main")
        XCTAssertTrue(try repo.cleanupCandidates(into:"").contains { $0.entry.path == entry.path })
        XCTAssertTrue(try repo.worktreeDetail(entry,against:"").contains("origin/main"))
    }
    func testMovedOwnedTaskRemainsDiscoverableAndSafelyRemovable() throws {
        let (base,repo,_,_) = try fixture(); defer { try? FileManager.default.removeItem(at:base) }
        let store = AgentTaskStore(directory:base.appendingPathComponent("Tasks")),task = try store.create(title:"Moved",in:repo),destination = base.appendingPathComponent("moved-task").path
        _ = try repo.run(["worktree","move","--",task.directory,destination])
        try store.relocateWorktree(from:task.directory,to:destination)
        let moved = try XCTUnwrap(store.task(at:destination))
        XCTAssertEqual(moved.originalDirectory,task.directory); XCTAssertEqual(moved.directory,destination)
        XCTAssertTrue(try store.tasks(in:repo).contains(moved))
        let fake = AgentTask(id:task.id,title:task.title,directory:repo.directory,branch:"main",commonDirectory:task.commonDirectory)
        XCTAssertThrowsError(try store.remove(fake,in:repo))
        try store.remove(moved,in:repo)
        XCTAssertNil(store.task(at:destination)); XCTAssertFalse(try store.tasks(in:repo).contains(moved))
        let records = try FileManager.default.subpathsOfDirectory(atPath:store.directory.path)
        XCTAssertTrue(records.contains { $0.hasSuffix(task.id.uuidString+".json") })
    }

}
