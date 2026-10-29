import XCTest
import LinvellPluginKit
@testable import LinvellCore

final class PluginP3Tests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/plugin-p3-tests/"+UUID().uuidString); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
    func manifest() -> [String:Any] {
        ["id":"dev.p3","name":"P3","version":"1","protocolVersion":1,"commands":[],"permissions":[],"views":[["id":"tree","title":"Tree","kind":"tree","items":[["id":"root","title":"Root","children":[["id":"leaf","title":"Leaf"]]]]]],"configuration":["enabled":true],"settings":[["key":"enabled","title":"Enabled","kind":"boolean"]]]
    }
    func package(_ value: [String:Any]) throws -> PluginPackage { try JSONSerialization.data(withJSONObject:value).write(to:root.appendingPathComponent("plugin.json")); return try PluginPackage(directory:root) }
    func testDataOnlyPackageAndBoundedViewUpdates() throws {
        let p = try package(manifest()); XCTAssertNil(p.executableURL)
        try PluginContributions.validate([PluginViewUpdate(id:"tree",text:"Updated",items:[PluginItem(id:"new",title:"New")])],manifest:p.manifest)
        XCTAssertThrowsError(try PluginContributions.validate([PluginViewUpdate(id:"unknown",text:"wrong")],manifest:p.manifest))
        XCTAssertThrowsError(try PluginContributions.validate([PluginViewUpdate(id:"tree",items:[PluginItem(id:"a",title:"A"),PluginItem(id:"a",title:"Duplicate")])],manifest:p.manifest))
        XCTAssertThrowsError(try PluginContributions.validate([PluginViewUpdate(id:"tree",items:[PluginItem(id:"a",title:"A",command:"not.declared")])],manifest:p.manifest))
        XCTAssertThrowsError(try PluginContributions.validate([PluginViewUpdate(id:"tree",items:(0...2000).map { PluginItem(id:"n\($0)",title:"Node") })],manifest:p.manifest))
    }
    func testInvalidResourcesAndSettingsAreRejected() throws {
        var m = manifest(); m["commands"] = [["id":"missing.exe","title":"Missing"]]; XCTAssertThrowsError(try package(m))
        m = manifest(); m["configuration"] = ["enabled":"wrong"]; XCTAssertThrowsError(try package(m))
        m = manifest(); m["views"] = [["id":"list","title":"List","kind":"list","items":[["id":"root","title":"Root","children":[["id":"child","title":"Child"]]]]]]; XCTAssertThrowsError(try package(m))
        m = manifest(); m["themes"] = [["id":"broken","title":"Broken","isDark":true,"colors":["canvas":"#000000"]]]; XCTAssertThrowsError(try package(m))
        m = manifest(); m["icons"] = [["id":"escape","path":"../outside.png"]]; XCTAssertThrowsError(try package(m))
        m = manifest(); m["views"] = [["id":"status","title":"Status","kind":"status","text":String(repeating:"x",count:201)]]; XCTAssertThrowsError(try package(m))
        m = manifest(); m["icons"] = [["id":"both","path":"icon.png","symbol":"star"]]; XCTAssertThrowsError(try package(m))
    }
    func testRealPNGAndThemeResources() throws {
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertNil(try PluginPackage(directory:repo.appendingPathComponent("Examples/ResourcePack")).executableURL)
        try FileManager.default.copyItem(at:repo.appendingPathComponent("Resources/FileIcons/swift.png"),to:root.appendingPathComponent("icon.png"))
        var m = manifest(); m["icons"] = [["id":"swift","path":"icon.png","fileExtensions":["swift"]]]
        m["themes"] = [["id":"green","title":"Green","isDark":true,"colors":Dictionary(uniqueKeysWithValues:PluginContributions.colorKeys.map { ($0,"#123456") })]]
        let p = try package(m); XCTAssertEqual(try PluginContributions.iconURL(p.manifest.icons![0],directory:root).lastPathComponent,"icon.png")
        try FileManager.default.removeItem(at:root.appendingPathComponent("icon.png"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("icon.png"),withDestinationURL:repo.appendingPathComponent("Resources/FileIcons/swift.png"))
        XCTAssertThrowsError(try package(m))
    }
    func testSnippetParsingUnicodeAndTabStopUpdates() throws {
        let expanded = try PluginSnippetExpansion("🐱 ${1:name} = ${2:value}; $0")
        XCTAssertEqual(expanded.text,"🐱 name = value; "); XCTAssertEqual(expanded.stops[0],NSRange(location:3,length:4))
        var cursor = PluginSnippetCursor(stops:expanded.stops,offset:5)
        XCTAssertTrue(cursor.edit(NSRange(location:8,length:4),replacementLength:6))
        XCTAssertEqual(cursor.advance(),NSRange(location:17,length:5)); XCTAssertEqual(cursor.advance(backwards:true),NSRange(location:8,length:6))
        XCTAssertFalse(cursor.edit(NSRange(location:0,length:1),replacementLength:1))
        XCTAssertEqual(try PluginSnippetExpansion("\\$1 $HOME").text,"$1 $HOME")
        XCTAssertThrowsError(try PluginSnippetExpansion((1...32).map { "$\($0)" }.joined()))
        for invalid in ["${1:a}${1:b}","${100:bad}","${1:unterminated","${1:nested ${2:x}}"] { XCTAssertThrowsError(try PluginSnippetExpansion(invalid)) }
    }
    func testNativeSettingsSavePreservesCommentsAndDetectsExternalChanges() throws {
        let p = try package(manifest()),store = PluginPersistence(directory:root.appendingPathComponent("store"))
        let file = try store.userConfiguration(package:p)
        try "{\n // keep\n \"unrelated\": 7\n}".write(to:file,atomically:true,encoding:.utf8)
        let snapshot = try store.configurationSnapshot(package:p)
        try store.saveConfiguration(["enabled":.bool(false)],package:p,expected:snapshot)
        let text = try String(contentsOf:file,encoding:.utf8)
        XCTAssertTrue(text.contains("// keep")); XCTAssertTrue(text.contains("\"unrelated\": 7"))
        XCTAssertEqual(try store.environment(package:p,workspace:nil).configuration["enabled"],.bool(false))
        XCTAssertThrowsError(try store.saveConfiguration(["enabled":.bool(true)],package:p,expected:snapshot))
        XCTAssertThrowsError(try PluginContributions.validateSetting(.string("bad"),field:p.manifest.settings![0]))
    }
}
