import AppKit
import XCTest
@testable import LinvellCore
@testable import Linvell

final class LiveSSHReviewTests: XCTestCase {
    func testWorkspaceUsesRealSSHForFileAndReviewPreview() throws {
        guard let fixture = ProcessInfo.processInfo.environment["LINVELL_SSH_FIXTURE"] else {
            throw XCTSkip("Disposable SSH fixture required")
        }
        _ = NSApplication.shared
        let config = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:fixture)))
        let remote = try SSHRemote(host:XCTUnwrap(config["host"]),configurationFile:XCTUnwrap(config["configurationFile"]))
        let root = try XCTUnwrap(config["root"])
        let path = root+"/ui-preview.txt"
        _ = try remote.request("create",path:path)
        let read = try remote.request("read",path:path)
        _ = try remote.request("write",path:path,content:Data("SSH UI preview 中文".utf8),digest:read.digest)
        let repo = GitRepository(remote:remote,directory:root)
        defer { _ = try? repo.run(["clean","-f","--","ui-preview.txt"]) }
        let workspace = WorkspaceController()
        defer { workspace.window?.orderOut(nil); workspace.gitWorkspaceView?.shutdown() }
        workspace.remoteConnection = remote
        workspace.remoteDirectory = root
        workspace.gitWorkspace()
        let git = try XCTUnwrap(workspace.gitWorkspaceView)
        let deadline = Date().addingTimeInterval(10)
        while git.changes.isEmpty,Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(git.changes.contains { $0.path == "ui-preview.txt" })
        let panel = GitReviewPanel(repository:git.repository,files:[.init(path:"ui-preview.txt",patch:nil)],owner:try XCTUnwrap(workspace.window))
        let sheet = try XCTUnwrap(panel.window)
        defer { workspace.window?.endSheet(sheet) }
        func descendants(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(descendants) }
        let content = try XCTUnwrap(sheet.contentView)
        let previewDeadline = Date().addingTimeInterval(10)
        var received = false
        while Date() < previewDeadline {
            received = descendants(content).compactMap { $0 as? NSTextView }.contains { $0.string.contains("SSH UI preview 中文") }
            if received { break }
            RunLoop.current.run(until:Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(received)
        workspace.window?.endSheet(sheet)
        let trackedPath = root+"/git-hunk.txt"
        let tracked = try remote.request("read",path:trackedPath)
        let original = String(decoding:try XCTUnwrap(Data(base64Encoded:XCTUnwrap(tracked.content))),as:UTF8.self)
        let changed = original.replacingOccurrences(of:"line 4\n",with:"SSH UI selected\n").replacingOccurrences(of:"line 39\n",with:"SSH UI unselected\n")
        _ = try remote.request("write",path:trackedPath,content:Data(changed.utf8),digest:tracked.digest)
        defer { _ = try? repo.run(["restore","--staged","--worktree","--","git-hunk.txt"]) }
        let change = try XCTUnwrap(repo.changes().first { $0.path == "git-hunk.txt" })
        let review = GitReviewPanel(repository:repo,files:[.init(path:"git-hunk.txt",patch:{ try repo.diff(change,staged:false) },indexSide:false)],owner:try XCTUnwrap(workspace.window))
        defer { if let sheet = review.window { workspace.window?.endSheet(sheet) } }
        let reviewContent = try XCTUnwrap(review.window?.contentView)
        let stageDeadline = Date().addingTimeInterval(10)
        var editor: GitPatchTextView?
        while editor == nil,Date() < stageDeadline {
            editor = descendants(reviewContent).compactMap { $0 as? GitPatchTextView }.first { $0.string.contains("+SSH UI selected") && $0.apply != nil }
            RunLoop.current.run(until:Date().addingTimeInterval(0.02))
        }
        let patchView = try XCTUnwrap(editor)
        let source = patchView.string as NSString
        let left = source.range(of:"-line 4\n"),right = source.range(of:"+SSH UI selected\n")
        patchView.setSelectedRange(NSUnionRange(left,right)); patchView.applyLines()
        let indexDeadline = Date().addingTimeInterval(10)
        var indexed = ""
        while Date() < indexDeadline {
            indexed = (try? repo.run(["show",":git-hunk.txt"])) ?? ""
            if indexed.contains("SSH UI selected") { break }
            RunLoop.current.run(until:Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(indexed.contains("SSH UI selected"))
        XCTAssertFalse(indexed.contains("SSH UI unselected"))
        XCTAssertEqual(try repo.workingFilePreview("git-hunk.txt"),changed)
    }
}
