import XCTest
import AppKit
import LinvellCore
@testable import Linvell

final class RemoteFolderSelectionTests: XCTestCase {
    func testSelectedChildAndEnteredChildChooseTheSameFolder() throws {
        _ = NSApplication.shared
        let browser = RemoteBrowser(connection:try SSHRemote(host:"example"),directoriesOnly:true,initialPath:"/projects",autoLoad:false)
        browser.entries = try JSONDecoder().decode([RemoteEntry].self,from:Data(#"[{"name":"hdl","path":"/projects/hdl","directory":true}]"#.utf8))
        browser.table.reloadData(); browser.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        XCTAssertEqual(browser.selectedDirectory,"/projects/hdl","A single selected folder is the Open target.")
        browser.directory = "/projects/hdl"; browser.entries = []; browser.table.reloadData(); browser.table.deselectAll(nil)
        XCTAssertEqual(browser.selectedDirectory,"/projects/hdl","With no selection, open the folder being browsed.")
    }
}
