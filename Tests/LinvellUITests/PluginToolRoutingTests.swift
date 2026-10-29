import XCTest
import AppKit
import LinvellPluginKit
@testable import Linvell
@testable import LinvellCore

final class PluginToolRoutingTests: XCTestCase {
    func testProviderOwnershipConflictMappingAndStop() throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/p45-ui-tests/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let script = directory.appendingPathComponent("tool"); try "#!/bin/sh\nexit 0\n".write(to:script,atomically:true,encoding:.utf8); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:script.path)
        var value: [String:Any] = ["id":"dev.provider","name":"Provider","version":"1","protocolVersion":1,"commands":[],"permissions":["document.read"],"languageServers":[["id":"language","title":"Language","languages":["linvell-test"],"fileExtensions":["lvt"],"program":["executable":"tool"]]],"tasks":[["id":"task","title":"Task","program":["executable":"tool"]]]]
        let file = directory.appendingPathComponent("plugin.json"); try JSONSerialization.data(withJSONObject:value).write(to:file)
        let workspace = WorkspaceController(); workspace.root = FileNode(directory)
        defer { workspace.stopPlugins(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil) }
        try workspace.installPlugin(PluginPackage(directory:directory))
        let owner = try XCTUnwrap(workspace.pluginSessions["dev.provider"])
        XCTAssertEqual(workspace.pluginLanguage(path:directory.appendingPathComponent("file.lvt").path,remote:nil,root:directory.path)?.id,"linvell-test")
        XCTAssertNil(workspace.pluginLanguage(path:"/other/file.lvt",remote:nil,root:"/other"))
        XCTAssertTrue(workspace.pluginToolOptions(owner).contains { $0.title == "Task" })
        workspace.languageServices.queue.sync { XCTAssertEqual(workspace.languageServices.pluginProviders.count,1) }
        value["id"] = "dev.conflict"; try JSONSerialization.data(withJSONObject:value).write(to:file)
        XCTAssertThrowsError(try workspace.installPlugin(PluginPackage(directory:directory)))
        workspace.stopPlugins()
        XCTAssertTrue(owner.isStopped); XCTAssertNil(workspace.pluginLanguage(path:directory.appendingPathComponent("file.lvt").path,remote:nil,root:directory.path))
        workspace.languageServices.queue.sync { XCTAssertTrue(workspace.languageServices.pluginProviders.isEmpty) }
    }
}
