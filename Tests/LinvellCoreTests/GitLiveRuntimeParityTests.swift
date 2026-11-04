import Foundation
import XCTest
import Darwin
@testable import LinvellCore

final class GitLiveRuntimeParityTests: XCTestCase {
    func testLiveSSHRuntimeParity() throws {
        guard let host = ProcessInfo.processInfo.environment["LINVELL_RUNTIME_SSH_HOST"] else { throw XCTSkip("No disposable runtime SSH host selected.") }
        let token = "runtime-"+UUID().uuidString
        let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/final-audit/live-fixtures").appendingPathComponent(token)
        let discoverHome = "python3 -c "+SSHRemote.quote("import os; print(os.path.expanduser('~'))")
        let homeResult = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:["-o","BatchMode=yes",host,discoverHome],directory:nil,timeout:15)
        guard homeResult.succeeded,homeResult.output.hasPrefix("/") else { XCTFail("Unable to discover the disposable SSH host's home directory."); return }
        let remoteHome = homeResult.output.trimmingCharacters(in:.newlines)
        let remoteRoot = URL(fileURLWithPath:remoteHome).appendingPathComponent("dev/build/linvell").appendingPathComponent(token).path
        try FileManager.default.createDirectory(at:local.appendingPathComponent("repository"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:local) }
        let repo = GitRepository(root:local.appendingPathComponent("repository"))
        _ = try repo.run(["init","-b","main"])
        for args in [["config","user.name","Fixture"],["config","user.email","fixture@example.invalid"],["config","commit.gpgsign","false"]] { _ = try repo.run(args) }
        func write(_ text: String,_ path: String) throws { try text.write(to:repo.root.appendingPathComponent(path),atomically:true,encoding:.utf8) }
        let original = String(repeating:"context\n",count:20)+"old\n"
        try write(original,"old name.txt")
        let utf16 = Data([0xff,0xfe])+("中文 👩‍💻\r\n".data(using:.utf16LittleEndian)!)
        try utf16.write(to:repo.root.appendingPathComponent("utf16.txt"))
        _ = try repo.run(["add","."]); try repo.commit("base")
        let base = try repo.resolvedRevision("HEAD")
        _ = try repo.run(["mv","old name.txt","new name.txt"]); try repo.commit("rename")
        let rename = try repo.resolvedRevision("HEAD")
        _ = try repo.run(["switch","-c","feature"]); try write(original+"feature\n","new name.txt"); _ = try repo.run(["add","new name.txt"]); try repo.commit("feature edit")
        let feature = try repo.resolvedRevision("HEAD")
        _ = try repo.run(["switch","main"]); try write("other\n","other"); _ = try repo.run(["add","other"]); try repo.commit("other edit")
        _ = try repo.run(["merge","--no-edit","feature"])
        let head = try repo.resolvedRevision("HEAD")
        try FileManager.default.createSymbolicLink(at:repo.root.appendingPathComponent("link"),withDestinationURL:repo.root.appendingPathComponent("utf16.txt"))
        XCTAssertEqual(mkfifo(repo.root.appendingPathComponent("fifo").path,0o600),0)
        _ = try repo.run(["init","--bare",local.appendingPathComponent("remote.git").path])
        let unbornLocal = local.appendingPathComponent("unborn")
        try FileManager.default.createDirectory(at:unbornLocal,withIntermediateDirectories:true)
        let unbornRepository = GitRepository(root:unbornLocal)
        _ = try unbornRepository.run(["init","-b","main"])
        try "staged\n".write(to:unbornLocal.appendingPathComponent("f"),atomically:true,encoding:.utf8)
        _ = try unbornRepository.run(["add","f"])
        try "final\n".write(to:unbornLocal.appendingPathComponent("f"),atomically:true,encoding:.utf8)
        try "untracked\n".write(to:unbornLocal.appendingPathComponent("u"),atomically:true,encoding:.utf8)
        let remote = try SSHRemote(host:host)
        let mkdir = "python3 -c "+SSHRemote.quote("import os; os.makedirs("+String(reflecting:remoteRoot)+",exist_ok=False)")
        let setup = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:["-o","BatchMode=yes",host,mkdir],directory:nil,timeout:15)
        guard setup.succeeded else { XCTFail("Unable to create the unique disposable remote fixture."); return }
        defer {
            // Only the unique synthetic fixture created above is eligible for removal.
            let cleanupProgram = """
            import os,shutil
            base=os.path.realpath(os.path.join(os.path.expanduser('~'),'dev','build','linvell'))
            target=\(String(reflecting:remoteRoot))
            token=\(String(reflecting:token))
            if not token.startswith('runtime-') or os.path.basename(target)!=token or os.path.dirname(os.path.realpath(target))!=base or os.path.islink(target):
                raise RuntimeError('Refusing to remove a path outside the owned runtime fixture.')
            shutil.rmtree(target)
            if os.path.lexists(target): raise RuntimeError('Disposable fixture cleanup did not finish.')
            """
            let cleanup = "python3 -c "+SSHRemote.quote(cleanupProgram)
            do {
                let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:["-o","BatchMode=yes",host,cleanup],directory:nil,timeout:15)
                XCTAssertTrue(result.succeeded,"Disposable remote fixture cleanup failed.")
            } catch { XCTFail("Disposable remote fixture cleanup failed: "+error.localizedDescription) }
        }
        let sync = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/rsync"),arguments:["-a","--",local.path+"/",host+":"+remoteRoot+"/"],directory:nil,timeout:30)
        XCTAssertTrue(sync.succeeded)
        let live = GitRepository(remote:remote,directory:remoteRoot+"/repository")
        XCTAssertEqual(try live.resolvedWorkingTree().directory,live.directory)
        let history = try live.fileHistoryEntries("new name.txt",revision:head)
        XCTAssertTrue(history.contains { $0.commit.hash == base }); XCTAssertTrue(history.contains { $0.commit.hash == feature })
        XCTAssertEqual(try live.introducingMerge(feature)?.hash,head)
        let renameEntry = try XCTUnwrap(history.first { $0.commit.hash == rename })
        XCTAssertEqual(renameEntry.oldPath,"old name.txt")
        XCTAssertTrue(try live.fileHistoryDiff(renameEntry).contains("rename from old name.txt"))
        XCTAssertTrue(try live.comparisonPatch(base,rename,path:"new name.txt").contains("rename from old name.txt"))
        let images = try live.fileHistoryImages(renameEntry)
        XCTAssertEqual(images.0,Data(original.utf8)); XCTAssertEqual(images.1,images.0)
        let source = try live.workingFilePreviewWithSize("utf16.txt")
        XCTAssertEqual(source.text,"中文 👩‍💻\r\n"); XCTAssertEqual(source.bytes,utf16.count)
        XCTAssertThrowsError(try live.workingFileData("link")); XCTAssertThrowsError(try live.workingFileData("fifo"))
        // Remove only the synthetic nontracked special files before aggregate diff tests.
        let removeSpecial = "python3 -c "+SSHRemote.quote("import os; [os.unlink("+String(reflecting:live.directory)+"+'/'+name) for name in ['link','fifo']]")
        XCTAssertTrue(try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:[host,removeSpecial],directory:nil,timeout:15).succeeded)
        let initialFingerprint = try live.refreshFingerprint()
        XCTAssertEqual(try live.refreshFingerprint(),initialFingerprint)
        let read = try remote.request("read",path:live.directory+"/new name.txt")
        let edited = Data((original+"changed\n").utf8)
        _ = try remote.request("write",path:live.directory+"/new name.txt",content:edited,digest:read.digest)
        XCTAssertNotEqual(try live.refreshFingerprint(),initialFingerprint)
        XCTAssertTrue(try live.comparisonPatch(base:.commit(head),target:.workingTree,path:"new name.txt").contains("+changed"))
        XCTAssertTrue(try live.comparisonPatch(base:.workingTree,target:.commit(head),path:"new name.txt").contains("-changed"))
        XCTAssertEqual(try live.uncommittedStat().files,1)
        _ = try live.run(["add","new name.txt"])
        let change = try XCTUnwrap(live.changes().first)
        let patch = try live.diff(change,staged:true)
        let selected = try GitHunk.selection(in:patch,range:NSRange(location:0,length:patch.utf16.count),unstage:true)
        try live.applyHunk(selected,unstage:false)
        XCTAssertTrue(try live.run(["diff","--cached"]).isEmpty)
        // A stale, conflicting index patch is rejected and its failure status is journaled.
        XCTAssertThrowsError(try live.applyHunk(selected,unstage:false))
        let failure = try XCTUnwrap(GitCommandJournal.shared.entries(for:live.journalScope).first)
        XCTAssertEqual(failure.command,"apply"); XCTAssertNotNil(failure.exitCode); XCTAssertFalse(failure.succeeded)
        XCTAssertFalse(failure.details.contains("context\n"))
        _ = try live.run(["remote","add","origin",remoteRoot+"/remote.git"])
        XCTAssertNil(try live.trackingState()?.upstream)
        XCTAssertGreaterThan(try XCTUnwrap(live.trackingState()).ahead,0)
        try live.pushTrackingBranch()
        XCTAssertNotNil(try live.trackingState()?.upstream)
        _ = try live.fetch(tags:true,prune:true)
        _ = try live.fetch(tags:true,prune:true,scheduledSince:.distantPast)
        let unborn = GitRepository(remote:remote,directory:remoteRoot+"/unborn")
        let aggregate = try unborn.uncommittedPatch()
        XCTAssertTrue(aggregate.contains("+final")); XCTAssertTrue(aggregate.contains("+untracked")); XCTAssertFalse(aggregate.contains("+staged"))
        XCTAssertEqual(try unborn.uncommittedStat().files,2)
    }
}
