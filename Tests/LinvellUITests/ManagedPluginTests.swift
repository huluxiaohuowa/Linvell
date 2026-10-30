import XCTest
import AppKit
import LinvellPluginKit
@testable import Linvell
@testable import LinvellCore

final class ManagedPluginTests: XCTestCase {
    var root: URL!,store: PluginStore!
    override func setUpWithError() throws {
        _ = NSApplication.shared
        root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/managed-plugin-ui-tests/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        store = PluginStore(directory:root.appendingPathComponent("installed"))
    }
    override func tearDownWithError() throws { Theme.pluginTheme = nil;FileIcon.pluginIcons = nil;try FileManager.default.removeItem(at:root) }
    func fixture() throws -> InstalledPlugin {
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidate = try store.prepare(file:repo.appendingPathComponent("Examples/ResourcePack"))
        return try store.install(candidate,expectedRevision:nil)
    }
    func ready(_ predicate: @escaping () -> Bool) {
        let done = expectation(description:"managed plugin lifecycle")
        func check(_ remaining: Int) {
            if predicate() { done.fulfill() }
            else if remaining > 0 { DispatchQueue.main.asyncAfter(deadline:.now()+0.02) { check(remaining-1) } }
        }
        check(150);wait(for:[done],timeout:4)
    }
    func close(_ workspace: WorkspaceController) {
        workspace.managedPluginLoad = UUID();workspace.stopPlugins();workspace.recoveryTimer?.invalidate();workspace.window?.orderOut(nil)
        NotificationCenter.default.removeObserver(workspace)
    }
    func testInstalledPackagesRestoreAfterRestartAndPersistThemeIcons() throws {
        let record = try fixture();try store.selectTheme(plugin:record.id,id:"forest");try store.selectIcons(plugin:record.id)
        let first = WorkspaceController(pluginStore:store,managedAutoload:true);first.showWindow(nil);first.syncManagedPlugins()
        ready { first.pluginSessions[record.id] != nil && Theme.pluginTheme != nil }
        XCTAssertEqual(Theme.pluginTheme?.1.id,"forest");XCTAssertNotNil(FileIcon.pluginIcons)
        let old = try XCTUnwrap(first.pluginSessions[record.id]);close(first);XCTAssertTrue(old.isStopped)
        let restarted = WorkspaceController(pluginStore:PluginStore(directory:store.directory),managedAutoload:true);defer { close(restarted) }
        restarted.showWindow(nil);restarted.syncManagedPlugins()
        ready { restarted.pluginSessions[record.id] != nil && Theme.pluginTheme != nil }
        XCTAssertEqual(Theme.pluginTheme?.1.id,"forest")
        try store.setEnabled(record.id,false);restarted.syncManagedPlugins()
        ready { restarted.pluginSessions[record.id] == nil }
        XCTAssertNil(Theme.pluginTheme);XCTAssertNil(FileIcon.pluginIcons)
    }
    func testIndividualDisableReloadAndRemovalAffectAllWorkspaceInstances() throws {
        let record = try fixture(),a = WorkspaceController(pluginStore:store,managedAutoload:true),b = WorkspaceController(pluginStore:store,managedAutoload:true)
        defer { close(a);close(b) }
        a.showWindow(nil);b.showWindow(nil);a.syncManagedPlugins();b.syncManagedPlugins()
        ready { a.pluginSessions[record.id] != nil && b.pluginSessions[record.id] != nil }
        let prior = try XCTUnwrap(a.pluginSessions[record.id])
        NotificationCenter.default.post(name:PluginStore.willChange,object:record.id)
        XCTAssertTrue(prior.isStopped);XCTAssertNil(b.pluginSessions[record.id])
        try store.setEnabled(record.id,false);NotificationCenter.default.post(name:PluginStore.changed,object:record.id)
        ready { a.pluginSessions[record.id] == nil && b.pluginSessions[record.id] == nil }
        try store.setEnabled(record.id,true);NotificationCenter.default.post(name:PluginStore.changed,object:record.id)
        ready { a.pluginSessions[record.id] != nil && b.pluginSessions[record.id] != nil }
        XCTAssertFalse(a.pluginSessions[record.id] === prior)
        NotificationCenter.default.post(name:PluginStore.willChange,object:record.id)
        try store.uninstall(record.id,expectedRevision:record.revision);NotificationCenter.default.post(name:PluginStore.changed,object:record.id)
        ready { a.pluginSessions[record.id] == nil && b.pluginSessions[record.id] == nil }
    }
}
