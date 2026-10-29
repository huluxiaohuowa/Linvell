import AppKit
import LinvellCore

/// Folder-scoped configuration deliberately lives outside application Preferences.
final class ProjectSettingsController: NSWindowController {
    var scope: String
    let languageTools: LanguageToolsPane
    init(owner: WorkspaceController) {
        let remote = owner.remoteConnection,root = remote == nil ? owner.root!.url.path : owner.remoteDirectory
        scope = LanguageTools.scope(remote:remote,root:root)
        languageTools = LanguageToolsPane(owner:owner)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:850,height:720),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = L.text("Project Settings")+" — "+URL(fileURLWithPath:root).lastPathComponent
        window.minSize = NSSize(width:660,height:560); window.center(); window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named:Theme.isDark ? .darkAqua : .aqua)
        super.init(window:window)
        let canvas = Surface(Theme.canvas); window.contentView = canvas
        let folder = NSTextField(wrappingLabelWithString:root); folder.font = .monospacedSystemFont(ofSize:12,weight:.regular); folder.textColor = Theme.secondary; folder.isSelectable = true
        let host = Theme.label(remote.map { "SSH · "+$0.host } ?? L.text("This Mac"),size:13,color:Theme.accent)
        languageTools.onRootResolved = { [weak self,weak window] path in
            folder.stringValue = path; window?.title = L.text("Project Settings")+" — "+URL(fileURLWithPath:path).lastPathComponent
            self?.scope = LanguageTools.scope(remote:remote,root:path)
        }
        let title = Theme.label("Project Settings",size:28,weight:.semibold)
        let description = NSTextField(wrappingLabelWithString:L.text("Applies only to this folder. Configuration is stored in its .linvell/settings.json.")); description.font = .systemFont(ofSize:13); description.textColor = Theme.secondary
        let scroll = ResponsiveScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = ProjectSettingsDocument(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        Theme.pin(Theme.stack([title,host,folder,description,Theme.label("Language Tools",size:18,weight:.semibold),languageTools,NSView()],orientation:.vertical,spacing:14),in:document,inset:24)
        document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor).isActive = true
        document.heightAnchor.constraint(greaterThanOrEqualTo:scroll.contentView.heightAnchor).isActive = true
        Theme.pin(scroll,in:canvas)
        NotificationCenter.default.addObserver(self,selector:#selector(languageChanged),name:L.changed,object:nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func languageChanged() { window?.title = L.text("Project Settings")+" — "+URL(fileURLWithPath:languageTools.root).lastPathComponent; if let content = window?.contentView { L.apply(to:content) } }
}
private final class ProjectSettingsDocument: NSView { override var isFlipped: Bool { true } }

extension WorkspaceController {
    @objc func showProjectSettings() {
        guard root != nil || remoteConnection != nil else { status.stringValue = L.text("Open a project folder before configuring its language tools."); return }
        let root = remoteConnection == nil ? self.root!.url.path : remoteDirectory
        let scope = LanguageTools.scope(remote:remoteConnection,root:root)
        if projectSettings?.scope != scope { projectSettings?.close(); projectSettings = ProjectSettingsController(owner:self) }
        projectSettings?.showWindow(nil); projectSettings?.window?.makeKeyAndOrderFront(nil)
    }
}
