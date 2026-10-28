import XCTest
@testable import LinvellCore

final class RollbackArchiveTests: XCTestCase {
    func testMigrationRetainsNewestOlderVersionAndLeavesInFlightVersionAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        func app(_ name: String,_ version: String) throws -> URL {
            let path = root.appendingPathComponent(name+".app")
            try FileManager.default.createDirectory(at:path.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
            try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"top.fuluwa.linvell","LinvellReleaseVersion":version],format:.xml,options:0).write(to:path.appendingPathComponent("Contents/Info.plist"))
            try Data(version.utf8).write(to:path.appendingPathComponent("Contents/MacOS/Linvell")); return path
        }
        let current = try app("Linvell","0.1.4"),old = try app(".Linvell-previous-old","0.1.2"),newer = try app(".Linvell-previous-newest","0.1.3"),future = try app(".Linvell-previous-inflight","0.1.5")
        let archive = root.appendingPathComponent("Rollback")
        try RollbackArchive.migrateLegacyCopies(beside:current,directory:archive)
        XCTAssertFalse(FileManager.default.fileExists(atPath:old.path)); XCTAssertFalse(FileManager.default.fileExists(atPath:newer.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:future.path)); XCTAssertTrue(FileManager.default.fileExists(atPath:current.path))
        let output = root.appendingPathComponent("Extracted")
        _ = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ditto"),arguments:["-x","-k",archive.appendingPathComponent("PreviousVersion.zip").path,output.path],directory:nil)
        XCTAssertEqual(try String(contentsOf:output.appendingPathComponent("Linvell.app/Contents/MacOS/Linvell"),encoding:.utf8),"0.1.3")
    }
    func testRetainsOnlyOneCompressedVersionAndRemovesAppCopies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let directory = root.appendingPathComponent("Rollback")
        for version in ["0.1.1","0.1.2"] {
            let app = root.appendingPathComponent(".Linvell-previous-"+UUID().uuidString+".app")
            try FileManager.default.createDirectory(at:app.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
            let info = ["CFBundleIdentifier":"top.fuluwa.linvell","LinvellReleaseVersion":version]
            try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
            try Data(version.utf8).write(to:app.appendingPathComponent("Contents/MacOS/Linvell"))
            let archive = try RollbackArchive.retain(previous:app,directory:directory)
            XCTAssertEqual(archive.lastPathComponent,"PreviousVersion.zip")
            XCTAssertFalse(FileManager.default.fileExists(atPath:app.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path).filter { !$0.hasPrefix(".") },["PreviousVersion.zip"])
        }
        let output = root.appendingPathComponent("Extracted")
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ditto"),arguments:["-x","-k",directory.appendingPathComponent("PreviousVersion.zip").path,output.path],directory:nil)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(try String(contentsOf:output.appendingPathComponent("Linvell.app/Contents/MacOS/Linvell"),encoding:.utf8),"0.1.2")
    }
}
