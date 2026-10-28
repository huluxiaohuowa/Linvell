import XCTest
@testable import LinvellCore

final class RemoteGitTransportTests: XCTestCase {
    func testLiveSSHGitHistoryHunksBranchesAndCommit() throws {
        guard let file = ProcessInfo.processInfo.environment["LINVELL_SSH_FIXTURE"] else { throw XCTSkip("A disposable SSH Git fixture was not selected.") }
        let config = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as! [String:String]
        guard config["gitFixture"] == "ready" else { throw XCTSkip("The selected SSH fixture has no disposable Git repository.") }
        let remote = try SSHRemote(host:try XCTUnwrap(config["host"])),root = try XCTUnwrap(config["root"])
        let repo = try GitRepository(remote:remote,directory:root+"/nested").resolvedWorkingTree()
        XCTAssertEqual(URL(fileURLWithPath:repo.directory).lastPathComponent,URL(fileURLWithPath:root).lastPathComponent); XCTAssertEqual(try repo.history().count,4)
        let path = root+"/git-hunk.txt",read = try remote.request("read",path:path)
        let original = try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(read.content)))
        var lines = String(decoding:original,as:UTF8.self).components(separatedBy:"\n")
        lines[4] = "edited first hunk"; lines[39] = "edited second hunk"
        _ = try remote.request("write",path:path,content:Data(lines.joined(separator:"\n").utf8),digest:read.digest)
        let change = try XCTUnwrap(repo.changes().first { $0.path == "git-hunk.txt" })
        let hunks = GitHunk.parse(try repo.diff(change,staged:false)); XCTAssertEqual(hunks.count,2)
        try repo.applyHunk(try XCTUnwrap(hunks.first),unstage:false)
        let staged = try repo.diff(change,staged:true)
        XCTAssertTrue(staged.contains("edited first hunk")); XCTAssertFalse(staged.contains("edited second hunk"))
        try repo.applyHunk(try XCTUnwrap(GitHunk.parse(staged).first),unstage:true)
        XCTAssertTrue(try repo.diff(change,staged:true).isEmpty)
        _ = try repo.run(["switch","-c","acceptance/temporary"])
        try repo.stage(change); try repo.commit("Verify SSH Git commit")
        XCTAssertEqual(try repo.run(["branch","--show-current"]).trimmingCharacters(in:.whitespacesAndNewlines),"acceptance/temporary")
        XCTAssertFalse(try repo.history().isEmpty)
        XCTAssertFalse(try repo.changes().contains { $0.path == "git-hunk.txt" })
    }
    func testRemoteTransportPreservesRepositoryAcrossRootResolutionAndHunkInput() throws {
        var calls: [(String,[String],Data?)] = []
        let remote = try SSHRemote(host:"example")
        let repository = GitRepository(directory:"/parent/project/subdir",remote:remote) { path,args,input,_ in
            calls.append((path,args,input))
            if args == ["rev-parse","--show-toplevel"] { return "/parent/project\n" }
            if args.first == "status" { return " M file name.swift\0" }
            return ""
        }
        let resolved = try repository.resolvedWorkingTree()
        XCTAssertEqual(resolved.remote?.host,"example"); XCTAssertEqual(resolved.directory,"/parent/project")
        let change = try XCTUnwrap(resolved.changes().first); try resolved.stage(change)
        let hunk = try XCTUnwrap(GitHunk.parse("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n").first)
        try resolved.applyHunk(hunk,unstage:false)
        XCTAssertEqual(calls.last?.0,"/parent/project"); XCTAssertEqual(calls.last?.2,Data(hunk.patch.utf8))
        XCTAssertTrue(calls.contains { $0.1 == ["add","--","file name.swift"] })
    }
    func testSSHGitQuotingRunsSafelyThroughPOSIXAndFishLocally() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Linvell-Git-"+UUID().uuidString)
        let repoURL = root.appendingPathComponent("space ' $repo")
        try FileManager.default.createDirectory(at:repoURL,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:repoURL); _ = try repo.run(["init","-b","main"])
        let path = "literal ' $x; touch SHOULD_NOT_EXIST.txt"
        try "fixture\n".write(to:repoURL.appendingPathComponent(path),atomically:true,encoding:.utf8)
        let command = SSHRemote.gitCommand(["add","--",path],directory:repoURL.path)
        for shell in [URL(fileURLWithPath:"/bin/sh"),ToolCommand.executable("fish")].compactMap({ $0 }) {
            let result = try ToolCommand.run(shell,arguments:["-c",command],directory:root)
            XCTAssertTrue(result.succeeded); XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("SHOULD_NOT_EXIST.txt").path))
        }
        XCTAssertTrue(try repo.changes().contains { $0.path == path && $0.staged })
    }
}
