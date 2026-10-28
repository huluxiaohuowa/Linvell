import AppKit
import LinvellCore
import SwiftTerm

final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    lazy var children: [FileNode] = {
        guard isDirectory else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles])) ?? []
        return urls.map(FileNode.init).sorted { a,b in a.isDirectory != b.isDirectory ? a.isDirectory : a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending }
    }()
    init(_ url: URL) { self.url = url; isDirectory = (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true }
}

final class WorkspaceController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    var documents: [OpenDocument] = []
    var current: OpenDocument?
    var activePane: EditorPane?
    var panes: [EditorPane] = []
    var root: FileNode?
    let outline = HierarchyOutlineView()
    let body = ResizablePanes()
    let content = ResizablePanes()
    let editors = ResizablePanes()
    let sidebar = Surface(Theme.panel)
    let activity = Surface(Theme.canvas)
    let workspaceArea = NSView()
    let center = Surface(Theme.canvas)
    let tabs = NSStackView()
    let tabScroll = NSScrollView()
    let editorHost = NSView()
    let status = Theme.label("Ready",size:12,color:Theme.secondary)
    let modeLabel = Theme.label("TEXT",size:11,color:Theme.accent,weight:.semibold)
    let breadcrumb = Theme.label("Your next idea starts here",size:12,color:Theme.secondary)
    let previewButton = NSButton()
    var markdownView: MarkdownPreview?
    let projectTitle = Theme.label("Linvell",size:14,weight:.semibold)
    let search = NSSearchField()
    var vimEnabled = UserDefaults.standard.bool(forKey:"vimEnabled")
    var terminal: LocalProcessTerminalView?
    var terminalHost: NSView?
    var recoveryTimer: Timer?
    var commandPanel: NSPanel?
    let recovery: RecoveryStore
    var recoveryErrorShown = false
    var fileIndex: [URL] = []
    var picker: QuickPicker?
    var sidebarKind = "files"
    var activityButtons: [NSButton] = []
    var preferences: PreferencesController?
    var restoringLayout = true
    var loading: [URL:UUID] = [:]
    var latestOpenRequest: UUID?
    var remoteConnection: SSHRemote?
    var remoteDirectory = "~"
    var remoteBrowser: RemoteBrowser?
    var runWorkspaceView: RunWorkspace?

    init() {
        let support = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!.appendingPathComponent("Linvell/Recovery",isDirectory:true)
        recovery = RecoveryStore(directory:support)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1320,height:860),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init(window:window)
        window.contentView = WorkspaceRootView(frame:NSRect(x:0,y:0,width:1320,height:860))
        window.title = "Linvell"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named:Theme.profile.isDark ? .darkAqua : .aqua); window.backgroundColor = Theme.panel
        window.minSize = NSSize(width:800,height:540); window.delegate = self
        window.setFrameAutosaveName("Linvell.Workspace"); window.center()
        buildUI(); showWelcome()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in self?.persistRecovery() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { recoveryTimer?.invalidate() }

    func buildUI() {
        guard let rootView = window?.contentView else { return }
        rootView.clipsToBounds = true
        let shell = NSStackView(); shell.orientation = .vertical; shell.spacing = 0; shell.alignment = .leading; shell.distribution = .fill
        Theme.pin(shell,in:rootView)
        let header = Surface(Theme.panel); header.heightAnchor.constraint(equalToConstant:54).isActive = true
        let command = NSButton(title:L.text("Search files or run a command…    ⌘P"),target:self,action:#selector(quickOpen))
        command.bezelStyle = .inline; command.isBordered = false; command.font = .systemFont(ofSize:13)
        command.contentTintColor = Theme.secondary; command.wantsLayer = true; command.layer?.cornerRadius = 6
        command.layer?.borderColor = Theme.secondary.withAlphaComponent(0.20).cgColor; command.layer?.borderWidth = 1
        command.heightAnchor.constraint(equalToConstant:30).isActive = true
        let heading = Theme.stack([
            projectTitle,NSView(),command,NSView(),
            Theme.button("sidebar.left",help:"Toggle Sidebar",target:self,action:#selector(toggleSidebar)),
            Theme.button("folder.badge.plus",help:"Open Folder…",target:self,action:#selector(openFolder)),
            Theme.button("rectangle.split.2x1",help:"Split Editor",target:self,action:#selector(toggleSplit)),
            Theme.button("terminal",help:"Toggle Terminal",target:self,action:#selector(toggleTerminal))
        ])
        heading.translatesAutoresizingMaskIntoConstraints = false; header.addSubview(heading)
        command.widthAnchor.constraint(equalTo:header.widthAnchor,multiplier:0.35).isActive = true
        NSLayoutConstraint.activate([heading.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:90),heading.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-20),heading.bottomAnchor.constraint(equalTo:header.bottomAnchor,constant:-13)])
        shell.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo:shell.widthAnchor).isActive = true
        body.isVertical = true; body.firstMinimum = 180; body.secondMinimum = 400
        body.addArrangedSubview(sidebar); body.addArrangedSubview(center)
        body.onResize = { [weak self] width in if self?.restoringLayout == false { UserDefaults.standard.set(width,forKey:"sidebarWidth") } }
        content.onResize = { [weak self] height in
            if let self,self.terminalHost?.isHidden == false { UserDefaults.standard.set(self.content.bounds.height-height-1,forKey:"terminalHeight") }
        }
        let area = Theme.stack([activity,body],spacing:0); area.alignment = .top
        activity.widthAnchor.constraint(equalToConstant:52).isActive = true
        activity.heightAnchor.constraint(equalTo:area.heightAnchor).isActive = true
        body.heightAnchor.constraint(equalTo:area.heightAnchor).isActive = true
        shell.addArrangedSubview(area)
        area.widthAnchor.constraint(equalTo:shell.widthAnchor).isActive = true
        area.heightAnchor.constraint(equalTo:rootView.heightAnchor,constant:-84).isActive = true
        let footer = Theme.stack([modeLabel,NSView(),status]); footer.edgeInsets = NSEdgeInsets(top:0,left:16,bottom:0,right:20)
        footer.heightAnchor.constraint(equalToConstant:30).isActive = true; shell.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo:shell.widthAnchor).isActive = true
        setupActivity()
        setupSidebar(); setupCenter()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.contentView?.layoutSubtreeIfNeeded()
            let defaults = UserDefaults.standard
            let width = defaults.integer(forKey:"layoutVersion") >= 2 ? defaults.double(forKey:"sidebarWidth") : 260
            self.body.setPosition(width > 0 ? width : 260,ofDividerAt:0)
            self.outline.reloadData(); self.outline.needsDisplay = true
            self.restoringLayout = false; defaults.set(2,forKey:"layoutVersion")
        }
    }

    private func setupSidebar() {
        let label = Theme.label("EXPLORER",size:11,color:Theme.secondary,weight:.semibold)
        let row = Theme.stack([label,NSView(),Theme.button("plus",help:"New File",target:self,action:#selector(newFile)),Theme.button("arrow.clockwise",help:"Refresh Files",target:self,action:#selector(refreshFiles))],spacing:4)
        row.heightAnchor.constraint(equalToConstant:40).isActive = true
        search.placeholderString = L.text("Filter files"); search.font = .systemFont(ofSize:13); search.delegate = self
        search.target = self; search.action = #selector(filterChanged)
        while outline.tableColumns.count > 1 { outline.removeTableColumn(outline.tableColumns.last!) }
        let column = outline.tableColumns.first ?? NSTableColumn(identifier:NSUserInterfaceItemIdentifier("files"))
        if outline.tableColumns.isEmpty { outline.addTableColumn(column) }
        column.width = max(180,sidebar.bounds.width-32); column.resizingMask = .autoresizingMask
        outline.outlineTableColumn = column; outline.headerView = nil
        outline.indentationPerLevel = 18; outline.indentationMarkerFollowsCell = true; outline.autoresizesOutlineColumn = true
        outline.dataSource = self; outline.delegate = self; outline.rowHeight = 32
        outline.backgroundColor = Theme.panel; outline.style = .plain; outline.intercellSpacing = NSSize(width:0,height:4)
        outline.target = self; outline.action = #selector(fileClicked)
        outline.setAccessibilityLabel("Workspace files")
        let scroll = NSScrollView(); scroll.documentView = outline; scroll.hasVerticalScroller = true
        scroll.drawsBackground = true; scroll.backgroundColor = Theme.panel; scroll.borderType = .noBorder
        let foot = Theme.label("⌘K ⌘O  Open folder",size:11,color:Theme.secondary)
        let stack = Theme.stack([row,search,scroll,foot],orientation:.vertical,spacing:10)
        Theme.pin(stack,in:sidebar,inset:16)
    }

    private func setupActivity() {
        let icon = NSImageView()
        if let url = Bundle.main.url(forResource:"Linvell",withExtension:"png") { icon.image = NSImage(contentsOf:url) }
        icon.imageScaling = .scaleProportionallyUpOrDown; icon.heightAnchor.constraint(equalToConstant:32).isActive = true
        var controls: [NSView] = [icon]
        for (index,entry) in [("doc.on.doc","Explorer"),("magnifyingglass","Search Project"),("arrow.triangle.branch","Source Control"),("list.bullet.rectangle","Document Symbols"),("square.grid.2x2","Project Tools")].enumerated() {
            let button = Theme.button(entry.0,help:entry.1,target:self,action:#selector(activityClicked(_:)))
            button.tag = index; button.image?.isTemplate = true
            button.contentTintColor = index == 0 ? Theme.accent : Theme.secondary
            activityButtons.append(button); controls.append(button)
        }
        controls.append(NSView()); controls.append(Theme.button("gearshape",help:"Settings",target:self,action:#selector(showSettings)))
        let stack = Theme.stack(controls,orientation:.vertical,spacing:18); Theme.pin(stack,in:activity,inset:10)
    }
    @objc private func activityClicked(_ sender: NSButton) {
        switch sender.tag { case 0: showSidebar("files"); case 1: showSidebar("search"); case 2: gitWorkspace(); case 3: showSymbols(); default: projectTools() }
    }
    private func showSidebar(_ kind: String) {
        sidebarKind = kind; sidebar.isHidden = false
        sidebar.subviews.forEach { $0.removeFromSuperview() }
        if kind == "files",let connection = remoteConnection { setupRemoteSidebar(connection) }
        else if kind == "files" { setupSidebar() }
        else if let project = root?.url {
            let tool = ToolSidebar(kind:kind,project:project)
            tool.onSelect = { [weak self] url,line in self?.open(url) { [weak self] in self?.goToLine(line) } }
            Theme.pin(tool,in:sidebar)
        } else {
            let label = Theme.label("Open a folder to get started.",size:13,color:Theme.secondary)
            label.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(label)
            NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:18),label.topAnchor.constraint(equalTo:sidebar.topAnchor,constant:24)])
        }
        for button in activityButtons { button.contentTintColor = button.tag == (kind == "files" ? 0 : kind == "search" ? 1 : 2) ? Theme.accent : Theme.secondary }
        body.adjustSubviews()
    }
    private func goToLine(_ line: Int) {
        guard let view = activePane?.textView else { return }
        let lines = view.string.components(separatedBy:"\n"), preceding = lines.prefix(max(0,min(line-1,lines.count)))
        let offset = min(view.string.utf16.count,preceding.reduce(0) { $0 + $1.utf16.count + 1 })
        view.setSelectedRange(NSRange(location:offset,length:0)); view.scrollRangeToVisible(view.selectedRange()); window?.makeFirstResponder(view)
    }
    private func showSymbols() {
        guard let current else { return }
        let lines = current.buffer.text.components(separatedBy:"\n")
        let expression = try? NSRegularExpression(pattern:#"^\s*(?:(?:public|private|fileprivate|internal|open|final|static|export|async)\s+)*(?:struct|class|enum|protocol|func|function|def|interface|type)\s+([^\s({:]+)"#)
        let options = lines.enumerated().compactMap { index,line -> PickerOption? in
            guard let match = expression?.firstMatch(in:line,range:NSRange(location:0,length:line.utf16.count)) else { return nil }
            let name = (line as NSString).substring(with:match.range(at:1))
            return PickerOption(title:name,detail:"Line \(index+1) · text-based symbol",invoke:{ [weak self] in self?.goToLine(index+1) })
        }
        picker = QuickPicker(title:L.text("Document symbols (text-based)"),options:options,owner:window!)
    }
    @objc func showSettings() {
        if preferences == nil { preferences = PreferencesController() }
        preferences?.showWindow(nil); preferences?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func projectTools() {
        guard let project = root?.url else { openFolder(); return }
        current = nil; activePane = nil; panes = []; markdownView = nil
        editors.arrangedSubviews.forEach { $0.removeFromSuperview() }
        editors.addArrangedSubview(ProjectTools(project:project))
        renderTabs(); previewButton.isHidden = true; breadcrumb.stringValue = L.text("Project Tools")
        status.stringValue = L.text("Project-scoped tools"); modeLabel.stringValue = L.text("TOOLS")
        activityButtons.forEach { $0.contentTintColor = $0.tag == 4 ? Theme.accent : Theme.secondary }
    }
    @objc func gitWorkspace() {
        guard let project = root?.url else { openFolder(); return }
        current = nil; activePane = nil; panes = []; markdownView = nil
        editors.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let git = GitWorkspace(project:project); git.onOpen = { [weak self] in self?.open($0) }
        editors.addArrangedSubview(git); editors.adjustSubviews(); renderTabs()
        previewButton.isHidden = true; breadcrumb.stringValue = L.text("Source Control")
        status.stringValue = L.text("Git repository"); modeLabel.stringValue = "GIT"
        activityButtons.forEach { $0.contentTintColor = $0.tag == 2 ? Theme.accent : Theme.secondary }
    }
    @objc func runWorkspace() {
        let directory = remoteConnection == nil ? (root?.url.path ?? current?.fileURL?.deletingLastPathComponent().path) : remoteDirectory
        guard let directory else { openFolder(); return }
        if let existing = runWorkspaceView,existing.directory != directory || existing.remote?.host != remoteConnection?.host {
            guard existing.mayClose() else { return }; existing.terminate(); runWorkspaceView = nil
        }
        if runWorkspaceView == nil { runWorkspaceView = RunWorkspace(directory:directory,remote:remoteConnection) }
        current = nil; activePane = nil; panes = []; markdownView = nil
        editors.arrangedSubviews.forEach { $0.removeFromSuperview() }
        editors.addArrangedSubview(runWorkspaceView!); editors.adjustSubviews(); renderTabs()
        previewButton.isHidden = true; breadcrumb.stringValue = L.text("Run & Preview"); modeLabel.stringValue = "RUN"
    }

    private func setupCenter() {
        tabs.orientation = .horizontal; tabs.spacing = 4; tabs.alignment = .centerY
        tabs.edgeInsets = NSEdgeInsets(top:0,left:0,bottom:0,right:0)
        tabScroll.documentView = tabs; tabScroll.hasHorizontalScroller = true; tabScroll.autohidesScrollers = true
        tabScroll.drawsBackground = false; tabScroll.heightAnchor.constraint(equalToConstant:42).isActive = true
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.heightAnchor.constraint(equalTo:tabScroll.contentView.heightAnchor).isActive = true
        previewButton.title = "Preview"; previewButton.image = NSImage(systemSymbolName:"eye",accessibilityDescription:nil)
        previewButton.imagePosition = .imageLeading; previewButton.isBordered = false; previewButton.contentTintColor = Theme.accent
        previewButton.target = self; previewButton.action = #selector(toggleMarkdownPreview); previewButton.isHidden = true
        previewButton.setAccessibilityLabel(L.text("Toggle Preview")); previewButton.toolTip = L.text("Preview · ⇧⌘V")
        let pathRow = Theme.stack([breadcrumb,NSView(),previewButton]); pathRow.edgeInsets = NSEdgeInsets(top:0,left:24,bottom:0,right:24)
        pathRow.heightAnchor.constraint(equalToConstant:34).isActive = true
        editors.isVertical = true
        Theme.pin(editors,in:editorHost)
        editorHost.translatesAutoresizingMaskIntoConstraints = false
        content.isVertical = false; content.addArrangedSubview(editorHost)
        let stack = Theme.stack([tabScroll,pathRow,content],orientation:.vertical,spacing:0)
        Theme.pin(stack,in:center)
    }

    private func showWelcome() {
        editors.arrangedSubviews.forEach { $0.removeFromSuperview() }; panes = []; activePane = nil
        markdownView = nil; editors.addArrangedSubview(WelcomeView(owner:self))
    }

    @objc func newFile() {
        if remoteConnection != nil { remoteBrowser?.createFile(); return }
        latestOpenRequest = nil; activate(OpenDocument(DocumentBuffer()))
    }
    @objc func openFile() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = false
        p.beginSheetModal(for:window!) { [weak self] result in if result == .OK { p.urls.forEach { self?.open($0) } } }
    }
    @objc func openFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
        p.beginSheetModal(for:window!) { [weak self] result in if result == .OK, let url = p.url { self?.setProject(url) } }
    }
    func setProject(_ url: URL) {
        let wasRemote = remoteConnection != nil
        if wasRemote {
            guard mayCloseTerminal() else { return }; terminateTerminal()
            terminalHost?.removeFromSuperview(); terminalHost = nil; terminal = nil
        }
        remoteConnection = nil; remoteBrowser = nil
        root = FileNode(url); projectTitle.stringValue = url.lastPathComponent
        outline.reloadData(); UserDefaults.standard.set(url.path,forKey:"lastProject")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let files = ProjectFiles.list(url)
            DispatchQueue.main.async { [weak self] in if self?.root?.url == url { self?.fileIndex = files } }
        }
        if wasRemote || sidebarKind != "files" { showSidebar(wasRemote ? "files" : sidebarKind) }
    }
    func open(_ url: URL,completion: (() -> Void)? = nil) {
        if (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true { setProject(url); return }
        if let existing = documents.first(where: { $0.fileURL == url.resolvingSymlinksInPath() }) { activate(existing); completion?(); return }
        let resolved = url.resolvingSymlinksInPath()
        if ImagePreview.supports(resolved) { latestOpenRequest = nil; activate(OpenDocument(imageURL:resolved)); completion?(); return }
        guard loading[resolved] == nil else { return }
        let request = UUID(); loading[resolved] = request; latestOpenRequest = request
        status.stringValue = L.format("Opening %@…",url.lastPathComponent)
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            do {
                let buffer = try DocumentBuffer(url:resolved),index = LineIndex(buffer.text)
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.loading[resolved] == request else { return }
                    self.loading.removeValue(forKey:resolved)
                    guard self.window?.isVisible == true else { return }
                    let doc = OpenDocument(buffer,lines:index)
                    if self.latestOpenRequest == request { self.activate(doc); completion?() }
                    else { self.documents.append(doc); self.renderTabs() }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.loading.removeValue(forKey:resolved); self?.show(error) }
            }
        }
    }
    func activate(_ document: OpenDocument) {
        if !documents.contains(where: { $0 === document }) { documents.append(document) }
        current = document
        editors.arrangedSubviews.forEach { $0.removeFromSuperview() }
        panes = []; activePane = nil; markdownView = nil
        if let url = document.imageURL { editors.addArrangedSubview(ImagePreview(url:url)) }
        else {
            let pane = makePane(document); editors.addArrangedSubview(pane); activePane = pane
            if document.supportsPreview && document.markdownPreview {
                let preview = MarkdownPreview(root:document.fileURL!.deletingLastPathComponent(),html:document.isHTML)
                preview.openFile = { [weak self] in self?.open($0) }; preview.render(document.buffer.text)
                markdownView = preview; editors.addArrangedSubview(preview); editors.setPosition(editors.bounds.width/2,ofDividerAt:0)
            }
        }
        editors.adjustSubviews(); renderTabs(); updateStatus(); window?.makeFirstResponder(activePane?.textView)
        window?.title = "\(document.displayName) — Linvell"
    }
    private func makePane(_ document: OpenDocument) -> EditorPane {
        let pane = EditorPane(document:document,vim:vimEnabled)
        pane.translatesAutoresizingMaskIntoConstraints = false
        pane.onFocus = { [weak self,weak pane] in self?.activePane = pane }
        pane.onChange = { [weak self] in self?.updateStatus(); self?.updateTabTitles() }
        pane.onTextChanged = { [weak self] in self?.markdownView?.render(document.buffer.text) }
        pane.textView.exCommand = { [weak self] _ in self?.showEx() }
        panes.append(pane); return pane
    }
    private func renderTabs() {
        tabs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index,doc) in documents.enumerated() {
            let b = NSButton(title:doc.displayName,target:self,action:#selector(tabClicked(_:)))
            b.tag = index; b.bezelStyle = .inline; b.isBordered = false; b.font = .systemFont(ofSize:13,weight:doc === current ? .semibold : .regular)
            b.contentTintColor = doc === current ? Theme.foreground : Theme.secondary
            let close = Theme.button("xmark",help:L.format("Close %@",doc.displayName),target:self,action:#selector(closeTab(_:))); close.tag = index
            let icon = FileIcon.view(for:doc.fileURL)
            let row = Theme.stack([icon,b,close],spacing:10); row.edgeInsets = NSEdgeInsets(top:0,left:16,bottom:0,right:6)
            row.heightAnchor.constraint(equalToConstant:42).isActive = true
            row.wantsLayer = true; row.layer?.backgroundColor = (doc === current ? Theme.canvas : Theme.panel).cgColor
            if doc === current { row.layer?.borderColor = Theme.accent.withAlphaComponent(0.3).cgColor; row.layer?.borderWidth = 1 }
            tabs.addArrangedSubview(row)
        }
        updateTabTitles()
    }
    private func updateTabTitles() {
        for (i,row) in tabs.arrangedSubviews.enumerated() {
            guard i < documents.count,let b = (row as? NSStackView)?.arrangedSubviews.compactMap({ $0 as? NSButton }).first else { continue }
            b.title = documents[i].displayName + (documents[i].buffer.isModified ? "  •" : "")
        }
        window?.isDocumentEdited = documents.contains { $0.buffer.isModified }
    }
    @objc private func tabClicked(_ sender: NSButton) { activate(documents[sender.tag]) }
    @objc private func closeTab(_ sender: NSButton) { closeDocument(documents[sender.tag]) }
    @objc func closeCurrent() { if let current { closeDocument(current) } }
    private func closeDocument(_ doc: OpenDocument) {
        guard mayClose(doc) else { return }
        do { try recovery.remove(doc.buffer.id) } catch { show(error); return }
        documents.removeAll { $0 === doc }
        if current === doc {
            if let next = documents.last { activate(next) } else { current = nil; renderTabs(); showWelcome(); updateStatus() }
        } else { renderTabs() }
    }

    @objc func save() { if let current { _ = saveDocument(current) } }
    @objc func saveAs() { if let current { _ = saveDocument(current,asCopy:true) } }
    @discardableResult func saveDocument(_ doc: OpenDocument, asCopy: Bool = false) -> Bool {
        guard doc.imageURL == nil else { return true }
        if let remote = doc.remote,!asCopy {
            do {
                let data = try doc.buffer.dataForSaving()
                try RemoteProgress.perform("Saving remote file…") { try remote.save(data) }
                try doc.buffer.save(); try recovery.remove(doc.buffer.id)
                renderTabs(); updateStatus(); return true
            } catch { show(error); return false }
        }
        var destination: URL?
        if doc.buffer.url == nil || asCopy {
            let p = NSSavePanel(); p.nameFieldStringValue = doc.displayName
            guard p.runModal() == .OK, let url = p.url else { return false }; destination = url
        }
        do {
            try doc.buffer.save(to:destination); try recovery.remove(doc.buffer.id)
            if asCopy { doc.remote = nil }
            renderTabs(); updateStatus(); return true
        } catch { show(error); return false }
    }
    func mayClose(_ doc: OpenDocument) -> Bool {
        guard doc.buffer.isModified else { return true }
        let a = NSAlert(); a.messageText = L.format("Save changes to %@?",doc.buffer.displayName); a.informativeText = L.text("Your changes will be lost if you discard them.")
        a.addButton(withTitle:L.text("Save")); a.addButton(withTitle:L.text("Cancel")); a.addButton(withTitle:L.text("Discard"))
        switch a.runModal() { case .alertFirstButtonReturn: return saveDocument(doc); case .alertThirdButtonReturn: return true; default: return false }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { documents.allSatisfy(mayClose) && mayCloseTerminal() }
    func mayCloseTerminal() -> Bool {
        if let runWorkspaceView,!runWorkspaceView.mayClose() { return false }
        guard terminal?.process.running == true else { return true }
        let alert = NSAlert(); alert.messageText = L.text("Close this terminal session?"); alert.informativeText = L.text("The shell and its running processes will be stopped.")
        alert.addButton(withTitle:L.text("Close Session")); alert.addButton(withTitle:L.text("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    func terminateTerminal() {
        runWorkspaceView?.shutdown()
        guard let terminal else { return }
        let process = terminal.process!
        if process.running {
            let foreground = tcgetpgrp(process.childfd)
            if foreground > 0 && foreground != getpgrp() { kill(-foreground,SIGHUP) }
            let shell = process.shellPid
            if shell > 0 && shell != getpgrp() { kill(-shell,SIGHUP) }
        }
        terminal.terminate()
    }
    func windowWillClose(_ notification: Notification) {
        terminateTerminal(); recoveryTimer?.invalidate()
        for d in documents { try? recovery.remove(d.buffer.id) }
    }
    func persistRecovery() {
        do { for d in documents where d.buffer.isModified { try recovery.write(d.buffer) } }
        catch { if !recoveryErrorShown { recoveryErrorShown = true; show(error) } }
    }
    func restore() {
        if let path = UserDefaults.standard.string(forKey:"lastProject"),FileManager.default.fileExists(atPath:path) { setProject(URL(fileURLWithPath:path)) }
        do {
            for entry in try recovery.entries() {
                // Recovered content stays an untitled copy so a changed disk file cannot be overwritten.
                activate(OpenDocument(DocumentBuffer(text:entry.text,id:entry.id)))
            }
        } catch { show(error) }
    }

    func updateStatus() {
        guard let current else { status.stringValue = L.text("Development preview"); breadcrumb.stringValue = L.text("Your next idea starts here"); previewButton.isHidden = true; markdownView = nil; return }
        breadcrumb.stringValue = current.remote.map { $0.connection.host+":"+$0.path } ?? current.displayName; previewButton.isHidden = !current.supportsPreview
        previewButton.title = L.text(current.markdownPreview ? "Hide Preview" : "Preview")
        if current.imageURL != nil { status.stringValue = L.text("Image preview · Read only"); modeLabel.stringValue = L.text("IMAGE"); return }
        let p = min(activePane?.textView.selectedRange().location ?? 0,current.buffer.text.utf16.count)
        let row = current.lines.line(at:p),start = current.lines.starts[row]
        let line = row+1,column = (current.buffer.text as NSString).substring(with:NSRange(location:start,length:p-start)).count+1
        status.stringValue = L.format("Ln %d, Col %d     %@     %d pt",line,column,current.buffer.formatLabel,Int(Theme.fontSize))
        modeLabel.stringValue = vimEnabled ? L.text(current.vim.mode.rawValue) + (current.vim.pending.isEmpty ? "" : "  \(current.vim.pending)") : L.text("TEXT")
    }
    @objc func toggleVim() {
        vimEnabled.toggle(); UserDefaults.standard.set(vimEnabled,forKey:"vimEnabled")
        panes.forEach { $0.textView.vimEnabled = vimEnabled; $0.document.vim.escape(); $0.textView.needsDisplay = true }; updateStatus()
        PreferencesSync.shared.changed()
    }
    @objc func toggleSidebar() { sidebar.isHidden.toggle(); body.adjustSubviews() }
    @objc func toggleSplit() {
        guard let current,current.imageURL == nil else { return }
        if current.markdownPreview { current.markdownPreview = false; activate(current); return }
        if panes.count > 1 { let last = panes.removeLast(); last.removeFromSuperview(); activePane = panes.first }
        else { editors.addArrangedSubview(makePane(current)); editors.setPosition(editors.bounds.width/2,ofDividerAt:0) }
        editors.adjustSubviews()
    }
    @objc func toggleMarkdownPreview() {
        guard let current,current.supportsPreview else { return }
        current.markdownPreview.toggle(); activate(current)
    }
    @objc func increaseFont() { Theme.fontSize += 1; PreferencesSync.shared.changed() }
    @objc func decreaseFont() { Theme.fontSize -= 1; PreferencesSync.shared.changed() }
    func applyTheme() {
        window?.appearance = NSAppearance(named:Theme.profile.isDark ? .darkAqua : .aqua); window?.backgroundColor = Theme.panel
        func refresh(_ view: NSView) {
            (view as? Surface)?.refreshTheme(); (view as? ThemedLabel)?.refreshTheme()
            if let button = view as? NSButton { button.contentTintColor = Theme.secondary }
            view.needsDisplay = true; view.subviews.forEach(refresh)
        }
        if let view = window?.contentView { refresh(view) }
        (editors.arrangedSubviews.first as? GitWorkspace)?.refreshTheme()
        runWorkspaceView?.refreshTheme(); remoteBrowser?.table.backgroundColor = Theme.panel
        panes.forEach { $0.updateTheme() }; outline.backgroundColor = Theme.panel; outline.reloadData(); renderTabs()
        if let terminal { configureTerminal(terminal) }
        if let current,let markdownView { markdownView.render(current.buffer.text) }
        if sidebarKind != "files" { showSidebar(sidebarKind) }
    }
    func relocalize() {
        if let view = window?.contentView { L.apply(to:view) }
        if editors.arrangedSubviews.first is WelcomeView { showWelcome() }
        outline.reloadData(); renderTabs()
        if current != nil { updateStatus() }
    }
    @objc func toggleTerminal() {
        if let host = terminalHost { host.isHidden.toggle(); content.adjustSubviews(); if !host.isHidden,let terminal { window?.makeFirstResponder(terminal) }; return }
        let host = Surface(Theme.canvas)
        host.translatesAutoresizingMaskIntoConstraints = false
        let title = Theme.label("TERMINAL",size:11,color:Theme.secondary,weight:.semibold)
        let bar = Theme.stack([title,NSView(),Theme.button("xmark",help:"Hide Terminal",target:self,action:#selector(toggleTerminal))]); bar.heightAnchor.constraint(equalToConstant:32).isActive = true
        let term = LocalProcessTerminalView(frame:NSRect(x:0,y:0,width:900,height:220))
        configureTerminal(term)
        let stack = Theme.stack([bar,term],orientation:.vertical,spacing:4)
        Theme.pin(stack,in:host,inset:12)
        terminal = term; terminalHost = host; content.addArrangedSubview(host)
        let savedHeight = UserDefaults.standard.double(forKey:"terminalHeight")
        content.setPosition(max(120,content.bounds.height-(savedHeight > 100 ? savedHeight : 270)),ofDividerAt:0)
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"; env["TERM_PROGRAM"] = "Linvell"
        let shell = env["SHELL"] ?? "/bin/zsh"
        if let remote = remoteConnection {
            let command = "cd -- "+RunTasks.directoryExpression(remoteDirectory)+" && exec \"${SHELL:-/bin/sh}\" -l"
            term.startProcess(executable:"/usr/bin/ssh",args:["-tt","--",remote.host,command],environment:env.map { "\($0.key)=\($0.value)" },currentDirectory:FileManager.default.homeDirectoryForCurrentUser.path)
        } else {
            term.startProcess(executable:shell,args:["-l"],environment:env.map { "\($0.key)=\($0.value)" },currentDirectory:root?.url.path ?? FileManager.default.homeDirectoryForCurrentUser.path)
        }
        window?.makeFirstResponder(term)
    }
    private func configureTerminal(_ terminal: LocalProcessTerminalView) {
        let editorFont = Theme.editorFont
        terminal.font = editorFont.isFixedPitch ? editorFont : .monospacedSystemFont(ofSize:Theme.fontSize,weight:.regular)
        terminal.nativeBackgroundColor = Theme.canvas; terminal.nativeForegroundColor = Theme.foreground
        terminal.clipsToBounds = true; terminal.caretColor = Theme.accent; terminal.caretTextColor = Theme.canvas; terminal.caretViewTracksFocus = true
        let colors: [UInt32] = Theme.profile.isDark
            ? [0x27323B,0xED8796,0x8BD5A2,0xEED49F,0x8AADF4,0xC6A0F6,0x8BD5CA,0xCAD3F5,0x6E7B8A,0xF5A2AF,0xA6DA95,0xF5D8A6,0xA5C3FF,0xD5B2FF,0x9EE4DB,0xEFF4FF]
            : [0x35443F,0xB33245,0x247A4F,0x946300,0x245BC5,0x8251A3,0x187583,0xCBD5D0,0x657C71,0xCF3B50,0x34824D,0x956919,0x326BD4,0x985AB3,0x1B8791,0xFCFDFD]
        terminal.installColors(colors.map { value in SwiftTerm.Color(red:UInt16((value>>16)&255)*257,green:UInt16((value>>8)&255)*257,blue:UInt16(value&255)*257) })
    }

    @objc func find() { activePane?.textView.performFindPanelAction(menuItem(tag:Int(NSFindPanelAction.showFindPanel.rawValue))) }
    private func menuItem(tag: Int) -> NSMenuItem { let item = NSMenuItem(); item.tag = tag; return item }
    @objc func selectNextOccurrence() {
        guard let v = activePane?.textView else { return }
        if v.selectedRange().length == 0 { v.selectWord(nil); return }
        let ns = v.string as NSString, selected = v.selectedRange(), word = ns.substring(with:selected)
        let end = v.editingSelections.map { NSMaxRange($0) }.max() ?? NSMaxRange(selected)
        var range = ns.range(of:word,range:NSRange(location:end,length:ns.length-end))
        if range.location == NSNotFound { range = ns.range(of:word,range:NSRange(location:0,length:selected.location)) }
        if range.location != NSNotFound && !v.editingSelections.contains(range) {
            v.setSelections(v.editingSelections+[range]); v.scrollRangeToVisible(range)
        }
    }
    @objc func skipOccurrence() {
        guard let v = activePane?.textView,v.selectedRange().length > 0 else { return }
        var ranges = v.editingSelections
        guard let skipped = ranges.popLast() else { return }
        let ns = v.string as NSString,word = ns.substring(with:skipped),end = NSMaxRange(skipped)
        var next = ns.range(of:word,range:NSRange(location:end,length:ns.length-end))
        if next.location == NSNotFound { next = ns.range(of:word,range:NSRange(location:0,length:skipped.location)) }
        if next.location != NSNotFound,!ranges.contains(next) { v.setSelections(ranges+[next]); v.scrollRangeToVisible(next) }
    }
    @objc func selectAllOccurrences() {
        guard let v = activePane?.textView else { return }
        if v.selectedRange().length == 0 { v.selectWord(nil) }
        let ns = v.string as NSString,selection = v.selectedRange()
        guard selection.length > 0 else { return }
        let word = ns.substring(with:selection); var matches: [NSRange] = [],offset = 0
        while offset < ns.length {
            let r = ns.range(of:word,range:NSRange(location:offset,length:ns.length-offset))
            if r.location == NSNotFound { break }; matches.append(r); offset = NSMaxRange(r)
        }
        v.setSelections(matches)
    }
    @objc func undoSelections() { activePane?.textView.undoSelection() }
    @objc func addCursorAbove() { addCursors(direction:-1) }
    @objc func addCursorBelow() { addCursors(direction:1) }
    private func addCursors(direction: Int) {
        guard let v = activePane?.textView,let current else { return }
        let ns = v.string as NSString,index = current.lines
        var ranges = v.editingSelections
        for selection in ranges {
            let cursor = NSMaxRange(selection),row = index.line(at:cursor),targetRow = row+direction
            guard targetRow >= 0,targetRow < index.starts.count else { continue }
            let end = targetRow+1 < index.starts.count ? index.starts[targetRow+1]-1 : ns.length
            var target = min(end,index.starts[targetRow]+cursor-index.starts[row])
            if target < ns.length { target = ns.rangeOfComposedCharacterSequence(at:target).location }
            ranges.append(NSRange(location:target,length:0))
        }
        v.setSelections(ranges)
    }
    @objc func splitSelectionIntoLines() {
        guard let v = activePane?.textView,let current else { return }
        let index = current.lines,ns = v.string as NSString
        var carets: [NSRange] = []
        for selection in v.editingSelections {
            let first = index.line(at:selection.location),last = index.line(at:max(selection.location,NSMaxRange(selection)-1))
            for line in first...last {
                let end = line+1 < index.starts.count ? index.starts[line+1]-1 : ns.length
                carets.append(NSRange(location:min(end,NSMaxRange(selection)),length:0))
            }
        }
        v.setSelections(carets)
    }
    @objc func selectCurrentLine() {
        guard let v = activePane?.textView,let current else { return }
        let row = current.lines.line(at:v.selectedRange().location),start = current.lines.starts[row]
        let end = row+1 < current.lines.starts.count ? current.lines.starts[row+1] : current.storage.length
        v.setSelections([NSRange(location:start,length:end-start)])
    }
    @objc func projectSearch() { showSidebar("search") }
    @objc func documentSymbols() { showSymbols() }
    @objc func replaceInFile() { activePane?.textView.performFindPanelAction(menuItem(tag:Int(NSTextFinder.Action.showReplaceInterface.rawValue))) }
    @objc func refreshFiles() { if let url = root?.url { root = FileNode(url); outline.reloadData() } }
    @objc private func filterChanged() { outline.reloadData() }
    private var filtered: [FileNode] {
        let nodes = root?.children ?? []
        return search.stringValue.isEmpty ? nodes : nodes.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(search.stringValue) }
    }
    func outlineView(_ outlineView: NSOutlineView,numberOfChildrenOfItem item: Any?) -> Int { (item as? FileNode)?.children.count ?? filtered.count }
    func outlineView(_ outlineView: NSOutlineView,child index: Int,ofItem item: Any?) -> Any { (item as? FileNode)?.children[index] ?? filtered[index] }
    func outlineView(_ outlineView: NSOutlineView,isItemExpandable item: Any) -> Bool { (item as? FileNode)?.isDirectory == true }
    func outlineView(_ outlineView: NSOutlineView,viewFor tableColumn: NSTableColumn?,item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let label = Theme.label(node.url.lastPathComponent,size:13,color:node.isDirectory ? Theme.foreground : Theme.secondary)
        label.lineBreakMode = .byTruncatingMiddle
        let image = FileIcon.view(for:node.url,folder:node.isDirectory,expanded:outlineView.isItemExpanded(node))
        return Theme.stack([image,label],spacing:8)
    }
    @objc private func fileClicked() {
        guard outline.clickedRow >= 0,let node = outline.item(atRow:outline.clickedRow) as? FileNode else { return }
        if node.isDirectory { if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) } }
        else { open(node.url) }
    }
    func show(_ error: Error) { let alert = NSAlert(error:error); if let window { alert.beginSheetModal(for:window) } }

    @objc func quickOpen() {
        if let connection = remoteConnection { quickOpenRemote(connection); return }
        guard let root else { openFile(); return }
        let options = fileIndex.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.map { url in
            PickerOption(title:url.lastPathComponent,detail:ProjectFiles.relative(url,root:root.url),fileURL:url,invoke:{ [weak self] in self?.open(url) })
        }
        picker = QuickPicker(title:L.text("Search files by name"),options:options,owner:window!)
    }
    @objc func commandPalette() {
        var options: [PickerOption] = []
        for (title,selector) in [("New File",#selector(newFile)),("Open Folder…",#selector(openFolder)),("Connect to SSH Host…",#selector(connectSSH)),("Source Control",#selector(gitWorkspace)),("Run & Preview",#selector(runWorkspace)),("Find in File",#selector(find)),("Toggle Vim Mode",#selector(toggleVim)),("Split Editor",#selector(toggleSplit)),("Toggle Terminal",#selector(toggleTerminal)),("Increase Font Size",#selector(increaseFont)),("Decrease Font Size",#selector(decreaseFont))] {
            options.append(PickerOption(title:title,detail:"Linvell command",invoke:{ [weak self] in self?.perform(selector) }))
        }
        options.append(PickerOption(title:L.text("Preferences: Theme and Font"),detail:"Appearance",invoke:{ [weak self] in self?.showSettings() }))
        picker = QuickPicker(title:L.text("Search commands"),options:options,owner:window!)
    }
    private func showEx() {
        let alert = NSAlert(); alert.messageText = L.text("Vim command"); alert.informativeText = L.text("Available in this preview: :w, :q, :wq, :set number, :set nonumber")
        let field = NSTextField(string:":"); field.frame = NSRect(x:0,y:0,width:340,height:28); field.font = .monospacedSystemFont(ofSize:15,weight:.regular)
        alert.accessoryView = field; alert.addButton(withTitle:L.text("Run")); alert.addButton(withTitle:L.text("Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for:window!) { [weak self] response in
            guard response == .alertFirstButtonReturn,let self else { return }
            switch field.stringValue.trimmingCharacters(in:.whitespaces).trimmingCharacters(in:CharacterSet(charactersIn:":")) {
            case "w": self.save()
            case "q": self.closeCurrent()
            case "wq": if let doc = self.current,self.saveDocument(doc) { self.closeCurrent() }
            case "set number", "set nu": self.panes.forEach { $0.scroll.rulersVisible = true }
            case "set nonumber", "set nonu": self.panes.forEach { $0.scroll.rulersVisible = false }
            default: self.show(NSError(domain:"Linvell.Vim",code:1,userInfo:[NSLocalizedDescriptionKey:"This Ex command is not implemented yet."]))
            }
        }
    }
}
