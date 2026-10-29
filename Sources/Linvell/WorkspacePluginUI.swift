import AppKit
import LinvellCore
import LinvellPluginKit

extension WorkspaceController {
    func pluginIcon(_ id: String,session: PluginSession) -> NSImage? {
        let key = pluginViewKey(session,"icon."+id)
        if let cached = pluginImages[key] { return cached }
        guard let icon = session.package.manifest.icons?.first(where:{ $0.id == id }) else { return nil }
        let image: NSImage?
        if let symbol = icon.symbol { image = NSImage(systemSymbolName:symbol,accessibilityDescription:id) }
        else if let file = try? PluginContributions.iconURL(icon,directory:session.package.directory) { image = NSImage(contentsOf:file) }
        else { image = nil }
        if let image { pluginImages[key] = image }; return image
    }
    func pluginViewKey(_ session: PluginSession,_ id: String) -> String { session.sessionID.uuidString+"/"+id }
    func receivePluginViews(_ updates: [PluginViewUpdate],session: PluginSession) {
        guard pluginSessions[session.package.manifest.id] === session else { return }
        var changed = false
        for update in updates {
            let key = pluginViewKey(session,update.id),old = pluginViewValues[key]
            let merged = PluginViewUpdate(id:update.id,text:update.text ?? old?.text,items:update.items ?? old?.items)
            guard old != merged else { continue }; changed = true; pluginViewValues[key] = merged
            if let definition = session.package.manifest.views?.first(where:{ $0.id == update.id }) {
                if let view = pluginDataViews[key],view.window?.isVisible == true { view.update(text:merged.text ?? definition.text ?? "",items:merged.items ?? definition.items ?? []) }
            }
        }
        if changed { renderPluginStatus() }
    }
    func dataView(_ definition: PluginView,session: PluginSession) -> PluginDataView {
        let key = pluginViewKey(session,definition.id)
        if let existing = pluginDataViews[key] {
            let data = pluginViewValues[key]; existing.update(text:data?.text ?? definition.text ?? "",items:data?.items ?? definition.items ?? [])
            return existing
        }
        let view = PluginDataView(definition)
        view.icon = { [weak self,weak session] id in guard let session else { return nil }; return self?.pluginIcon(id,session:session) }
        view.invoke = { [weak self,weak session] command,event in if let session { self?.executePlugin(session,command:command,uiEvent:event) } }
        let data = pluginViewValues[key]
        view.update(text:data?.text ?? definition.text ?? "",items:data?.items ?? definition.items ?? [])
        pluginDataViews[key] = view; return view
    }
    func showPluginView(_ id: String,session: PluginSession) {
        guard pluginSessions[session.package.manifest.id] === session,let definition = session.package.manifest.views?.first(where:{ $0.id == id }),definition.kind != .status else { return }
        let view = dataView(definition,session:session),key = pluginViewKey(session,id)
        if definition.kind == .panel {
            let controller: PluginOwnedWindow
            if let existing = pluginWindows[key] { controller = existing }
            else { controller = PluginOwnedWindow(owner:self,title:session.package.manifest.name+" — "+definition.title); Theme.pin(view,in:controller.window!.contentView!); pluginWindows[key] = controller }
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        } else {
            sidebarKind = "plugin:"+key; sidebar.isHidden = false; sidebar.subviews.forEach { $0.removeFromSuperview() }; Theme.pin(view,in:sidebar)
        }
    }
    func openPluginSettings(_ session: PluginSession) {
        guard pluginSessions[session.package.manifest.id] === session,!(session.package.manifest.settings ?? []).isEmpty else { return }
        let key = session.sessionID.uuidString+"/settings/"
        if let existing = pluginWindows[key] { if existing.window?.isVisible != true { (existing as? PluginSettingsWindow)?.reloadSettings() }; existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let controller = PluginSettingsWindow(owner:self,session:session); pluginWindows[key] = controller
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func selectPluginTheme(_ id: String,session: PluginSession) {
        guard pluginSessions[session.package.manifest.id] === session,let theme = session.package.manifest.themes?.first(where:{ $0.id == id }) else { return }
        Theme.pluginTheme = (session.sessionID,theme); NotificationCenter.default.post(name:PreferencesSync.didApply,object:nil)
    }
    func selectPluginIcons(_ session: PluginSession) {
        var images: [String:NSImage] = [:]
        for icon in session.package.manifest.icons ?? [] {
            if let image = pluginIcon(icon.id,session:session) { for ext in icon.fileExtensions ?? [] { images[ext] = image } }
        }
        FileIcon.pluginIcons = (session.sessionID,images); NotificationCenter.default.post(name:PreferencesSync.didApply,object:nil)
    }
    func insertPluginSnippet(_ id: String,session: PluginSession) {
        do {
            guard pluginSessions[session.package.manifest.id] === session,let snippet = session.package.manifest.snippets?.first(where:{ $0.id == id }),let editor = activePane?.textView,let document = current,!editor.hasMarkedText(),editor.editingSelections.count == 1 else { throw PluginError.invalidState }
            let ext = document.fileURL?.pathExtension.lowercased() ?? ""
            guard (snippet.scope ?? []).isEmpty || snippet.scope!.contains(ext) else { throw PluginError.invalidState }
            let expansion = try PluginSnippetExpansion(snippet.body),original = editor.string as NSString
            var range = editor.selectedRange()
            if range.length == 0,let prefix = snippet.prefix,range.location >= prefix.utf16.count {
                let before = NSRange(location:range.location-prefix.utf16.count,length:prefix.utf16.count)
                if original.substring(with:before) == prefix { range = before }
            }
            let result = try MultiEdit.apply([range],replacement:expansion.text,to:editor.string)
            guard result.text.utf8.count <= 2*1024*1024 else { throw PluginError.invalidState }
            editor.restoreMultiEdit(result.text,selections:result.selections.map(NSValue.init(range:)))
            let cursor = PluginSnippetCursor(stops:expansion.stops,offset:range.location)
            editor.setSelectedRange(cursor.current); editor.pluginSnippet = cursor.isFinal ? nil : cursor; editor.pluginSnippetOwner = session.sessionID
            if editor.vimEnabled { document.vim.escape(); document.vim.key("i") }
            editor.undoManager?.setActionName(L.text("Insert Plugin Snippet")); window?.makeFirstResponder(editor); updateStatus()
        } catch { show(error) }
    }
    func clearPluginUI(_ session: PluginSession) {
        let prefix = session.sessionID.uuidString+"/"
        if sidebarKind.hasPrefix("plugin:"+prefix) { showSidebar("files") }
        for key in Array(pluginWindows.keys) where key.hasPrefix(prefix) { pluginWindows.removeValue(forKey:key)?.close() }
        for key in Array(pluginDataViews.keys) where key.hasPrefix(prefix) { pluginDataViews.removeValue(forKey:key) }
        for key in Array(pluginImages.keys) where key.hasPrefix(prefix) { pluginImages.removeValue(forKey:key) }
        for key in Array(pluginViewValues.keys) where key.hasPrefix(prefix) { pluginViewValues.removeValue(forKey:key) }
        if Theme.pluginTheme?.0 == session.sessionID { Theme.pluginTheme = nil; NotificationCenter.default.post(name:PreferencesSync.didApply,object:nil) }
        if FileIcon.pluginIcons?.0 == session.sessionID { FileIcon.pluginIcons = nil; NotificationCenter.default.post(name:PreferencesSync.didApply,object:nil) }
        panes.filter { $0.textView.pluginSnippetOwner == session.sessionID }.forEach { $0.textView.pluginSnippet = nil; $0.textView.pluginSnippetOwner = nil }
        renderPluginStatus()
    }
    func renderPluginStatus() {
        let previous = Dictionary(uniqueKeysWithValues:pluginStatusBar.arrangedSubviews.compactMap { view -> (String,NSButton)? in guard let button = view as? NSButton,let id = button.identifier?.rawValue else { return nil }; return (id,button) })
        let entries = pluginSessions.values.sorted { $0.package.manifest.id < $1.package.manifest.id }.flatMap { session in
            (session.package.manifest.views ?? []).filter { $0.kind == .status }.map { (session,$0) }
        }
        pluginStatusBar.isHidden = entries.isEmpty
        let visible = Array(entries.prefix(3)),ids = Set(visible.map { pluginViewKey($0.0,$0.1.id) })
        for (id,button) in previous where !ids.contains(id) { button.removeFromSuperview() }
        for (index,pair) in visible.enumerated() {
            let (session,definition) = pair
            let key = pluginViewKey(session,definition.id),value = pluginViewValues[key]?.text ?? definition.text ?? definition.title
            let button: NSButton
            if let existing = previous[key] { button = existing; if button.title != value { button.title = value } }
            else {
                button = NSButton(title:value,target:self,action:#selector(pluginStatusClicked(_:)))
                button.widthAnchor.constraint(lessThanOrEqualToConstant:110).isActive = true
            }
            button.identifier = .init(key); button.isBordered = false; button.font = .systemFont(ofSize:11); button.contentTintColor = Theme.accent
            button.cell?.lineBreakMode = .byTruncatingTail
            button.toolTip = definition.title+": "+value; button.setAccessibilityLabel(button.toolTip)
            if let icon = definition.icon { button.image = pluginIcon(icon,session:session); button.imagePosition = .imageLeading; button.imageScaling = .scaleProportionallyDown }
            button.isEnabled = definition.command != nil
            if index >= pluginStatusBar.arrangedSubviews.count || pluginStatusBar.arrangedSubviews[index] !== button { button.removeFromSuperview(); pluginStatusBar.insertArrangedSubview(button,at:index) }
        }
    }
    @objc private func pluginStatusClicked(_ sender: NSButton) {
        for session in pluginSessions.values {
            if let definition = session.package.manifest.views?.first(where:{ pluginViewKey(session,$0.id) == sender.identifier?.rawValue }),let command = definition.command {
                executePlugin(session,command:command,uiEvent:PluginUIEvent(viewID:definition.id,kind:"activate")); return
            }
        }
    }
    func restorePluginSidebar(_ key: String) -> Bool {
        for session in pluginSessions.values {
            if let definition = session.package.manifest.views?.first(where:{ pluginViewKey(session,$0.id) == key }) { showPluginView(definition.id,session:session); return true }
        }
        return false
    }
}
