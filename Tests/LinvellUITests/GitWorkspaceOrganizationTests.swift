import AppKit
import XCTest
import LinvellCore
@testable import Linvell

final class GitWorkspaceOrganizationTests: XCTestCase {
    func testRemovingRepositoryRemovesSavedAndRecentButKeepsGroupAndFiles() throws {
        let suite = "Linvell.RepositoryOrganization."+UUID().uuidString,defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let location = WorkspaceSession.local(path:"/fixture/repo")
        GitRepositoryOrganization.persist([location],defaults:defaults); WorkspaceSession.save(location,defaults:defaults)
        defaults.set([location.repositoryID:"Group"],forKey:"git.repositoryGroups"); defaults.set(["Group"],forKey:"git.repositoryGroupNames")
        GitRepositoryOrganization.remove([location.repositoryID],defaults:defaults)
        XCTAssertTrue(GitRepositoryOrganization.locations(defaults:defaults).isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey:"git.repositoryGroupNames"),["Group"])
    }
    func testRelocationMigratesPreferencesAndRemoteIdentity() throws {
        let suite = "Linvell.RepositoryRelocation."+UUID().uuidString,defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let old = WorkspaceSession.ssh(host:"fixture",path:"/old"),new = WorkspaceSession.ssh(host:"fixture",path:"/new")
        GitRepositoryOrganization.persist([old],defaults:defaults); WorkspaceSession.save(old,defaults:defaults)
        defaults.set([old.repositoryID:"Alias"],forKey:"git.repositoryAliases"); defaults.set([old.repositoryID:"Group"],forKey:"git.repositoryGroups"); defaults.set([old.repositoryID:false],forKey:"git.repositoryWorktreeVisibility")
        defaults.set("Failure",forKey:GitAutoFetchScheduler.key(old)+".error"); defaults.set([GitAutoFetchScheduler.key(old):"Failure"],forKey:"git.autoFetchErrors")
        XCTAssertNil(GitRepositoryOrganization.relocate(old,to:"/new",defaults:defaults))
        XCTAssertEqual(GitRepositoryOrganization.locations(defaults:defaults),[new])
        XCTAssertEqual(defaults.dictionary(forKey:"git.repositoryAliases")?[new.repositoryID] as? String,"Alias")
        XCTAssertFalse(GitRepositoryOrganization.showsWorktrees(new,defaults:defaults))
        XCTAssertEqual(defaults.string(forKey:GitAutoFetchScheduler.key(new)+".error"),"Failure")
        XCTAssertEqual(defaults.dictionary(forKey:"git.autoFetchErrors")?[GitAutoFetchScheduler.key(new)] as? String,"Failure")
    }
    func testWorktreeVisibilityIsSharedAcrossTheRepositoryFamily() throws {
        let suite = "Linvell.WorktreeVisibility."+UUID().uuidString,defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let main = WorkspaceSession.local(path:"/fixture/main"),linked = WorkspaceSession.local(path:"/fixture/linked")
        let trees = GitWorktreeEntry.parse("worktree /fixture/main\0branch refs/heads/main\0\0worktree /fixture/linked\0branch refs/heads/feature\0")
        defaults.set([linked.repositoryID:false],forKey:"git.repositoryWorktreeVisibility")
        GitRepositoryOrganization.registerWorktreeFamily(trees,location:main,defaults:defaults)
        XCTAssertFalse(GitRepositoryOrganization.showsWorktrees(main,defaults:defaults)); XCTAssertFalse(GitRepositoryOrganization.showsWorktrees(linked,defaults:defaults))
        GitRepositoryOrganization.setWorktreesEnabled(true,for:linked,defaults:defaults)
        XCTAssertTrue(GitRepositoryOrganization.showsWorktrees(main,defaults:defaults)); XCTAssertTrue(GitRepositoryOrganization.showsWorktrees(linked,defaults:defaults))
    }
    func testMovedReviewMetadataPreservesSnapshotsAndDeletedHistory() throws {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/final-audit/workspace-fixtures").appendingPathComponent(UUID().uuidString),reviews = base.appendingPathComponent("Reviews"),bucket = base.appendingPathComponent("Tasks/bucket")
        defer { try? FileManager.default.removeItem(at:base) }; try FileManager.default.createDirectory(at:bucket,withIntermediateDirectories:true)
        let old = "/fixture/old",new = "/fixture/new",sourceStore = ReviewCommentStore(project:old,host:nil,directory:reviews),targetStore = ReviewCommentStore(project:new,host:nil,directory:reviews)
        let note = try ReviewComment.editor(path:old+"/file.swift",text:"immutable snapshot\n",range:NSRange(location:0,length:9)); try sourceStore.save([note])
        try GitWorktreePersistence.relocate(.local(path:old),to:new,support:base)
        let moved = try XCTUnwrap(targetStore.load().first)
        XCTAssertEqual(moved.path,new+"/file.swift"); XCTAssertEqual(moved.lines,note.lines)
        try GitWorktreePersistence.relocate(.local(path:new),to:nil,support:base)
        XCTAssertEqual(try targetStore.load().count,1)
    }
    func testBrowserRendersPersistedInterleavedGroupAndStandaloneRootOrder() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["git.savedRepositories",WorkspaceSession.recentKey,WorkspaceSession.key,"lastProject","git.repositoryGroups","git.repositoryGroupNames","git.repositorySort","git.repositorySortAscending","git.repositoryOrder","git.repositoryRootOrder","git.repositoryGroupOrder","git.repositoryCollapsedGroups","git.archivedRepositories","git.repositoryAliases","git.repositoryAdded","git.repositoryModified","git.repositoryWorktreeFamilies"]
        let previous = keys.map { ($0,defaults.object(forKey:$0)) }
        defer { for (key,value) in previous { defaults.set(value,forKey:key) } }
        for key in keys { defaults.removeObject(forKey:key) }
        let grouped = WorkspaceSession.local(path:"/fixture/grouped"),standalone = WorkspaceSession.local(path:"/fixture/standalone")
        GitRepositoryOrganization.persist([grouped,standalone]); defaults.set([grouped.repositoryID:"Group"],forKey:"git.repositoryGroups"); defaults.set(["Group"],forKey:"git.repositoryGroupNames")
        defaults.set(GitRepositorySort.manual.rawValue,forKey:"git.repositorySort"); defaults.set([standalone.repositoryID,"group:Group"],forKey:"git.repositoryRootOrder")
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        owner.orderFront(nil)
        let browser = GitRepositoryBrowserPanel(owner:owner,onOpen:{ _ in },onClone:{},onAdd:{},onGroup:{ _,_ in })
        defer { browser.closeSheet(); owner.orderOut(nil) }
        let outline = browser.outline
        let first = try XCTUnwrap(outline.dataSource?.outlineView?(outline,child:0,ofItem:nil) as? GitRepositoryBrowserPanel.Node)
        let second = try XCTUnwrap(outline.dataSource?.outlineView?(outline,child:1,ofItem:nil) as? GitRepositoryBrowserPanel.Node)
        XCTAssertEqual(first.location,standalone); XCTAssertEqual(second.id,"group:Group")
        XCTAssertEqual(second.children.first?.location,grouped)
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        let rendered = try XCTUnwrap(outline.view(atColumn:0,row:0,makeIfNecessary:true) as? NSTextField)
        XCTAssertEqual(rendered.stringValue,"standalone")
    }
    func testNativeSheetsAndNestedAlertsMatchDarkAndLightEditorThemes() throws {
        _ = NSApplication.shared
        let previous = UserDefaults.standard.object(forKey:"theme"),plugin = Theme.pluginTheme
        defer { UserDefaults.standard.set(previous,forKey:"theme"); Theme.pluginTheme = plugin }
        for profile in [Theme.Profile.dark,.light] {
            Theme.profile = profile
            let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:[.titled],backing:.buffered,defer:false)
            owner.appearance = NSAppearance(named:profile.isDark ? .aqua : .darkAqua)
            owner.orderFront(nil)
            let sheet = GitNativeSheet(title:"Repository Settings",owner:owner,width:760)
            let window = try XCTUnwrap(sheet.window)
            sheet.row("Source",Theme.label("/fixture/source")); sheet.fit(); window.contentView?.layoutSubtreeIfNeeded()
            let expected: NSAppearance.Name = profile.isDark ? .darkAqua : .aqua
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]),expected)
            let alert = GitNativeSheet.alert(owner:window)
            XCTAssertEqual(alert.window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]),expected)
            XCTAssertEqual(window.backgroundColor,Theme.panel)
            sheet.closeSheet(); owner.orderOut(nil)
        }
    }
    func testLongWorktreeMetadataKeepsTheIntendedSheetWidth() throws {
        _ = NSApplication.shared
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:900),styleMask:[.titled],backing:.buffered,defer:false)
        owner.orderFront(nil)
        let sheet = GitNativeSheet(title:"Finish Worktree",owner:owner,width:760)
        let path = String(repeating:"/very-long-ssh-worktree-component",count:16)
        let field = Theme.label(path)
        sheet.row("Source",field); sheet.row("Target Worktree",Theme.label(path+"/target")); sheet.fit()
        sheet.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(sheet.window?.contentView?.bounds.width ?? 0,761)
        XCTAssertLessThanOrEqual(field.bounds.width,720)
        XCTAssertEqual(field.toolTip,path)
        sheet.closeSheet(); owner.orderOut(nil)
    }
    func testNativeWorktreePanelExposesDetachedAndMergeOnlyReview() throws {
        _ = NSApplication.shared
        let owner = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        let repo = GitRepository(root:URL(fileURLWithPath:"/nonexistent-fixture"))
        owner.orderFront(nil)
        let panel = GitWorktreeCreatePanel(repository:repo,owner:owner,onCreated:{ _ in })
        panel.window?.orderFront(nil)
        XCTAssertEqual(panel.mode.numberOfItems,3); XCTAssertEqual(panel.mode.itemTitle(at:2),L.text("Detached HEAD"))
        let deadline = Date().addingTimeInterval(3); while panel.working,Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        if let view = panel.window?.contentView {
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            XCTAssertGreaterThan(panel.window!.frame.height,300)
            XCTAssertLessThan(panel.window!.frame.height,(NSScreen.main?.visibleFrame.height ?? 1000)+30)
            if let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:bitmap)
                let output = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/final-audit/workspace-create-panel.png")
                try bitmap.representation(using:.png,properties:[:])?.write(to:output)
            }
        }
        panel.closeSheet(); owner.orderOut(nil)
    }
}
