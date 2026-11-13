import AppKit
import XCTest
@testable import LinvellCore
@testable import Linvell

final class LiveSSHWorkspaceFilesTests: XCTestCase {
    private func wait(_ message: String,until ready: () -> Bool,file: StaticString = #filePath,line: UInt = #line) {
        let deadline = Date().addingTimeInterval(15)
        while !ready(),Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.025)) }
        XCTAssertTrue(ready(),message,file:file,line:line)
    }

    func testSearchOpenRenameSaveIgnoreAndTrashOverSSHWithoutShowingAWindow() throws {
        guard let file = ProcessInfo.processInfo.environment["LINVELL_SSH_WORKSPACE_FILES_FIXTURE"] else {
            throw XCTSkip("A disposable SSH workspace fixture is required.")
        }
        let fixture = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:URL(fileURLWithPath:file)))
        let root = try XCTUnwrap(fixture["root"]), prefix = try XCTUnwrap(fixture["name"])
        let remote = try SSHRemote(host:XCTUnwrap(fixture["host"]))
        let app = NSApplication.shared
        XCTAssertNotEqual(app.activationPolicy(),.regular)
        let defaults = UserDefaults.standard
        let keys = [WorkspaceSession.key,WorkspaceSession.recentKey,"git.repositoryOpened","git.repositoryAdded",
                    "workspaceTabHistory","lastWorkspaceTabs","iCloudSyncEnabled","autoSave"]
        let saved = keys.map { defaults.object(forKey:$0) }
        defaults.set(false,forKey:"iCloudSyncEnabled")
        let workspace = WorkspaceController()
        defer {
            workspace.recoveryTimer?.invalidate()
            for (key,value) in zip(keys,saved) { defaults.set(value,forKey:key) }
        }
        XCTAssertFalse(try XCTUnwrap(workspace.window).isVisible)
        workspace.remoteConnection = remote; workspace.remoteDirectory = root
        workspace.showSidebar("files")
        let tree = try XCTUnwrap(workspace.remoteBrowser)
        wait("Remote file tree loaded") { tree.rootNode.children != nil }
        let children = try XCTUnwrap(tree.rootNode.children)
        for name in ["ignored","loose.skip"] {
            let node = try XCTUnwrap(children.first { $0.name == name })
            XCTAssertTrue(node.isIgnored)
            let cell = try XCTUnwrap(tree.outlineView(tree.table,viewFor:nil,item:node))
            XCTAssertLessThan(cell.alphaValue,1)
        }
        let tracked = try XCTUnwrap(children.first { $0.name == "tracked.skip" })
        XCTAssertFalse(tracked.isIgnored)
        XCTAssertEqual(tree.outlineView(tree.table,viewFor:nil,item:tracked)?.alphaValue,1)
        let nested = try XCTUnwrap(children.first { $0.name == "nested" })
        tree.table.expandItem(nested)
        wait("Nested ignore rules loaded") { nested.children?.contains { $0.name == "nested-hidden.txt" && $0.isIgnored } == true }

        workspace.projectSearch()
        let search = try XCTUnwrap(workspace.sidebar.subviews.first as? ToolSidebar)
        search.query.stringValue = "STRASSE needle [.*]"; search.refresh()
        wait("Remote search results loaded") { search.results.count == 1 }
        XCTAssertEqual(search.results.first?.detail,"nested/child/note.swift:2")
        search.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        search.selected()
        XCTAssertEqual(search.table.numberOfRows,1)
        search.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); search.selected()
        XCTAssertEqual(search.table.numberOfRows,2)
        search.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false); search.selected()
        let original = root+"/nested/child/note.swift"
        wait("Clicking the result opens the source and navigates to line 2") {
            workspace.current?.remote?.path == original && workspace.activePane?.textView.selectedRange() == (workspace.current?.storage.string as NSString?)?.range(of:"Straße NEEDLE [.*]")
        }
        let doc = try XCTUnwrap(workspace.current)
        wait("Silica rules run on remote file contents") {
            doc.syntax.analysis.tokens.contains { $0.kind == .string } && doc.syntax.analysis.tokens.contains { $0.kind == .comment }
        }

        search.caseToggle.state = .on; search.refresh()
        wait("Exact-case search does not return folded matches") { search.results.isEmpty }
        let rootListing = try remote.request("quick-files",path:root)
        XCTAssertFalse(rootListing.entries?.contains { $0.name == "loose.skip" } == true)
        XCTAssertTrue(rootListing.entries?.contains { $0.name == "tracked.skip" } == true)
        tree.filter.stringValue = "LOOSE"
        tree.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:tree.filter))
        wait("Remote explorer filters and retains Git ignore state") {
            (tree.table.item(atRow:0) as? RemoteTreeNode)?.isIgnored == true
        }
        let copy = try XCTUnwrap(remote.request("duplicate",path:original,repositoryRoot:root).path)
        let secondCopy = try XCTUnwrap(remote.request("duplicate",path:original,repositoryRoot:root).path)
        XCTAssertTrue(copy.hasSuffix("note copy.swift"))
        XCTAssertTrue(secondCopy.hasSuffix("note copy 2.swift"))
        XCTAssertEqual(try remote.request("read",path:copy).content,try remote.request("read",path:original).content)
        let newFolder = root+"/new project folder"
        _ = try remote.request("mkdir",path:newFolder,repositoryRoot:root)
        _ = try remote.request("create",path:newFolder+"/child.txt",repositoryRoot:root)
        let copiedFolder = try XCTUnwrap(remote.request("duplicate",path:newFolder,repositoryRoot:root).path)
        XCTAssertEqual(try remote.request("read",path:copiedFolder+"/child.txt").content,"")
        XCTAssertThrowsError(try remote.request("mkdir",path:newFolder,repositoryRoot:root))

        func mutate(_ path: String,name: String?) throws -> String {
            var outcome: Result<String,Error>?
            workspace.mutateRemoteItem(path,newName:name) { outcome = $0 }
            wait("Remote operation completed") { outcome != nil }
            return try XCTUnwrap(outcome).get()
        }
        let renamed = try mutate(original,name:"note renamed.swift")
        XCTAssertEqual(doc.remote?.path,renamed)
        XCTAssertEqual(doc.displayName,"note renamed.swift")
        XCTAssertEqual(doc.buffer.url,doc.remote?.localURL)
        XCTAssertThrowsError(try remote.request("read",path:original))
        let newDirectory = try mutate(root+"/nested",name:"new nested")
        let movedFile = newDirectory+"/child/note renamed.swift"
        XCTAssertEqual(doc.remote?.path,movedFile)
        let updated = "let updated = true\n"
        defaults.set("true",forKey:"autoSave")
        try doc.buffer.replace(NSRange(location:0,length:doc.buffer.text.utf16.count),with:updated)
        search.query.stringValue = "updated"; search.refresh()
        wait("Search sees unsaved SSH edits") { search.results.first?.url.path == movedFile }
        workspace.scheduleAutoSave(doc)
        wait("The existing editor buffer saves at the renamed remote path") { !doc.buffer.isModified }
        let savedRemote = try remote.request("read",path:movedFile)
        XCTAssertEqual(savedRemote.content,Data(updated.utf8).base64EncodedString())
        XCTAssertEqual(WorkspaceTabs.load(for:.ssh(host:remote.host,path:root))?.active,movedFile)
        workspace.showSidebar("files")
        let updatedTree = try XCTUnwrap(workspace.remoteBrowser)
        wait("The tree reflects the folder rename") {
            updatedTree.rootNode.children?.contains { $0.name == "new nested" } == true
                && updatedTree.rootNode.children?.contains { $0.name == "nested" } == false
        }

        let trashPath = root+"/"+prefix+".txt",trashDirectory = root+"/"+prefix
        workspace.openRemote(trashPath,connection:remote)
        wait("Opened the file to be moved") { workspace.current?.remote?.path == trashPath }
        let trashDocument = try XCTUnwrap(workspace.current)
        let trashedFile = try mutate(trashPath,name:nil)
        XCTAssertFalse(workspace.documents.contains { $0 === trashDocument })
        let trashedDirectory = try mutate(trashDirectory,name:nil)
        for (original,destination,contents) in [
            (trashPath,trashedFile,"trash recovery sample\n"),
            (trashDirectory+"/inside.txt",trashedDirectory+"/inside.txt","nested recovery sample\n")
        ] {
            XCTAssertThrowsError(try remote.request("read",path:original))
            XCTAssertEqual(try remote.request("read",path:destination).content,Data(contents.utf8).base64EncodedString())
        }
        wait("The tree removes trashed files and folders") {
            updatedTree.rootNode.children?.allSatisfy { $0.name != prefix && $0.name != prefix+".txt" } == true
        }
        let infoRoot = URL(fileURLWithPath:trashedFile).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("info")
        for (from,to) in [(trashPath,trashedFile),(trashDirectory,trashedDirectory)] {
            let info = infoRoot.appendingPathComponent(URL(fileURLWithPath:to).lastPathComponent+".trashinfo").path
            let metadata = try XCTUnwrap(Data(base64Encoded:XCTUnwrap(remote.request("read",path:info).content)))
            XCTAssertTrue(String(decoding:metadata,as:UTF8.self).removingPercentEncoding?.contains("Path="+from+"\n") == true)
        }
        XCTAssertThrowsError(try remote.renameItem(at:movedFile,to:"../invalid",in:root))
        XCTAssertThrowsError(try remote.renameItem(at:root+"/tracked.skip",to:"collision.txt",in:root))
        XCTAssertThrowsError(try remote.trashItem(at:root,in:root))
        XCTAssertEqual(try remote.request("read",path:root+"/collision.txt").content,Data("destination must remain\n".utf8).base64EncodedString())
        XCTAssertFalse(try XCTUnwrap(workspace.window).isVisible)
    }
}
