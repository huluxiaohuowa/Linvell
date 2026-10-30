import XCTest
@testable import LinvellCore

final class UpdateInstallationSourceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
    private func fixture(tap: String = "huluxiaohuowa/tap") throws -> (URL,URL) {
        let prefix = root.appendingPathComponent("brew"),app = root.appendingPathComponent("custom-apps/Linvell.app")
        let cask = prefix.appendingPathComponent("Caskroom/linvell"),version = cask.appendingPathComponent("0.2.0")
        try FileManager.default.createDirectory(at:app,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:version,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:version.appendingPathComponent("Linvell.app"),withDestinationURL:app)
        try FileManager.default.createDirectory(at:cask.appendingPathComponent(".metadata"),withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:["source":["tap":tap]]).write(to:cask.appendingPathComponent(".metadata/INSTALL_RECEIPT.json"))
        return (prefix,app)
    }
    func testCustomAppDirectoryUsesActualCaskArtifactAndTapReceipt() throws {
        let (prefix,app) = try fixture()
        let source = UpdateInstallationSource.detect(application:app,prefixes:[prefix])
        XCTAssertEqual(source,.homebrew(tap:"huluxiaohuowa/tap"))
        XCTAssertFalse(source.supportsSelfUpdates)
        XCTAssertEqual(source.upgradeCommand,"brew upgrade --cask huluxiaohuowa/tap/linvell")
        XCTAssertEqual(source.metadataURL?.host,"raw.githubusercontent.com")
        XCTAssertEqual(UpdateInstallationSource.detect(application:prefix.appendingPathComponent("Caskroom/linvell/0.2.0/Linvell.app"),prefixes:[prefix]),source)
    }
    func testManualCopyDoesNotInheritAnotherAppsHomebrewSource() throws {
        let (prefix,_) = try fixture()
        let manual = root.appendingPathComponent("manual/Linvell.app")
        try FileManager.default.createDirectory(at:manual,withIntermediateDirectories:true)
        XCTAssertEqual(UpdateInstallationSource.detect(application:manual,prefixes:[prefix]),.direct)
        XCTAssertTrue(UpdateInstallationSource.direct.supportsSelfUpdates)
        XCTAssertNil(UpdateInstallationSource.direct.upgradeCommand)
    }
    func testOfficialCaskUsesOfficialApi() throws {
        let (prefix,app) = try fixture(tap:"homebrew/cask")
        let source = UpdateInstallationSource.detect(application:app,prefixes:[prefix])
        XCTAssertEqual(source.upgradeCommand,"brew upgrade --cask linvell")
        XCTAssertEqual(source.metadataURL?.absoluteString,"https://formulae.brew.sh/api/cask/linvell.json")
        XCTAssertEqual(source.availableVersion(in:Data(#"{"version":"0.2.3"}"#.utf8)),"0.2.3")
        XCTAssertNil(source.availableVersion(in:Data(#"{"version":"latest"}"#.utf8)))
    }
    func testMissingOrUntrustedReceiptKeepsManagedAppProtected() throws {
        let (prefix,app) = try fixture(tap:"bad/tap; echo unsafe")
        let receipt = prefix.appendingPathComponent("Caskroom/linvell/.metadata/INSTALL_RECEIPT.json")
        for remove in [false,true] {
            if remove { try FileManager.default.removeItem(at:receipt) }
            let source = UpdateInstallationSource.detect(application:app,prefixes:[prefix])
            XCTAssertEqual(source,.homebrew(tap:nil)); XCTAssertFalse(source.supportsSelfUpdates)
            XCTAssertEqual(source.upgradeCommand,"brew upgrade --cask linvell"); XCTAssertNil(source.metadataURL)
        }
    }
    func testTapMetadataAcceptsOnlyStableVersionWithoutExecutingRuby() {
        let source = UpdateInstallationSource.homebrew(tap:"huluxiaohuowa/tap")
        XCTAssertEqual(source.availableVersion(in:Data("cask \"linvell\" do\n  version \"0.2.3\"\nend\n".utf8)),"0.2.3")
        for text in ["version :latest","version \"0.2.3-beta\"","version ENV.fetch('VERSION')","", "version \"0.02.3\""] {
            XCTAssertNil(source.availableVersion(in:Data(text.utf8)))
        }
    }
    func testUnknownTapStaysManagedWithoutFetchingAnUntrustedEndpoint() throws {
        let (prefix,app) = try fixture(tap:"example/tools")
        let source = UpdateInstallationSource.detect(application:app,prefixes:[prefix])
        XCTAssertFalse(source.supportsSelfUpdates); XCTAssertNil(source.metadataURL)
        XCTAssertEqual(source.upgradeCommand,"brew upgrade --cask example/tools/linvell")
    }
}
