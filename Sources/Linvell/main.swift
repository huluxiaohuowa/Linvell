import AppKit
import LinvellCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspaces: [WorkspaceController] = []
    var keyMonitor: Any?
    var chordDeadline: Date?
    var receivedOpenFiles = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let icon = Bundle.main.url(forResource:"AppIcon",withExtension:"icns").flatMap({ NSImage(contentsOf:$0) }) {
            NSApp.applicationIconImage = icon
        }
        buildMenus(); Rendering.install()
        NSApp.servicesProvider = self
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self,let workspace = NSApp.keyWindow?.windowController as? WorkspaceController else { return event }
            let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            if let until = self.chordDeadline,Date() < until {
                self.chordDeadline = nil
                if command && event.charactersIgnoringModifiers == "d" { workspace.skipOccurrence(); return nil }
                if command && event.charactersIgnoringModifiers == "i" { workspace.hoverCommand(); return nil }
                if command && event.charactersIgnoringModifiers == "o" { workspace.openFolder(); return nil }
                if command && event.charactersIgnoringModifiers == "0" { workspace.foldAllCode(); return nil }
                if command && event.charactersIgnoringModifiers == "j" { workspace.unfoldAllCode(); return nil }
                if event.keyCode == 53 { return nil }
            }
            if command && event.charactersIgnoringModifiers == "k",(NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true {
                self.chordDeadline = Date().addingTimeInterval(2); return nil
            }
            return event
        }
        NotificationCenter.default.addObserver(self,selector:#selector(preferencesApplied),name:PreferencesSync.didApply,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(languageApplied),name:L.changed,object:nil)
        // Launch Services can deliver openFiles before didFinishLaunching.
        // Reuse that window and do not restore a second welcome workspace.
        let controller = workspaceForOpening()
        let args = CommandLine.arguments.dropFirst()
        if let at = args.firstIndex(of:"--benchmark-open"),args.index(after:at) < args.endIndex,
           let out = args.firstIndex(of:"--benchmark-report"),args.index(after:out) < args.endIndex {
            let file = URL(fileURLWithPath:args[args.index(after:at)]),report = URL(fileURLWithPath:args[args.index(after:out)])
            let started = ProcessInfo.processInfo.systemUptime
            controller.open(file) {
                let opened = ProcessInfo.processInfo.systemUptime
                controller.window?.contentView?.layoutSubtreeIfNeeded(); controller.window?.displayIfNeeded()
                guard let pane = controller.activePane,let manager = pane.textView.layoutManager,let container = pane.textView.textContainer else { return }
                manager.ensureLayout(forBoundingRect:pane.textView.visibleRect,in:container)
                let painted = ProcessInfo.processInfo.systemUptime
                let ns = pane.textView.string as NSString
                pane.textView.scrollRangeToVisible(NSRange(location:ns.length/2,length:0))
                controller.window?.displayIfNeeded()
                let scrolled = ProcessInfo.processInfo.systemUptime
                let values: [String:Any] = ["bytes":(try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0,"lines":controller.current?.lines.starts.count ?? 0,"openSeconds":opened-started,"firstLayoutSeconds":painted-started,"midpointScrollSeconds":scrolled-painted,"maximumRefreshRate":controller.window?.screen?.maximumFramesPerSecond ?? 0,"method":"Local native AppKit timing; no Sublime comparison or frame-latency acceptance"]
                try? JSONSerialization.data(withJSONObject:values,options:[.sortedKeys,.prettyPrinted]).write(to:report,options:.atomic)
                NSApp.terminate(nil)
            }
            return
        }
        if let index = args.firstIndex(of:"--demo"), args.index(after:index) < args.endIndex {
            controller.window?.setContentSize(NSSize(width:1320,height:860)); controller.window?.center()
            let file = URL(fileURLWithPath:args[args.index(after:index)])
            let folder = file.deletingLastPathComponent(),project = folder.lastPathComponent == "Samples" ? folder.deletingLastPathComponent() : folder
            controller.setProject(project)
            let manifest = project.appendingPathComponent("Package.swift")
            if manifest != file,FileManager.default.fileExists(atPath:manifest.path) { controller.open(manifest) }
            controller.open(file)
        } else if !receivedOpenFiles { controller.restore() }
        NSApp.activate(ignoringOtherApps:true)
        PreferencesSync.shared.start()
        UpdateManager.shared.start()
        if Bundle.main.bundleIdentifier == "top.fuluwa.linvell" {
            let application = Bundle.main.bundleURL
            DispatchQueue.global(qos:.utility).async { try? RollbackArchive.migrateLegacyCopies(beside:application) }
        }
    }
    @objc private func preferencesApplied() {
        for workspace in workspaces {
            workspace.vimEnabled = PreferencesSync.value("vimEnabled") == "true"
            workspace.panes.forEach { $0.textView.vimEnabled = workspace.vimEnabled; $0.updatePreferences() }
            workspace.documents.forEach { workspace.scheduleAutoSave($0) }
            workspace.applyTheme(); workspace.updateStatus()
        }
    }
    @objc private func languageApplied() {
        buildMenus()
        for workspace in workspaces { workspace.relocalize() }
    }
    @discardableResult @objc func newWorkspace() -> WorkspaceController {
        let controller = WorkspaceController(managedAutoload:true); workspaces.append(controller)
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }
    @objc func newWindow(_ sender: Any?) { newWorkspace() }
    func workspaceForOpening() -> WorkspaceController {
        workspaces.first(where:{ $0.window?.isKeyWindow == true })
            ?? workspaces.last(where:{ $0.window?.isVisible == true }) ?? newWorkspace()
    }
    func application(_ sender: NSApplication,openFiles filenames: [String]) {
        receivedOpenFiles = true
        let controller = workspaceForOpening()
        filenames.forEach { controller.open(URL(fileURLWithPath:$0)) }; sender.reply(toOpenOrPrint:.success)
    }
    @objc func openInLinvell(_ pasteboard: NSPasteboard,userData: String?,error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = FileDrop.urls(pasteboard)
        guard !urls.isEmpty else { return }
        receivedOpenFiles = true
        let controller = workspaceForOpening()
        urls.forEach { controller.open($0) }
        controller.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool {
        if !flag { workspaceForOpening().window?.makeKeyAndOrderFront(nil) }; return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for workspace in workspaces where workspace.window?.isVisible == true || workspace.agentsRunning {
            if !workspace.documents.allSatisfy(workspace.mayClose) || !workspace.mayCloseTerminal() || !workspace.mayCloseAgents() { return .terminateCancel }
        }
        if UpdateManager.shared.shouldInstallOnQuit {
            do { try UpdateManager.shared.scheduleInstallation() }
            catch { NSAlert(error:error).runModal(); return .terminateCancel }
        }
        for workspace in workspaces {
            workspace.shutdownAgent()
            workspace.stopPlugins()
            workspace.terminateTerminal()
            for doc in workspace.documents { try? workspace.recovery.remove(doc.buffer.id) }
        }
        return .terminateNow
    }
    @objc func route(_ item: NSMenuItem) {
        guard let action = item.representedObject as? String else { return }
        if NSApp.keyWindow?.windowController is PluginOwnedWindow,action == NSStringFromSelector(#selector(WorkspaceController.closeCurrent)) {
            NSApp.keyWindow?.performClose(nil); return
        }
        if let settings = NSApp.keyWindow?.windowController as? PluginSettingsWindow,action == NSStringFromSelector(#selector(WorkspaceController.save)) { settings.saveSettings(); return }
        if NSApp.keyWindow?.windowController is PreferencesController,action == NSStringFromSelector(#selector(WorkspaceController.closeCurrent)) {
            NSApp.keyWindow?.performClose(nil); return
        }
        let controller = (NSApp.keyWindow?.windowController as? WorkspaceController) ?? (NSApp.keyWindow?.windowController as? PluginOwnedWindow)?.workspaceOwner ?? workspaces.last ?? newWorkspace()
        controller.perform(NSSelectorFromString(action))
    }
    @objc func website() { NSWorkspace.shared.open(URL(string:"https://linvell.fuluwa.top")!) }
    @objc func checkUpdates() {
        let workspace = workspaces.last ?? newWorkspace()
        workspace.showSettings(); workspace.preferences?.showUpdates(); UpdateManager.shared.check()
    }
    @objc func selectTheme(_ item: NSMenuItem) {
        guard let profile = Theme.Profile(rawValue:item.title) else { return }
        Theme.profile = profile
        item.menu?.items.forEach { $0.state = $0 === item ? .on : .off }
        PreferencesSync.shared.changed()
    }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"Linvell",.applicationVersion:UpdateManager.currentVersion,.credits:NSAttributedString(string:"Native Swift editor\nFull Vim and expanded IDE features are in development.\nlinvell.fuluwa.top")])
    }
    private func buildMenus() {
        let bar = NSMenu(); NSApp.mainMenu = bar
        func menu(_ title: String) -> NSMenu { let item = NSMenuItem(); let m = NSMenu(title:L.text(title)); item.submenu = m; bar.addItem(item); return m }
        func item(_ m: NSMenu,_ title: String,_ action: Selector,_ key: String = "",_ mods: NSEvent.ModifierFlags = [.command],route: Bool = false) {
            let i = NSMenuItem(title:L.text(title),action:route ? #selector(self.route(_:)) : action,keyEquivalent:key); i.keyEquivalentModifierMask = mods
            if route { i.target = self; i.representedObject = NSStringFromSelector(action) }
            m.addItem(i)
        }
        let app = menu("Linvell")
        let about = NSMenuItem(title:L.text("About Linvell"),action:#selector(self.about),keyEquivalent:""); about.target = self; app.addItem(about)
        let updates = NSMenuItem(title:L.text("Check for Updates…"),action:#selector(checkUpdates),keyEquivalent:""); updates.target = self; app.addItem(updates)
        app.addItem(.separator()); item(app,"Hide Linvell",#selector(NSApplication.hide(_:)),"h")
        item(app,"Settings…",#selector(WorkspaceController.showSettings),",",route:true)
        app.addItem(.separator()); item(app,"Quit Linvell",#selector(NSApplication.terminate(_:)),"q")
        let file = menu("File")
        item(file,"New File",#selector(WorkspaceController.newFile),"n",route:true)
        let nw = NSMenuItem(title:L.text("New Window"),action:#selector(newWindow(_:)),keyEquivalent:"n"); nw.target = self; nw.keyEquivalentModifierMask = [.command,.shift]; file.addItem(nw)
        item(file,"Open…",#selector(WorkspaceController.openFile),"o",route:true)
        item(file,"Open Folder…",#selector(WorkspaceController.openFolder),route:true)
        item(file,"Open Local Folder…",#selector(WorkspaceController.openLocalFolder),route:true)
        item(file,"Open Remote Folder…",#selector(WorkspaceController.openRemoteFolder),route:true)
        item(file,"Connect to SSH Host…",#selector(WorkspaceController.connectSSH),route:true)
        file.addItem(.separator())
        item(file,"Close File",#selector(WorkspaceController.closeCurrent),"w",route:true)
        item(file,"Save",#selector(WorkspaceController.save),"s",route:true)
        item(file,"Save As…",#selector(WorkspaceController.saveAs),"s",[.command,.shift],route:true)
        item(file,"Save All",#selector(WorkspaceController.saveAll),"s",[.command,.option],route:true)
        let edit = menu("Edit")
        item(edit,"Undo",Selector(("undo:")),"z"); item(edit,"Redo",Selector(("redo:")),"z",[.command,.shift]); edit.addItem(.separator())
        item(edit,"Cut",#selector(NSText.cut(_:)),"x"); item(edit,"Copy",#selector(NSText.copy(_:)),"c"); item(edit,"Paste",#selector(NSText.paste(_:)),"v"); item(edit,"Select All",#selector(NSText.selectAll(_:)),"a")
        edit.addItem(.separator())
        item(edit,"Move Line Up",#selector(EditorTextView.moveLinesUp(_:)),String(UnicodeScalar(NSUpArrowFunctionKey)!),[.option])
        item(edit,"Move Line Down",#selector(EditorTextView.moveLinesDown(_:)),String(UnicodeScalar(NSDownArrowFunctionKey)!),[.option])
        item(edit,"Copy Line Up",#selector(EditorTextView.copyLinesUp(_:)),String(UnicodeScalar(NSUpArrowFunctionKey)!),[.option,.shift])
        item(edit,"Copy Line Down",#selector(EditorTextView.copyLinesDown(_:)),String(UnicodeScalar(NSDownArrowFunctionKey)!),[.option,.shift])
        item(edit,"Delete Line",#selector(EditorTextView.deleteLines(_:)),"k",[.command,.shift])
        item(edit,"Toggle Line Comment",#selector(EditorTextView.toggleLineComment(_:)),"/")
        item(edit,"Indent Line",#selector(EditorTextView.indentLines(_:)),"]")
        item(edit,"Outdent Line",#selector(EditorTextView.outdentLines(_:)),"[")
        item(edit,"Insert Line Below",#selector(EditorTextView.insertLineBelow(_:)),"\r")
        item(edit,"Insert Line Above",#selector(EditorTextView.insertLineAbove(_:)),"\r",[.command,.shift])
        let find = menu("Find")
        item(find,"Find in File…",#selector(WorkspaceController.find),"f",route:true)
        item(find,"Replace in File…",#selector(WorkspaceController.replaceInFile),"f",[.command,.option],route:true)
        item(find,"Search Project…",#selector(WorkspaceController.projectSearch),"f",[.command,.shift],route:true)
        item(find,"Select Next Occurrence",#selector(WorkspaceController.selectNextOccurrence),"d",route:true)
        item(find,"Select All Occurrences",#selector(WorkspaceController.selectAllOccurrences),"l",[.command,.shift],route:true)
        item(find,"Undo Selection",#selector(WorkspaceController.undoSelections),"u",route:true)
        item(find,"Split Selection into Lines",#selector(WorkspaceController.splitSelectionIntoLines),"i",[.option,.shift],route:true)
        item(find,"Add Cursor Above",#selector(WorkspaceController.addCursorAbove),String(UnicodeScalar(NSUpArrowFunctionKey)!),[.command,.option],route:true)
        item(find,"Add Cursor Below",#selector(WorkspaceController.addCursorBelow),String(UnicodeScalar(NSDownArrowFunctionKey)!),[.command,.option],route:true)
        item(find,"Select Line",#selector(WorkspaceController.selectCurrentLine),"l",route:true)
        item(edit,"Fold Code",#selector(WorkspaceController.foldCode),"[",[.command,.option],route:true)
        item(edit,"Unfold Code",#selector(WorkspaceController.unfoldCode),"]",[.command,.option],route:true)
        item(edit,"Fold All",#selector(WorkspaceController.foldAllCode),route:true)
        item(edit,"Unfold All",#selector(WorkspaceController.unfoldAllCode),route:true)
        let go = menu("Go")
        item(go,"Go to Definition",#selector(WorkspaceController.definitionCommand),String(UnicodeScalar(NSF12FunctionKey)!),[],route:true)
        item(go,"Find All References",#selector(WorkspaceController.findReferences),String(UnicodeScalar(NSF12FunctionKey)!),[.shift],route:true)
        item(go,"Go Back",#selector(WorkspaceController.goBack),String(UnicodeScalar(NSLeftArrowFunctionKey)!),[.option],route:true)
        item(go,"Go Forward",#selector(WorkspaceController.goForward),String(UnicodeScalar(NSRightArrowFunctionKey)!),[.option],route:true)
        item(go,"Go Back",#selector(WorkspaceController.goBack),"-",[.control],route:true)
        go.items.last?.isHidden = true; go.items.last?.allowsKeyEquivalentWhenHidden = true
        item(go,"Go Forward",#selector(WorkspaceController.goForward),"-",[.control,.shift],route:true)
        go.items.last?.isHidden = true; go.items.last?.allowsKeyEquivalentWhenHidden = true
        item(go,"Go to Declaration",#selector(WorkspaceController.declaration),route:true)
        item(go,"Go to Type Definition",#selector(WorkspaceController.typeDefinition),route:true)
        item(go,"Go to Implementation",#selector(WorkspaceController.implementation),String(UnicodeScalar(NSF12FunctionKey)!),[.command],route:true)
        item(go,"Workspace Symbols…",#selector(WorkspaceController.workspaceSymbols),"t",[.command],route:true)
        item(go,"Parameter Hints",#selector(WorkspaceController.signatureHelp)," ",[.command,.shift],route:true)
        item(edit,"Format Document",#selector(WorkspaceController.formatDocument),"f",[.option,.shift],route:true)
        item(go,"Show Hover",#selector(WorkspaceController.hoverCommand),route:true)
        item(go,"Code Suggestions",#selector(WorkspaceController.completionCommand)," ",[.control],route:true)
        item(edit,"Rename Symbol…",#selector(WorkspaceController.renameSymbol),String(UnicodeScalar(NSF2FunctionKey)!),[],route:true)
        item(edit,"Language Tools…",#selector(WorkspaceController.showLanguageTools),route:true)
        item(edit,"Load Development Plugin…",#selector(WorkspaceController.loadDevelopmentPlugin),route:true)
        item(edit,"Stop Plugins",#selector(WorkspaceController.stopPlugins),route:true)
        let project = menu("Project")
        item(project,"Project Settings…",#selector(WorkspaceController.showProjectSettings),route:true)
        let view = menu("View")
        item(view,"Command Palette",#selector(WorkspaceController.commandPalette),"p",[.command,.shift],route:true)
        item(view,"Open Quickly…",#selector(WorkspaceController.quickOpen),"p",route:true)
        item(view,"Go to Symbol…",#selector(WorkspaceController.documentSymbols),"o",[.command,.shift],route:true)
        item(view,"Toggle Preview",#selector(WorkspaceController.toggleMarkdownPreview),"v",[.command,.shift],route:true)
        item(view,"Problems",#selector(WorkspaceController.showProblems),"m",[.command,.shift],route:true)
        item(view,"Restart Language Services",#selector(WorkspaceController.restartLanguageServices),route:true)
        item(view,"Project Tools",#selector(WorkspaceController.projectTools),route:true)
        item(view,"Source Control",#selector(WorkspaceController.gitWorkspace),"g",[.control,.shift],route:true)
        item(view,"Git Commit Graph",#selector(WorkspaceController.gitWorkspace),route:true)
        item(view,"Run & Preview",#selector(WorkspaceController.runWorkspace),"b",[.command,.shift],route:true)
        view.addItem(.separator())
        item(view,"Toggle Sidebar",#selector(WorkspaceController.toggleSidebar),"b",route:true)
        item(view,"Split Editor",#selector(WorkspaceController.toggleSplit),"\\",route:true)
        item(view,"Toggle Terminal",#selector(WorkspaceController.toggleTerminal),"`",[.control],route:true)
        item(view,"Toggle Vim Mode",#selector(WorkspaceController.toggleVim),"",route:true)
        view.addItem(.separator())
        let themes = NSMenu(title:L.text("Theme")), themeItem = NSMenuItem(title:L.text("Theme"),action:nil,keyEquivalent:"")
        themeItem.submenu = themes; view.addItem(themeItem)
        for profile in Theme.Profile.allCases {
            let i = NSMenuItem(title:profile.rawValue,action:#selector(selectTheme(_:)),keyEquivalent:""); i.target = self; i.state = profile == Theme.profile ? .on : .off; themes.addItem(i)
        }
        item(view,"Increase Font Size",#selector(WorkspaceController.increaseFont),"=",route:true)
        item(view,"Decrease Font Size",#selector(WorkspaceController.decreaseFont),"-",route:true)
        let win = menu("Window"); NSApp.windowsMenu = win
        item(win,"Minimize",#selector(NSWindow.performMiniaturize(_:)),"m")
        item(win,"Zoom",#selector(NSWindow.performZoom(_:)))
        PluginMenus.install(in:bar)
        let help = menu("Help"); let web = NSMenuItem(title:L.text("Linvell Website"),action:#selector(website),keyEquivalent:""); web.target = self; help.addItem(web)
    }
}

L.configureLaunchLanguage()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
