import XCTest
import AppKit
import LinvellCore
@testable import Linvell

final class RemoteTreeTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while !condition(),Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.05)) }
        return condition()
    }
    func testRemoteProjectExpandsNestedFoldersAndRestoresItsRoot() throws {
        guard let file = ProcessInfo.processInfo.environment["LINVELL_SSH_FIXTURE"] else { throw XCTSkip("A disposable SSH fixture was not selected.") }
        _ = NSApplication.shared
        let object = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as! [String:String]
        let remote = try SSHRemote(host:try XCTUnwrap(object["host"])),root = try XCTUnwrap(object["root"])
        let browser = RemoteExplorer(connection:remote,path:root)
        XCTAssertTrue(waitUntil { browser.rootNode.children != nil })
        let nested = try XCTUnwrap(browser.rootNode.children?.first { $0.name == "nested" })
        browser.table.expandItem(nested)
        XCTAssertTrue(waitUntil { nested.children != nil })
        let child = try XCTUnwrap(nested.children?.first { $0.name == "child" })
        browser.table.expandItem(child)
        XCTAssertTrue(waitUntil { child.children?.contains { $0.name == "note.md" } == true })
        XCTAssertEqual(browser.directory,root,"Expanding a child must keep the selected project root.")
        XCTAssertGreaterThan(browser.table.row(forItem:child),browser.table.row(forItem:nested))
        let defaults = UserDefaults.standard,keys = [WorkspaceSession.key,WorkspaceSession.startupKey,"lastProject"]
        let saved = keys.map { defaults.object(forKey:$0) }
        let workspace = WorkspaceController()
        defer {
            workspace.window?.orderOut(nil); workspace.recoveryTimer?.invalidate()
            for (key,value) in zip(keys,saved) { defaults.set(value,forKey:key) }
        }
        WorkspaceSession.save(.ssh(host:remote.host,path:root)); defaults.set("restore",forKey:WorkspaceSession.startupKey)
        workspace.restore(recoverDrafts:false)
        XCTAssertTrue(waitUntil { workspace.remoteBrowser?.rootNode.children != nil })
        XCTAssertEqual(workspace.remoteDirectory,root); XCTAssertNil(workspace.root)
        XCTAssertEqual(WorkspaceSession.load(),.ssh(host:remote.host,path:root))
    }
}
