import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspaces: [WorkspaceController] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenus()
        NotificationCenter.default.addObserver(self,selector:#selector(preferencesApplied),name:PreferencesSync.didApply,object:nil)
        let controller = newWorkspace()
        let args = CommandLine.arguments.dropFirst()
        if let index = args.firstIndex(of:"--demo"), args.index(after:index) < args.endIndex {
            controller.window?.setContentSize(NSSize(width:1320,height:860)); controller.window?.center()
            let file = URL(fileURLWithPath:args[args.index(after:index)])
            controller.setProject(file.deletingLastPathComponent().deletingLastPathComponent())
            controller.open(file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Package.swift")); controller.open(file)
        } else { controller.restore() }
        NSApp.activate(ignoringOtherApps:true)
        PreferencesSync.shared.start()
    }
    @objc private func preferencesApplied() {
        for workspace in workspaces {
            workspace.vimEnabled = PreferencesSync.value("vimEnabled") == "true"
            workspace.panes.forEach { $0.textView.vimEnabled = workspace.vimEnabled; $0.updatePreferences() }
            workspace.applyTheme(); workspace.updateStatus()
        }
    }
    @discardableResult @objc func newWorkspace() -> WorkspaceController {
        let controller = WorkspaceController(); workspaces.append(controller)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }
    @objc func newWindow(_ sender: Any?) { newWorkspace() }
    func application(_ sender: NSApplication,openFiles filenames: [String]) {
        let controller = workspaces.first(where: { $0.window?.isKeyWindow == true }) ?? workspaces.last ?? newWorkspace()
        filenames.forEach { controller.open(URL(fileURLWithPath:$0)) }; sender.reply(toOpenOrPrint:.success)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWorkspace() }; return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for workspace in workspaces where workspace.window?.isVisible == true {
            if !workspace.documents.allSatisfy(workspace.mayClose) || !workspace.mayCloseTerminal() { return .terminateCancel }
        }
        for workspace in workspaces {
            workspace.terminateTerminal()
            for doc in workspace.documents { try? workspace.recovery.remove(doc.buffer.id) }
        }
        return .terminateNow
    }
    @objc func route(_ item: NSMenuItem) {
        guard let action = item.representedObject as? String else { return }
        if NSApp.keyWindow?.windowController is PreferencesController,action == NSStringFromSelector(#selector(WorkspaceController.closeCurrent)) {
            NSApp.keyWindow?.performClose(nil); return
        }
        let controller = (NSApp.keyWindow?.windowController as? WorkspaceController) ?? workspaces.last ?? newWorkspace()
        controller.perform(NSSelectorFromString(action))
    }
    @objc func website() { NSWorkspace.shared.open(URL(string:"https://linvell.fuluwa.top")!) }
    @objc func selectTheme(_ item: NSMenuItem) {
        guard let profile = Theme.Profile(rawValue:item.title) else { return }
        Theme.profile = profile
        item.menu?.items.forEach { $0.state = $0 === item ? .on : .off }
        PreferencesSync.shared.changed()
    }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"Linvell",.applicationVersion:"0.1.0 · Development Preview",.credits:NSAttributedString(string:"Native Swift editor\nFull Vim and expanded IDE features are in development.\nlinvell.fuluwa.top")])
    }
    private func buildMenus() {
        let bar = NSMenu(); NSApp.mainMenu = bar
        func menu(_ title: String) -> NSMenu { let item = NSMenuItem(); let m = NSMenu(title:title); item.submenu = m; bar.addItem(item); return m }
        func item(_ m: NSMenu,_ title: String,_ action: Selector,_ key: String = "",_ mods: NSEvent.ModifierFlags = [.command],route: Bool = false) {
            let i = NSMenuItem(title:title,action:route ? #selector(self.route(_:)) : action,keyEquivalent:key); i.keyEquivalentModifierMask = mods
            if route { i.target = self; i.representedObject = NSStringFromSelector(action) }
            m.addItem(i)
        }
        let app = menu("Linvell")
        let about = NSMenuItem(title:"About Linvell",action:#selector(self.about),keyEquivalent:""); about.target = self; app.addItem(about)
        app.addItem(.separator()); item(app,"Hide Linvell",#selector(NSApplication.hide(_:)),"h")
        item(app,"Settings…",#selector(WorkspaceController.showSettings),",",route:true)
        app.addItem(.separator()); item(app,"Quit Linvell",#selector(NSApplication.terminate(_:)),"q")
        let file = menu("File")
        item(file,"New File",#selector(WorkspaceController.newFile),"n",route:true)
        let nw = NSMenuItem(title:"New Window",action:#selector(newWindow(_:)),keyEquivalent:"n"); nw.target = self; nw.keyEquivalentModifierMask = [.command,.shift]; file.addItem(nw)
        item(file,"Open…",#selector(WorkspaceController.openFile),"o",route:true)
        item(file,"Open Folder…",#selector(WorkspaceController.openFolder),"o",[.command,.shift],route:true)
        file.addItem(.separator())
        item(file,"Close File",#selector(WorkspaceController.closeCurrent),"w",route:true)
        item(file,"Save",#selector(WorkspaceController.save),"s",route:true)
        item(file,"Save As…",#selector(WorkspaceController.saveAs),"s",[.command,.shift],route:true)
        let edit = menu("Edit")
        item(edit,"Undo",Selector(("undo:")),"z"); item(edit,"Redo",Selector(("redo:")),"z",[.command,.shift]); edit.addItem(.separator())
        item(edit,"Cut",#selector(NSText.cut(_:)),"x"); item(edit,"Copy",#selector(NSText.copy(_:)),"c"); item(edit,"Paste",#selector(NSText.paste(_:)),"v"); item(edit,"Select All",#selector(NSText.selectAll(_:)),"a")
        let find = menu("Find")
        item(find,"Find in File…",#selector(WorkspaceController.find),"f",route:true)
        item(find,"Select Next Occurrence",#selector(WorkspaceController.selectNextOccurrence),"d",route:true)
        let view = menu("View")
        item(view,"Command Palette",#selector(WorkspaceController.commandPalette),"p",[.command,.shift],route:true)
        item(view,"Open Quickly…",#selector(WorkspaceController.quickOpen),"p",route:true)
        view.addItem(.separator())
        item(view,"Toggle Sidebar",#selector(WorkspaceController.toggleSidebar),"b",route:true)
        item(view,"Split Editor",#selector(WorkspaceController.toggleSplit),"\\",route:true)
        item(view,"Toggle Terminal",#selector(WorkspaceController.toggleTerminal),"`",[.control],route:true)
        item(view,"Toggle Vim Mode",#selector(WorkspaceController.toggleVim),"",route:true)
        view.addItem(.separator())
        let themes = NSMenu(title:"Theme"), themeItem = NSMenuItem(title:"Theme",action:nil,keyEquivalent:"")
        themeItem.submenu = themes; view.addItem(themeItem)
        for profile in Theme.Profile.allCases {
            let i = NSMenuItem(title:profile.rawValue,action:#selector(selectTheme(_:)),keyEquivalent:""); i.target = self; i.state = profile == Theme.profile ? .on : .off; themes.addItem(i)
        }
        item(view,"Increase Font Size",#selector(WorkspaceController.increaseFont),"=",route:true)
        item(view,"Decrease Font Size",#selector(WorkspaceController.decreaseFont),"-",route:true)
        let win = menu("Window"); NSApp.windowsMenu = win
        item(win,"Minimize",#selector(NSWindow.performMiniaturize(_:)),"m")
        item(win,"Zoom",#selector(NSWindow.performZoom(_:)))
        let help = menu("Help"); let web = NSMenuItem(title:"Linvell Website",action:#selector(website),keyEquivalent:""); web.target = self; help.addItem(web)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
