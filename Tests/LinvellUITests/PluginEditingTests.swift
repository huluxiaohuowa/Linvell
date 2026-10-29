import XCTest
import AppKit
import LinvellPluginKit
@testable import Linvell
@testable import LinvellCore

final class PluginEditingTests: XCTestCase {
    func testPluginEditIsUndoableAndRejectsStaleResult() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceController(),document = OpenDocument(DocumentBuffer(text:"hello 🐱"))
        defer { workspace.stopPlugins(); workspace.resetLanguageServices(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil) }
        workspace.documents = [document]; workspace.activate(document)
        let pane = try XCTUnwrap(workspace.activePane),revision = document.buffer.revision
        try workspace.applyPluginReplacement("HELLO 🐱",document:document,pane:pane,revision:revision,original:"hello 🐱")
        XCTAssertEqual(pane.textView.string,"HELLO 🐱")
        pane.textView.undoManager?.undo()
        XCTAssertEqual(pane.textView.string,"hello 🐱")
        XCTAssertThrowsError(try workspace.applyPluginReplacement("lost",document:document,pane:pane,revision:revision,original:"hello 🐱"))
        XCTAssertEqual(pane.textView.string,"hello 🐱")
        workspace.current = nil
        XCTAssertThrowsError(try workspace.applyPluginReplacement("lost",document:document,pane:pane,revision:document.buffer.revision,original:pane.textView.string))
    }
    func testRangeEditsUseOneUndoTransaction() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceController(),document = OpenDocument(DocumentBuffer(text:"hello 中文 🐱"))
        defer { workspace.stopPlugins(); workspace.resetLanguageServices(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil) }
        workspace.documents = [document]; workspace.activate(document)
        let pane = try XCTUnwrap(workspace.activePane),revision = document.buffer.revision
        try workspace.applyPluginEdits([PluginTextEdit(location:0,length:5,text:"HI"),PluginTextEdit(location:6,length:2,text:"世界")],document:document,pane:pane,revision:revision,original:document.buffer.text)
        XCTAssertEqual(pane.textView.string,"HI 世界 🐱")
        pane.textView.undoManager?.undo(); XCTAssertEqual(pane.textView.string,"hello 中文 🐱")
        XCTAssertThrowsError(try workspace.applyPluginEdits([PluginTextEdit(location:0,length:1,text:"")],document:document,pane:pane,revision:revision,original:document.buffer.text))
    }
    func testMenuConflictsAndUnloadingContributions() throws {
        _ = NSApplication.shared
        let savedMenu = NSApp.mainMenu,workspace = WorkspaceController()
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/plugin-menu-tests/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { workspace.stopPlugins(); workspace.resetLanguageServices(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil); NSApp.mainMenu = savedMenu; try? FileManager.default.removeItem(at:root) }
        let bar = NSMenu(); NSApp.mainMenu = bar; PluginMenus.install(in:bar)
        workspace.showWindow(nil); workspace.window?.makeKeyAndOrderFront(nil)
        func package(_ id: String,key: String) throws -> PluginPackage {
            let folder = root.appendingPathComponent(id); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:URL(fileURLWithPath:"/bin/cat"),to:folder.appendingPathComponent("fixture"))
            let value: [String:Any] = ["id":id,"name":id,"version":"1","protocolVersion":1,"executable":"fixture","permissions":[],"commands":[["id":"test","title":"Test Menu","menu":"plugins","keybinding":key]]]
            try JSONSerialization.data(withJSONObject:value).write(to:folder.appendingPathComponent("plugin.json"))
            return try PluginPackage(directory:folder)
        }
        let store = PluginPersistence(directory:root.appendingPathComponent("state"))
        try workspace.installPlugin(package("dev.first",key:"cmd+ctrl+9"),persistence:store)
        XCTAssertEqual(workspace.pluginSessions.count,1)
        PluginMenus.refresh(workspace:workspace)
        XCTAssertEqual(bar.items.first?.submenu?.items.last?.title,"dev.first")
        XCTAssertThrowsError(try workspace.installPlugin(package("dev.second",key:"cmd+ctrl+9"),persistence:store))
        XCTAssertThrowsError(try workspace.installPlugin(package("dev.reserved",key:"cmd+c"),persistence:store))
        XCTAssertEqual(workspace.pluginSessions.count,1)
        workspace.stopPlugins()
        XCTAssertEqual(bar.items.first?.submenu?.items.count,2)
        XCTAssertTrue(workspace.pluginSessions.isEmpty)
    }

}
