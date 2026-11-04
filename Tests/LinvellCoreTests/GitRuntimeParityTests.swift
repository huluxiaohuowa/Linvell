import Foundation
import XCTest
import Darwin
@testable import LinvellCore

final class GitRuntimeParityTests: XCTestCase {
    private func fixture(_ body: (GitRepository,URL) throws -> Void) throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/final-audit/fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        for args in [["config","user.name","Fixture"],["config","user.email","fixture@example.invalid"],["config","commit.gpgsign","false"]] { _ = try repo.run(args) }
        try body(repo,root)
    }
    private func write(_ text: String,_ path: String,_ root: URL) throws { try text.write(to:root.appendingPathComponent(path),atomically:true,encoding:.utf8) }
    func testRenameHistoryRetainsOldPathsAcrossPagesAndComparison() throws {
        try fixture { repo,root in
            try write("first\n","old.txt",root); _ = try repo.run(["add","."]); try repo.commit("first")
            try write("second\n","old.txt",root); _ = try repo.run(["add","."]); try repo.commit("second")
            let before = try repo.resolvedRevision("HEAD")
            _ = try repo.run(["mv","old.txt","new.txt"]); try repo.commit("rename")
            let tip = try repo.resolvedRevision("HEAD")
            let first = try repo.fileHistoryEntries("new.txt",revision:tip,limit:1)
            let rest = try repo.fileHistoryEntries("new.txt",revision:tip,limit:2,offset:1)
            XCTAssertEqual(first.map(\.commit.subject),["rename"])
            XCTAssertEqual(first.first?.oldPath,"old.txt"); XCTAssertEqual(first.first?.newPath,"new.txt")
            XCTAssertEqual(rest.map(\.commit.subject),["second","first"])
            XCTAssertTrue(try repo.fileHistoryDiff(first[0]).contains("rename from old.txt"))
            XCTAssertTrue(try repo.fileHistoryDiff(rest[0]).contains("+second"))
            let sides = try repo.fileHistoryImages(first[0]); XCTAssertEqual(sides.0,Data("second\n".utf8)); XCTAssertEqual(sides.1,sides.0)
            XCTAssertTrue(try repo.comparisonPatch(before,tip,path:"new.txt").contains("rename from old.txt"))
        }
    }
    func testMergedFileCommitRemainsReachableAndIntroducingMergeResolved() throws {
        try fixture { repo,root in
            try write("base\n","f",root); _ = try repo.run(["add","."]); try repo.commit("base")
            _ = try repo.run(["switch","-c","feature"]); try write("feature\n","f",root); _ = try repo.run(["add","."]); try repo.commit("feature edit")
            let feature = try repo.resolvedRevision("HEAD")
            _ = try repo.run(["switch","main"]); try write("other\n","other",root); _ = try repo.run(["add","."]); try repo.commit("other")
            _ = try repo.run(["merge","--no-edit","feature"])
            let history = try repo.fileHistoryEntries("f")
            XCTAssertTrue(history.contains { $0.commit.hash == feature })
            XCTAssertEqual(try repo.introducingMerge(feature)?.hash,try repo.resolvedRevision("HEAD"))
        }
    }
    func testWorkingTreeComparisonsAndUnbornAggregateUseFinalContents() throws {
        try fixture { repo,root in
            try write("staged\n","f",root); _ = try repo.run(["add","."]); try write("final\n","f",root)
            try write("untracked\n","u",root)
            let unborn = try repo.uncommittedPatch()
            XCTAssertTrue(unborn.contains("+final")); XCTAssertTrue(unborn.contains("+untracked")); XCTAssertFalse(unborn.contains("+staged"))
            XCTAssertEqual(try repo.uncommittedStat().files,2)
            _ = try repo.run(["add","."]); try repo.commit("initial")
            let hash = try repo.resolvedRevision("HEAD")
            try write("changed\n","f",root); try write("new\n","new",root)
            XCTAssertEqual(Set(try repo.comparisonPaths(base:.commit(hash),target:.workingTree)),Set(["f","new"]))
            XCTAssertTrue(try repo.comparisonPatch(base:.workingTree,target:.commit(hash),path:"new").contains("-new"))
            XCTAssertEqual(try repo.comparisonStat(base:.commit(hash),target:.workingTree).files,2)
        }
    }
    func testSecurePreviewRejectsParentSymlinkAndFIFOWithoutBlocking() throws {
        try fixture { repo,root in
            let directory = root.appendingPathComponent("real"); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try write("source","real/f",root)
            try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("alias"),withDestinationURL:directory)
            XCTAssertThrowsError(try repo.workingFileData("alias/f"))
            let fifo = root.appendingPathComponent("fifo").path
            XCTAssertEqual(mkfifo(fifo,0o600),0)
            XCTAssertThrowsError(try repo.workingFileData("fifo"))
        }
    }
    func testDiagnosticsKeepCommandStatusButNotPayloadOrCredentials() throws {
        try fixture { repo,_ in
            _ = try? repo.run(["-c","http.extraHeader=Authorization: secret","show","missing"],input:Data("private source".utf8))
            let entry = try XCTUnwrap(GitCommandJournal.shared.entries(for:repo.journalScope).first)
            XCTAssertEqual(entry.command,"show"); XCTAssertNotNil(entry.exitCode)
            XCTAssertTrue(entry.displayCommand.contains("show")); XCTAssertFalse(entry.details.contains("secret")); XCTAssertFalse(entry.details.contains("private source"))
        }
    }
    func testTrackingFallbackAndFirstPublish() throws {
        try fixture { repo,root in
            try write("base","f",root); _ = try repo.run(["add","."]); try repo.commit("base")
            let bare = root.appendingPathComponent("remote.git")
            _ = try repo.run(["init","--bare",bare.path]); _ = try repo.run(["remote","add","origin",bare.path])
            let tracking = try XCTUnwrap(repo.trackingState()); XCTAssertNil(tracking.upstream); XCTAssertEqual(tracking.ahead,1)
            try repo.pushTrackingBranch()
            XCTAssertNotNil(try repo.trackingState()?.upstream)
        }
    }
    func testConcurrentFetchObserversShareExecutionAndScheduledSuccess() throws {
        let lock = NSLock(),started = DispatchSemaphore(value:0),release = DispatchSemaphore(value:0)
        let joined = expectation(description:"both fetch observers complete"); joined.expectedFulfillmentCount = 2
        let path = "/fixture/"+UUID().uuidString
        var fetches = 0
        let repo = GitRepository(directory:path,remote:nil) { _,args,_,_ in
            if args == ["rev-parse","--show-toplevel"] { return path+"\n" }
            XCTAssertEqual(args,["fetch","--all"])
            lock.lock(); fetches += 1; lock.unlock()
            started.signal(); _ = release.wait(timeout:.now()+3)
            return ""
        }
        for _ in 0..<2 {
            DispatchQueue.global().async {
                do { _ = try repo.fetch() } catch { XCTFail(error.localizedDescription) }
                joined.fulfill()
            }
        }
        XCTAssertEqual(started.wait(timeout:.now()+3),.success)
        // Keep the owner in flight until the other observer has entered the shared coordinator.
        Thread.sleep(forTimeInterval:0.1)
        release.signal(); wait(for:[joined],timeout:4)
        _ = try repo.fetch(scheduledSince:.distantPast)
        XCTAssertEqual(fetches,1)
    }

    func testSSHReaderProtocolRejectsSymlinksAndFIFO() throws {
        try fixture { _,root in
            try write("remote source","f",root)
            try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:root.appendingPathComponent("f"))
            XCTAssertEqual(mkfifo(root.appendingPathComponent("fifo").path,0o600),0)
            func request(_ path: String) throws -> [String:Any] {
                let input = try JSONSerialization.data(withJSONObject:["operation":"review-read","path":root.appendingPathComponent(path).path,"repositoryRoot":root.path])
                let result = try ToolCommand.run(try XCTUnwrap(ToolCommand.executable("python3")),arguments:["-c",SSHRemote.agent],directory:root,timeout:3,input:input)
                XCTAssertTrue(result.succeeded)
                let text = try XCTUnwrap(result.output.components(separatedBy:"LINVELL_JSON:").last)
                return try JSONSerialization.jsonObject(with:Data(text.utf8)) as! [String:Any]
            }
            let valid = try request("f")
            XCTAssertEqual(Data(base64Encoded:try XCTUnwrap(valid["content"] as? String)),Data("remote source".utf8))
            XCTAssertNotNil(try request("link")["error"])
            XCTAssertNotNil(try request("fifo")["error"])
        }
    }

    func testCRLFPreviewCountsPhysicalLinesOnce() throws {
        let source = String(repeating:"x\r\n",count:60000)
        XCTAssertEqual(try GitPreviewText.decode(Data(source.utf8),plain:false),source)
    }

    func testUncommittedPatchDiffsSymlinkWithoutReadingTarget() throws {
        try fixture { repo,root in
            try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:URL(fileURLWithPath:"/nonexistent/private-target"))
            let patch = try repo.uncommittedPatch()
            XCTAssertTrue(patch.contains("120000")); XCTAssertTrue(patch.contains("+/nonexistent/private-target"))
            XCTAssertThrowsError(try repo.workingFilePreview("link"))
        }
    }

    func testPartialUnstageOfRenamedFileKeepsRenameAndRestoresIndexContent() throws {
        try fixture { repo,root in
            try write(String(repeating:"context\n",count:20)+"old\n","old name.txt",root)
            _ = try repo.run(["add","."]); try repo.commit("base")
            _ = try repo.run(["mv","old name.txt","new name.txt"])
            try write(String(repeating:"context\n",count:20)+"new\n","new name.txt",root)
            _ = try repo.run(["add","."])
            let change = try XCTUnwrap(repo.changes().first)
            let patch = try repo.diff(change,staged:true)
            XCTAssertTrue(patch.contains("rename from"))
            let first = try XCTUnwrap(patch.range(of:"@@ "))
            let offset = patch[..<first.lowerBound].utf16.count
            let selection = try GitHunk.selection(in:patch,range:NSRange(location:offset,length:patch.utf16.count-offset),unstage:true)
            try repo.applyHunk(selection,unstage:false)
            XCTAssertEqual(String(decoding:try repo.blobData(":",path:"new name.txt"),as:UTF8.self),String(repeating:"context\n",count:20)+"old\n")
            XCTAssertTrue(try repo.run(["diff","--cached","--name-status"]).contains("R100"))
        }
    }

    func testScheduledFetchDoesNotLoseRequestedPruneAndTags() throws {
        let path = "/fixture/"+UUID().uuidString
        var commands: [[String]] = []
        let repo = GitRepository(directory:path,remote:nil) { _,args,_,_ in
            if args.first == "rev-parse" { return path+"\n" }
            commands.append(args); return ""
        }
        _ = try repo.fetch()
        _ = try repo.fetch(tags:true,prune:true,scheduledSince:.distantPast)
        _ = try repo.fetch(tags:true,prune:true,scheduledSince:.distantPast)
        XCTAssertEqual(commands,[["fetch","--all"],["fetch","--all","--tags","--prune"]])
    }

}
