import XCTest
import LinvellPluginKit
@testable import LinvellCore

final class PluginStoreTests: XCTestCase {
    var root: URL!,store: PluginStore!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/plugin-manager-tests/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        store = PluginStore(directory:root.appendingPathComponent("store"),allowLoopback:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
    func folder(_ version: String,id: String = "dev.manager") throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let manifest: [String:Any] = ["id":id,"name":"Manager Example","version":version,"protocolVersion":1,"commands":[],"permissions":["storage"],"views":[["id":"status","title":"Status","kind":"status","text":"Installed "+version]]]
        try JSONSerialization.data(withJSONObject:manifest).write(to:folder.appendingPathComponent("plugin.json"));return folder
    }
    func zip(_ folder: URL,name: String = "plugin.zip") throws -> URL {
        let archive = root.appendingPathComponent(name)
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ditto"),arguments:["-c","-k","--keepParent",folder.path,archive.path],directory:nil)
        XCTAssertTrue(result.succeeded);return archive
    }
    @discardableResult func install(_ version: String,previous: InstalledPlugin? = nil) throws -> InstalledPlugin {
        let candidate = try store.prepare(file:zip(folder(version),name:UUID().uuidString+".zip"))
        return try store.install(candidate,expectedRevision:previous?.revision)
    }
    func testInstallRestartEnableThemeAndRollback() throws {
        let first = try install("1.0.0"),second = try install("1.0.1",previous:first)
        XCTAssertEqual(try store.registry().installed.first?.version,"1.0.1")
        XCTAssertEqual(try store.package(second).manifest.id,"dev.manager")
        try store.selectTheme(plugin:first.id,id:"forest");try store.selectIcons(plugin:first.id);try store.setEnabled(first.id,false)
        let restarted = PluginStore(directory:store.directory)
        let state = try restarted.registry();XCTAssertEqual(state.themeID,"forest");XCTAssertEqual(state.iconPlugin,first.id);XCTAssertEqual(state.installed.first?.enabled,false)
        let rollback = try restarted.rollback(first.id,expectedRevision:second.revision)
        XCTAssertEqual(rollback.version,"1.0.0");XCTAssertFalse(rollback.enabled)
        XCTAssertEqual(try restarted.rollback(first.id,expectedRevision:rollback.revision).version,"1.0.1")
        try restarted.uninstall(first.id,expectedRevision:second.revision)
        XCTAssertTrue(try restarted.registry().installed.isEmpty);XCTAssertNil(try restarted.registry().themeID);XCTAssertNil(try restarted.registry().iconPlugin)
    }
    func testFailedAndStaleUpdatesKeepInstalledPackage() throws {
        let first = try install("1.0.0"),next = try store.prepare(file:folder("1.0.1"))
        let current = try store.install(next,expectedRevision:first.revision)
        XCTAssertThrowsError(try store.install(next,expectedRevision:first.revision))
        XCTAssertThrowsError(try store.uninstall(first.id,expectedRevision:first.revision))
        let corrupt = root.appendingPathComponent("bad.zip");try Data("not a zip".utf8).write(to:corrupt)
        XCTAssertThrowsError(try store.prepare(file:corrupt));XCTAssertEqual(try store.registry().installed.first,current)
        let target = store.directory.appendingPathComponent("packages/"+current.previous!+"/plugin.json")
        try Data("broken".utf8).write(to:target)
        XCTAssertThrowsError(try store.rollback(first.id,expectedRevision:current.revision));XCTAssertEqual(try store.registry().installed.first,current)
    }
    func testNativeCopyDoesNotDependOnOriginalAndRetainsOnlyRollbackCopy() throws {
        let original = try folder("1.0.0"),candidate = try store.prepare(file:original)
        try FileManager.default.removeItem(at:original)
        let first = try store.install(candidate,expectedRevision:nil),second = try install("1.0.1",previous:first),third = try install("1.0.2",previous:second)
        XCTAssertEqual(try store.package(third).manifest.version,"1.0.2")
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.directory.appendingPathComponent("packages/"+first.revision).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:store.directory.appendingPathComponent("packages/"+second.revision).path))
    }
    func testRegistryCorruptionAndSymlinkAreNotSilentlyReplaced() throws {
        let record = try install("1.0.0"),file = store.directory.appendingPathComponent("registry.json")
        let data = try Data(contentsOf:file);try Data("broken".utf8).write(to:file)
        XCTAssertThrowsError(try store.setEnabled(record.id,false));XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"broken")
        try FileManager.default.removeItem(at:file);let outside = root.appendingPathComponent("outside.json");try data.write(to:outside)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:outside)
        XCTAssertThrowsError(try store.registry());XCTAssertEqual(try Data(contentsOf:outside),data)
        let package = try folder("1.0.1");try FileManager.default.createSymbolicLink(at:package.appendingPathComponent("escape"),withDestinationURL:outside)
        XCTAssertThrowsError(try store.prepare(file:package))
    }
    func testUninstallDataCleanupIsExplicitAndIsolated() throws {
        let record = try install("1.0.0"),persistence = PluginPersistence(directory:root.appendingPathComponent("data"))
        try persistence.apply([PluginStateUpdate(scope:.global,key:"count",value:.number(7))],pluginID:record.id,workspace:nil)
        try persistence.apply([PluginStateUpdate(scope:.global,key:"other",value:.bool(true))],pluginID:"other.plugin",workspace:nil)
        let package = try store.package(record)
        try store.uninstall(record.id,expectedRevision:record.revision)
        XCTAssertEqual(try persistence.environment(package:package,workspace:nil).globalState["count"]?.number,7)
        try persistence.removeLocalData(pluginID:record.id)
        XCTAssertTrue(try persistence.environment(package:package,workspace:nil).globalState.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:persistence.directory.path).filter { $0.hasPrefix("other.plugin-") }.count,1)
    }
    func testInvalidHandshakeDoesNotCommitAnUpgrade() throws {
        let first = try install("1.0.0"),package = try folder("1.0.1"),script = package.appendingPathComponent("broken")
        try "#!/bin/sh\nexit 1\n".write(to:script,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:script.path)
        let file = package.appendingPathComponent("plugin.json");var manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any];manifest["executable"] = "broken";manifest["commands"] = [["id":"test","title":"Test"]];try JSONSerialization.data(withJSONObject:manifest).write(to:file)
        let candidate = try store.prepare(file:package)
        XCTAssertThrowsError(try PluginInstallation.checkStartup(candidate.package,workspace:nil))
        XCTAssertEqual(try store.registry().installed.first,first)
    }
    func malicious(_ body: String,name: String) throws -> URL {
        let python = try XCTUnwrap(ToolCommand.executable("python3")),out = root.appendingPathComponent(name)
        let result = try ToolCommand.run(python,arguments:["-c","import zipfile,sys,struct\np=sys.argv[1]\n"+body,out.path],directory:root)
        XCTAssertTrue(result.succeeded);return out
    }
    func testArchiveRejectsTraversalSymlinksCRCAndOversizedInflation() throws {
        let paths = try malicious("with zipfile.ZipFile(p,'w') as z:z.writestr('../escape','outside')",name:"traversal.zip")
        XCTAssertThrowsError(try store.prepare(file:paths))
        let link = try malicious("i=zipfile.ZipInfo('link');i.create_system=3;i.external_attr=(0o120777<<16)\nwith zipfile.ZipFile(p,'w') as z:z.writestr(i,'/tmp/outside')",name:"link.zip")
        XCTAssertThrowsError(try store.prepare(file:link))
        let crc = try malicious("with zipfile.ZipFile(p,'w') as z:z.writestr('plugin.json','valid payload')\nb=bytearray(open(p,'rb').read());b[41]^=1;open(p,'wb').write(b)",name:"crc.zip")
        XCTAssertThrowsError(try store.prepare(file:crc))
        let bomb = try malicious("with zipfile.ZipFile(p,'w',compression=zipfile.ZIP_DEFLATED) as z:z.writestr('plugin.json','A'*1000000)\nb=bytearray(open(p,'rb').read());i=b.index(b'PK\\x01\\x02');struct.pack_into('<I',b,22,1);struct.pack_into('<I',b,i+24,1);open(p,'wb').write(b)",name:"bomb.zip")
        XCTAssertThrowsError(try store.prepare(file:bomb))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("escape").path))
    }
    func testDeflatedArchiveAndExecutableMode() throws {
        let source = try folder("1.0.0"),archive = root.appendingPathComponent("deflated.zip"),python = try XCTUnwrap(ToolCommand.executable("python3"))
        let result = try ToolCommand.run(python,arguments:["-c","import zipfile,sys\nwith zipfile.ZipFile(sys.argv[2],'w',compression=zipfile.ZIP_DEFLATED) as z:\n z.write(sys.argv[1]+'/plugin.json','package/plugin.json')\n i=zipfile.ZipInfo('package/tool');i.external_attr=0o100755<<16;z.writestr(i,'#!/bin/sh\\nexit 0\\n')",source.path,archive.path],directory:root)
        XCTAssertTrue(result.succeeded)
        let candidate = try store.prepare(file:archive)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:candidate.package.directory.appendingPathComponent("tool").path))
    }
    func server() throws -> (Process,URL) {
        let process = Process(),pipe = Pipe();process.executableURL = try XCTUnwrap(ToolCommand.executable("python3"));process.arguments = ["-u","-c","import http.server,sys,os\nos.chdir(sys.argv[1])\nclass H(http.server.SimpleHTTPRequestHandler):\n def log_message(self,*a):pass\ns=http.server.ThreadingHTTPServer(('127.0.0.1',0),H);print(s.server_port,flush=True);s.serve_forever()",root.path];process.standardOutput = pipe;process.standardError = FileHandle.nullDevice
        try process.run();let line = pipe.fileHandleForReading.availableData;let port = try XCTUnwrap(Int(String(decoding:line,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)))
        return (process,URL(string:"http://127.0.0.1:\(port)")!)
    }
    func testURLAndSourceInstallUpdatesChecksumsAndRemoval() throws {
        let one = try zip(folder("1.0.0"),name:"one.zip"),two = try zip(folder("1.0.1"),name:"two.zip"),server = try server();defer { server.0.terminate();server.0.waitUntilExit() }
        let sourceURL = server.1.appendingPathComponent("catalog.json"),source = try store.saveSource(url:sourceURL)
        func catalog(_ archive: URL,version: String,hash: String? = nil) throws {
            let value: [String:Any] = ["schemaVersion":1,"name":"Example Source","plugins":[["id":"dev.manager","name":"Manager Example","version":version,"url":server.1.appendingPathComponent(archive.lastPathComponent).absoluteString,"sha256":try hash ?? PluginStore.digest(Data(contentsOf:archive))]]]
            try JSONSerialization.data(withJSONObject:value).write(to:root.appendingPathComponent("catalog.json"),options:.atomic)
        }
        try catalog(one,version:"1.0.0")
        let entry = try XCTUnwrap(store.catalog(source).plugins.first),candidate = try store.prepare(url:entry.url,entry:entry,sourceID:source.id)
        let first = try store.install(candidate,expectedRevision:nil)
        XCTAssertNil(try store.availableUpdate(first))
        try catalog(two,version:"1.0.1",hash:String(repeating:"0",count:64))
        XCTAssertThrowsError(try store.updateCandidate(first));XCTAssertEqual(try store.registry().installed.first,first)
        try catalog(two,version:"1.0.1")
        XCTAssertEqual(try store.availableUpdate(first),"1.0.1")
        let second = try store.install(store.updateCandidate(first),expectedRevision:first.revision)
        XCTAssertEqual(second.version,"1.0.1")
        let moved = try store.saveSource(url:sourceURL.appendingPathComponent("moved"),id:source.id);XCTAssertEqual(moved.id,source.id)
        _ = try store.saveSource(url:sourceURL,id:source.id)
        try store.removeSource(source.id);XCTAssertEqual(try store.registry().installed.first?.id,first.id);XCTAssertThrowsError(try store.updateCandidate(second))
        let restored = try store.saveSource(url:sourceURL);XCTAssertEqual(restored.id,source.id)
        XCTAssertNil(try store.availableUpdate(second))
        let direct = try store.prepare(url:server.1.appendingPathComponent("one.zip"));XCTAssertNil(direct.sourceID)
        XCTAssertThrowsError(try PluginDownloads.fetch(server.1.appendingPathComponent("one.zip"),maximum:8,allowLoopback:true))
        XCTAssertFalse(PluginDownloads.valid(server.1));XCTAssertFalse(PluginDownloads.valid(URL(string:"https://user:password@example.com/package.zip")!))
    }
}
