import XCTest
@testable import LinvellCore

final class SignedUpdateIntegrationTests: XCTestCase {
    func testCompressedSignedUpgradeLeavesOnlyInstalledHandlerAndOneRollback() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let old = environment["LINVELL_UPDATE_BASE_ZIP"],let next = environment["LINVELL_UPDATE_NEXT_ZIP"] else {
            throw XCTSkip("Requires two existing, signed release ZIPs; never installs into /Applications.")
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString+".noindex")
        let installed = root.appendingPathComponent("installed/Linvell.app"),jobRoot = root.appendingPathComponent(UUID().uuidString+".noindex")
        let candidate = jobRoot.appendingPathComponent("extracted/Linvell.app")
        try fm.createDirectory(at:jobRoot,withIntermediateDirectories:true)
        let ls = URL(fileURLWithPath:"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        defer {
            // Verify-then-delete is insufficient: unregister all temporary handlers first.
            if let enumerator = fm.enumerator(at:root,includingPropertiesForKeys:nil) {
                while let url = enumerator.nextObject() as? URL {
                    if url.pathExtension == "app" { RollbackArchive.unregister(url); enumerator.skipDescendants() }
                }
            }
            try? fm.removeItem(at:root)
            _ = try? ToolCommand.run(ls,arguments:["-f","/Applications/Linvell.app"],directory:nil)
        }
        let unpack = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ditto"),arguments:["-xk",old,installed.deletingLastPathComponent().path],directory:nil,timeout:120)
        XCTAssertTrue(unpack.succeeded)
        let zip = jobRoot.appendingPathComponent("update.zip")
        try fm.copyItem(at:URL(fileURLWithPath:next),to:zip)
        XCTAssertFalse(fm.fileExists(atPath:candidate.path))
        let job = InstallJob(application:installed,replacement:candidate,parentPID:123,relaunch:false,archive:zip)
        try job.unpackArchive(jobURL:jobRoot.appendingPathComponent("install-job.json"))
        // Deliberately reproduce the assessment/registration that used to leak duplicates.
        _ = try ToolCommand.run(ls,arguments:["-f",candidate.path],directory:nil)
        let previous = try SignedUpdate.install(current:installed,candidate:candidate)
        RollbackArchive.unregister(candidate); try fm.removeItem(at:candidate)
        let rollback = root.appendingPathComponent("Rollback")
        _ = try RollbackArchive.retain(previous:previous,directory:rollback)
        XCTAssertFalse(fm.fileExists(atPath:previous.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath:rollback.path).filter { !$0.hasPrefix(".") },["PreviousVersion.zip"])
        let signing = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/codesign"),arguments:["--verify","--deep","--strict",installed.path],directory:nil,timeout:60)
        XCTAssertTrue(signing.succeeded)
        let records = try ToolCommand.run(ls,arguments:["-dump"],directory:nil,maximumOutputBytes:32*1024*1024).output
        XCTAssertTrue(records.contains(installed.path))
        XCTAssertFalse(records.contains(candidate.path))
        XCTAssertFalse(records.contains(previous.path))
    }
}
