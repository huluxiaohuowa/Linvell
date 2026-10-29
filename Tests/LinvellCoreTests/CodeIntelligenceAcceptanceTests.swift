import XCTest
@testable import LinvellCore

final class CodeIntelligenceAcceptanceTests: XCTestCase {
    func testRealTypeScriptIndexesClosedFilesAndSynchronizesUnsavedChanges() async throws {
        guard ProcessInfo.processInfo.environment["LINVELL_MANAGED_TOOL_ACCEPTANCE"] == "1" else { throw XCTSkip("Real language service acceptance is opt-in") }
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let helper = root.appendingPathComponent("helper.ts"),main = root.appendingPathComponent("main.ts")
        try "export function greeting(name: string) { return name; }\n".write(to:helper,atomically:true,encoding:.utf8)
        try #"{"compilerOptions":{"strict":true},"include":["*.ts"]}"#.write(to:root.appendingPathComponent("tsconfig.json"),atomically:true,encoding:.utf8)
        let original = "import { greeting } from './helper';\nconst message = greeting('world');\n"
        try original.write(to:main,atomically:true,encoding:.utf8)
        let installed = try await ManagedLanguageTools.install(language:"typescript",remote:nil,root:root.path,temporaryDirectory:root)
        let rpc = try LanguageRPC(executable:URL(fileURLWithPath:installed.server),arguments:installed.arguments,directory:root)
        defer { rpc.stop() }
        let session = try LanguageSession(rpc:rpc,root:root.path,runtime:"")
        session.synchronize(uri:main.absoluteString,language:"typescript",text:original,version:0)
        let position = CodePosition(line:1,character:20)
        var locations: [CodeLocation] = []
        let deadline = Date().addingTimeInterval(20)
        repeat {
            locations = try CodeLocation.locations(session.request("textDocument/definition",uri:main.absoluteString,position:position))
            if locations.first?.uri != helper.absoluteString { try await Task.sleep(nanoseconds:300_000_000) }
        } while locations.first?.uri != helper.absoluteString && Date() < deadline
        XCTAssertEqual(locations.first?.uri,helper.absoluteString,"Definition must reach a file that was never opened")
        let symbols = try CodeSymbol.parse(rpc.request("workspace/symbol",params:["query":"greet"]))
        XCTAssertTrue(symbols.contains { $0.name == "greeting" && $0.location.uri == helper.absoluteString })
        let updated = original.replacingOccurrences(of:"const message",with:"const translatedMessage")
        session.synchronize(uri:main.absoluteString,language:"typescript",text:updated,version:1)
        let hover = try session.request("textDocument/hover",uri:main.absoluteString,position:CodePosition(line:1,character:11))
        XCTAssertTrue(String(describing:hover).contains("translatedMessage"),"The service must index the unsaved incremental version")
        // Like VS Code, navigate to the exported definition before renaming it; an import alias has its own scope.
        session.synchronize(uri:helper.absoluteString,language:"typescript",text:try String(contentsOf:helper,encoding:.utf8),version:0)
        let edits = try CodeWorkspaceEdit.parse(session.request("textDocument/rename",uri:helper.absoluteString,position:CodePosition(line:0,character:20),extra:["newName":"salutation"]))
        XCTAssertTrue(edits.contains { $0.uri == helper.absoluteString }); XCTAssertTrue(edits.contains { $0.uri == main.absoluteString })
        let documentSymbols = try CodeSymbol.parse(session.request("textDocument/documentSymbol",uri:main.absoluteString,position:CodePosition(line:0,character:0)),documentURI:main.absoluteString)
        XCTAssertTrue(documentSymbols.contains { $0.name == "translatedMessage" })
    }
    func testRemoteMetadataAndProjectToolsUseTargetFolder() throws {
        guard let file = ProcessInfo.processInfo.environment["LINVELL_REMOTE_LANGUAGE_FIXTURE"] else { throw XCTSkip("Requires explicitly synced SSH fixture") }
        struct Fixture: Decodable { let host: String,root: String }
        let fixture = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:file)))
        let remote = try SSHRemote(host:fixture.host)
        let first = try remote.request("language-file-states",path:fixture.root)
        let states = try XCTUnwrap(first.fileStates)
        let cached = try remote.request("language-file-states",path:fixture.root,digest:first.digest)
        XCTAssertEqual(cached.digest,first.digest); XCTAssertNil(cached.fileStates,"An unchanged project must not retransmit its source index")
        XCTAssertTrue(states.keys.contains { $0.hasSuffix("/fixture_lsp.py") })
        XCTAssertFalse(states.keys.contains { $0.contains("/.linvell/tools/") })
        let reports = try XCTUnwrap(remote.request("project-tools",path:fixture.root,content:Data("3".utf8)).reports)
        XCTAssertTrue(reports.contains { $0.first == "System" })
        XCTAssertTrue(reports.contains { $0.first == "Project volume" })
    }
}
