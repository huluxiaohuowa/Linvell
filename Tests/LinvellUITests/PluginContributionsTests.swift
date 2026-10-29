import XCTest
import AppKit
import LinvellPluginKit
@testable import Linvell
@testable import LinvellCore

final class PluginContributionsTests: XCTestCase {
    var workspace: WorkspaceController!
    var root: URL!
    override func setUpWithError() throws {
        _ = NSApplication.shared; workspace = WorkspaceController()
        root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/plugin-p3-ui-tests/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws {
        workspace.stopPlugins(); workspace.resetLanguageServices(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil); Theme.pluginTheme = nil; FileIcon.pluginIcons = nil
        try FileManager.default.removeItem(at:root)
    }
    func package() throws -> PluginPackage {
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:repo.appendingPathComponent("Examples/HelloPlugin/plugin.json"))) as? [String:Any])
        manifest.removeValue(forKey:"events"); manifest.removeValue(forKey:"executable"); manifest["commands"] = []
        manifest["views"] = [["id":"tree","title":"Native Tree","kind":"tree","items":[["id":"root","title":"Root","children":[["id":"child","title":"Child","icon":"spark"]]]]],["id":"list","title":"Native List","kind":"list","items":[["id":"one","title":"One"]]],["id":"settings","title":"Native Tools","kind":"panel","text":"Native body"],["id":"status","title":"Status","kind":"status","text":"Ready"]]
        try JSONSerialization.data(withJSONObject:manifest).write(to:root.appendingPathComponent("plugin.json"))
        return try PluginPackage(directory:root)
    }
    func testNativeViewsPreserveSelectionAndCleanUpOnStop() throws {
        try workspace.installPlugin(package(),persistence:PluginPersistence(directory:root.appendingPathComponent("state")))
        let session = try XCTUnwrap(workspace.pluginSessions.values.first)
        workspace.showPluginView("tree",session:session)
        let key = workspace.pluginViewKey(session,"tree"),view = try XCTUnwrap(workspace.pluginDataViews[key]),outline = try XCTUnwrap(view.table as? NSOutlineView)
        outline.expandItem(outline.item(atRow:0)); outline.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        workspace.showWindow(nil)
        workspace.receivePluginViews([PluginViewUpdate(id:"tree",text:"Refreshed",items:[PluginItem(id:"root",title:"Root",children:[PluginItem(id:"child",title:"Updated")])])],session:session)
        XCTAssertEqual(outline.numberOfRows,2); XCTAssertEqual(outline.selectedRow,1)
        workspace.showPluginView("list",session:session); XCTAssertFalse(try XCTUnwrap(workspace.pluginDataViews[workspace.pluginViewKey(session,"list")]).table is NSOutlineView)
        workspace.showPluginView("settings",session:session); XCTAssertEqual(workspace.pluginWindows.count,1)
        workspace.openPluginSettings(session); XCTAssertEqual(workspace.pluginWindows.count,2)
        XCTAssertEqual(workspace.pluginStatusBar.arrangedSubviews.count,1)
        workspace.stopPlugins(); XCTAssertTrue(workspace.pluginWindows.isEmpty); XCTAssertTrue(workspace.pluginDataViews.isEmpty); XCTAssertTrue(workspace.pluginStatusBar.arrangedSubviews.isEmpty); XCTAssertEqual(workspace.sidebarKind,"files")
    }
    func testResourceThemeIconsSnippetAndUnloadRestoration() throws {
        try workspace.installPlugin(package(),persistence:PluginPersistence(directory:root.appendingPathComponent("state")))
        let session = try XCTUnwrap(workspace.pluginSessions.values.first)
        workspace.selectPluginTheme("forest",session:session); XCTAssertEqual(Theme.pluginTheme?.1.title,"Plugin Forest"); XCTAssertTrue(Theme.isDark); XCTAssertEqual(Theme.palette[0],0x10241E)
        workspace.selectPluginIcons(session); XCTAssertNotNil(FileIcon.pluginIcons?.1["swift"])
        let file = root.appendingPathComponent("main.swift"); try "".write(to:file,atomically:true,encoding:.utf8)
        let doc = OpenDocument(try DocumentBuffer(url:file))
        workspace.documents = [doc]; workspace.activate(doc); workspace.insertPluginSnippet("greeting",session:session)
        let editor = try XCTUnwrap(workspace.activePane?.textView)
        XCTAssertTrue(editor.string.contains("func greet")); XCTAssertEqual((editor.string as NSString).substring(with:editor.selectedRange()),"greet")
        XCTAssertNotNil(editor.pluginSnippet); editor.undoManager?.undo(); XCTAssertEqual(editor.string,"")
        workspace.stopPlugins(); XCTAssertNil(Theme.pluginTheme); XCTAssertNil(FileIcon.pluginIcons); XCTAssertNil(editor.pluginSnippet)
    }
    func testSnippetTypingMovesRemainingTabStops() throws {
        try workspace.installPlugin(package(),persistence:PluginPersistence(directory:root.appendingPathComponent("state")))
        let session = try XCTUnwrap(workspace.pluginSessions.values.first),file = root.appendingPathComponent("main.swift")
        try "".write(to:file,atomically:true,encoding:.utf8)
        let doc = OpenDocument(try DocumentBuffer(url:file)); workspace.documents = [doc]; workspace.activate(doc)
        workspace.insertPluginSnippet("greeting",session:session)
        let editor = try XCTUnwrap(workspace.activePane?.textView); editor.vimEnabled = false
        editor.insertText("welcome",replacementRange:NSRange(location:NSNotFound,length:0))
        XCTAssertTrue(editor.string.contains("func welcome"))
        let tab = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,characters:"\t",charactersIgnoringModifiers:"\t",isARepeat:false,keyCode:48))
        editor.keyDown(with:tab)
        XCTAssertEqual((editor.string as NSString).substring(with:editor.selectedRange()),"Hello")
        editor.insertText("Hi",replacementRange:NSRange(location:NSNotFound,length:0)); editor.keyDown(with:tab)
        XCTAssertNil(editor.pluginSnippet); XCTAssertEqual(editor.selectedRange().location,editor.string.utf16.count)
    }

    func testNativeSettingsFormRendersAndSavesUserScope() throws {
        let store = PluginPersistence(directory:root.appendingPathComponent("state"))
        try workspace.installPlugin(package(),persistence:store)
        let session = try XCTUnwrap(workspace.pluginSessions.values.first),controller = PluginSettingsWindow(owner:workspace,session:session)
        defer { controller.close() }
        let ready = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in controller.form.arrangedSubviews.count == 5 },object:nil)
        wait(for:[ready],timeout:3)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.form.fittingSize.height,0)
        let row = try XCTUnwrap(controller.form.arrangedSubviews.first as? NSStackView)
        let input = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? NSTextField }.first(where:{ $0.isEditable }))
        input.stringValue = "Saved by native form"; controller.saveSettings()
        let saved = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in
            (try? store.environment(package:session.package,workspace:nil).configuration["greeting"]) == .string("Saved by native form")
        },object:nil)
        wait(for:[saved],timeout:3)
    }

}
