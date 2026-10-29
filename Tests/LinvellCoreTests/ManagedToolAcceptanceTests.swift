import XCTest
@testable import LinvellCore

final class ManagedToolAcceptanceTests: XCTestCase {
    func testRealLocalPythonAndTypeScriptInstallStartAndClear() async throws {
        guard ProcessInfo.processInfo.environment["LINVELL_MANAGED_TOOL_ACCEPTANCE"] == "1" else { throw XCTSkip("Network installation acceptance is opt-in.") }
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        for language in ["python","typescript"] {
            let result = try await ManagedLanguageTools.install(language:language,remote:nil,root:root.path,temporaryDirectory:root)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix("linvell-tool-relay-") })
            let text = language == "python" ? "def greeting(name):\n    return name\n\ngreeting('world')\n" : "function greeting(name: string) { return name; }\ngreeting('world');\n"
            let file = root.appendingPathComponent(language == "python" ? "main.py" : "main.ts")
            try text.write(to:file,atomically:true,encoding:.utf8)
            let rpc = try LanguageRPC(executable:URL(fileURLWithPath:result.server),arguments:result.arguments,directory:root)
            let session = try LanguageSession(rpc:rpc,root:root.path,runtime:"")
            session.synchronize(uri:file.absoluteString,language:language,text:text,version:0)
            let position = CodePosition(line:language == "python" ? 3 : 1,character:3)
            var locations: [CodeLocation] = []
            let deadline = Date().addingTimeInterval(30)
            repeat {
                locations = try CodeLocation.locations(session.request("textDocument/definition",uri:file.absoluteString,position:position))
                if locations.isEmpty { try await Task.sleep(nanoseconds:300_000_000) }
            } while locations.isEmpty && Date() < deadline
            XCTAssertEqual(locations.first?.range.start.line,0,language)
            let edits = try CodeWorkspaceEdit.parse(session.request("textDocument/rename",uri:file.absoluteString,position:position,extra:["newName":"salutation"]))
            XCTAssertEqual(edits.first?.edits.count,2,language)
            rpc.stop()
            try ManagedLanguageTools.remove(language:language,remote:nil,root:root.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath:result.server)); XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
        }
    }
    func testRemoteInstallFromClientAndStartRealPythonService() async throws {
        guard ProcessInfo.processInfo.environment["LINVELL_MANAGED_TOOL_ACCEPTANCE"] == "1",let path = ProcessInfo.processInfo.environment["LINVELL_REMOTE_LANGUAGE_FIXTURE"] else { throw XCTSkip("Requires synced disposable SSH fixture.") }
        struct Fixture: Decodable { let host: String,root: String,local: String }
        let fixture = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let remote = try SSHRemote(host:fixture.host)
        let relay = URL(fileURLWithPath:fixture.local).appendingPathComponent("relay")
        try FileManager.default.createDirectory(at:relay,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:relay) }
        let result = try await ManagedLanguageTools.install(language:"python",remote:remote,root:fixture.root,temporaryDirectory:relay)
        defer { try? ManagedLanguageTools.remove(language:"python",remote:remote,root:result.root) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:relay.path).isEmpty)
        let text = "def greeting(name):\n    return name\n\ngreeting('world')\n"
        let uri = URL(fileURLWithPath:result.root+"/acceptance.py").absoluteString
        let command = "/bin/sh -c "+SSHRemote.quote("cd "+SSHRemote.quote(result.root)+" && exec "+SSHRemote.quote(result.server)+" --stdio")
        let rpc = try LanguageRPC(executable:URL(fileURLWithPath:"/usr/bin/ssh"),arguments:remote.transportArguments(command:command),directory:nil)
        defer { rpc.stop() }
        let session = try LanguageSession(rpc:rpc,root:result.root,runtime:"")
        session.synchronize(uri:uri,language:"python",text:text,version:0)
        var locations: [CodeLocation] = []
        let deadline = Date().addingTimeInterval(30)
        repeat {
            locations = try CodeLocation.locations(session.request("textDocument/definition",uri:uri,position:CodePosition(line:3,character:3)))
            if locations.isEmpty { try await Task.sleep(nanoseconds:300_000_000) }
        } while locations.isEmpty && Date() < deadline
        XCTAssertEqual(locations.first?.range.start.line,0)
        try ManagedLanguageTools.addIgnore(remote:remote,root:result.root)
        let ignore = try remote.request("read",path:result.root+"/.gitignore")
        let rules = String(decoding:Data(base64Encoded:try XCTUnwrap(ignore.content))!,as:UTF8.self)
        XCTAssertEqual(rules.components(separatedBy:"/.linvell/tools/").count,2)
    }
    func testOfficialNodeArchiveRetainsLicenseAndRuns() async throws {
        guard ProcessInfo.processInfo.environment["LINVELL_MANAGED_TOOL_ACCEPTANCE"] == "1" else { throw XCTSkip("Network installation acceptance is opt-in.") }
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let arch = try NativeToolRelay.probe(root:root.path,storage:.project).nodeArchitecture
        let name = "node-"+ManagedLanguageTools.nodeVersion+"-darwin-"+arch
        let (temporary,_) = try await URLSession.shared.download(from:URL(string:"https://nodejs.org/dist/"+ManagedLanguageTools.nodeVersion+"/"+name+".tar.gz")!)
        defer { try? FileManager.default.removeItem(at:temporary) }
        try ManagedToolArchive.extract(temporary,to:root,member:name+"/bin/node")
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("LICENSE").path))
        let result = try ToolCommand.run(root.appendingPathComponent("bin/node"),arguments:["--version"],directory:nil)
        XCTAssertTrue(result.succeeded); XCTAssertEqual(result.output,ManagedLanguageTools.nodeVersion)
    }
}
