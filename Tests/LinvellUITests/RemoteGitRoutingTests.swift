import XCTest
import AppKit
@testable import Linvell
@testable import LinvellCore

final class RemoteGitRoutingTests: XCTestCase {
    func testGitButtonUsesRemoteRepositoryWithoutOpeningFolderPicker() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceController()
        defer { workspace.window?.orderOut(nil); workspace.recoveryTimer?.invalidate() }
        workspace.remoteConnection = try SSHRemote(host:"example"); workspace.remoteDirectory = "/example/project"
        workspace.gitRepositoryFactory = { remote,path in
            GitRepository(directory:path,remote:remote) { path,args,_,_ in
                if args.first == "rev-parse" { return path+"\n" }
                if args.first == "status" { return " M source.swift\0" }
                if args.first == "branch" { return "main\n" }
                if args.first == "log" { return String(repeating:"a",count:40)+"\0\0Demo\02026-10-28\0Initial commit\0HEAD -> main\0\n" }
                if args.first == "show" { return "diff --git a/source.swift b/source.swift\n+fixture\n" }
                return ""
            }
        }
        workspace.gitWorkspace()
        let git = try XCTUnwrap(workspace.editors.arrangedSubviews.first as? GitWorkspace)
        XCTAssertEqual(git.repository.remote?.host,"example")
        XCTAssertNil(workspace.remoteFolderPicker); XCTAssertNil(workspace.window?.attachedSheet)
        XCTAssertEqual(workspace.activeActivity,2)
        let deadline = Date().addingTimeInterval(5)
        while git.changes.isEmpty,Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(git.changes.first?.path,"source.swift")
        XCTAssertEqual(git.commits.first?.subject,"Initial commit")
    }
}
