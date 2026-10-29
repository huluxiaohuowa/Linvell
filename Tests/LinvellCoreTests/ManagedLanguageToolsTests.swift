import XCTest
import CryptoKit
@testable import LinvellCore

final class ManagedLanguageToolsTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
    func fixture() throws -> ([String:Any],URL) {
        let fm = FileManager.default,project = root.appendingPathComponent("project"),work = root.appendingPathComponent("payload"),package = work.appendingPathComponent("package")
        try fm.createDirectory(at:project,withIntermediateDirectories:true)
        try fm.createDirectory(at:package.appendingPathComponent("dist"),withIntermediateDirectories:true)
        try Data("// language service fixture\n".utf8).write(to:package.appendingPathComponent("dist/pyright-langserver.js"))
        let node = root.appendingPathComponent("fixture-node")
        try Data("#!/bin/sh\nprintf 'v22.23.4\\n'\n".utf8).write(to:node); try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:node.path)
        let archive = work.appendingPathComponent("pyright.tgz")
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/tar"),arguments:["-czf",archive.path,"-C",work.path,"package"],directory:nil,environment:["COPYFILE_DISABLE":"1"])
        XCTAssertTrue(result.succeeded)
        let digest = SHA256.hash(data:try Data(contentsOf:archive)).map { String(format:"%02x",$0) }.joined()
        let spec: [String:Any] = ["root":project.path,"provider":"pyright","version":"fixture","storage":"project","node":node.path,"artifacts":[["file":"pyright.tgz","kind":"npm","package":"pyright","sha256":digest]]]
        return (spec,work)
    }
    func testIgnoreRuleIsIdempotentAndDoesNotIgnoreSettings() throws {
        let ignore = root.appendingPathComponent(".gitignore"),original = "# Existing rules\nbuild/\n"
        try Data(original.utf8).write(to:ignore)
        try ManagedLanguageTools.addIgnore(remote:nil,root:root.path)
        try ManagedLanguageTools.addIgnore(remote:nil,root:root.path)
        let text = try String(contentsOf:ignore,encoding:.utf8)
        XCTAssertTrue(text.hasPrefix(original)); XCTAssertEqual(text.components(separatedBy:"/.linvell/tools/").count,2)
        XCTAssertFalse(text.contains("settings.json")); XCTAssertFalse(text.components(separatedBy:.newlines).contains(".linvell/"))
    }
    func testProjectInstallAndClearKeepSourceAndOtherLanguages() throws {
        let (spec,work) = try fixture(),project = URL(fileURLWithPath:spec["root"] as! String)
        let source = project.appendingPathComponent("main.py"); try Data("value = 1\n".utf8).write(to:source)
        let installed = try NativeToolRelay.install(spec:spec,work:work)
        XCTAssertTrue(installed.server.hasPrefix(project.path+"/.linvell/tools/pyright/"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:installed.server))
        let other = project.appendingPathComponent(".linvell/tools/unmanaged"); try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        try NativeToolRelay.remove(language:"python",root:project.path,storage:.project)
        XCTAssertFalse(FileManager.default.fileExists(atPath:installed.server))
        XCTAssertEqual(try String(contentsOf:source,encoding:.utf8),"value = 1\n"); XCTAssertTrue(FileManager.default.fileExists(atPath:other.path))
    }
    func testUserStorageRetainsFilesWhileAnotherProjectUsesThem() throws {
        var (spec,work) = try fixture(); spec["storage"] = "user"
        let home = root.appendingPathComponent("host-home"),a = spec["root"] as! String,b = root.appendingPathComponent("other-project")
        try FileManager.default.createDirectory(at:b,withIntermediateDirectories:true)
        _ = try NativeToolRelay.install(spec:spec,work:work,home:home)
        spec["root"] = b.path; _ = try NativeToolRelay.install(spec:spec,work:work,home:home)
        let folder = home.appendingPathComponent(".linvell/language-services/pyright")
        try NativeToolRelay.remove(language:"python",root:a,storage:.user,home:home)
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder.path))
        XCTAssertEqual(try NativeToolRelay.marker(folder)["projects"] as? [String],[b.path])
        try NativeToolRelay.remove(language:"python",root:b.path,storage:.user,home:home)
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:b.appendingPathComponent(".gitignore").path))
    }
    func testUnmanagedFoldersAndSymlinkTargetsArePreserved() throws {
        let project = root.appendingPathComponent("project"),folder = project.appendingPathComponent(".linvell/tools/pyright")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        XCTAssertThrowsError(try NativeToolRelay.remove(language:"python",root:project.path,storage:.project))
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder.path))
        let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        try FileManager.default.removeItem(at:project.appendingPathComponent(".linvell"))
        try FileManager.default.createSymbolicLink(at:project.appendingPathComponent(".linvell"),withDestinationURL:outside)
        XCTAssertThrowsError(try NativeToolRelay.remove(language:"python",root:project.path,storage:.project))
        XCTAssertTrue(FileManager.default.fileExists(atPath:outside.path))
    }
    func testRelayAgentUsesSameProjectRulesAndSafeClear() throws {
        let (spec,work) = try fixture()
        let bundle = work.appendingPathComponent("upload.tar")
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/tar"),arguments:["-cf",bundle.path,"-C",work.path,"pyright.tgz"],directory:nil,environment:["COPYFILE_DISABLE":"1"])
        XCTAssertTrue(result.succeeded)
        let python = try XCTUnwrap(ToolCommand.executable("python3"))
        let encoded = try JSONSerialization.data(withJSONObject:spec).base64EncodedString()
        let install = try ToolCommand.run(python,arguments:["-c",ManagedToolRelay.agent,encoded],directory:nil,inputFile:bundle)
        XCTAssertTrue(install.succeeded,install.output)
        let project = URL(fileURLWithPath:spec["root"] as! String)
        XCTAssertTrue(FileManager.default.fileExists(atPath:project.appendingPathComponent(".linvell/tools/pyright/bin/pyright-language-server").path))
        let removeSpec: [String:Any] = ["root":project.path,"provider":"pyright","storage":"project","remove":true]
        let removed = try ToolCommand.run(python,arguments:["-c",ManagedToolRelay.agent,try JSONSerialization.data(withJSONObject:removeSpec).base64EncodedString()],directory:nil)
        XCTAssertTrue(removed.succeeded,removed.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath:project.appendingPathComponent(".linvell/tools/pyright").path))
    }
    func testCancelledInstallLeavesNoRelayDownload() async throws {
        let cancelled = LanguageInstallCancellation(); cancelled.cancel()
        do {
            _ = try await ManagedLanguageTools.install(language:"python",remote:nil,root:root.path,cancel:cancelled,temporaryDirectory:root)
            XCTFail("Cancelled installation must not complete")
        } catch is CancellationError { }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix("linvell-tool-relay-") })
    }
    func testPackageSymlinkCannotEscapeManagedInstall() throws {
        let (spec,work) = try fixture()
        let package = work.appendingPathComponent("package")
        try FileManager.default.createSymbolicLink(at:package.appendingPathComponent("escape"),withDestinationURL:root)
        let archive = work.appendingPathComponent("unsafe.tgz")
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/tar"),arguments:["-czf",archive.path,"-C",work.path,"package"],directory:nil,environment:["COPYFILE_DISABLE":"1"])
        XCTAssertTrue(result.succeeded)
        XCTAssertThrowsError(try ManagedToolArchive.extract(archive,to:work.appendingPathComponent("unpacked")))
        var unsafe = spec
        unsafe["artifacts"] = [["file":"unsafe.tgz","kind":"npm","package":"pyright","sha256":SHA256.hash(data:try Data(contentsOf:archive)).map { String(format:"%02x",$0) }.joined()]]
        let upload = work.appendingPathComponent("unsafe-upload.tar")
        XCTAssertTrue(try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/tar"),arguments:["-cf",upload.path,"-C",work.path,"unsafe.tgz"],directory:nil,environment:["COPYFILE_DISABLE":"1"]).succeeded)
        let python = try XCTUnwrap(ToolCommand.executable("python3"))
        let reply = try ToolCommand.run(python,arguments:["-c",ManagedToolRelay.agent,try JSONSerialization.data(withJSONObject:unsafe).base64EncodedString()],directory:nil,inputFile:upload)
        XCTAssertFalse(reply.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath:URL(fileURLWithPath:spec["root"] as! String).appendingPathComponent(".linvell/tools/pyright").path))
    }
    func testStorageSettingsAreIndependentPerLanguage() throws {
        var python = LanguageToolchain(); python.storage = .user; python.addGitIgnore = false
        let one = try JSONCSettings(Data("{}".utf8)).updating("python",profile:python)
        let settings = try JSONCSettings(one)
        XCTAssertEqual(settings.setting("python").storage,.user); XCTAssertFalse(settings.setting("python").addGitIgnore)
        XCTAssertEqual(settings.setting("typescript").storage,.project)
    }
}
