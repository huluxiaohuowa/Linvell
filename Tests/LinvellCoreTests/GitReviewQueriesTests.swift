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
    func testReviewPreviewAndFailedJournalEntry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        let file = root.appendingPathComponent("file.txt")
        try "source preview\n".write(to:file,atomically:true,encoding:.utf8)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:file)
        XCTAssertEqual(try repo.reviewFiles(),["file.txt","link"])
        XCTAssertEqual(try repo.workingFilePreview("file.txt"),"source preview\n")
        XCTAssertThrowsError(try repo.workingFilePreview("link"))
        XCTAssertThrowsError(try repo.workingFilePreview("../file.txt"))
        let operation = UUID()
        XCTAssertThrowsError(try GitCommandJournal.$operation.withValue(operation) { try repo.run(["show","missing"]) })
        let entry = try XCTUnwrap(GitCommandJournal.shared.entries(for:repo.journalScope).first)
        XCTAssertEqual(entry.operation,operation)
        XCTAssertEqual(entry.command,"show")
        XCTAssertFalse(entry.succeeded)
    }
    func testBinaryRevisionComparisonAndLargePreview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        _ = try repo.run(["config","user.name","Fixture"])
        _ = try repo.run(["config","user.email","fixture@example.invalid"])
        _ = try repo.run(["config","commit.gpgsign","false"])
        let bytes = Data([0,1,2,128,255,10])
        try bytes.write(to:root.appendingPathComponent("image.png"))
        _ = try repo.run(["add","."]); try repo.commit("Binary revision")
        let base = try repo.resolvedRevision("HEAD")
        XCTAssertEqual(try repo.blobData(base,path:"image.png"),bytes)
        let changed = bytes+Data([127])
        try changed.write(to:root.appendingPathComponent("image.png"))
        _ = try repo.run(["add","."]); try repo.commit("Changed image")
        let target = try repo.resolvedRevision("HEAD")
        XCTAssertEqual(try repo.comparePaths(base,target),["image.png"])
        XCTAssertEqual(try repo.blobData(target,path:"image.png"),changed)
        let pair = try repo.patchImages(repo.comparisonPatch(base,target,path:"image.png"))
        XCTAssertEqual(pair.0,bytes); XCTAssertEqual(pair.1,changed)
        _ = try repo.run(["mv","image.png","renamed.png"])
        try repo.commit("Renamed image")
        let rename = try repo.patchImages(repo.commitDiff(repo.resolvedRevision("HEAD"),path:"renamed.png"))
        // A path-filtered rename may be emitted as an addition; the new side must remain available.
        XCTAssertEqual(rename.1,changed)
        let renamePair = try repo.commitImages(repo.resolvedRevision("HEAD"),path:"renamed.png")
        XCTAssertEqual(renamePair.0,changed); XCTAssertEqual(renamePair.1,changed)
        let remoteRoot = root.appendingPathComponent("remote.git")
        _ = try repo.run(["init","--bare",remoteRoot.path])
        try repo.createAndPushTag("release-test",revision:target,remote:remoteRoot.path)
        XCTAssertEqual(try repo.run(["--git-dir="+remoteRoot.path,"rev-parse","refs/tags/release-test"]).trimmingCharacters(in:.newlines),target)
        let text = String(repeating:"line\n",count:220000)
        try text.write(to:root.appendingPathComponent("large.txt"),atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try repo.workingFilePreview("large.txt"))
        XCTAssertEqual(try repo.workingFilePreview("large.txt",largeFile:true),text)
    }
}

extension GitReviewQueriesTests {
    func testPreviewDecodesBOMTextAndRejectsMalformedSurrogates() throws {
        for encoding in [String.Encoding.utf16LittleEndian,.utf16BigEndian] {
            let bom = encoding == .utf16LittleEndian ? Data([0xFF,0xFE]) : Data([0xFE,0xFF])
            let data = bom+("中文 👩‍💻\n".data(using:encoding)!)
            XCTAssertEqual(try GitPreviewText.decode(data,plain:false),"中文 👩‍💻\n")
        }
        XCTAssertThrowsError(try GitPreviewText.decode(Data([0xFF,0xFE,0,0xD8]),plain:false))
        XCTAssertThrowsError(try GitPreviewText.decode(Data([0xFE,0xFF,0]),plain:false))
        XCTAssertThrowsError(try GitPreviewText.decode(Data([0x41,0,0x42]),plain:false))
        let long = Data(String(repeating:"x",count:20001).utf8)
        XCTAssertThrowsError(try GitPreviewText.decode(long,plain:false))
        XCTAssertEqual(try GitPreviewText.decode(long,plain:true).utf8.count,20001)
    }
}

extension GitReviewQueriesTests {
    func testModificationDateIncludesUntrackedFilesAndDeletedTrackedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        let file = root.appendingPathComponent("untracked.txt")
        try "text".write(to:file,atomically:true,encoding:.utf8)
        let future = Date().addingTimeInterval(100)
        try FileManager.default.setAttributes([.modificationDate:future],ofItemAtPath:file.path)
        XCTAssertEqual(try repo.modificationDate().timeIntervalSince1970,future.timeIntervalSince1970,accuracy:0.01)
        _ = try repo.run(["add","."])
        try FileManager.default.removeItem(at:file)
        XCTAssertGreaterThan(try repo.modificationDate().timeIntervalSince1970,Date().timeIntervalSince1970-10)
    }
}
