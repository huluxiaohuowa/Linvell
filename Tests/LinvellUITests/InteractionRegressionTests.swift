import XCTest
import AppKit
@testable import Linvell
@testable import LinvellCore

final class InteractionRegressionTests: XCTestCase {
    func testLeavingEditorDismissesHoverImmediately() {
        _ = NSApplication.shared
        let editor = EditorTextView(frame:NSRect(x:0,y:0,width:600,height:400))
        editor.string = "functionName()"; editor.hoverOffset = 0
        var dismissed = false; editor.codeDismiss = { dismissed = true }
        editor.mouseExited(with:NSEvent())
        XCTAssertTrue(dismissed,"A hover must disappear when the pointer leaves the editor")
    }
    func testOptionArrowsReachNavigationInsteadOfWordMovement() throws {
        _ = NSApplication.shared
        let editor = EditorTextView(frame:NSRect(x:0,y:0,width:600,height:400)); editor.string = "one two"
        var actions: [String] = []; editor.codeAction = { action,_ in actions.append(action) }
        for code: UInt16 in [123,124] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.option,timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code))
            editor.keyDown(with:event)
        }
        XCTAssertEqual(actions,["back","forward"])
    }
    func testMovingOffSymbolCancelsPendingHoverAndInvalidatesResponse() {
        _ = NSApplication.shared
        let editor = EditorTextView(frame:NSRect(x:0,y:0,width:600,height:400))
        editor.string = "first second"; editor.hoverOffset = 0
        let generation = editor.hoverGeneration
        var dismissed = false; editor.codeHoverDismiss = { dismissed = true }
        editor.updateCodeHover(at:NSPoint(x:500,y:300))
        XCTAssertTrue(dismissed); XCTAssertEqual(editor.hoverOffset,-1); XCTAssertNotEqual(generation,editor.hoverGeneration)
        XCTAssertNil(editor.hoverWork)
    }
    func testRecentProjectsAreHostAwareDeduplicatedAndBounded() throws {
        let name = "Linvell.Recents."+UUID().uuidString,defaults = try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        let a = WorkspaceSession.local(path:"/projects/a"),b = WorkspaceSession.ssh(host:"test-host",path:"/projects/a")
        WorkspaceSession.save(a,defaults:defaults); WorkspaceSession.save(b,defaults:defaults); WorkspaceSession.save(a,defaults:defaults)
        XCTAssertEqual(WorkspaceSession.recent(defaults:defaults),[a,b])
        XCTAssertTrue(b.title.contains("test-host")); XCTAssertNotEqual(a.title,b.title)
        for index in 0..<20 { WorkspaceSession.save(.local(path:"/projects/\(index)"),defaults:defaults) }
        XCTAssertEqual(WorkspaceSession.recent(defaults:defaults).count,12)
        XCTAssertFalse(PreferencesSync.defaults.keys.contains(WorkspaceSession.recentKey))
    }
    func testProjectSettingsUsesCommonHeaderActionForLocalAndSSHWorkspaces() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceController()
        defer { workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil) }
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        let settings = try XCTUnwrap(buttons(try XCTUnwrap(workspace.window?.contentView)).first { $0.action == #selector(WorkspaceController.showProjectSettings) })
        XCTAssertTrue(settings.target === workspace)
        workspace.root = FileNode(URL(fileURLWithPath:"/fixture/local"))
        let local = ProjectSettingsController(owner:workspace)
        XCTAssertNil(local.languageTools.remote); XCTAssertEqual(local.languageTools.root,"/fixture/local")
        local.window?.orderOut(nil)
        workspace.root = nil; workspace.remoteConnection = try SSHRemote(host:"example"); workspace.remoteDirectory = "/fixture/remote"
        let remote = ProjectSettingsController(owner:workspace)
        XCTAssertEqual(remote.languageTools.remote?.host,"example"); XCTAssertEqual(remote.languageTools.root,"/fixture/remote")
        XCTAssertTrue(settings.target === workspace)
        remote.window?.orderOut(nil)
    }
    func testWelcomeRendersRecentLocalAndRemoteProjects() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard,prior = defaults.object(forKey:WorkspaceSession.recentKey),last = defaults.object(forKey:WorkspaceSession.key)
        defer { defaults.set(prior,forKey:WorkspaceSession.recentKey); defaults.set(last,forKey:WorkspaceSession.key) }
        defaults.set(try JSONEncoder().encode([WorkspaceSession]()),forKey:WorkspaceSession.recentKey)
        WorkspaceSession.save(.local(path:"/Projects/NativeApp")); WorkspaceSession.save(.ssh(host:"example-host",path:"/Projects/RemoteApp"))
        let workspace = WorkspaceController()
        defer { workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil) }
        let welcome = WelcomeView(owner:workspace); welcome.frame = NSRect(x:0,y:0,width:1100,height:900); welcome.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> WelcomeRecents? { (view as? WelcomeRecents) ?? view.subviews.compactMap(find).first }
        let recents = try XCTUnwrap(find(welcome))
        XCTAssertEqual(recents.locations.count,2); XCTAssertTrue(recents.locations[0].title.contains("example-host"))
        XCTAssertGreaterThan(recents.frame.height,100)
        if let directory = ProcessInfo.processInfo.environment["LINVELL_UI_ARTIFACT_DIR"],let bitmap = welcome.bitmapImageRepForCachingDisplay(in:welcome.bounds) {
            welcome.cacheDisplay(in:welcome.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:directory).appendingPathComponent("welcome-recents.png"))
        }
    }
    func testLateRemoteReadCannotStealFocusAfterReturningToPreviousEditor() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceController(),root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { workspace.languageServices.stop(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil); try? FileManager.default.removeItem(at:root) }
        let origin = OpenDocument(DocumentBuffer(text:"origin")),connection = try SSHRemote(host:"example")
        let remote = try RemoteDocument(connection:connection,path:"/fixture/note.txt",digest:"fixture",data:Data("remote".utf8),cacheRoot:root)
        let loaded = OpenDocument(try DocumentBuffer(url:remote.localURL)); loaded.remote = remote
        workspace.activate(origin)
        let request = UUID(); workspace.latestOpenRequest = request
        workspace.activate(origin)
        var completed = false
        workspace.finishRemoteOpen(loaded,request:request,completion:{ completed = true })
        XCTAssertTrue(workspace.current === origin); XCTAssertFalse(completed)
        XCTAssertTrue(workspace.documents.contains { $0 === loaded })
        let latest = UUID(); workspace.latestOpenRequest = latest
        workspace.finishRemoteOpen(loaded,request:latest,completion:{ completed = true })
        XCTAssertTrue(workspace.current === loaded); XCTAssertTrue(completed)
    }
    func testOptionArrowsActuallyRestoreDefinitionOriginAndReturnForward() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceController(),folder = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { workspace.languageServices.stop(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil); try? FileManager.default.removeItem(at:folder) }
        func document(_ name: String) throws -> OpenDocument {
            let file = folder.appendingPathComponent(name); try "first\nsecond\n".write(to:file,atomically:true,encoding:.utf8)
            return OpenDocument(try DocumentBuffer(url:file))
        }
        let a = try document("a.txt"),b = try document("b.txt")
        workspace.documents = [a,b]; workspace.activate(a); workspace.activePane?.textView.setSelectedRange(NSRange(location:3,length:0))
        let range = try JSONDecoder().decode(CodeRange.self,from:Data(#"{"start":{"line":1,"character":1},"end":{"line":1,"character":3}}"#.utf8))
        workspace.navigateCode(CodeLocation(uri:b.fileURL!.absoluteString,range:range),remote:nil)
        for code: UInt16 in [123,124] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.option,timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code))
            workspace.activePane?.textView.keyDown(with:event)
            XCTAssertTrue(workspace.current === (code == 123 ? a : b))
            XCTAssertEqual(workspace.activePane?.textView.selectedRange().location,code == 123 ? 3 : 7)
        }
    }
    func testLanguageServerSettingsUseTheTargetHostAndSurviveToolchainRoundTrip() throws {
        let language = try XCTUnwrap(CodeLanguage.supported.first { $0.id == "python" })
        var profile = LanguageToolchain(); profile.server = "${workspaceFolder}/service"; profile.runtime = "${userHome}/python"
        profile.configurationJSON = #"{"python":{"analysis":{"extraPaths":["${workspaceFolder}/src","${userHome}/lib"]}}}"#
        let resolved = LanguageTools.resolved(profile,language:language,tools:["__home":"/remote/user"],root:"/remote/project")
        XCTAssertEqual(resolved.runtime,"/remote/user/python")
        let resolvedObject = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(resolved.configurationJSON.utf8)) as? [String:Any])
        let analysis = try XCTUnwrap((resolvedObject["python"] as? [String:Any])?["analysis"] as? [String:Any])
        XCTAssertEqual(analysis["extraPaths"] as? [String],["/remote/project/src","/remote/user/lib"])
        let source = try JSONCSettings(Data("{}".utf8)).updating("python",profile:profile)
        let restored = try JSONSerialization.jsonObject(with:Data(try JSONCSettings(source).setting("python").configurationJSON.utf8)) as? NSDictionary
        XCTAssertEqual(restored,try JSONSerialization.jsonObject(with:Data(profile.configurationJSON.utf8)) as? NSDictionary)
    }
    func testRemoteSourceWatchUsesCacheAndClassifiesActualChanges() {
        let previous = ["/project/unchanged.py":"1","/project/edited.py":"1","/project/removed.py":"1"]
        XCTAssertTrue(RemoteLanguageWorkspaceWatch.changes(previous:previous,current:previous).0.isEmpty)
        let changes = RemoteLanguageWorkspaceWatch.changes(previous:previous,current:["/project/unchanged.py":"1","/project/edited.py":"2","/project/new.py":"1"])
        XCTAssertEqual(changes.0,["/project/edited.py","/project/new.py","/project/removed.py"])
        XCTAssertEqual(changes.1,[2,1,3])
    }
    func testHoverCardCannotStealKeyboardFocusAndHasNoActionButton() {
        _ = NSApplication.shared
        let panel = CodeHoverPanel(),content = CodeHoverContent(text:"function(value: String)",navigate:{})
        panel.contentViewController = content; content.loadViewIfNeeded()
        XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
        func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
        XCTAssertTrue(buttons(content.view).isEmpty)
        XCTAssertLessThanOrEqual(content.preferredContentSize.width,420)
        panel.close()
    }
    func testRemoteProjectToolsShowsWorkspaceInsteadOfFolderPicker() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceController()
        workspace.remoteConnection = try SSHRemote(host:"example"); workspace.remoteDirectory = "/fixture/project"
        workspace.projectToolsReportLoader = { _ in [("Host","Remote fixture")] }
        defer {
            if let sheet = workspace.window?.attachedSheet { workspace.window?.endSheet(sheet); sheet.orderOut(nil) }
            workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil)
        }
        workspace.projectTools()
        let tools = try XCTUnwrap(workspace.editors.arrangedSubviews.first as? ProjectTools)
        XCTAssertEqual(tools.remote?.host,"example"); XCTAssertEqual(tools.project.path,"/fixture/project")
        XCTAssertNil(workspace.window?.attachedSheet)
        XCTAssertNil(workspace.remoteFolderPicker)
    }
}
