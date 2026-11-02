import XCTest
@testable import LinvellCore

final class AgentTaskTests: XCTestCase {
    func testTasksIsolateDirtyCheckoutPersistAndRefuseDirtyOrExternalRemoval() throws {
        let fm = FileManager.default,root = fm.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/task-fixtures/"+UUID().uuidString)
        let project = root.appendingPathComponent("repo with spaces"),store = AgentTaskStore(directory:root.appendingPathComponent("tasks"))
        try fm.createDirectory(at:project,withIntermediateDirectories:true)
        let repo = GitRepository(root:project)
        defer { try? fm.removeItem(at:root) }
        _ = try repo.run(["init","-b","main"]); _ = try repo.run(["config","user.name","Fixture"]); _ = try repo.run(["config","user.email","fixture@example.invalid"])
        let file = project.appendingPathComponent("a.txt")
        try "original\n".write(to:file,atomically:true,encoding:.utf8)
        _ = try repo.run(["add","."]); _ = try repo.run(["commit","-m","Initial"])
        try "unsaved main work\n".write(to:file,atomically:true,encoding:.utf8)
        let a = try store.create(title:"任务 ' ; $(literal)",in:repo),b = try store.create(title:"任务 ' ; $(literal)",in:repo)
        XCTAssertNotEqual(a.directory,b.directory); XCTAssertNotEqual(a.branch,b.branch)
        XCTAssertEqual(store.task(at:a.directory),a); XCTAssertNil(store.task(at:project.path))
        XCTAssertTrue(a.branch.hasPrefix("codex/"))
        XCTAssertEqual(try String(contentsOf:URL(fileURLWithPath:a.directory).appendingPathComponent("a.txt"),encoding:.utf8),"original\n")
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"unsaved main work\n")
        let fromTask = GitRepository(root:URL(fileURLWithPath:a.directory))
        XCTAssertEqual(Set(try store.tasks(in:fromTask).map(\.id)),Set([a.id,b.id]))
        XCTAssertEqual(try fromTask.run(["branch","--show-current"]).trimmingCharacters(in:.newlines),a.branch)
        let dirty = URL(fileURLWithPath:a.directory).appendingPathComponent("untracked.txt")
        try "preserve".write(to:dirty,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try store.remove(a,in:repo)); XCTAssertTrue(fm.fileExists(atPath:dirty.path))
        try fm.removeItem(at:dirty)
        let fake = AgentTask(id:a.id,title:a.title,directory:project.path,branch:"main",commonDirectory:a.commonDirectory)
        XCTAssertThrowsError(try store.remove(fake,in:repo))
        try store.remove(a,in:repo)
        XCTAssertEqual(try store.tasks(in:repo),[b]); XCTAssertFalse(fm.fileExists(atPath:a.directory))
        XCTAssertNoThrow(try repo.run(["show-ref","--verify","refs/heads/"+a.branch]))
        try store.remove(b,in:repo)
        XCTAssertThrowsError(try store.create(title:"\n",in:repo))
    }
}
