import XCTest
@testable import LinvellCore

final class RemoteGitTransportTests: XCTestCase {
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
