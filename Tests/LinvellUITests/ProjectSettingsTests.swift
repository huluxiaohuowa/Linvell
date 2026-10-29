import XCTest
import AppKit
import CryptoKit
@testable import LinvellCore
@testable import Linvell

final class ProjectSettingsTests: XCTestCase {
    func testProjectPaneIsSeparateAndKeepsPerLanguageStorage() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let workspace = WorkspaceController(); workspace.root = FileNode(root)
        let controller = ProjectSettingsController(owner:workspace)
        let prefs = PreferencesController(owner:workspace)
        defer {
            controller.window?.orderOut(nil); prefs.statusTimer?.invalidate(); prefs.window?.orderOut(nil)
            workspace.recoveryTimer?.invalidate(); workspace.languageServices.stop(); workspace.window?.orderOut(nil)
            try? FileManager.default.removeItem(at:root)
        }
        XCTAssertEqual(prefs.buttons.count,6)
        XCTAssertTrue(prefs.buttons.contains { $0.title == L.text("Plugins") })
        XCTAssertEqual(controller.languageTools.root,root.path)
        XCTAssertEqual(controller.scope,LanguageTools.scope(remote:nil,root:root.path))
        XCTAssertTrue(controller.languageTools.advancedBox.isHidden)
        let pane = controller.languageTools
        pane.storage.selectItem(at:1); pane.storageChanged()
        XCTAssertEqual(pane.selectedStorage,.user); XCTAssertTrue(pane.autoIgnore.isHidden); XCTAssertTrue(pane.ignoreButton.isHidden)
        pane.storage.selectItem(at:0); pane.storageChanged()
        XCTAssertFalse(pane.autoIgnore.isHidden); XCTAssertFalse(pane.ignoreButton.isHidden)
        pane.setInstalling(true); XCTAssertTrue(pane.cancelButton.isHidden)
        pane.setInstalling(true,cancellable:true); XCTAssertFalse(pane.cancelButton.isHidden)
        pane.setInstalling(false)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        if let directory = ProcessInfo.processInfo.environment["LINVELL_UI_ARTIFACT_DIR"],let view = controller.window?.contentView,let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:directory).appendingPathComponent("project-settings.png"))
        }
    }
    func testExistingExecutableApprovalSurvivesStoragePreferenceChanges() throws {
        let root = "/fixture/"+UUID().uuidString,language = try XCTUnwrap(CodeLanguage.supported.first { $0.id == "python" })
        var profile = LanguageToolchain(); profile.server = "/fixture/server"; profile.runtime = "/fixture/python"; profile.arguments = ["--stdio"]
        struct PreviousProfile: Encodable { let runtime: String,server: String,arguments: [String],enabled: Bool }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let payload = PreviousProfile(runtime:profile.runtime,server:profile.server,arguments:profile.arguments,enabled:profile.enabled)
        let digest = SHA256.hash(data:try encoder.encode(payload)).map { String(format:"%02x",$0) }.joined()
        let key = "approvedProjectLanguageTools."+SHA256.hash(data:Data((LanguageTools.scope(remote:nil,root:root)+"|"+language.id).utf8)).map { String(format:"%02x",$0) }.joined()
        UserDefaults.standard.set(digest,forKey:key); defer { UserDefaults.standard.removeObject(forKey:key) }
        profile.storage = .user; profile.addGitIgnore = false
        XCTAssertTrue(LanguageTools.approved(profile,language:language,remote:nil,root:root))
        profile.server = "/different/server"
        XCTAssertFalse(LanguageTools.approved(profile,language:language,remote:nil,root:root))
    }
}
