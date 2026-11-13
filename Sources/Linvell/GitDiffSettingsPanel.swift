import AppKit

/// Shared diff presentation preferences with the same renderer used by reviews.
final class GitDiffSettingsPanel: GitNativeSheet {
    private let layout = Theme.choiceButton(),wrap = NSButton(checkboxWithTitle:L.text("Wrap Lines"),target:nil,action:nil)
    private let font = Theme.choiceButton(),size = NSTextField()
    private let preview = GitReviewDiffView(frame:NSRect(x:0,y:0,width:720,height:220))
    private let fonts: [EditorFonts.Option]
    private let patch = "diff --git a/Example.swift b/Example.swift\n--- a/Example.swift\n+++ b/Example.swift\n@@ -1,3 +1,3 @@\n struct Example {\n-    let title = \"Before\"\n+    let title = \"After\" // Preview\n }\n"
    init(owner: NSWindow) {
        let selected = UserDefaults.standard.string(forKey:"editorFontFamily") ?? "SF Mono"
        fonts = EditorFonts.installedMonospace(selected:selected)
        super.init(title:"Diff Appearance",owner:owner,width:800)
        layout.addItems(withTitles:[L.text("Auto"),L.text("Unified"),L.text("Side by Side")])
        layout.selectItem(at:UserDefaults.standard.object(forKey:"git.diffMode") as? Int ?? 1)
        wrap.state = UserDefaults.standard.bool(forKey:"git.wrapDiff") ? .on : .off
        font.addItems(withTitles:fonts.map(\.title)); font.selectItem(at:fonts.firstIndex { $0.value == selected || EditorFonts.resolve($0.value,size:14)?.fontName == EditorFonts.resolve(selected,size:14)?.fontName } ?? 0)
        size.stringValue = String(Int(Theme.fontSize))
        for control in [layout,font,wrap,size] as [NSControl] { control.target = self; control.action = #selector(save) }
        row("Diff Layout",layout); body.addArrangedSubview(wrap); row("Editor Font",font); row("Font Size",size)
        body.addArrangedSubview(Theme.label("Font changes also apply to the source editor.",size:11,color:Theme.secondary))
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.widthAnchor.constraint(equalToConstant:740).isActive = true; preview.heightAnchor.constraint(equalToConstant:230).isActive = true
        preview.showsControls = false
        body.addArrangedSubview(preview); preview.render(patch,path:"Example.swift"); fit()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func save() {
        let defaults = UserDefaults.standard
        defaults.set(layout.indexOfSelectedItem,forKey:"git.diffMode"); defaults.set(wrap.state == .on,forKey:"git.wrapDiff")
        if fonts.indices.contains(font.indexOfSelectedItem) { defaults.set(fonts[font.indexOfSelectedItem].value,forKey:"editorFontFamily") }
        Theme.fontSize = CGFloat(min(30,max(11,size.integerValue))); size.stringValue = String(Int(Theme.fontSize))
        PreferencesSync.shared.changed()
        preview.render(patch,path:"Example.swift")
    }
}
