import XCTest
@testable import LinvellCore

final class UpdateStagingTests: XCTestCase {
    func testCompressedJobUnpacksOnlyInsideItsOwnDirectory() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source/Linvell.app"),jobRoot = root.appendingPathComponent(UUID().uuidString+".noindex")
        try fm.createDirectory(at:source.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
        try fm.createDirectory(at:jobRoot,withIntermediateDirectories:true)
        defer { RollbackArchive.unregister(jobRoot.appendingPathComponent("extracted/Linvell.app")); try? fm.removeItem(at:root) }
        try Data("fixture executable".utf8).write(to:source.appendingPathComponent("Contents/MacOS/Linvell"))
        try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"test.linvell.update-fixture"],format:.xml,options:0).write(to:source.appendingPathComponent("Contents/Info.plist"))
        let archive = jobRoot.appendingPathComponent("update.zip"),target = jobRoot.appendingPathComponent("extracted/Linvell.app"),jobURL = jobRoot.appendingPathComponent("install-job.json")
        let zipped = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ditto"),arguments:["-c","-k","--keepParent",source.path,archive.path],directory:nil)
        XCTAssertTrue(zipped.succeeded)
        XCTAssertFalse(fm.fileExists(atPath:target.path))
        let job = InstallJob(application:root.appendingPathComponent("Installed.app"),replacement:target,parentPID:123,relaunch:false,archive:archive)
        try job.unpackArchive(jobURL:jobURL)
        XCTAssertEqual(try Data(contentsOf:target.appendingPathComponent("Contents/MacOS/Linvell")),Data("fixture executable".utf8))
        XCTAssertTrue(fm.fileExists(atPath:archive.path))
        let outside = InstallJob(application:root.appendingPathComponent("Installed.app"),replacement:source,parentPID:123,relaunch:false,archive:archive)
        XCTAssertThrowsError(try outside.unpackArchive(jobURL:jobURL))
        XCTAssertTrue(fm.fileExists(atPath:source.path))
        RollbackArchive.unregister(target); try fm.removeItem(at:target.deletingLastPathComponent())
        try fm.createSymbolicLink(at:target.deletingLastPathComponent(),withDestinationURL:source.deletingLastPathComponent())
        XCTAssertThrowsError(try job.unpackArchive(jobURL:jobURL))
        XCTAssertTrue(fm.fileExists(atPath:source.path))
    }

    func testPruningKeepsPreparedRecentAndUnownedFolders() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let now = Date()
        func job(_ name: String, age: TimeInterval) throws -> URL {
            let directory = root.appendingPathComponent(name)
            try fm.createDirectory(at:directory.appendingPathComponent("extracted/Linvell.app/Contents"),withIntermediateDirectories:true)
            try fm.setAttributes([.modificationDate:now.addingTimeInterval(-age)],ofItemAtPath:directory.path)
            return directory
        }
        let obsolete = try job(UUID().uuidString,age:172800)
        let failed = try job(UUID().uuidString+".noindex",age:172800)
        let prepared = try job(UUID().uuidString+".noindex",age:172800)
        let recent = try job(UUID().uuidString+".noindex",age:30)
        let other = try job("user-data",age:172800)
        UpdateStaging.prune(in:root,keeping:prepared.appendingPathComponent("extracted/Linvell.app"),now:now)
        XCTAssertFalse(fm.fileExists(atPath:obsolete.path))
        XCTAssertFalse(fm.fileExists(atPath:failed.path))
        for kept in [prepared,recent,other] { XCTAssertTrue(fm.fileExists(atPath:kept.path)) }
    }

    func testRemovalRefusesOutsideAndSymlinkTargets() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        let updates = root.appendingPathComponent("Updates"),outside = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at:updates,withIntermediateDirectories:true)
        try fm.createDirectory(at:outside,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let link = updates.appendingPathComponent(UUID().uuidString+".noindex")
        try fm.createSymbolicLink(at:link,withDestinationURL:outside)
        XCTAssertFalse(UpdateStaging.owns(candidate:link.appendingPathComponent("extracted/Linvell.app"),in:updates))
        XCTAssertFalse(UpdateStaging.owns(candidate:URL(fileURLWithPath:"/Applications/Linvell.app"),in:updates))
        XCTAssertTrue(UpdateStaging.owns(candidate:updates.appendingPathComponent(UUID().uuidString+".noindex/extracted/Linvell.app"),in:updates))
        UpdateStaging.remove(outside,in:updates)
        UpdateStaging.remove(link,in:updates)
        XCTAssertTrue(fm.fileExists(atPath:outside.path))
        XCTAssertTrue(fm.fileExists(atPath:link.path))
    }
}
