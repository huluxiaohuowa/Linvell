import XCTest
@testable import LinvellCore

final class ProjectLanguageSettingsTests: XCTestCase {
    func testPerLanguageJSONCPreservesCommentsAndOtherSettings() throws {
        let original = Data("""
        {
          // keep this workspace note
          "editor.tabSize": 2,
          "[python]": {
            // keep this interpreter comment
            "linvell.interpreterPath": "old-python",
            "unrelated.option": true,
          },
        }
        """.utf8)
        var python = LanguageToolchain(); python.runtime = "${workspaceFolder}/.venv/bin/python"; python.server = "/tools/pylsp"
        let first = try JSONCSettings(original).updating("python",profile:python)
        var swift = LanguageToolchain(); swift.runtime = "/tools/swift"; swift.server = "/tools/sourcekit-lsp"
        let both = try JSONCSettings(first).updating("swift",profile:swift),settings = try JSONCSettings(both)
        XCTAssertEqual(settings.setting("python").runtime,python.runtime)
        XCTAssertEqual(settings.setting("swift").runtime,swift.runtime)
        XCTAssertEqual(settings.values["editor.tabSize"] as? Int,2)
        XCTAssertEqual((settings.values["[python]"] as? [String:Any])?["unrelated.option"] as? Bool,true)
        let rendered = String(decoding:both,as:UTF8.self)
        XCTAssertTrue(rendered.contains("// keep this workspace note")); XCTAssertTrue(rendered.contains("// keep this interpreter comment"))
        XCTAssertThrowsError(try JSONCSettings(Data(#"{"[python]":1}"#.utf8)).updating("python",profile:python))
        XCTAssertThrowsError(try JSONCSettings(Data("{/* unfinished".utf8)))
        XCTAssertThrowsError(try JSONCSettings(Data(#"{"x":1,"x":2}"#.utf8)))
    }
    func testProjectFilesAreIndependentAndConcurrentChangesAreNotOverwritten() throws {
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let original = try ProjectLanguageSettings.read(root:root.path,remote:nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent(".linvell").path))
        var profile = LanguageToolchain(); profile.runtime = "/tools/python3"; profile.server = "/tools/pylsp"
        let saved = try original.write(language:"python",profile:profile)
        XCTAssertEqual(try JSONCSettings(saved.data).setting("python").runtime,profile.runtime)
        XCTAssertThrowsError(try original.write(language:"swift",profile:LanguageToolchain()))
        profile.runtime = "/tools/swift"; profile.server = "/tools/sourcekit-lsp"
        let combined = try saved.write(language:"swift",profile:profile)
        XCTAssertEqual(try JSONCSettings(combined.data).setting("python").runtime,"/tools/python3")
        XCTAssertEqual(try JSONCSettings(combined.data).setting("swift").runtime,"/tools/swift")
    }
    func testRemoteSettingsProtocolUsesProjectRootAndDigestChecks() throws {
        guard let python = ToolCommand.executable("python3") else { throw XCTSkip("Python fixture runtime unavailable") }
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        func request(_ operation: String,content: Data? = nil,digest: String? = nil) throws -> RemoteReply {
            var object: [String:String] = ["operation":operation,"path":root.path]
            object["content"] = content?.base64EncodedString(); object["digest"] = digest
            let result = try ToolCommand.run(python,arguments:["-c",SSHRemote.agent],directory:root,input:JSONSerialization.data(withJSONObject:object))
            let line = try XCTUnwrap(result.output.components(separatedBy:"\n").last { $0.hasPrefix("LINVELL_JSON:") })
            return try JSONDecoder().decode(RemoteReply.self,from:Data(line.dropFirst(13).utf8))
        }
        let first = try request("settings-read"); XCTAssertEqual(first.digest,"missing")
        var profile = LanguageToolchain(); profile.runtime = "${workspaceFolder}/.venv/bin/python"
        let content = try JSONCSettings(Data("{}".utf8)).updating("python",profile:profile)
        let written = try request("settings-write",content:content,digest:first.digest)
        XCTAssertNil(written.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent(".linvell/settings.json").path))
        XCTAssertNotNil(try request("settings-write",content:Data("{}".utf8),digest:"missing").error)
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(".linvell/settings.json")),content)
    }
}
