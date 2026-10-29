import XCTest
@testable import LinvellCore

final class LanguageIndexTests: XCTestCase {
    func testHierarchicalAndWorkspaceSymbolsKeepSemanticLocations() throws {
        let range: [String:Any] = ["start":["line":4,"character":2],"end":["line":4,"character":10]]
        let nested: [[String:Any]] = [["name":"Container","kind":5,"range":range,"selectionRange":range,"children":[["name":"method","kind":6,"range":range,"selectionRange":range]]]]
        let symbols = try CodeSymbol.parse(nested,documentURI:"file:///fixture/file.swift")
        XCTAssertEqual(symbols.map(\.name),["Container","method"]); XCTAssertEqual(symbols.last?.container,"Container")
        XCTAssertEqual(symbols.last?.location.range.start.line,4)
        let item: [String:Any] = ["name":"definition","kind":12,"location":["uri":"file:///fixture/helper.py","range":range]]
        let workspace = try CodeSymbol.parse([item,item])
        XCTAssertEqual(workspace.count,1); XCTAssertEqual(workspace.first?.location.uri,"file:///fixture/helper.py")
    }
    func testProjectLanguageConfigurationMergesDottedAndLanguageScopedSettings() throws {
        let source = Data(#"{"python.analysis.typeCheckingMode":"strict","[python]":{"linvell.languageServerSettings":{"python":{"analysis":{"extraPaths":["${workspaceFolder}/src"]}}}},"editor.fontSize":16}"#.utf8)
        let settings = try JSONCSettings(source),profile = settings.setting("python")
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(profile.configurationJSON.utf8)) as? [String:Any])
        let analysis = try XCTUnwrap((config["python"] as? [String:Any])?["analysis"] as? [String:Any])
        XCTAssertEqual(analysis["typeCheckingMode"] as? String,"strict")
        XCTAssertEqual(analysis["extraPaths"] as? [String],["${workspaceFolder}/src"])
        XCTAssertNil(config["editor"])
        let roundTrip = try settings.updating("python",profile:profile)
        XCTAssertTrue(String(decoding:roundTrip,as:UTF8.self).contains("linvell.languageServerSettings"))
        XCTAssertEqual(try JSONCSettings(roundTrip).setting("python").configurationJSON,profile.configurationJSON)
    }
    func testNativeFileEventsObserveExternalEditsWithoutScanningSourceContents() throws {
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let file = root.appendingPathComponent("helper.py"),event = expectation(description:"Native file event")
        event.assertForOverFulfill = false
        let watcher = LanguageWorkspaceWatch(root:root.path) { paths,_ in if paths.contains(file.path) { event.fulfill() } }
        try "def helper(): pass\n".write(to:file,atomically:true,encoding:.utf8)
        wait(for:[event],timeout:4)
        withExtendedLifetime(watcher) {}
        try FileManager.default.removeItem(at:root)
    }
}
