import XCTest
@testable import LinvellCore

final class LiveGitParityTests: XCTestCase {
    func testRealSSHReviewSearchConflictAndCleanup() throws {
        guard let fixture = ProcessInfo.processInfo.environment["LINVELL_SSH_FIXTURE"] else {
            throw XCTSkip("Disposable SSH fixture required")
        }
        let config = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:fixture)))
        let remote = try SSHRemote(host:XCTUnwrap(config["host"]),configurationFile:XCTUnwrap(config["configurationFile"]))
        let parent = try XCTUnwrap(config["root"])+"/../parity-"+UUID().uuidString
        _ = try GitRepository(remote:remote,directory:config["root"]!).run(["init",parent])
        let repo = GitRepository(remote:remote,directory:parent)
        defer { try? FileManager.default.removeItem(atPath:parent) }
        _ = try repo.run(["config","user.name","Fixture"])
        _ = try repo.run(["config","user.email","fixture@example.invalid"])
        _ = try repo.run(["config","commit.gpgsign","false"])
        _ = try repo.run(["switch","--orphan","main"])
        func write(_ repo: GitRepository,_ value: String) throws {
            let file = repo.directory+"/source.txt"
            if let read = try? remote.request("read",path:file) {
                _ = try remote.request("write",path:file,content:Data(value.utf8),digest:read.digest)
            } else {
                _ = try remote.request("create",path:file)
                let read = try remote.request("read",path:file)
                _ = try remote.request("write",path:file,content:Data(value.utf8),digest:read.digest)
            }
            _ = try repo.run(["add","source.txt"])
            try repo.commit(value)
        }
        try write(repo,"base 中文\n")
        let base = try repo.resolvedRevision("HEAD")
        XCTAssertEqual(try repo.workingFilePreview("source.txt"),"base 中文\n")
        XCTAssertEqual(try repo.blobData(base,path:"source.txt"),Data("base 中文\n".utf8))
        let sourcePath = parent+"-source"
        _ = try repo.run(["worktree","add","-b","feature","--",sourcePath])
        let source = GitRepository(remote:remote,directory:sourcePath)
        try write(source,"incoming 中文\n")
        try write(repo,"target 中文\n")
        XCTAssertEqual(try repo.searchHistory("incoming 中文").commits.count,1)
        let entry = try XCTUnwrap(repo.worktrees().first { $0.branch == "feature" })
        let merge = try XCTUnwrap(repo.finishWorktree(entry,into:"main"))
        XCTAssertEqual(try merge.conflicts().map(\.path),["source.txt"])
        let versions = try merge.versions("source.txt")
        XCTAssertEqual(versions.incoming,"incoming 中文\n")
        try merge.resolve("source.txt",useIncoming:true)
        try merge.complete()
        XCTAssertFalse(try repo.worktrees().contains { $0.path == sourcePath })
        let target = try repo.resolvedRevision("HEAD")
        XCTAssertEqual(try repo.comparePaths(base,target),["source.txt"])
        XCTAssertTrue(try repo.comparisonPatch(base,target,path:"source.txt").contains("+incoming 中文"))
        XCTAssertEqual(try repo.fileHistory("source.txt").first?.hash,target)
        let binary = Data([0,1,2,128,255,10])
        let binaryPath = parent+"/image.png"
        _ = try remote.request("create",path:binaryPath)
        let binaryRead = try remote.request("read",path:binaryPath)
        _ = try remote.request("write",path:binaryPath,content:binary,digest:binaryRead.digest)
        _ = try repo.run(["add","image.png"])
        try repo.commit("SSH binary preview")
        XCTAssertEqual(try repo.blobData(repo.resolvedRevision("HEAD"),path:"image.png"),binary)
        _ = try repo.run(["worktree","prune"])
    }
}
