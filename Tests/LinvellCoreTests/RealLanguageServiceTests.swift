import XCTest
@testable import LinvellCore

final class RealLanguageServiceTests: XCTestCase {
    func testClangdUsesScopeForDefinitionReferencesHoverCompletionAndRename() throws {
        guard ProcessInfo.processInfo.environment["LINVELL_REAL_LANGUAGE_SERVICES"] == "1" else { throw XCTSkip("Real toolchain acceptance is opt-in.") }
        guard let clangd = ToolCommand.executable("clangd") else { throw XCTSkip("clangd not installed") }
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let path = root.appendingPathComponent("scope.c"),uri = path.absoluteString
        let text = "int total = 10;\nint compute(int value) { int total = value; return total + 1; }\nint main(void) { return compute(total); }\n"
        try text.write(to:path,atomically:true,encoding:.utf8)
        let rpc = try LanguageRPC(executable:clangd,arguments:["--background-index=false","--log=error"],directory:root); defer { rpc.stop() }
        let session = try LanguageSession(rpc:rpc,root:root.path,runtime:"")
        session.synchronize(uri:uri,language:"c",text:text,version:0)
        let local = CodePosition(offset:(text as NSString).range(of:"return total").location+8,in:text)
        let definitions = try CodeLocation.locations(session.request("textDocument/definition",uri:uri,position:local))
        XCTAssertEqual(definitions.first?.range.start.line,1)
        let references = try CodeLocation.locations(session.request("textDocument/references",uri:uri,position:local,extra:["context":["includeDeclaration":true]]))
        XCTAssertEqual(references.count,2)
        let hover = try session.request("textDocument/hover",uri:uri,position:local)
        XCTAssertFalse(hover is NSNull)
        let edits = try CodeWorkspaceEdit.parse(session.request("textDocument/rename",uri:uri,position:local,extra:["newName":"localTotal"]))
        let updated = try CodeTextEdit.applying(try XCTUnwrap(edits.first).edits,to:text)
        XCTAssertTrue(updated.contains("int total = 10;"))
        XCTAssertTrue(updated.contains("int localTotal = value; return localTotal + 1;"))
        XCTAssertTrue(updated.contains("compute(total)"))
        let completion = try session.request("textDocument/completion",uri:uri,position:CodePosition(offset:(text as NSString).range(of:"compute(total)").location+3,in:text))
        let items = completion as? [[String:Any]] ?? (completion as? [String:Any])?["items"] as? [[String:Any]] ?? []
        XCTAssertTrue(items.contains { ($0["label"] as? String)?.contains("compute") == true })
    }
    func testSourceKitSwiftCrossFileDefinitionAndRename() throws {
        guard ProcessInfo.processInfo.environment["LINVELL_REAL_LANGUAGE_SERVICES"] == "1" else { throw XCTSkip("Real toolchain acceptance is opt-in.") }
        let found = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/xcrun"),arguments:["--find","sourcekit-lsp"],directory:nil)
        guard found.succeeded else { throw XCTSkip("SourceKit unavailable") }
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Sources/Probe")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Probe\", targets: [.executableTarget(name: \"Probe\")])\n".write(to:root.appendingPathComponent("Package.swift"),atomically:true,encoding:.utf8)
        let helper = source.appendingPathComponent("Helper.swift"),main = source.appendingPathComponent("main.swift")
        let definition = "func greeting(_ name: String) -> String { name }\n",call = "print(greeting(\"World\"))\n"
        try definition.write(to:helper,atomically:true,encoding:.utf8); try call.write(to:main,atomically:true,encoding:.utf8)
        let rpc = try LanguageRPC(executable:URL(fileURLWithPath:found.output),arguments:["--scratch-path",root.appendingPathComponent("build").path],directory:root); defer { rpc.stop() }
        let session = try LanguageSession(rpc:rpc,root:root.path,runtime:"")
        session.synchronize(uri:helper.absoluteString,language:"swift",text:definition,version:0)
        session.synchronize(uri:main.absoluteString,language:"swift",text:call,version:0)
        let position = CodePosition(line:0,character:8)
        var locations: [CodeLocation] = []
        let deadline = Date().addingTimeInterval(25)
        repeat {
            locations = try CodeLocation.locations(session.request("textDocument/definition",uri:main.absoluteString,position:position))
            if locations.isEmpty { Thread.sleep(forTimeInterval:0.5) }
        } while locations.isEmpty && Date() < deadline
        XCTAssertEqual(locations.first.flatMap { URL(string:$0.uri)?.resolvingSymlinksInPath() },helper.resolvingSymlinksInPath())
        _ = try rpc.request("workspace/synchronize",params:["index":true],timeout:60)
        let edit = try session.request("textDocument/rename",uri:main.absoluteString,position:position,extra:["newName":"salutation"])
        let plans = try CodeWorkspaceEdit.parse(edit)
        for plan in plans { print("Swift rename fixture:",URL(string:plan.uri)?.lastPathComponent ?? "?",plan.edits.count) }
        XCTAssertEqual(plans.count,2)
        XCTAssertTrue(plans.allSatisfy { !$0.edits.isEmpty })
    }

}
