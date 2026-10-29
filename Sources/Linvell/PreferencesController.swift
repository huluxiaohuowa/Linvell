import AppKit

final class PreferencesController: NSWindowController {
    weak var workspaceOwner: WorkspaceController?
    let detail = Surface(Theme.canvas)
    let navigation = Surface(Theme.panel)
    var category = 0
    var buttons: [NSButton] = []
    var statusLabel: NSTextField?
    var statusTimer: Timer?
    init(owner: WorkspaceController? = nil) {
        self.workspaceOwner = owner
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title = L.text("Linvell Settings"); window.minSize = NSSize(width:780,height:610); window.center(); window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named:Theme.profile.isDark ? .darkAqua : .aqua); window.backgroundColor = Theme.canvas
        super.init(window:window)
        let stack = Theme.stack([navigation,detail],spacing:0); stack.alignment = .top
        Theme.pin(stack,in:window.contentView!)
        navigation.widthAnchor.constraint(equalToConstant:200).isActive = true
        navigation.heightAnchor.constraint(equalTo:stack.heightAnchor).isActive = true; detail.heightAnchor.constraint(equalTo:stack.heightAnchor).isActive = true
        let heading = Theme.label("SETTINGS",size:11,color:Theme.secondary,weight:.semibold)
        var rows: [NSView] = [heading]
        for (index,entry) in [("paintpalette","Appearance"),("textformat","Editor"),("keyboard","Vim"),("icloud","Sync"),("arrow.triangle.2.circlepath","Updates")].enumerated() {
            let b = NSButton(title:L.text(entry.1),image:NSImage(systemSymbolName:entry.0,accessibilityDescription:nil)!,target:self,action:#selector(selectCategory(_:)))
            b.tag = index; b.isBordered = false; b.imagePosition = .imageLeading; b.alignment = .left; b.font = .systemFont(ofSize:14)
            b.heightAnchor.constraint(equalToConstant:40).isActive = true; buttons.append(b); rows.append(b)
        }
        rows.append(NSView()); rows.append(Theme.label("Linvell \(UpdateManager.currentVersion)",size:11,color:Theme.secondary))
        Theme.pin(Theme.stack(rows,orientation:.vertical,spacing:12),in:navigation,inset:20)
        render()
        NotificationCenter.default.addObserver(self,selector:#selector(preferencesUpdated),name:PreferencesSync.didApply,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(updateStatusChanged),name:UpdateManager.changed,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(languageApplied),name:L.changed,object:nil)
        statusTimer = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
            guard let self else { return }; self.statusLabel?.stringValue = self.category == 3 ? PreferencesSync.shared.status : UpdateManager.shared.status
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self); statusTimer?.invalidate() }
    @objc private func selectCategory(_ sender: NSButton) { category = sender.tag; render() }
    func showUpdates() { category = 4; render(); showWindow(nil); window?.makeKeyAndOrderFront(nil) }
    @objc private func updateStatusChanged() { if category == 4 { render() } }
    @objc private func languageApplied() {
        window?.title = L.text("Linvell Settings"); L.apply(to:navigation)
        for (index,title) in ["Appearance","Editor","Vim","Sync","Updates"].enumerated() { buttons[index].title = L.text(title) }
        render()
    }
    @objc private func preferencesUpdated() {
        window?.appearance = NSAppearance(named:Theme.profile.isDark ? .darkAqua : .aqua); window?.backgroundColor = Theme.canvas
        navigation.refreshTheme(); detail.refreshTheme(); render()
    }
    private func render() {
        detail.subviews.forEach { $0.removeFromSuperview() }; statusLabel = nil
        buttons.forEach { $0.contentTintColor = $0.tag == category ? Theme.accent : Theme.secondary }
        let title = ["Appearance","Editor","Vim","iCloud Sync","Updates"][category]
        let subtitle = ["A workspace that feels like your own.","Comfortable text, deliberate defaults.","A native engine, built one behavior at a time.","Your preferences, across your Macs.","Stay current, on your terms."][category]
        var rows: [NSView] = [Theme.label(title,size:30,weight:.semibold),Theme.label(subtitle,size:14,color:Theme.secondary)]
        switch category {
        case 0:
            rows.append(section("STARTUP"))
            let startup = Theme.choiceButton()
            startup.addItems(withTitles:[L.text("Empty window"),L.text("Restore last workspace")])
            startup.selectItem(at:WorkspaceSession.shouldRestore ? 1 : 0); startup.target = self; startup.action = #selector(startupChanged(_:))
            rows.append(settingRow("On startup",startup))
            rows.append(text("Restore the last local project or SSH folder. Files and folders opened from Finder always take priority."))
            rows.append(section("INTERFACE LANGUAGE"))
            let language = Theme.choiceButton()
            language.addItems(withTitles:[L.text("Follow macOS"),"English","简体中文"])
            let choices = ["system","en","zh-Hans"]
            language.selectItem(at:choices.firstIndex(of:UserDefaults.standard.string(forKey:L.languageKey) ?? "system") ?? 0)
            language.target = self; language.action = #selector(languageChanged(_:))
            rows.append(settingRow("Language",language))
            rows.append(text("Language changes apply immediately. You can also choose its language in macOS System Settings → General → Language & Region → Applications."))
            rows.append(section("COLOR THEME"))
            let profiles = Theme.Profile.allCases
            for start in stride(from:0,to:profiles.count,by:2) {
                var tiles: [NSView] = []
                for profile in profiles[start..<min(start+2,profiles.count)] {
                    let b = ThemePreview(profile:profile,target:self,action:#selector(themeSelected(_:))); b.tag = Theme.Profile.allCases.firstIndex(of:profile)!
                    tiles.append(b)
                }
                let row = Theme.stack(tiles,spacing:16); row.distribution = .fillEqually; rows.append(row)
            }
            rows.append(Theme.label("Themes update the editor, sidebar and terminal together.",size:12,color:Theme.secondary))
        case 1:
            rows.append(section("SAVING"))
            rows.append(check("Automatically save changes",key:"autoSave"))
            rows.append(text("Save existing local and remote files after a short pause. New untitled files still need Save As. External-change conflicts stop automatic saving."))
            rows.append(section("TYPOGRAPHY"))
            let selected = PreferencesSync.value("editorFontFamily"),options = EditorFonts.installedMonospace(selected:selected)
            let font = Theme.choiceButton()
            for option in options { font.addItem(withTitle:option.title); font.lastItem?.representedObject = option.value }
            let resolved = selected == "SF Mono" ? selected : EditorFonts.resolve(selected,size:14)?.fontName ?? selected
            if let index = options.firstIndex(where:{ $0.value == resolved || $0.value == selected }) { font.selectItem(at:index) }
            font.identifier = NSUserInterfaceItemIdentifier("editorFontFamily"); font.target = self; font.action = #selector(popupChanged(_:))
            let all = Theme.actionButton("All Fonts…",target:self,action:#selector(showAllFonts))
            rows.append(settingRow("Font family",Theme.stack([font,all],spacing:8)))
            rows.append(text("The list includes installed monospace fonts. All Fonts opens the macOS font chooser; the terminal keeps a monospace font."))
            let size = Theme.choiceButton(); size.addItems(withTitles:(11...30).map(String.init))
            size.selectItem(withTitle:String(Int(Theme.fontSize))); size.identifier = NSUserInterfaceItemIdentifier("editorFontSize"); size.target = self; size.action = #selector(popupChanged(_:))
            rows.append(settingRow("Font size",size))
            rows.append(section("LAYOUT & INDENTATION"))
            rows.append(check("Show line numbers",key:"lineNumbers")); rows.append(check("Relative line numbers",key:"relativeLineNumbers")); rows.append(check("Wrap long lines",key:"wordWrap"))
            rows.append(check("Indent with spaces",key:"useSpaces"))
            let tabs = Theme.choiceButton(); tabs.addItems(withTitles:["2","4","8"]); tabs.selectItem(withTitle:PreferencesSync.value("tabWidth")); tabs.identifier = NSUserInterfaceItemIdentifier("tabWidth"); tabs.target = self; tabs.action = #selector(popupChanged(_:))
            rows.append(settingRow("Tab width",tabs))
            let sample = Theme.label("let idea = \"Make something thoughtful.\"",size:Theme.fontSize,color:Theme.accent)
            sample.font = Theme.editorFont; rows.append(sample)
        case 2:
            rows.append(section("MODAL EDITING")); rows.append(check("Enable Vim mode",key:"vimEnabled"))
            rows.append(text("Normal, Insert, Visual, Visual Line and Visual Block modes support common motions, multiple selections, changes, copy/paste and undo. Use v, V or Control-V for visual selection."))
            rows.append(section("COMPATIBILITY"))
            rows.append(text("The Swift Vim engine supports composed operators, text objects, registers, repeat and normal/insert macro recording. Full compatibility, mappings, Vim regular expressions, Vimscript and Vim9 remain in development."))
            rows.append(text("Press Escape to return to Normal mode. Terminal input is always sent to the shell."))
        case 3:
            rows.append(section("ICLOUD DRIVE"))
            let enabled = NSButton(checkboxWithTitle:L.text("Sync preferences with iCloud Drive"),target:self,action:#selector(syncChanged(_:))); enabled.state = PreferencesSync.shared.enabled ? .on : .off; rows.append(enabled)
            let state = text(PreferencesSync.shared.status); statusLabel = state; rows.append(state)
            let now = Theme.actionButton("Sync Now",target:self,action:#selector(syncNow)); rows.append(Theme.stack([now,NSView()]))
            rows.append(section("WHAT SYNCs".uppercased()))
            rows.append(text("Color theme, font family and size, line numbers, wrapping, indentation and Vim mode. Changes to different settings are merged independently."))
            rows.append(section("STAYS ON THIS MAC"))
            rows.append(text("Documents, recovery snapshots, project paths, terminal environment and credentials. iCloud Drive must be enabled in macOS System Settings."))
        default:
            let updates = UpdateManager.shared
            rows.append(section("GITHUB RELEASES")); rows.append(Theme.label(L.format("Installed: %@",UpdateManager.currentVersion),size:14))
            for (tag,title,value) in [(0,"Automatically check for updates",updates.automaticChecks),(1,"Automatically download verified updates",updates.automaticDownloads),(2,"Install downloaded updates when Linvell quits",updates.automaticInstall),(3,"Include preview releases",updates.includePreviews)] {
                let b = NSButton(checkboxWithTitle:L.text(title),target:self,action:#selector(updatePreferenceChanged(_:))); b.tag = tag; b.state = value ? .on : .off; b.font = .systemFont(ofSize:14); rows.append(b)
            }
            rows.append(section("STATUS")); let state = text(updates.status); statusLabel = state; rows.append(state)
            let check = Theme.actionButton("Check Now",target:self,action:#selector(checkUpdate)); check.isEnabled = !updates.busy
            let download = Theme.actionButton("Download Update",target:self,action:#selector(downloadUpdate)); download.isEnabled = !updates.busy && updates.offer != nil
            let install = Theme.actionButton("Install and Restart",target:self,action:#selector(installUpdate)); install.isEnabled = !updates.busy && updates.prepared != nil
            rows.append(Theme.stack([check,download,install,NSView()]))
            rows.append(text("Checks run every six hours. Downloads require a matching checksum and Linvell signing identity. Installation waits for normal quit, including unsaved-document prompts, and retains the previous app for recovery."))
            rows.append(text("Update preferences apply to this Mac and are not synchronized through iCloud. Automatic download and installation are off by default."))
        }
        rows.append(NSView())
        let scroll = ResponsiveScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        let document = SettingsDocument(); document.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = document
        Theme.pin(scroll,in:detail)
        let stack = Theme.stack(rows,orientation:.vertical,spacing:18); Theme.pin(stack,in:document,inset:32)
        document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor).isActive = true
        document.heightAnchor.constraint(greaterThanOrEqualTo:scroll.contentView.heightAnchor).isActive = true
    }
    private func section(_ title: String) -> NSTextField { Theme.label(title,size:11,color:Theme.secondary,weight:.semibold) }
    private func text(_ value: String) -> NSTextField { let l = NSTextField(wrappingLabelWithString:L.text(value)); l.font = .systemFont(ofSize:13); l.textColor = Theme.secondary; return l }
    private func settingRow(_ title: String,_ control: NSView) -> NSStackView { Theme.stack([Theme.label(title,size:14),NSView(),control]) }
    private func check(_ title: String,key: String) -> NSButton {
        let b = NSButton(checkboxWithTitle:L.text(title),target:self,action:#selector(checkChanged(_:))); b.identifier = NSUserInterfaceItemIdentifier(key)
        b.state = PreferencesSync.value(key) == "true" ? .on : .off; b.font = .systemFont(ofSize:14); return b
    }
    @objc private func themeSelected(_ sender: NSButton) { Theme.profile = Theme.Profile.allCases[sender.tag]; PreferencesSync.shared.changed() }
    @objc private func popupChanged(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue,let title = sender.titleOfSelectedItem else { return }
        let value = (sender.selectedItem?.representedObject as? String) ?? title
        UserDefaults.standard.set(value,forKey:key); PreferencesSync.shared.changed()
    }
    @objc private func showAllFonts() {
        let manager = NSFontManager.shared; manager.target = self; manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(Theme.editorFont,isMultiple:false); manager.orderFrontFontPanel(self)
    }
    @objc func changeFont(_ sender: NSFontManager) {
        let font = sender.convert(Theme.editorFont)
        UserDefaults.standard.set(font.fontName,forKey:"editorFontFamily"); PreferencesSync.shared.changed()
    }
    @objc private func checkChanged(_ sender: NSButton) {
        if let key = sender.identifier?.rawValue { UserDefaults.standard.set(sender.state == .on,forKey:key); PreferencesSync.shared.changed() }
    }
    @objc private func syncChanged(_ sender: NSButton) { PreferencesSync.shared.enabled = sender.state == .on; statusLabel?.stringValue = PreferencesSync.shared.status }
    @objc private func syncNow() { PreferencesSync.shared.sync(); statusLabel?.stringValue = PreferencesSync.shared.status }
    @objc private func languageChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(["system","en","zh-Hans"][sender.indexOfSelectedItem],forKey:L.languageKey)
        L.configureLaunchLanguage(); NotificationCenter.default.post(name:L.changed,object:nil)
    }
    @objc private func startupChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 0 ? "empty" : "restore",forKey:WorkspaceSession.startupKey)
    }
    @objc private func updatePreferenceChanged(_ sender: NSButton) {
        let value = sender.state == .on
        switch sender.tag { case 0: UpdateManager.shared.automaticChecks = value; case 1: UpdateManager.shared.automaticDownloads = value; case 2: UpdateManager.shared.automaticInstall = value; default: UpdateManager.shared.includePreviews = value }
    }
    @objc private func checkUpdate() { UpdateManager.shared.check() }
    @objc private func downloadUpdate() { UpdateManager.shared.download() }
    @objc private func installUpdate() { UpdateManager.shared.requestInstall() }
}

private final class SettingsDocument: NSView { override var isFlipped: Bool { true } }

final class ThemePreview: NSButton {
    let profile: Theme.Profile
    init(profile: Theme.Profile,target: AnyObject,action: Selector) {
        self.profile = profile; super.init(frame:.zero); self.target = target; self.action = action; isBordered = false
        setAccessibilityLabel(profile.rawValue); heightAnchor.constraint(equalToConstant:160).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx:2,dy:2), palette = profile.colors
        Theme.color(palette[0]).setFill(); NSBezierPath(roundedRect:r,xRadius:10,yRadius:10).fill()
        Theme.color(palette[1]).setFill(); NSRect(x:r.minX+1,y:r.minY+30,width:48,height:r.height-31).fill()
        for (i,width) in [52.0,80,62,95,46].enumerated() {
            Theme.color(palette[i%3+4]).withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect:NSRect(x:66,y:r.maxY-25-CGFloat(i)*15,width:width,height:4),xRadius:2,yRadius:2).fill()
        }
        let selected = profile == Theme.profile
        let title = L.text(profile.rawValue) + (selected ? "   ✓" : "")
        (title as NSString).draw(at:NSPoint(x:14,y:10),withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.medium),.foregroundColor:Theme.color(palette[2])])
        (selected ? Theme.accent : Theme.secondary.withAlphaComponent(0.25)).setStroke()
        let path = NSBezierPath(roundedRect:r,xRadius:10,yRadius:10); path.lineWidth = selected ? 2 : 1; path.stroke()
    }
}
