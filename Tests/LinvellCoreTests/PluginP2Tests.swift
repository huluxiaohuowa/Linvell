import XCTest
import LinvellPluginKit
@testable import LinvellCore

final class PluginP2Tests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/plugin-p2-tests/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:directory) }
    func package() throws -> PluginPackage {
        try FileManager.default.copyItem(at:URL(fileURLWithPath:"/bin/cat"),to:directory.appendingPathComponent("fixture"))
        let raw = #"{"id":"dev.p2","name":"P2","version":"1","protocolVersion":1,"executable":"fixture","permissions":["storage"],"configuration":{"greeting":"default","other":true},"commands":[{"id":"p2.test","title":"Test","menu":"plugins","keybinding":"cmd+ctrl+9"}]}"#
        try raw.write(to:directory.appendingPathComponent("plugin.json"),atomically:true,encoding:.utf8)
        return try PluginPackage(directory:directory)
    }
    func testUTF16RangeTransactionsAndInvalidOffsets() throws {
        let original = "🐱 hello 中文"
        let edits = [PluginTextEdit(location:9,length:2,text:"世界"),PluginTextEdit(location:3,length:5,text:"HELLO")]
        XCTAssertEqual(try PluginEdits.apply(edits,to:original).text,"🐱 HELLO 世界")
        for values in [[PluginTextEdit(location:1,length:1,text:"")], [PluginTextEdit(location:3,length:5,text:""),PluginTextEdit(location:4,length:1,text:"")], [PluginTextEdit(location:0,length:0,text:"a"),PluginTextEdit(location:0,length:0,text:"b")], [PluginTextEdit(location:Int.max,length:1,text:"")], [PluginTextEdit(location:0,length:-1,text:"")]] {
            XCTAssertThrowsError(try PluginEdits.apply(values,to:original))
        }
        XCTAssertEqual(try PluginEdits.apply([],to:original).text,original)
    }
    func testConfigurationPrecedenceAndCommentPreservation() throws {
        let package = try package(),store = PluginPersistence(directory:directory.appendingPathComponent("store"))
        let file = try store.userConfiguration(package:package)
        try #"{"greeting":"user","userOnly":3}"#.write(to:file,atomically:true,encoding:.utf8)
        let workspace = PluginWorkspace(root:directory.appendingPathComponent("workspace").path)
        let settingsFolder = URL(fileURLWithPath:workspace.root).appendingPathComponent(".linvell")
        try FileManager.default.createDirectory(at:settingsFolder,withIntermediateDirectories:true)
        let original = "{\n  // retain this comment\n  \"unrelated\": 42,\n  \"plugins\": {\"other.plugin\": {\"x\": 1}}\n}\n"
        try original.write(to:settingsFolder.appendingPathComponent("settings.json"),atomically:true,encoding:.utf8)
        let settings = try ProjectLanguageSettings.read(root:workspace.root,remote:nil)
        _ = try settings.writePlugin("dev.p2",configuration:["greeting":"workspace"])
        XCTAssertThrowsError(try settings.writePlugin("dev.p2",configuration:["lost":true]))
        let updated = try String(contentsOf:settingsFolder.appendingPathComponent("settings.json"),encoding:.utf8)
        XCTAssertTrue(updated.contains("// retain this comment")); XCTAssertTrue(updated.contains("\"unrelated\": 42")); XCTAssertTrue(updated.contains("other.plugin"))
        let values = try store.environment(package:package,workspace:workspace).configuration
        XCTAssertEqual(values["greeting"],.string("workspace")); XCTAssertEqual(values["other"],.bool(true)); XCTAssertEqual(values["userOnly"],.number(3))
        XCTAssertEqual(try store.environment(package:package,workspace:nil).configuration["greeting"],.string("user"))
    }
    func testStateNamespacesDeletionLimitsAndCorruption() throws {
        let package = try package(),store = PluginPersistence(directory:directory.appendingPathComponent("store"))
        let a = PluginWorkspace(root:directory.appendingPathComponent("a").path),b = PluginWorkspace(root:directory.appendingPathComponent("b").path)
        try store.apply([.init(scope:.global,key:"count",value:.number(2)),.init(scope:.workspace,key:"local",value:.string("A"))],pluginID:package.manifest.id,workspace:a)
        XCTAssertEqual(try store.environment(package:package,workspace:a).workspaceState["local"],.string("A"))
        XCTAssertNil(try store.environment(package:package,workspace:b).workspaceState["local"])
        XCTAssertEqual(try store.environment(package:package,workspace:b).globalState["count"],.number(2))
        let other = PluginPersistence(directory:store.directory)
        try other.apply([.init(scope:.global,key:"other",value:.null)],pluginID:package.manifest.id,workspace:nil)
        try store.apply([.init(scope:.global,key:"count",value:nil)],pluginID:package.manifest.id,workspace:nil)
        XCTAssertNil(try store.environment(package:package,workspace:nil).globalState["count"])
        XCTAssertEqual(try store.environment(package:package,workspace:nil).globalState["other"],.null)
        XCTAssertThrowsError(try store.apply([.init(scope:.workspace,key:"x",value:.bool(true))],pluginID:package.manifest.id,workspace:nil))
        XCTAssertThrowsError(try store.apply([.init(scope:.global,key:"large",value:.string(String(repeating:"x",count:300000)))],pluginID:package.manifest.id,workspace:nil))
        XCTAssertThrowsError(try store.apply([.init(scope:.global,key:"x",value:.bool(true))],pluginID:"../outside",workspace:nil))
        var manifest = try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("plugin.json"))) as? [String:Any])
        manifest["id"] = "dev.P2"
        try JSONSerialization.data(withJSONObject:manifest).write(to:directory.appendingPathComponent("plugin.json"))
        let differentlyCased = try PluginPackage(directory:directory)
        XCTAssertTrue(try store.environment(package:differentlyCased,workspace:nil).globalState.isEmpty)
        try store.apply([.init(scope:.global,key:"other",value:.string("different plugin"))],pluginID:differentlyCased.manifest.id,workspace:nil)
        XCTAssertEqual(try store.environment(package:package,workspace:nil).globalState["other"],.null)
        let file = try store.userConfiguration(package:package).deletingLastPathComponent().appendingPathComponent("global-state.json")
        try "broken".write(to:file,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try store.apply([.init(scope:.global,key:"x",value:.bool(true))],pluginID:package.manifest.id,workspace:nil))
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"broken")
    }
    func testKeybindingValidationAndJSONValueRoundTrip() throws {
        XCTAssertEqual(try PluginKeybinding("cmd+ctrl+9"),try PluginKeybinding("CTRL+CMD+9"))
        for invalid in ["cmd+cmd+x","shift+a","cmd+","cmd+F12","cmd+unknown+x","cmd+é"] { XCTAssertThrowsError(try PluginKeybinding(invalid)) }
        let values: [String:PluginValue] = ["text":.string("中文 🐱"),"nested":.object(["items":.array([.number(2),.bool(true),.null])])]
        XCTAssertEqual(try JSONDecoder().decode([String:PluginValue].self,from:JSONEncoder().encode(values)),values)
        let updates = [PluginStateUpdate(scope:.global,key:"null",value:.null),PluginStateUpdate(scope:.global,key:"remove",value:nil)]
        let decoded = try JSONDecoder().decode([PluginStateUpdate].self,from:JSONEncoder().encode(updates))
        XCTAssertEqual(decoded[0].value,.null); XCTAssertNil(decoded[1].value)
    }
    func testConcurrentStateWritersPreserveUnrelatedKeys() throws {
        let package = try package(),root = directory.appendingPathComponent("store")
        let lock = NSLock(); var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations:20) { index in
            do { try PluginPersistence(directory:root).apply([.init(scope:.global,key:"key-\(index)",value:.number(Double(index)))],pluginID:package.manifest.id,workspace:nil) }
            catch { lock.lock(); errors.append(error); lock.unlock() }
        }
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(try PluginPersistence(directory:root).environment(package:package,workspace:nil).globalState.count,20)
    }

}
