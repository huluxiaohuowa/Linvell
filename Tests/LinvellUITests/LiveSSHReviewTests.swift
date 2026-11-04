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
    }
}
