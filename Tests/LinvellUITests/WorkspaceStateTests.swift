import XCTest
import AppKit
import LinvellCore
@testable import Linvell

final class WorkspaceStateTests: XCTestCase {
    func testWorkspaceTitleBarRemainsOpaqueAcrossThemeChanges() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceController()
        defer { workspace.recoveryTimer?.invalidate() }
        let window = try XCTUnwrap(workspace.window)
        XCTAssertTrue(window.isOpaque)
        XCTAssertEqual(window.backgroundColor.alphaComponent,1)
        let defaults = UserDefaults.standard
        let keys = ["theme","followSystemTheme"]
        let saved = keys.map { defaults.object(forKey:$0) }
        defer { for (key,value) in zip(keys,saved) { defaults.set(value,forKey:key) } }
        defaults.set(false,forKey:"followSystemTheme")
        for profile in [Theme.Profile.seaGlass,.dark] {
            defaults.set(profile.rawValue,forKey:"theme")
            workspace.applyTheme()
            XCTAssertTrue(window.isOpaque)
            XCTAssertEqual(window.backgroundColor,Theme.panel)
        }
        XCTAssertFalse(window.isVisible)
    }

    func testLastWorkspaceRoundTripsLocalAndRemoteWithoutCloudKeys() throws {
        let name = "Linvell.WorkspaceStateTests."+UUID().uuidString,defaults = try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        for session in [WorkspaceSession.local(path:"/example/project"),.ssh(host:"example-host",path:"/example/remote-project")] {
            WorkspaceSession.save(session,defaults:defaults); XCTAssertEqual(WorkspaceSession.load(defaults:defaults),session)
        }
        XCTAssertFalse(PreferencesSync.defaults.keys.contains(WorkspaceSession.key))
        XCTAssertFalse(PreferencesSync.defaults.keys.contains(WorkspaceSession.startupKey))
    }
    func testStartupChoiceKeepsTheLastLocationWhileOpeningEmpty() throws {
        let name = "Linvell.StartupTests."+UUID().uuidString,defaults = try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        XCTAssertTrue(WorkspaceSession.shouldRestore(defaults:defaults))
        let location = WorkspaceSession.ssh(host:"example-host",path:"/example/project")
        WorkspaceSession.save(location,defaults:defaults)
        defaults.set("empty",forKey:WorkspaceSession.startupKey)
        XCTAssertFalse(WorkspaceSession.shouldRestore(defaults:defaults))
        XCTAssertEqual(WorkspaceSession.load(defaults:defaults),location)
        defaults.set("restore",forKey:WorkspaceSession.startupKey)
        XCTAssertTrue(WorkspaceSession.shouldRestore(defaults:defaults))
        XCTAssertEqual(WorkspaceSession.load(defaults:defaults),location)
    }
    func testSavedTabsOnlyRestoreForTheirWorkspace() throws {
        let name = "Linvell.WorkspaceTabsTests."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        let location = WorkspaceSession.ssh(host:"test-host",path:"/project")
        let tabs = WorkspaceTabs(workspace:location,paths:["/project/a.swift","/project/b.swift"],active:"/project/a.swift")
        defaults.set(try JSONEncoder().encode(tabs),forKey:WorkspaceTabs.key)
        XCTAssertEqual(WorkspaceTabs.load(for:location,defaults:defaults)?.paths,tabs.paths)
        let local = WorkspaceSession.local(path:"/local")
        WorkspaceTabs(workspace:local,paths:["/local/b.swift","/local/a.swift"],active:"/local/a.swift").save(defaults:defaults)
        XCTAssertEqual(WorkspaceTabs.load(for:local,defaults:defaults)?.paths,["/local/b.swift","/local/a.swift"])
        XCTAssertEqual(WorkspaceTabs.load(for:location,defaults:defaults)?.paths,tabs.paths)
        XCTAssertEqual(WorkspaceTabs.load(for:location,defaults:defaults)?.active,tabs.active)
        XCTAssertNil(WorkspaceTabs.load(for:.local(path:"/project"),defaults:defaults))
        XCTAssertNil(WorkspaceTabs.load(for:.ssh(host:"other-host",path:"/project"),defaults:defaults))
        XCTAssertFalse(PreferencesSync.defaults.keys.contains(WorkspaceTabs.key))
    }

    func testTabReorderRetainsSelection() {
        _ = NSApplication.shared
        let workspace = WorkspaceController()
        defer { workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil) }
        let a = OpenDocument(DocumentBuffer()), b = OpenDocument(DocumentBuffer()), c = OpenDocument(DocumentBuffer())
        workspace.documents = [a,b,c]; workspace.current = b
        XCTAssertTrue(workspace.moveTab(a.buffer.id,toInsertion:3))
        XCTAssertEqual(workspace.documents.map { $0.buffer.id },[b.buffer.id,c.buffer.id,a.buffer.id])
        XCTAssertTrue(workspace.moveTab(a.buffer.id,toInsertion:0))
        XCTAssertEqual(workspace.documents.map { $0.buffer.id },[a.buffer.id,b.buffer.id,c.buffer.id])
        XCTAssertTrue(workspace.current === b)
        XCTAssertFalse(workspace.moveTab(a.buffer.id,toInsertion:4))
    }

    func testTabTitleIsInsideTheWindowContentArea() throws {
        _ = NSApplication.shared
        let workspace = WorkspaceController()
        defer { workspace.recoveryTimer?.invalidate() }
        let window = try XCTUnwrap(workspace.window)
        let document = OpenDocument(DocumentBuffer())
        workspace.documents = [document]
        workspace.renderTabs()
        window.contentView?.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap(workspace.tabRows[document.buffer.id])
        let button = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? TabTitleButton }.first)
        let frame = button.convert(button.bounds,to:nil)
        XCTAssertFalse(frame.isEmpty)
        XCTAssertTrue(window.contentLayoutRect.contains(frame),"The title bar must leave the entire label clickable.")
    }

    func testActivityKeepsOneVisibleSelectedButton() {
        _ = NSApplication.shared
        let workspace = WorkspaceController()
        defer { workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil) }
        for index in 0..<workspace.activityButtons.count {
            workspace.selectActivity(index)
            XCTAssertEqual(workspace.activityButtons.filter { $0.state == .on }.count,1)
            XCTAssertEqual(workspace.activityButtons[index].state,.on)
        }
    }
    func testSelectedActivityRendersInLightAndDarkThemes() throws {
        _ = NSApplication.shared
        let original = Theme.profile
        defer { Theme.profile = original }
        for profile in [Theme.Profile.light,.dark] {
            Theme.profile = profile
            let strip = Surface(Theme.canvas)
            strip.frame = NSRect(x:0,y:0,width:116,height:272)
            for (index,symbol) in ["doc.on.doc","magnifyingglass","arrow.triangle.branch","list.bullet.rectangle","square.grid.2x2"].enumerated() {
                let off = Theme.activityButton(symbol,help:"Explorer",target:self,action:#selector(NSObject.className))
                let on = Theme.activityButton(symbol,help:"Explorer",target:self,action:#selector(NSObject.className))
                off.frame = NSRect(x:10,y:10+index*50,width:38,height:38)
                on.frame = NSRect(x:68,y:10+index*50,width:38,height:38)
                off.state = .off; off.contentTintColor = Theme.secondary
                on.state = .on; on.contentTintColor = Theme.accent
                strip.addSubview(off); strip.addSubview(on)
            }
            let bitmap = try XCTUnwrap(strip.bitmapImageRepForCachingDisplay(in:strip.bounds))
            strip.cacheDisplay(in:strip.bounds,to:bitmap)
            if let path = ProcessInfo.processInfo.environment["LINVELL_SNAPSHOT_DIR"] {
                try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(fileURLWithPath:path).appendingPathComponent("activity-"+profile.rawValue+".png"))
            }
            // Sample the left indicator, away from the symbol glyph.
            let scale = CGFloat(bitmap.pixelsWide)/strip.bounds.width
            let y = bitmap.pixelsHigh-Int(25*scale)
            let off = try XCTUnwrap(bitmap.colorAt(x:Int(11*scale),y:y))
            let on = try XCTUnwrap(bitmap.colorAt(x:Int(69*scale),y:y))
            XCTAssertNotEqual(off,on,"Selected activity needs a visible indicator in both themes.")
        }
    }
    func testGitFileRowsDoNotExposeRawStatusOrOverflow() throws {
        _ = NSApplication.shared
        let change = try XCTUnwrap(GitRepository.parseStatus("?? docs/research/"+String(repeating:"long-name-",count:15)+".md\0").first)
        let cell = GitFileCell(change:change)
        cell.frame = NSRect(x:0,y:0,width:320,height:58); cell.layoutSubtreeIfNeeded()
        XCTAssertEqual(cell.badge.stringValue,L.text("Untracked"))
        XCTAssertFalse(cell.name.stringValue.hasPrefix("??"))
        for label in [cell.name,cell.path,cell.badge] {
            XCTAssertTrue(cell.bounds.contains(label.frame),"Every label must stay inside its own row.")
            XCTAssertEqual(label.maximumNumberOfLines,1)
        }
        XCTAssertGreaterThanOrEqual(cell.path.frame.minY,0)
    }
}
