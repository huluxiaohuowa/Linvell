import AppKit
import XCTest
import LinvellCore
@testable import Linvell

final class GitRepositoryPickerTests: XCTestCase {
    func testCloneOpensRepositoryAndPickerRetainsAliasesArchiveAndManualOrder() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["lastProject","git.repositoryAliases","git.archivedRepositories","git.repositoryOrder",
                    "git.repositoryGroups","git.repositoryGroupNames","git.repositorySortByName","git.repositorySort","git.repositorySortAscending","git.repositoryAdded","git.repositoryOpened","git.repositoryModified","git.savedRepositories",WorkspaceSession.key,WorkspaceSession.recentKey]
        let previous = keys.map { ($0,defaults.object(forKey:$0)) }
        defer { for (key,value) in previous { defaults.set(value,forKey:key) } }
        defaults.set("manual",forKey:"git.repositorySort")
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let source = fixture.appendingPathComponent("source")
        let destination = fixture.appendingPathComponent("cloned")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:fixture) }
        let repo = GitRepository(root:source)
        _ = try repo.run(["init","-b","main"])
        let workspace = WorkspaceController()
        defer { workspace.picker?.dismiss(); workspace.window?.orderOut(nil) }
        let done = expectation(description:"Clone selected")
        workspace.cloneGitRepository(from:source.path,into:destination) { success in
            XCTAssertTrue(success)
            done.fulfill()
        }
        wait(for:[done],timeout:10)
        XCTAssertEqual(workspace.gitWorkspaceView?.repository.directory,destination.path)
        XCTAssertTrue(WorkspaceSession.recent().contains(.local(path:destination.path)))

        let current = "local:"+destination.path,previousRepo = "local:"+source.path
        let extra = fixture.appendingPathComponent("extra")
        let extraID = "local:"+extra.path
        defaults.set(try JSONEncoder().encode([WorkspaceSession.local(path:source.path),.local(path:extra.path)]),forKey:"git.savedRepositories")
        defaults.set([current:"Cloned alias"],forKey:"git.repositoryAliases")
        defaults.set([previousRepo],forKey:"git.archivedRepositories")
        workspace.browseGitRepositories()
        let picker = try XCTUnwrap(workspace.picker)
        XCTAssertEqual(picker.options.first { $0.reorderID == current }?.title,"Cloned alias")
        XCTAssertFalse(picker.options.contains { $0.reorderID == previousRepo })
        XCTAssertTrue(picker.moveRepository(extraID,before:current))
        XCTAssertEqual(defaults.stringArray(forKey:"git.repositoryOrder")?.first,extraID)
        let archive = try XCTUnwrap(picker.options.first { $0.title == L.text("Archived Repositories…") })
        picker.dismiss()
        archive.invoke()
        XCTAssertTrue(workspace.picker?.options.contains { $0.reorderID == previousRepo } == true)
        workspace.picker?.dismiss()
        workspace.manageGitGroups([.local(path:source.path),.local(path:destination.path)])
        let groups = try XCTUnwrap(workspace.picker)
        let add = try XCTUnwrap(groups.options.first { $0.title == L.text("New Group…") })
        groups.dismiss(); add.invoke()
        let sheet = try XCTUnwrap(workspace.window?.attachedSheet)
        func descendants(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(descendants) }
        let controls = descendants(try XCTUnwrap(sheet.contentView))
        let name = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }.first { $0.placeholderString == L.text("Group Name") })
        name.stringValue = "Fixture group"
        let check = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.toolTip == source.path })
        check.state = .on
        let submit = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == L.text("Save") })
        submit.performClick(nil)
        let deadline = Date().addingTimeInterval(3)
        while (defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String])?[previousRepo] != "Fixture group",Date() < deadline {
            RunLoop.current.run(until:Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual((defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String])?[previousRepo],"Fixture group")
    }
}
