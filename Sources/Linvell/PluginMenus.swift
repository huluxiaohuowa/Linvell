import AppKit
import LinvellCore
import LinvellPluginKit

final class PluginMenus: NSObject, NSMenuItemValidation {
    static let shared = PluginMenus()
    static let changed = Notification.Name("Linvell.PluginsChanged")
    static var activeWorkspace: WorkspaceController? { (NSApp.keyWindow?.windowController as? WorkspaceController) ?? (NSApp.keyWindow?.windowController as? PluginOwnedWindow)?.workspaceOwner }
    private static let menuID = NSUserInterfaceItemIdentifier("Linvell.Plugins")
    static func install(in bar: NSMenu) {
        let root = NSMenuItem(); root.identifier = menuID; root.submenu = NSMenu(title:L.text("Plugins")); bar.addItem(root)
        refresh()
    }
    static func refresh(workspace: WorkspaceController? = nil) {
        guard let root = NSApp.mainMenu?.items.first(where:{ $0.identifier == menuID })?.submenu else { return }
        root.removeAllItems()
        let load = NSMenuItem(title:L.text("Load Development Plugin…"),action:#selector(loadPlugin),keyEquivalent:""); load.target = shared; root.addItem(load)
        let stop = NSMenuItem(title:L.text("Stop Plugins"),action:#selector(stopPlugins),keyEquivalent:""); stop.target = shared; root.addItem(stop)
        guard let workspace = workspace ?? activeWorkspace else { return }
        for session in workspace.pluginSessions.values.sorted(by:{ $0.package.manifest.id < $1.package.manifest.id }) {
            let group = NSMenuItem(title:session.package.manifest.name,action:nil,keyEquivalent:""); group.submenu = NSMenu(title:session.package.manifest.name); root.addItem(group)
            if session.isStopped {
                for (title,kind) in [("Plugin Logs","logs"),("Reconnect Plugin","reconnect")] {
                    let item = NSMenuItem(title:L.text(title),action:#selector(contribute(_:)),keyEquivalent:""); item.target = shared; item.representedObject = [session.package.manifest.id,kind,""]; group.submenu?.addItem(item)
                }; continue
            }
            for command in session.package.manifest.commands where command.menu == "plugins" {
                let item = NSMenuItem(title:command.title,action:#selector(run(_:)),keyEquivalent:"")
                if let raw = command.keybinding,let keybinding = try? PluginKeybinding(raw) { item.keyEquivalent = keybinding.key; item.keyEquivalentModifierMask = modifiers(keybinding) }
                item.target = shared; item.representedObject = [session.package.manifest.id,command.id]; group.submenu?.addItem(item)
            }
            func contribution(_ title: String,_ kind: String,_ id: String = "") {
                let item = NSMenuItem(title:title,action:#selector(contribute(_:)),keyEquivalent:"")
                item.target = shared; item.representedObject = [session.package.manifest.id,kind,id]; group.submenu?.addItem(item)
            }
            for view in session.package.manifest.views ?? [] {
                if view.kind == .status { contribution(view.title,"status",view.id) }
                else { contribution(view.title,"view",view.id) }
            }
            if !(session.package.manifest.settings ?? []).isEmpty { contribution(L.text("Plugin Settings…"),"settings") }
            for theme in session.package.manifest.themes ?? [] { contribution(L.text("Plugin Theme")+": "+theme.title,"theme",theme.id) }
            if (session.package.manifest.icons ?? []).contains(where:{ !($0.fileExtensions ?? []).isEmpty }) { contribution(L.text("Use Plugin File Icons"),"icons") }
            for snippet in session.package.manifest.snippets ?? [] { contribution(L.text("Plugin Snippet")+": "+snippet.title,"snippet",snippet.id) }
            for task in session.package.manifest.tasks ?? [] { contribution(L.text("Plugin Task")+": "+task.title,"task",task.id) }
            for debugger in session.package.manifest.debuggers ?? [] { contribution(L.text("Plugin Debugger")+": "+debugger.title,"debug",debugger.id) }
            contribution(L.text("Plugin Logs"),"logs")
            contribution(L.text("Reconnect Plugin"),"reconnect")
            group.submenu?.addItem(.separator())
            for (title,scope) in [("User Plugin Configuration…","user"),("Workspace Plugin Configuration…","workspace")] {
                let item = NSMenuItem(title:L.text(title),action:#selector(configuration(_:)),keyEquivalent:"")
                item.target = shared; item.representedObject = [session.package.manifest.id,scope]; group.submenu?.addItem(item)
            }
        }
    }
    static func validate(_ sessions: [PluginSession]) throws {
        var keys: [PluginKeybinding] = []
        func visit(_ menu: NSMenu) {
            for item in menu.items where item.identifier != menuID {
                if !item.keyEquivalent.isEmpty {
                    let mods = item.keyEquivalentModifierMask.intersection([.command,.control,.option,.shift])
                    let tokens: [(String,NSEvent.ModifierFlags)] = [("cmd",.command),("ctrl",.control),("option",.option),("shift",.shift)]
                    let raw = tokens.filter { mods.contains($0.1) }.map(\.0)+[item.keyEquivalent.lowercased()]
                    if let parsed = try? PluginKeybinding(raw.joined(separator:"+")) { keys.append(parsed) }
                }
                if let submenu = item.submenu { visit(submenu) }
            }
        }
        if let main = NSApp.mainMenu { visit(main) }
        // These native responder-chain equivalents may not be explicitly present in every app menu.
        for raw in ["cmd+a","cmd+c","cmd+v","cmd+x","cmd+z","cmd+shift+z","cmd+k"] { keys.append(try PluginKeybinding(raw)) }
        for session in sessions {
            for command in session.package.manifest.commands {
                if let raw = command.keybinding {
                    let key = try PluginKeybinding(raw)
                    guard !keys.contains(key) else { throw PluginError.shortcutConflict }; keys.append(key)
                }
            }
        }
    }
    static func modifiers(_ value: PluginKeybinding) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        for (name,flag) in [("cmd",NSEvent.ModifierFlags.command),("ctrl",.control),("option",.option),("shift",.shift)] where value.modifiers.contains(name) { mask.insert(flag) }
        return mask
    }
    @objc private func loadPlugin() { Self.activeWorkspace?.loadDevelopmentPlugin() }
    @objc private func stopPlugins() { Self.activeWorkspace?.stopPlugins() }
    @objc private func run(_ item: NSMenuItem) {
        guard let workspace = Self.activeWorkspace,let ids = item.representedObject as? [String],let session = workspace.pluginSessions[ids[0]] else { return }
        workspace.executePlugin(session,command:ids[1])
    }
    @objc private func configuration(_ item: NSMenuItem) {
        guard let workspace = Self.activeWorkspace,let ids = item.representedObject as? [String],let session = workspace.pluginSessions[ids[0]] else { return }
        workspace.openPluginConfiguration(session,workspaceScope:ids[1] == "workspace")
    }
    @objc private func contribute(_ item: NSMenuItem) {
        guard let workspace = Self.activeWorkspace,let ids = item.representedObject as? [String],let session = workspace.pluginSessions[ids[0]] else { return }
        switch ids[1] {
        case "task": workspace.runPluginTask(ids[2],session:session)
        case "debug": workspace.startPluginDebugger(ids[2],session:session)
        case "logs": workspace.showPluginLogs(session)
        case "reconnect": workspace.reconnectPlugin(session)
        case "view": workspace.showPluginView(ids[2],session:session)
        case "settings": workspace.openPluginSettings(session)
        case "theme": workspace.selectPluginTheme(ids[2],session:session)
        case "icons": workspace.selectPluginIcons(session)
        case "snippet": workspace.insertPluginSnippet(ids[2],session:session)
        case "status": if let view = session.package.manifest.views?.first(where:{ $0.id == ids[2] }) {
            if let command = view.command { workspace.executePlugin(session,command:command,uiEvent:PluginUIEvent(viewID:view.id,kind:"activate")) }
            else { workspace.status.stringValue = workspace.pluginViewValues[workspace.pluginViewKey(session,view.id)]?.text ?? view.text ?? view.title }
        }
        default: break
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let workspace = Self.activeWorkspace,NSApp.keyWindow?.attachedSheet == nil else { return false }
        if let ids = item.representedObject as? [String] {
            guard workspace.pluginSessions[ids[0]] != nil else { return false }
            if item.action == #selector(configuration(_:)) { return ids[1] != "workspace" || workspace.pluginWorkspace != nil }
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView,text.isEditable,!(text is EditorTextView) { return false }
        }
        return true
    }
}
