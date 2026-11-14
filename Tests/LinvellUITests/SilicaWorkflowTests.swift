import AppKit
import XCTest
@testable import Linvell
import LinvellCore

final class SilicaWorkflowTests: XCTestCase {
    func testExplorerListsAndFiltersHiddenItems() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey:ExplorerVisibility.key)
        defaults.removeObject(forKey:ExplorerVisibility.key)
        defer { defaults.set(previous,forKey:ExplorerVisibility.key) }
        XCTAssertTrue(ExplorerVisibility.showsHidden)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let git = root.appendingPathComponent(".git",isDirectory:true)
        let nested = root.appendingPathComponent(".linvell/.empty",isDirectory:true)
        try FileManager.default.createDirectory(at:git,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        try Data().write(to:git.appendingPathComponent("HEAD"))
        try Data().write(to:root.appendingPathComponent(".example"))
        XCTAssertEqual(Set(FileNode(root).children.map { $0.url.lastPathComponent }),[".git",".linvell",".example"])
        let index = ProjectFiles.list(root,forExplorer:true)
        let results = FileNode.filteredTree(index.filter { ProjectFiles.relative($0,root:root).contains(".empty") },under:root)
        XCTAssertEqual(results.first?.children.first?.url.lastPathComponent,".empty")
        XCTAssertEqual(results.first?.children.first?.isDirectory,true)
        XCTAssertTrue(index.contains { $0.path == git.appendingPathComponent("HEAD").path })
        XCTAssertTrue(ProjectFiles.list(root).isEmpty)
        let workspace = WorkspaceController()
        defer { workspace.recoveryTimer?.invalidate() }
        workspace.root = FileNode(root)
        XCTAssertEqual(workspace.outlineView(workspace.outline,numberOfChildrenOfItem:nil),3)
        ExplorerVisibility.setShowsHidden(false)
        XCTAssertEqual(workspace.outlineView(workspace.outline,numberOfChildrenOfItem:nil),0)
        XCTAssertTrue(ProjectFiles.list(root,forExplorer:true).isEmpty)
        ExplorerVisibility.setShowsHidden(true)
        XCTAssertEqual(workspace.outlineView(workspace.outline,numberOfChildrenOfItem:nil),3)
    }

    func testLocalFileCopySearchAndProjectRoutingWithoutOpeningWindows() throws {
        let app = NSApplication.shared
        XCTAssertNotEqual(app.activationPolicy(),.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        let nested = root.appendingPathComponent("nested",isDirectory:true)
        try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file = nested.appendingPathComponent("example.swift")
        let source = String(repeating:" ",count:165)+"😺 Find find\r\nThird"
        try Data(source.utf8).write(to:file)
        let first = try ExplorerActions.duplicate(file,directory:false),second = try ExplorerActions.duplicate(file,directory:false)
        XCTAssertEqual(first.lastPathComponent,"example copy.swift")
        XCTAssertEqual(second.lastPathComponent,"example copy 2.swift")
        XCTAssertEqual(try Data(contentsOf:second),Data(source.utf8))
        let folder = try ExplorerActions.duplicate(nested,directory:true)
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder.appendingPathComponent(file.lastPathComponent).path))
        let matches = ToolSidebar.matches(in:source,url:file,project:root,query:"find",exact:false,limit:10)
        XCTAssertEqual(matches.map(\.detail),["nested/example.swift:1","nested/example.swift:1"])
        XCTAssertEqual(matches.map(\.range.location),[168,173])
        XCTAssertEqual(ToolSidebar.matches(in:source,url:file,project:root,query:"find",exact:true,limit:10).count,1)
        XCTAssertTrue(matches.allSatisfy { NSMaxRange($0.highlight) <= $0.title.utf16.count })
        XCTAssertEqual(QuickPicker.fileQuery("nested/example.swift:21").line,21)
        XCTAssertEqual(QuickPicker.fileQuery(":3").name,"")
        XCTAssertNil(QuickPicker.fileQuery("example:abc").line)
        let outer = WorkspaceSession.local(path:root.path),inner = WorkspaceSession.local(path:nested.path)
        XCTAssertEqual(AppDelegate.projectFolder(for:file,recent:[outer,inner]).path,nested.path)

        let tree = FileNode.filteredTree([file,second],under:root)
        XCTAssertEqual(tree.map { $0.url.lastPathComponent },["nested"])
        XCTAssertEqual(tree.first?.children.count,2)
        let workspace = WorkspaceController()
        defer { workspace.recoveryTimer?.invalidate() }
        let alpha = OpenDocument(DocumentBuffer(text:"one")),bravo = OpenDocument(DocumentBuffer(text:"two"))
        workspace.activate(alpha); workspace.activate(bravo); workspace.selectNextTab()
        XCTAssertTrue(workspace.current === alpha)
        workspace.selectPreviousTab()
        XCTAssertTrue(workspace.current === bravo)
        XCTAssertFalse(try XCTUnwrap(workspace.window).isVisible)
    }

    func testIndentDetectionAndMarkupCommentRoundTrip() throws {
        let twoSpaces = try XCTUnwrap(EditorIndentation.detect("func demo() {\n  if true {\n    print(1)\n  }\n}"))
        XCTAssertEqual(twoSpaces.unit,"  ")
        let tabs = try XCTUnwrap(EditorIndentation.detect("first\n\tsecond\n\t\tthird"))
        XCTAssertEqual(tabs.unit,"\t")
        XCTAssertNil(EditorIndentation.detect("first\nsecond"))
        let source = "  <p>Example</p>  \n\n  <a>Link</a>"
        let selection = [NSRange(location:0,length:source.utf16.count)]
        let markup = SourceSyntax.commentDelimiters(for:"page.html")
        let action = LineEditing.Action.blockComment(markup.open,try XCTUnwrap(markup.close))
        let commented = LineEditing.apply(action,text:source,selections:selection)
        XCTAssertEqual(commented.text,"  <!-- <p>Example</p>   -->\n\n  <!-- <a>Link</a> -->")
        XCTAssertEqual(LineEditing.apply(action,text:commented.text,selections:commented.selections).text,source)
        XCTAssertEqual(SourceSyntax.commentDelimiters(for:"Dockerfile").open,"#")
    }

    func testRecentRemovalAndClearingKeepStartupAndTabHistory() throws {
        let key = "Linvell.RecentTests."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:key))
        defer { defaults.removePersistentDomain(forName:key) }
        let local = WorkspaceSession.local(path:"/projects/local"),remote = WorkspaceSession.ssh(host:"sample",path:"/projects/remote")
        WorkspaceSession.save(local,defaults:defaults)
        WorkspaceSession.save(remote,defaults:defaults)
        WorkspaceTabs(workspace:remote,paths:["/projects/remote/test.swift"],active:nil).save(defaults:defaults)
        WorkspaceSession.removeRecent(local,defaults:defaults)
        XCTAssertEqual(WorkspaceSession.recent(defaults:defaults),[remote])
        WorkspaceSession.clearRecents(defaults:defaults)
        XCTAssertEqual(WorkspaceSession.recent(defaults:defaults),[])
        XCTAssertEqual(WorkspaceSession.load(defaults:defaults),remote)
        XCTAssertEqual(WorkspaceTabs.load(for:remote,defaults:defaults)?.paths,["/projects/remote/test.swift"])
        XCTAssertEqual(Theme.Profile.githubLight.matching(dark:true),.githubDark)
        XCTAssertEqual(Theme.Profile.solarizedDark.matching(dark:false),.solarized)
    }
}
