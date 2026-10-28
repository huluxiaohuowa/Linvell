import XCTest
import AppKit
@testable import Linvell

final class LaunchOpeningTests: XCTestCase {
    func testFinderFolderBeforeLaunchReusesItsWorkspace() throws {
        _ = NSApplication.shared
        let originalProject = UserDefaults.standard.object(forKey:"lastProject")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let delegate = AppDelegate()
        defer {
            delegate.workspaces.forEach { $0.window?.close() }
            UserDefaults.standard.set(originalProject,forKey:"lastProject")
            try? FileManager.default.removeItem(at:folder)
        }
        delegate.application(NSApp,openFiles:[folder.path])
        let startup = delegate.workspaceForOpening()
        XCTAssertTrue(delegate.receivedOpenFiles)
        XCTAssertEqual(delegate.workspaces.count,1)
        XCTAssertEqual(startup.root?.url.path,folder.path)
        XCTAssertNil(startup.current)
        let file = folder.appendingPathComponent("example.txt")
        try "A standalone file".write(to:file,atomically:true,encoding:.utf8)
        let opened = expectation(description:"File opens in the same window")
        startup.open(file) { opened.fulfill() }
        wait(for:[opened],timeout:5)
        XCTAssertEqual(startup.current?.fileURL,file)
        XCTAssertTrue(delegate.workspaceForOpening() === startup)
        XCTAssertEqual(delegate.workspaces.count,1)
    }
}
