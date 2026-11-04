import AppKit
import XCTest
import LinvellCore
@testable import Linvell

final class GitReviewParityTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(descendants) }
    private func wait(_ condition: () -> Bool,file: StaticString = #filePath,line: UInt = #line) {
        let deadline = Date().addingTimeInterval(8)
        while !condition(),Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(condition(),file:file,line:line)
    }
    private func repository() throws -> GitRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"])
        _ = try repo.run(["config","user.name","Test"]); _ = try repo.run(["config","user.email","test@example.invalid"])
        _ = try repo.run(["config","commit.gpgsign","false"])
        return repo
    }
    private func owner() -> NSWindow {
        _ = NSApplication.shared
        return NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:800),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
    }
    func testNativeTreePreservesAncestorsFoldingFilteringAndSelection() throws {
        _ = NSApplication.shared
        let tree = GitReviewFileTree(frame:NSRect(x:0,y:0,width:280,height:500))
        tree.update(paths:["a/b/one.swift","a/c/two.swift","root.txt"],query:"",selection:"a/b/one.swift")
        XCTAssertEqual(tree.visiblePaths,["a/b/one.swift","a/c/two.swift","root.txt"])
        XCTAssertEqual(tree.directoryPaths,["a","a/b","a/c"])
        XCTAssertEqual((tree.outline.item(atRow:tree.outline.selectedRow) as? GitReviewFileTree.Node)?.path,"a/b/one.swift")
        var selected = ""; tree.onSelect = { selected = $0 }
        let two = try XCTUnwrap(tree.visibleRows.firstIndex { $0.path == "a/c/two.swift" })
        tree.outline.selectRowIndexes(IndexSet(integer:two),byExtendingSelection:false)
        XCTAssertEqual(selected,"a/c/two.swift")
        tree.toggle(path:"a")
        XCTAssertEqual(tree.visiblePaths,["root.txt"])
        tree.update(paths:["a/b/one.swift","a/c/two.swift","root.txt"],query:"one",selection:nil)
        XCTAssertEqual(tree.visiblePaths,["a/b/one.swift"])
    }
    func testPatchSyntaxAndSimilarityAlignmentRetainSourceOffsets() throws {
        _ = NSApplication.shared
        let patch = "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1,2 +1,3 @@\n-let answer = 1\n+// inserted note\n+let answer = 2\n return answer\n"
        let styled = GitDiffRendering.styled(patch,path:"a.swift")
        let keyword = (patch as NSString).range(of:"let answer = 2").location
        XCTAssertEqual(styled.attribute(.foregroundColor,at:keyword,effectiveRange:nil) as? NSColor,Theme.keyword)
        let split = GitSplitDiff(frame:NSRect(x:0,y:0,width:800,height:500))
        split.render(styled)
        let left = split.oldText.string.components(separatedBy:"\n"),right = split.newText.string.components(separatedBy:"\n")
        let old = try XCTUnwrap(left.firstIndex(of:"-let answer = 1"))
        XCTAssertEqual(right[old],"+let answer = 2")
        XCTAssertEqual(left[try XCTUnwrap(right.firstIndex(of:"+// inserted note"))],"")
        let mapping = try XCTUnwrap(split.newLines.first { (split.newText.string as NSString).substring(with:$0.display) == "+let answer = 2" })
        XCTAssertEqual((patch as NSString).substring(with:mapping.source),"+let answer = 2")
    }
    func testWrappedColumnsUseEqualLogicalRowHeightAndContinuousPatchExpands() throws {
        _ = NSApplication.shared
        let patch = "@@ -1,2 +1,2 @@\n-short\n+"+String(repeating:"longword ",count:45)+"\n context\n"
        let split = GitSplitDiff(frame:NSRect(x:0,y:0,width:700,height:500))
        split.layoutSubtreeIfNeeded(); split.setWrap(true); split.render(GitDiffRendering.styled(patch,path:"a.txt")); split.layoutSubtreeIfNeeded()
        let old = split.oldText.string as NSString,new = split.newText.string as NSString
        let oldContext = old.range(of:" context"),newContext = new.range(of:" context")
        func y(_ text: NSTextView,_ range: NSRange) -> CGFloat {
            let manager = text.layoutManager!; manager.ensureLayout(for:text.textContainer!)
            return manager.lineFragmentRect(forGlyphAt:manager.glyphIndexForCharacter(at:range.location),effectiveRange:nil).minY
        }
        XCTAssertEqual(y(split.oldText,oldContext),y(split.newText,newContext),accuracy:1)
        let panes = try XCTUnwrap(descendants(split).compactMap { $0 as? ResizablePanes }.first)
        panes.setPosition(220,ofDividerAt:0); split.layoutSubtreeIfNeeded()
        XCTAssertEqual(y(split.oldText,oldContext),y(split.newText,newContext),accuracy:1)
        let view = GitReviewDiffView(frame:NSRect(x:0,y:0,width:700,height:500))
        view.continuous = true
        view.render("@@ -1,100 +1,100 @@\n"+String(repeating:" context\n",count:100),path:"a.txt")
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.measuredHeight,1700)
    }
    func testExistingReviewViewsReactToSharedPreferences() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard,oldMode = defaults.object(forKey:"git.diffMode"),oldWrap = defaults.object(forKey:"git.wrapDiff")
        defer { if let oldMode { defaults.set(oldMode,forKey:"git.diffMode") } else { defaults.removeObject(forKey:"git.diffMode") }; if let oldWrap { defaults.set(oldWrap,forKey:"git.wrapDiff") } else { defaults.removeObject(forKey:"git.wrapDiff") } }
        let a = GitReviewDiffView(frame:NSRect(x:0,y:0,width:800,height:400)),b = GitReviewDiffView(frame:NSRect(x:0,y:0,width:800,height:400))
        defaults.set(2,forKey:"git.diffMode"); defaults.set(true,forKey:"git.wrapDiff")
        NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:defaults)
        for view in [a,b] {
            XCTAssertEqual(descendants(view).compactMap { $0 as? NSSegmentedControl }.first?.selectedSegment,2)
            XCTAssertEqual(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == L.text("Wrap Lines") }?.state,.on)
        }
    }
    func testFilteringAndCollapsedFoldersRestrictMultipleDiffBodies() throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at:repo.root) }
        let window = owner()
        let panel = GitReviewPanel(repository:repo,files:[.init(path:"a/b/one.txt",patch:{"ONE"}),.init(path:"a/c/two.txt",patch:{"TWO"})],owner:window)
        defer { if let sheet = panel.window { window.endSheet(sheet) }; window.orderOut(nil) }
        let content = try XCTUnwrap(panel.window?.contentView)
        let expand = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == L.text("Expand Diffs") })
        expand.performClick(nil)
        wait { self.descendants(content).compactMap { $0 as? GitReviewDiffView }.contains { $0.editor.string == "TWO" } }
        let search = try XCTUnwrap(descendants(content).compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "one"; search.sendAction(search.action,to:search.target)
        wait { !self.descendants(content).compactMap { $0 as? GitReviewDiffView }.contains { $0.editor.string == "TWO" } }
        let collapse = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == L.text("Collapse Folders") })
        search.stringValue = ""; search.sendAction(search.action,to:search.target); collapse.performClick(nil)
        XCTAssertFalse(descendants(content).compactMap { $0 as? GitReviewDiffView }.contains { $0.editor.string == "ONE" })
    }
    func testLargeSourceModeSurvivesDiskRefreshAndShowsMetadata() throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at:repo.root) }
        let path = repo.root.appendingPathComponent("large.txt")
        try String(repeating:"x",count:1_100_000).write(to:path,atomically:true,encoding:.utf8)
        let window = owner(),panel = GitReviewPanel(repository:repo,files:[.init(path:"large.txt",patch:nil)],owner:window)
        defer { if let sheet = panel.window { window.endSheet(sheet) }; window.orderOut(nil) }
        let content = try XCTUnwrap(panel.window?.contentView)
        let load = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == L.text("Load Large Plain Text") })
        wait { !load.isHidden }; load.performClick(nil)
        wait { self.descendants(content).compactMap { $0 as? NSTextView }.contains { $0.string.count == 1_100_000 } }
        try (String(repeating:"y",count:1_100_000)+"\nupdated").write(to:path,atomically:true,encoding:.utf8)
        panel.refreshFromDisk(force:true)
        wait { self.descendants(content).compactMap { $0 as? NSTextView }.contains { $0.string.hasSuffix("updated") } }
        XCTAssertTrue(descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains(L.text("Plain Text")) })
    }
    func testImageReviewCanStageCurrentImageAndRemoveCompletedEntry() throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at:repo.root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:4,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let data = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        try data.write(to:repo.root.appendingPathComponent("image.png"))
        let change = try XCTUnwrap(repo.changes().first),window = owner()
        let panel = GitReviewPanel(repository:repo,files:[.init(path:"image.png",patch:{ try repo.diff(change,staged:false) },indexSide:false,images:{ (nil,data) })],owner:window)
        defer { if let sheet = panel.window { window.endSheet(sheet) }; window.orderOut(nil) }
        let content = try XCTUnwrap(panel.window?.contentView)
        wait { self.descendants(content).compactMap { $0 as? NSButton }.contains { $0.title == L.text("Stage File") } }
        let stage = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == L.text("Stage File") })
        stage.performClick(nil)
        wait { (try? repo.run(["show",":image.png"])) != nil }
        wait { self.descendants(content).compactMap { $0 as? NSTextView }.contains { $0.string == L.text("No Changes") } }
    }
    func testRenamedFileHistoryShowsFullMetadataAndRefreshesAfterCommit() throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at:repo.root) }
        let old = repo.root.appendingPathComponent("old.txt"),new = repo.root.appendingPathComponent("new.txt")
        try "base\n".write(to:old,atomically:true,encoding:.utf8)
        _ = try repo.run(["add","."]); try repo.commit("original\n\nOriginal body")
        try FileManager.default.moveItem(at:old,to:new)
        _ = try repo.run(["add","-A"]); try repo.commit("renamed\n\nRename body")
        let window = owner(),panel = GitReviewPanel(repository:repo,files:[.init(path:"new.txt",patch:nil)],owner:window)
        defer { if let sheet = panel.window { window.endSheet(sheet) }; window.orderOut(nil) }
        let content = try XCTUnwrap(panel.window?.contentView)
        let modes = try XCTUnwrap(descendants(content).compactMap { $0 as? NSSegmentedControl }.first)
        modes.selectedSegment = 1; modes.sendAction(modes.action,to:modes.target)
        wait { self.descendants(content).compactMap { $0 as? NSPopUpButton }.contains { $0.itemTitles.contains { $0.contains("original") } } }
        let revisions = try XCTUnwrap(descendants(content).compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains { $0.contains("original") } })
        XCTAssertTrue(revisions.itemTitles.allSatisfy { $0.contains("Test") && $0.contains("T") })
        revisions.selectItem(at:1); revisions.sendAction(revisions.action,to:revisions.target)
        wait { self.descendants(content).compactMap { $0 as? GitReviewDiffView }.contains { $0.editor.string.contains("+base") } }
        XCTAssertTrue(descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Original body") })
        try "updated\n".write(to:new,atomically:true,encoding:.utf8)
        _ = try repo.run(["add","."]); try repo.commit("new tip")
        panel.refreshFromDisk(force:true)
        wait { revisions.itemTitles.count == 3 }
        XCTAssertTrue(revisions.selectedItem?.title.contains("original") == true)
    }
    func testFindUsesVisibleSplitEditorAndContextActionsRemainAttached() throws {
        let window = owner(),view = GitReviewDiffView(frame:NSRect(x:0,y:0,width:1000,height:600))
        window.contentView = view
        let oldMode = UserDefaults.standard.object(forKey:"git.diffMode")
        defer { if let oldMode { UserDefaults.standard.set(oldMode,forKey:"git.diffMode") } else { UserDefaults.standard.removeObject(forKey:"git.diffMode") }; window.orderOut(nil) }
        UserDefaults.standard.set(2,forKey:"git.diffMode")
        NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:UserDefaults.standard)
        view.render("@@ -1 +1 @@\n-before\n+after\n",path:"a.txt"); view.layoutSubtreeIfNeeded()
        view.find()
        XCTAssertTrue(view.visibleEditor.enclosingScrollView?.isFindBarVisible == true)
        XCTAssertFalse(view.editor.enclosingScrollView?.isFindBarVisible == true)
        let repo = GitRepository(root:FileManager.default.temporaryDirectory)
        var applied = false
        let panel = GitReviewPanel(repository:repo,files:[.init(path:"a.txt",patch:{"patch"})],owner:window,
            context:.init(title:"Stash review",base:"base",target:"target",statistics:"2 files",primaryActionTitle:"Apply inspected stash",primaryAction:{ applied = true }))
        let content = try XCTUnwrap(panel.window?.contentView)
        XCTAssertTrue(descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "base → target" })
        let apply = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Apply inspected stash" })
        apply.performClick(nil)
        XCTAssertTrue(applied)
        XCTAssertNil(window.attachedSheet)
    }

    func testContinuousReviewUsesMeasuredFramesWithoutInnerVerticalScroll() throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at:repo.root) }
        let patch = "diff --git a/a.swift b/a.swift\n--- a/a.swift\n+++ b/a.swift\n@@ -1,75 +1,75 @@\n"+(0..<75).map { " let value\($0) = \($0)\n" }.joined()
        let window = owner(),panel = GitReviewPanel(repository:repo,files:[.init(path:"src/a.swift",patch:{patch}),.init(path:"src/b.swift",patch:{patch})],owner:window)
        defer { if let sheet = panel.window { window.endSheet(sheet) }; window.orderOut(nil) }
        let content = try XCTUnwrap(panel.window?.contentView)
        let expand = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == L.text("Expand Diffs") })
        expand.performClick(nil)
        wait { self.descendants(content).compactMap { $0 as? GitReviewDiffView }.filter { $0.continuous && $0.editor.string == patch }.count == 2 }
        content.layoutSubtreeIfNeeded(); RunLoop.current.run(until:Date().addingTimeInterval(0.1)); content.layoutSubtreeIfNeeded()
        for preview in descendants(content).compactMap({ $0 as? GitReviewDiffView }).filter(\.continuous) {
            XCTAssertGreaterThan(preview.frame.height,1200)
            XCTAssertEqual(preview.frame.height,preview.measuredHeight,accuracy:2)
            XCTAssertFalse(preview.visibleEditor.enclosingScrollView?.hasVerticalScroller == true)
        }
        if let path = ProcessInfo.processInfo.environment["LINVELL_SNAPSHOT_DIR"] {
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in:content.bounds))
            content.cacheDisplay(in:content.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path).appendingPathComponent("git-review-continuous.png"))
        }
    }

    func testContinuousImagesUseMeasuredAspectHeightAndOuterScrolling() throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at:repo.root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:256,pixelsHigh:128,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let data = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let window = owner(),panel = GitReviewPanel(repository:repo,files:[.init(path:"a.png",patch:{"Binary files differ"},images:{(data,data)})],owner:window)
        defer { if let sheet = panel.window { window.endSheet(sheet) }; window.orderOut(nil) }
        let content = try XCTUnwrap(panel.window?.contentView)
        let expand = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == L.text("Expand Diffs") })
        expand.performClick(nil)
        wait { self.descendants(content).compactMap { $0 as? GitImageComparison }.contains(where: \.continuous) }
        content.layoutSubtreeIfNeeded(); RunLoop.current.run(until:Date().addingTimeInterval(0.1)); content.layoutSubtreeIfNeeded()
        let comparison = try XCTUnwrap(descendants(content).compactMap { $0 as? GitImageComparison }.first( where: \.continuous))
        XCTAssertEqual(comparison.frame.height,comparison.measuredHeight,accuracy:2)
        XCTAssertGreaterThan(comparison.frame.height,170)
        XCTAssertTrue(descendants(comparison).compactMap { $0 as? GitReviewCodeScroll }.allSatisfy { !$0.hasVerticalScroller && $0.continuous })
        if let path = ProcessInfo.processInfo.environment["LINVELL_SNAPSHOT_DIR"] {
            let image = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in:content.bounds)); content.cacheDisplay(in:content.bounds,to:image)
            try image.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path).appendingPathComponent("git-review-images.png"))
        }
    }

    func testImageRenameWithoutImageExtensionUsesBothImageVersions() throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at:repo.root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:16,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let data = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let patch = "diff --git a/icon.png b/asset\nsimilarity index 100%\nrename from icon.png\nrename to asset\n"
        let window = owner(),panel = GitReviewPanel(repository:repo,files:[.init(path:"asset",patch:{patch},images:{(data,data)})],owner:window)
        defer { if let sheet = panel.window { window.endSheet(sheet) }; window.orderOut(nil) }
        let content = try XCTUnwrap(panel.window?.contentView)
        wait { self.descendants(content).compactMap { $0 as? GitImageComparison }.count == 1 }
        let expand = try XCTUnwrap(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == L.text("Expand Diffs") })
        expand.performClick(nil)
        wait { self.descendants(content).compactMap { $0 as? GitImageComparison }.contains(where: \.continuous) }
        XCTAssertTrue(GitReviewPanel.patchContainsImagePath(patch))
    }

    func testStaticHistoricalMessageWrapsScrollsAndSurvivesViewModeChanges() throws {
        let repo = try repository(); defer { try? FileManager.default.removeItem(at:repo.root) }
        try "source\n".write(to:repo.root.appendingPathComponent("a.txt"),atomically:true,encoding:.utf8)
        let message = "Historical subject\n\n"+(0..<100).map { "Body line \($0): "+String(repeating:"readable words ",count:8) }.joined(separator:"\n")+"\nFinal message line"
        let window = owner(),panel = GitReviewPanel(repository:repo,files:[.init(path:"a.txt",patch:{"@@ -1 +1 @@\n-before\n+after\n"})],owner:window,
            context:.init(title:"Historical subject",statistics:"Author · date · full commit hash",message:message))
        defer { if let sheet = panel.window { window.endSheet(sheet) }; window.orderOut(nil) }
        let content = try XCTUnwrap(panel.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let context = try XCTUnwrap(descendants(content).compactMap { $0 as? GitReviewContextMessageView }.first)
        context.layoutSubtreeIfNeeded()
        XCTAssertEqual(context.text.string,message)
        XCTAssertTrue(context.text.isSelectable); XCTAssertFalse(context.text.isEditable)
        XCTAssertGreaterThan(context.frame.width,300); XCTAssertGreaterThan(context.frame.height,40)
        XCTAssertLessThanOrEqual(context.frame.height,140); XCTAssertGreaterThan(context.text.frame.height,context.contentSize.height)
        XCTAssertFalse(context.hasHorizontalScroller)
        let last = (message as NSString).range(of:"Final message line")
        context.text.scrollRangeToVisible(last)
        XCTAssertGreaterThan(context.contentView.bounds.minY,0)
        let modes = try XCTUnwrap(descendants(content).compactMap { $0 as? NSSegmentedControl }.first)
        for mode in [0,1,2] {
            modes.selectedSegment = mode; modes.sendAction(modes.action,to:modes.target)
            content.layoutSubtreeIfNeeded()
            XCTAssertFalse(context.isHidden); XCTAssertEqual(context.text.string,message)
        }
        if let path = ProcessInfo.processInfo.environment["LINVELL_SNAPSHOT_DIR"] {
            let image = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in:content.bounds)); content.cacheDisplay(in:content.bounds,to:image)
            try image.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path).appendingPathComponent("git-review-context-message.png"))
        }
    }

    func testSettingsPreviewCanHideToolbarWithoutChangingRenderingOrPreferences() throws {
        _ = NSApplication.shared
        let preview = GitReviewDiffView(frame:NSRect(x:0,y:0,width:800,height:400))
        let patch = "@@ -1 +1 @@\n-let value = 1\n+let value = 2\n"
        preview.render(patch,path:"Example.swift"); preview.layoutSubtreeIfNeeded()
        let height = preview.measuredHeight
        let mode = UserDefaults.standard.object(forKey:"git.diffMode") as? Int
        let wrapping = UserDefaults.standard.object(forKey:"git.wrapDiff") as? Bool
        XCTAssertTrue(descendants(preview).compactMap { $0 as? NSSegmentedControl }.contains { !$0.isHiddenOrHasHiddenAncestor })
        preview.showsControls = false; preview.layoutSubtreeIfNeeded()
        XCTAssertFalse(descendants(preview).compactMap { $0 as? NSSegmentedControl }.contains { !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertFalse(descendants(preview).compactMap { $0 as? NSButton }.contains { !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertEqual(preview.editor.string,patch)
        XCTAssertEqual(preview.measuredHeight,height-31,accuracy:1)
        XCTAssertGreaterThan(preview.visibleEditor.enclosingScrollView?.frame.height ?? 0,300)
        XCTAssertEqual(UserDefaults.standard.object(forKey:"git.diffMode") as? Int,mode)
        XCTAssertEqual(UserDefaults.standard.object(forKey:"git.wrapDiff") as? Bool,wrapping)
        preview.showsControls = true; preview.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendants(preview).compactMap { $0 as? NSSegmentedControl }.contains { !$0.isHiddenOrHasHiddenAncestor })
    }

}
