import XCTest
import AppKit
@testable import LinvellCore
@testable import Linvell

final class AutoSaveAndCodeTests: XCTestCase {
    var workspace: WorkspaceController!
    var folder: URL!
    var previous: Any?
    override func setUpWithError() throws {
        _ = NSApplication.shared
        previous = UserDefaults.standard.object(forKey:"autoSave"); UserDefaults.standard.set("true",forKey:"autoSave")
        folder = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        workspace = WorkspaceController()
    }
    override func tearDownWithError() throws {
        UserDefaults.standard.set(previous,forKey:"autoSave")
        workspace.window?.undoManager?.removeAllActions()
        workspace.autoSaveWork.values.forEach { $0.cancel() }; workspace.languageServices.stop(); workspace.window?.orderOut(nil); workspace.recoveryTimer?.invalidate(); workspace = nil
        try FileManager.default.removeItem(at:folder)
    }
    func document(_ name: String,text: String) throws -> OpenDocument {
        let path = folder.appendingPathComponent(name); try text.write(to:path,atomically:true,encoding:.utf8)
        return OpenDocument(try DocumentBuffer(url:path))
    }
    func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(4)
        while !condition(),Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        return condition()
    }
    func testNativeTypingChangesCloseButtonToDotAndAutoSaveRestoresX() throws {
        let doc = try document("note.txt",text:"hello"); workspace.activate(doc)
        let view = try XCTUnwrap(workspace.activePane?.textView)
        view.setSelectedRange(NSRange(location:5,length:0)); view.insertText(" world",replacementRange:view.selectedRange())
        let close = try XCTUnwrap((workspace.tabs.arrangedSubviews.first as? NSStackView)?.arrangedSubviews.last as? TabCloseButton)
        XCTAssertTrue(close.modified); XCTAssertTrue(doc.buffer.isModified)
        XCTAssertTrue(wait { !doc.buffer.isModified })
        XCTAssertFalse(close.modified); XCTAssertEqual(try String(contentsOf:folder.appendingPathComponent("note.txt"),encoding:.utf8),"hello world")
    }
    func testAutoSaveConflictPreservesExternalFileAndDirtyTab() throws {
        let doc = try document("note.txt",text:"original"); workspace.activate(doc)
        doc.buffer.update("pending"); workspace.scheduleAutoSave(doc)
        try "external".write(to:folder.appendingPathComponent("note.txt"),atomically:true,encoding:.utf8)
        XCTAssertTrue(wait { workspace.autoSaveWork.isEmpty && workspace.autoSaving.isEmpty })
        XCTAssertTrue(doc.buffer.isModified); XCTAssertEqual(try String(contentsOf:folder.appendingPathComponent("note.txt"),encoding:.utf8),"external")
    }
    func testNavigationAcrossOpenFilesCanGoBackAndForward() throws {
        let a = try document("a.txt",text:"first\nsecond\n"),b = try document("b.txt",text:"target\n")
        workspace.documents = [a,b]; workspace.activate(a); workspace.activePane?.textView.setSelectedRange(NSRange(location:3,length:0))
        let raw: [String:Any] = ["uri":b.fileURL!.absoluteString,"range":["start":["line":0,"character":0],"end":["line":0,"character":6]]]
        workspace.navigateCode(try XCTUnwrap(CodeLocation.locations(raw).first),remote:nil)
        XCTAssertTrue(workspace.current === b); workspace.goBack(); XCTAssertTrue(workspace.current === a)
        XCTAssertEqual(workspace.activePane?.textView.selectedRange().location,3)
        workspace.goForward(); XCTAssertTrue(workspace.current === b)
    }
    func testCustomProjectLanguageAndHoverUseNativeViews() throws {
        let config = folder.appendingPathComponent(".linvell")
        try FileManager.default.createDirectory(at:config,withIntermediateDirectories:true)
        try #"{"files.associations":{"*.zig":"zig"},"[zig]":{"linvell.languageServerPath":"/fixture/zls"}}"#.write(to:config.appendingPathComponent("settings.json"),atomically:true,encoding:.utf8)
        _ = try LanguageTools.load(CodeLanguage.supported[0],remote:nil,root:folder.path,force:true)
        XCTAssertTrue(LanguageTools.configuredLanguages(remote:nil,root:folder.path).contains { $0.id == "zig" })
        workspace.setProject(folder)
        let doc = try document("main.zig",text:"fn main() void {}\n"); workspace.activate(doc)
        XCTAssertEqual(workspace.codeSnapshot(doc)?.language.id,"zig")
        XCTAssertTrue(workspace.window?.acceptsMouseMovedEvents == true)
        let hover = CodeHoverContent(text:"func greeting(_ name: String) -> String\nReturns a greeting.",navigate:{})
        hover.loadView()
        hover.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(hover.view.subviews.compactMap { $0 as? ResponsiveScrollView }.first)
        XCTAssertGreaterThan(scroll.documentView?.frame.width ?? 0,0)
        LanguageTools.invalidate(remote:nil,root:folder.path)
    }
    func testRemoteFolderPickerExposesRefreshAndUsesResponsiveScrollView() throws {
        let browser = RemoteBrowser(connection:try SSHRemote(host:"fixture"),autoLoad:false)
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton,button.identifier?.rawValue == "Linvell.Remote.Refresh" { return button }
            return view.subviews.compactMap(find).first
        }
        XCTAssertNotNil(find(browser)); XCTAssertTrue(browser.table.enclosingScrollView is ResponsiveScrollView)
    }
    func testProjectCanPersistDifferentLanguageInterpreters() throws {
        workspace.setProject(folder)
        let python = try XCTUnwrap(CodeLanguage.supported.first { $0.id == "python" }),swift = try XCTUnwrap(CodeLanguage.supported.first { $0.id == "swift" })
        var p = LanguageToolchain(); p.runtime = folder.appendingPathComponent(".venv/bin/python").path; p.server = "/fixture/pylsp"
        try LanguageTools.save(p,language:python,remote:nil,root:folder.path)
        var s = LanguageToolchain(); s.runtime = "/fixture/swift"; s.server = "/fixture/sourcekit-lsp"
        try LanguageTools.save(s,language:swift,remote:nil,root:folder.path)
        let data = try Data(contentsOf:folder.appendingPathComponent(".linvell/settings.json")),settings = try JSONCSettings(data)
        XCTAssertEqual(settings.setting("python").runtime,"${workspaceFolder}/.venv/bin/python")
        XCTAssertEqual(settings.setting("swift").runtime,"/fixture/swift")
        XCTAssertEqual(LanguageTools.cached(python,remote:nil,root:folder.path).server,"/fixture/pylsp")
        LanguageTools.invalidate(remote:nil,root:folder.path)
    }
    func testWorkspaceRenameIsOneUndoAndStalePreviewDoesNotPartiallyApply() throws {
        UserDefaults.standard.set("false",forKey:"autoSave")
        let a = try document("a.txt",text:"hello()\n"),b = try document("b.txt",text:"hello()\n")
        workspace.documents = [a,b]; workspace.activate(a)
        func plan(_ doc: OpenDocument) throws -> CodeDocumentEdits {
            let raw: [String:Any] = ["changes":[doc.fileURL!.absoluteString:[["range":["start":["line":0,"character":0],"end":["line":0,"character":5]],"newText":"greet"]]]]
            return try XCTUnwrap(CodeWorkspaceEdit.parse(raw).first)
        }
        let prepared = try [a,b].map { doc in PreparedCodeRename(edits:try plan(doc),original:doc.buffer.text,updated:"greet()\n",openID:doc.buffer.id,openVersion:doc.buffer.revision,buffer:nil,remote:nil) }
        let undo = try XCTUnwrap(workspace.window?.undoManager); undo.groupsByEvent = false
        workspace.applyCodeRename(prepared)
        XCTAssertEqual(a.buffer.text,"greet()\n"); XCTAssertEqual(b.buffer.text,"greet()\n")
        undo.undo(); XCTAssertEqual(a.buffer.text,"hello()\n"); XCTAssertEqual(b.buffer.text,"hello()\n")
        undo.redo(); XCTAssertEqual(a.buffer.text,"greet()\n"); XCTAssertEqual(b.buffer.text,"greet()\n")
        let before = a.buffer.text
        workspace.applyCodeRename(prepared)
        XCTAssertEqual(a.buffer.text,before); XCTAssertEqual(b.buffer.text,"greet()\n")
    }
    func testSubmodulePageFitsNativeWorkspaceAndHasUsableControls() throws {
        let repo = GitRepository(directory:"/fixture/project",remote:nil) { _,args,_,_ in
            if args.first == "rev-parse" { return "/fixture/project\n" }
            if args.first == "config" { return "submodule.library.path\nvendor/library\0submodule.library.url\nhttps://example.invalid/library.git\0" }
            if args.first == "ls-files" { return "160000 abc123 0\tvendor/library\0" }
            if args.first == "submodule" { return "vendor/library\0abc123\0main\0no\0" }
            return ""
        }
        let page = GitWorkspace(repository:repo),window = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:720),styleMask:.titled,backing:.buffered,defer:false)
        window.contentView = page; page.showSubmodules()
        defer { window.contentView = nil; window.orderOut(nil) }
        XCTAssertTrue(wait { page.submodulePage?.modules.count == 1 })
        window.contentView?.layoutSubtreeIfNeeded()
        let modules = try XCTUnwrap(page.submodulePage)
        XCTAssertGreaterThan(modules.bounds.width,400)
        XCTAssertGreaterThan(modules.table.enclosingScrollView?.bounds.height ?? 0,150)
        XCTAssertTrue(modules.table.enclosingScrollView is ResponsiveScrollView)
        XCTAssertEqual(modules.filtered.first?.path,"vendor/library")
    }
    func testGitOperationsRunNativelyAndPersistAcrossWorkspaceSwitches() throws {
        _ = try GitRepository(root:folder).run(["init","-b","main"])
        workspace.setProject(folder); workspace.gitWorkspace()
        let git = try XCTUnwrap(workspace.gitWorkspaceView)
        git.showOperations()
        let page = try XCTUnwrap(git.actionsPage)
        page.selectOperation("Submodule — Deinitialize",path:"vendor/a library")
        XCTAssertEqual(try GitOperation.customArguments(page.argv.stringValue),["submodule","deinit","--","vendor/a library"])
        page.perform(["status","--short","--branch"])
        XCTAssertTrue(wait { !page.busy })
        XCTAssertTrue(page.output.string.contains("main"))
        let doc = try document("note.txt",text:"source")
        workspace.activate(doc); workspace.gitWorkspace()
        XCTAssertTrue(workspace.gitWorkspaceView === git)
        XCTAssertTrue(git.actionsPage === page)
        XCTAssertTrue(page.output.enclosingScrollView is ResponsiveScrollView)
    }
    func testLanguageAndGitPanelsLayoutWithoutOpeningAnotherApplication() throws {
        workspace.setProject(folder)
        let panel = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:660),styleMask:.titled,backing:.buffered,defer:false)
        panel.appearance = NSAppearance(named:Theme.profile.isDark ? .darkAqua : .aqua)
        let tools = LanguageToolsPane(owner:workspace)
        panel.contentView = Surface(Theme.canvas); Theme.pin(tools,in:panel.contentView!,inset:24)
        defer { panel.contentView = nil; panel.orderOut(nil) }
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(tools.runtime.frame.width,250)
        XCTAssertGreaterThan(tools.languages.frame.width,250)
        XCTAssertLessThanOrEqual(tools.server.convert(tools.server.bounds,to:panel.contentView).maxX,900)
        func capture(_ view: NSView,_ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["LINVELL_UI_ARTIFACT_DIR"] else { return }
            let root = URL(fileURLWithPath:directory); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds)); view.cacheDisplay(in:view.bounds,to:rep)
            try XCTUnwrap(rep.representation(using:.png,properties:[:])).write(to:root.appendingPathComponent(name+".png"))
        }
        try capture(try XCTUnwrap(panel.contentView),"language-tools")
        let repo = GitRepository(directory:folder.path,remote:nil) { _,args,_,_ in args.first == "rev-parse" ? self.folder.path+"\n" : "" }
        let git = GitWorkspace(repository:repo); panel.contentView = git; git.showOperations(); panel.contentView?.layoutSubtreeIfNeeded()
        let actions = try XCTUnwrap(git.actionsPage)
        actions.selectOperation("Submodule — Update With Rebase",path:"vendor/library")
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(actions.argv.frame.width,250)
        XCTAssertGreaterThan(actions.resultHost.frame.height,200)
        try capture(git,"git-operations")
    }

}
