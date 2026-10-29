import AppKit
import LinvellCore

final class PluginMenus: NSObject, NSMenuItemValidation {
    static let shared = PluginMenus()
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
        guard let workspace = workspace ?? (NSApp.keyWindow?.windowController as? WorkspaceController) else { return }
        for session in workspace.pluginSessions.values.sorted(by:{ $0.package.manifest.id < $1.package.manifest.id }) {
            let group = NSMenuItem(title:session.package.manifest.name,action:nil,keyEquivalent:""); group.submenu = NSMenu(title:session.package.manifest.name); root.addItem(group)
            for command in session.package.manifest.commands where command.menu == "plugins" {
                let item = NSMenuItem(title:command.title,action:#selector(run(_:)),keyEquivalent:"")
                if let raw = command.keybinding,let keybinding = try? PluginKeybinding(raw) { item.keyEquivalent = keybinding.key; item.keyEquivalentModifierMask = modifiers(keybinding) }
                item.target = shared; item.representedObject = [session.package.manifest.id,command.id]; group.submenu?.addItem(item)
            }
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
    @objc private func loadPlugin() { (NSApp.keyWindow?.windowController as? WorkspaceController)?.loadDevelopmentPlugin() }
    @objc private func stopPlugins() { (NSApp.keyWindow?.windowController as? WorkspaceController)?.stopPlugins() }
    @objc private func run(_ item: NSMenuItem) {
        guard let workspace = NSApp.keyWindow?.windowController as? WorkspaceController,let ids = item.representedObject as? [String],let session = workspace.pluginSessions[ids[0]] else { return }
        workspace.executePlugin(session,command:ids[1])
    }
    @objc private func configuration(_ item: NSMenuItem) {
        guard let workspace = NSApp.keyWindow?.windowController as? WorkspaceController,let ids = item.representedObject as? [String],let session = workspace.pluginSessions[ids[0]] else { return }
        workspace.openPluginConfiguration(session,workspaceScope:ids[1] == "workspace")
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let workspace = NSApp.keyWindow?.windowController as? WorkspaceController,workspace.window?.attachedSheet == nil else { return false }
        if let ids = item.representedObject as? [String] {
            guard workspace.pluginSessions[ids[0]] != nil else { return false }
            if item.action == #selector(configuration(_:)) { return ids[1] != "workspace" || workspace.pluginWorkspace != nil }
            if let text = workspace.window?.firstResponder as? NSTextView,!(text is EditorTextView) { return false }
        }
        return true
    }
}
