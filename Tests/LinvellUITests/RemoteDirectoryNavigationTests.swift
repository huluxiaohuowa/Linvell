import XCTest
import AppKit
import LinvellCore
@testable import Linvell

final class RemoteDirectoryNavigationTests: XCTestCase {
    func testCachedFolderAppearsSynchronouslyAndPreservesSelectionOnRevisit() throws {
        _ = NSApplication.shared
        let host = "cache-fixture-"+UUID().uuidString.lowercased(),remote = try SSHRemote(host:host)
        defer { RemoteDirectoryCache.shared.invalidate(host:host) }
        let reply = try JSONDecoder().decode(RemoteReply.self,from:Data(#"{"path":"/project","entries":[{"name":"hdl","path":"/project/hdl","directory":true}]}"#.utf8))
        _ = try RemoteDirectoryCache.shared.list(host:host,path:"/project") { reply }
        let browser = RemoteBrowser(connection:remote,directoriesOnly:true,initialPath:"/",autoLoad:false)
        browser.browse("/project")
        XCTAssertFalse(browser.isLoading)
        XCTAssertEqual(browser.entries.first?.name,"hdl")
        browser.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        browser.browse("/project")
        XCTAssertEqual(browser.table.selectedRow,0)
        XCTAssertEqual(browser.selectedDirectory,"/project/hdl")
        let tree = RemoteExplorer(connection:remote,path:"/project")
        XCTAssertEqual(tree.rootNode.children?.first?.name,"hdl")
        XCTAssertGreaterThanOrEqual(tree.table.row(forItem:tree.rootNode),0)
        XCTAssertGreaterThan(tree.table.row(forItem:try XCTUnwrap(tree.rootNode.children?.first)),tree.table.row(forItem:tree.rootNode))
    }
}
