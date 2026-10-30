import XCTest
import AppKit
import LinvellCore
@testable import Linvell

final class UpdateSourceTests: XCTestCase {
    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in:$0) }
    }
    func testHomebrewSettingsShowUpgradeCommandInsteadOfSelfUpdateControls() throws {
        _ = NSApplication.shared
        let controller = PreferencesController(updates:UpdateManager(installationSource:.homebrew(tap:"huluxiaohuowa/tap")))
        defer { controller.statusTimer?.invalidate(); controller.window?.orderOut(nil) }
        controller.showUpdates(); controller.window?.contentView?.layoutSubtreeIfNeeded()
        let titles = buttons(in:controller.detail).map(\.title)
        XCTAssertTrue(titles.contains(L.text("Copy Upgrade Command")))
        XCTAssertTrue(titles.contains(L.text("Automatically check for updates")))
        for title in ["Download Update","Install and Restart","Automatically download verified updates","Install downloaded updates when Linvell quits","Include preview releases"] {
            XCTAssertFalse(titles.contains(L.text(title)))
        }
        if let directory = ProcessInfo.processInfo.environment["LINVELL_UI_ARTIFACT_DIR"],let view = controller.window?.contentView,let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:directory).appendingPathComponent("homebrew-updates.png"))
        }
    }
    func testDirectSettingsRetainDownloadInstallAndPreviewControls() {
        _ = NSApplication.shared
        let controller = PreferencesController(updates:UpdateManager(installationSource:.direct))
        defer { controller.statusTimer?.invalidate(); controller.window?.orderOut(nil) }
        controller.showUpdates()
        let titles = buttons(in:controller.detail).map(\.title)
        for title in ["Download Update","Install and Restart","Include preview releases"] { XCTAssertTrue(titles.contains(L.text(title))) }
        XCTAssertFalse(titles.contains(L.text("Copy Upgrade Command")))
    }
    func testHomebrewSourceBlocksAllInAppInstallationEntryPoints() {
        let source = UpdateInstallationSource.homebrew(tap:"huluxiaohuowa/tap")
        let manager = UpdateManager(installationSource:source)
        XCTAssertFalse(manager.supportsSelfUpdates)
        manager.download(); manager.requestInstall()
        XCTAssertFalse(manager.busy); XCTAssertNil(manager.offer); XCTAssertNil(manager.prepared)
        XCTAssertFalse(manager.installRequested); XCTAssertFalse(manager.shouldInstallOnQuit)
        XCTAssertThrowsError(try manager.scheduleInstallation())
        XCTAssertTrue(manager.status.contains("brew upgrade --cask huluxiaohuowa/tap/linvell"))
    }
    func testUnknownHomebrewSourceNeverFallsBackToGitHub() {
        let manager = UpdateManager(installationSource:.homebrew(tap:"example/tools"))
        manager.check()
        XCTAssertFalse(manager.busy); XCTAssertNil(manager.offer)
        XCTAssertTrue(manager.status.contains("brew upgrade --cask example/tools/linvell"))
    }
    func testRealHomebrewInstallChecksLiveTapWithoutInAppOffer() throws {
        guard let path = ProcessInfo.processInfo.environment["LINVELL_BREW_APP"] else { throw XCTSkip("Requires an isolated Homebrew installation.") }
        let source = UpdateInstallationSource.detect(application:URL(fileURLWithPath:path))
        XCTAssertEqual(source,.homebrew(tap:"huluxiaohuowa/tap"))
        let manager = UpdateManager(installationSource:source)
        manager.check()
        let deadline = Date().addingTimeInterval(30)
        while manager.busy,Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(manager.busy)
        XCTAssertTrue(manager.status.contains("brew upgrade --cask huluxiaohuowa/tap/linvell"),manager.status)
        XCTAssertNil(manager.offer); XCTAssertNil(manager.prepared)
    }
    func testDirectDownloadRetainsSelfUpdateSupport() {
        let manager = UpdateManager(installationSource:.direct)
        XCTAssertTrue(manager.supportsSelfUpdates)
        XCTAssertTrue(manager.status.contains("GitHub Releases"))
    }
}
