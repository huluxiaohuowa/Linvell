import AppKit
import XCTest
@testable import LinvellCore
@testable import Linvell

final class GitCleanupInteractionTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !predicate(),Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(predicate())
    }
    func testCleanupRefreshSelectionResultsAndFailureCommands() throws { try exercise(remote:nil,root:nil) }
    func testLiveSSHCleanupReviewAndPartialResults() throws {
        guard let path = ProcessInfo.processInfo.environment["LINVELL_SSH_FIXTURE"] else { throw XCTSkip("An isolated SSH fixture is required") }
        let config = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let remote = try SSHRemote(host:XCTUnwrap(config["host"]),configurationFile:XCTUnwrap(config["configurationFile"]))
        try exercise(remote:remote,root:URL(fileURLWithPath:try XCTUnwrap(config["root"])).deletingLastPathComponent().path)
    }
    private func exercise(remote: SSHRemote?,root: String?) throws {
        _ = NSApplication.shared
        let base = URL(fileURLWithPath:root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/git-interaction-tests").path)
        let directory = base.appendingPathComponent("cleanup-ui-"+UUID().uuidString).path
        let repo: GitRepository
        if let remote {
            _ = try GitRepository(remote:remote,directory:root!).run(["init","-b","main",directory])
            repo = GitRepository(remote:remote,directory:directory)
        } else {
            try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
            repo = GitRepository(root:URL(fileURLWithPath:directory)); _ = try repo.run(["init","-b","main"])
        }
        let good = directory+"-good",stale = directory+"-stale"
        defer { if remote == nil { for path in [directory,good,stale] { try? FileManager.default.removeItem(atPath:path) } } }
        _ = try repo.run(["config","user.name","Fixture"]); _ = try repo.run(["config","user.email","fixture@example.invalid"])
        _ = try repo.run(["config","commit.gpgsign","false"])
        func write(_ value: String,path: String) throws {
            if let remote {
                _ = try remote.request("create",path:path)
                let before = try remote.request("read",path:path)
                _ = try remote.request("write",path:path,content:Data(value.utf8),digest:before.digest)
            } else { try value.write(toFile:path,atomically:true,encoding:.utf8) }
        }
        try write("*.cache\n",path:directory+"/.gitignore")
        _ = try repo.run(["add","."]); try repo.commit("Fixture")
        _ = try repo.run(["worktree","add","-b","good","--",good])
        _ = try repo.run(["worktree","add","-b","stale","--",stale])
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:760),styleMask:.titled,backing:.buffered,defer:false)
        let panel = GitWorktreeCleanupPanel(repository:repo,target:"main",owner:owner,canRemove:{ _ in true },onRemoved:{})
        defer { if let sheet = panel.window { owner.endSheet(sheet) }; owner.orderOut(nil) }
        wait { panel.candidates.count == 2 }
        XCTAssertTrue(panel.selected.isEmpty)
        panel.toggleAllCandidates(); XCTAssertEqual(panel.selected.count,2)
        panel.toggleAllCandidates(); XCTAssertTrue(panel.selected.isEmpty)
        panel.toggleAllCandidates()
        try write("ignored",path:good+"/build.cache")
        panel.reloadCandidates()
        wait { panel.candidates.first { $0.entry.path == good }?.ignored == ["build.cache"] }
        XCTAssertEqual(panel.selected.count,2)
        let source = remote.map { GitRepository(remote:$0,directory:stale) } ?? GitRepository(root:URL(fileURLWithPath:stale))
        _ = try source.run(["commit","--allow-empty","-m","New work after preview"])
        panel.runCleanup()
        wait { panel.results.count == 2 && !panel.isRunning }
        XCTAssertTrue(try repo.worktrees().contains { $0.path == stale })
        XCTAssertFalse(try repo.worktrees().contains { $0.path == good })
        XCTAssertNil(panel.results.first { $0.path == good }?.command)
        let failure = try XCTUnwrap(panel.results.first { $0.path == stale })
        XCTAssertTrue(failure.command?.contains("worktree") == true)
        if remote != nil { XCTAssertTrue(failure.command?.hasPrefix("ssh -- ") == true) }
        XCTAssertEqual(GitWorktreeCleanupPanel.ignoredGroups(["cache/a","cache/b","one.txt"]),["cache/ (2)","one.txt (1)"])
        if let destination = ProcessInfo.processInfo.environment["LINVELL_SNAPSHOT_DIR"],let view = panel.window?.contentView {
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:destination).appendingPathComponent("git-cleanup-results.png"))
            }
        }
    }
}
