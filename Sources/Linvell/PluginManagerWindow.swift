import AppKit
import LinvellCore
import LinvellPluginKit

private final class PluginManagerCell: NSTableCellView {
    override var backgroundStyle: NSView.BackgroundStyle { didSet { textField?.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : Theme.foreground } }
}

/// A native manager for trusted, persistent packages; catalog downloads do not execute code.
final class PluginManagerWindow: PluginOwnedWindow, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let store: PluginStore
    private let queue = DispatchQueue(label:"top.fuluwa.linvell.plugin-manager",qos:.userInitiated)
    private let tabs = NSSegmentedControl(labels:[L.text("Installed Plugins"),L.text("Plugin Catalog"),L.text("Plugin Sources")],trackingMode:.selectOne,target:nil,action:nil)
    private let table = NSTableView(),details = NSTextField(wrappingLabelWithString:""),status = NSTextField(wrappingLabelWithString:"")
    private let actions = NSStackView(),sourceField = NSTextField()
    private let search = NSSearchField()
    private var listedInstalled: [InstalledPlugin] = [],listedSources: [PluginSource] = []
    private var controls: [NSControl] = []
    private var registry = PluginRegistry()
    private var catalogs: [String:PluginCatalog] = [:]
    private var offers: [String:String] = [:]
    private var available: [(PluginSource,PluginCatalog.Entry)] = []
    private var preferredSelection: String?
    private var renderedTab = 0
    private var busy = false
    init(owner: WorkspaceController,store: PluginStore? = nil) {
        self.store = store ?? owner.installedPluginStore;super.init(owner:owner,title:L.text("Plugin Manager"))
        window?.setContentSize(NSSize(width:880,height:650));window?.minSize = NSSize(width:760,height:580)
        tabs.selectedSegment = 0;tabs.target = self;tabs.action = #selector(tabChanged);controls.append(tabs)
        let install = button("Install Package…",#selector(installPackage)),url = button("Install from URL…",#selector(installURL)),check = button("Check Plugin Updates",#selector(checkUpdates))
        let heading = Theme.stack([install,url,check,NSView()])
        table.headerView = nil;table.rowHeight = 42;table.delegate = self;table.dataSource = self;table.backgroundColor = Theme.canvas
        let column = NSTableColumn(identifier:.init("plugin"));column.title = L.text("Plugins");table.addTableColumn(column);table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle;table.setAccessibilityLabel(L.text("Plugin Manager List"))
        let scroll = ResponsiveScrollView();scroll.documentView = table;scroll.hasVerticalScroller = true
        details.textColor = Theme.foreground;status.textColor = Theme.secondary;details.maximumNumberOfLines = 6;status.maximumNumberOfLines = 3
        search.placeholderString = L.text("Search plugins and sources");search.delegate = self;controls.append(search)
        sourceField.placeholderString = L.text("HTTPS source catalog URL");sourceField.isHidden = true
        actions.orientation = .horizontal;actions.spacing = 8
        let content = Theme.stack([heading,tabs,search,scroll,details,sourceField,actions,status],orientation:.vertical,spacing:12);content.alignment = .leading;content.detachesHiddenViews = true
        Theme.pin(content,in:window!.contentView!,inset:18)
        for view in [heading,search,scroll,details,sourceField,actions,status] as [NSView] { view.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true }
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:220).isActive = true
        NotificationCenter.default.addObserver(self,selector:#selector(storeChanged),name:PluginStore.changed,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(runtimeChanged),name:PluginMenus.changed,object:owner)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    private func button(_ title: String,_ action: Selector) -> NSButton { let value = Theme.actionButton(title,target:self,action:action);controls.append(value);return value }
    private func perform<T>(_ title: String,work: @escaping () throws -> T,completion: @escaping (T) -> Void = { _ in }) {
        guard !busy else { return };busy = true;status.stringValue = L.text(title);controls.forEach { $0.isEnabled = false }
        queue.async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async {
                guard let self else { return };self.busy = false;self.controls.forEach { $0.isEnabled = true }
                do { let value = try result.get();self.status.stringValue = L.text("Plugin operation completed.");completion(value) }
                catch { self.busy = true;NotificationCenter.default.post(name:PluginStore.changed,object:nil);self.busy = false;self.status.stringValue = L.existing(error.localizedDescription) }
                self.renderActions()
            }
        }
    }
    override func refreshAppearance() {
        super.refreshAppearance();table.backgroundColor = Theme.canvas;details.textColor = Theme.foreground;status.textColor = Theme.secondary;table.reloadData()
    }
    @objc private func runtimeChanged() { if tabs.selectedSegment == 0 { renderActions() } }
    @objc private func storeChanged() { if !busy { refresh() } }
    func refresh() {
        perform("Loading installed plugins…",work:{ try self.store.registry() }) { [weak self] value in self?.registry = value;self?.reload() }
    }
    private func reload() {
        func keys(_ tab: Int) -> [String] {
            switch tab { case 0: return listedInstalled.map(\.id);case 1:return available.map { $0.0.id+"/"+$0.1.id };default:return listedSources.map(\.id) }
        }
        let oldKeys = keys(renderedTab),row = table.selectedRow
        let selection = preferredSelection ?? (renderedTab == tabs.selectedSegment && oldKeys.indices.contains(row) ? oldKeys[row] : nil)
        preferredSelection = nil;renderedTab = tabs.selectedSegment
        func match(_ text: String) -> Bool { search.stringValue.isEmpty || text.localizedCaseInsensitiveContains(search.stringValue) }
        listedInstalled = registry.installed.filter { match($0.name+" "+$0.id) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        listedSources = registry.sources.filter { match($0.name+" "+$0.url.absoluteString) }
        available = registry.sources.flatMap { source in (catalogs[source.id]?.plugins ?? []).filter { match($0.name+" "+$0.id+" "+($0.description ?? "")) }.map { (source,$0) } }
        table.deselectAll(nil);table.reloadData();if table.numberOfRows > 0 { table.selectRowIndexes(IndexSet(integer:selection.flatMap { keys(renderedTab).firstIndex(of:$0) } ?? 0),byExtendingSelection:false) };renderActions()
    }
    func controlTextDidChange(_ notification: Notification) { reload() }
    @objc private func tabChanged() { sourceField.isHidden = tabs.selectedSegment != 2;reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { switch tabs.selectedSegment { case 0: return listedInstalled.count;case 1:return available.count;default:return listedSources.count } }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let text: String
        switch tabs.selectedSegment {
        case 0:
            guard listedInstalled.indices.contains(row) else { return nil };let record = listedInstalled[row]
            text = record.name+"  "+record.version+"  · "+L.text(record.enabled ? "Enabled" : "Disabled")+(offers[record.id].map { "  → "+$0 } ?? "")
        case 1:
            guard available.indices.contains(row) else { return nil };let (source,entry) = available[row];text = entry.name+"  "+entry.version+"  · "+source.name
        default:
            guard listedSources.indices.contains(row) else { return nil };let source = listedSources[row];text = source.name+"  · "+source.url.absoluteString
        }
        let value = NSTextField(labelWithString:text);value.lineBreakMode = .byTruncatingMiddle;value.textColor = Theme.foreground
        let cell = PluginManagerCell();cell.textField = value;Theme.pin(value,in:cell,inset:8);return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { renderActions() }
    private var selected: InstalledPlugin? { listedInstalled.indices.contains(table.selectedRow) ? listedInstalled[table.selectedRow] : nil }
    private func renderActions() {
        for view in actions.arrangedSubviews { controls.removeAll { $0 === view };actions.removeArrangedSubview(view);view.removeFromSuperview() }
        details.stringValue = ""
        switch tabs.selectedSegment {
        case 0:
            guard let record = selected else { details.stringValue = L.text("No installed plugins. Install a package or add a plugin source.");return }
            let running = workspaceOwner?.pluginSessions[record.id].map { !$0.isStopped } ?? false
            details.stringValue = record.id+"\n"+L.text(running ? "Loaded in this workspace" : "Not running in this workspace")+" · "+L.text("Loads when enabled, including after restart.")+"\n"+(record.sourceURL?.absoluteString ?? record.downloadURL?.absoluteString ?? L.text("Local package; update by installing a newer package."))
            actions.addArrangedSubview(button(record.enabled ? "Disable Plugin" : "Enable Plugin",#selector(toggleEnabled)))
            if record.enabled { actions.addArrangedSubview(button("Reload Plugin",#selector(reloadPlugin))) }
            actions.addArrangedSubview(button("Update Plugin…",#selector(updatePlugin)))
            let rollback = button("Roll Back Plugin…",#selector(rollbackPlugin));rollback.isEnabled = record.previous != nil && !busy;actions.addArrangedSubview(rollback)
            actions.addArrangedSubview(button("Uninstall Plugin…",#selector(uninstallPlugin)))
            if let session = workspaceOwner?.pluginSessions[record.id] {
                if !(session.package.manifest.settings ?? []).isEmpty { actions.addArrangedSubview(button("Plugin Settings…",#selector(settings))) }
                actions.addArrangedSubview(button("Plugin Logs",#selector(logs)))
            }
        case 1:
            actions.addArrangedSubview(button("Refresh Plugin Sources",#selector(checkUpdates)))
            if available.indices.contains(table.selectedRow) { let (source,entry) = available[table.selectedRow];details.stringValue = entry.id+"\n"+(entry.description ?? "")+"\n"+source.url.absoluteString;actions.addArrangedSubview(button("Install Selected Plugin…",#selector(installSelected))) }
            else { details.stringValue = L.text("Add an HTTPS plugin source, then refresh its catalog.") }
        default:
            actions.addArrangedSubview(button("Add Plugin Source",#selector(addSource)))
            if listedSources.indices.contains(table.selectedRow) {
                let source = listedSources[table.selectedRow];sourceField.stringValue = source.url.absoluteString;details.stringValue = L.text("Changing a source affects future updates. Installed plugins are kept when a source is removed.")
                actions.addArrangedSubview(button("Save Source URL",#selector(editSource)));actions.addArrangedSubview(button("Remove Plugin Source",#selector(removeSource)))
            }
            actions.addArrangedSubview(button("Refresh Plugin Sources",#selector(checkUpdates)))
        }
        if busy { controls.forEach { $0.isEnabled = false } }
    }
    private func announce(_ id: String? = nil) { NotificationCenter.default.post(name:PluginStore.changed,object:id);refresh() }
    private func pause(_ id: String) { NotificationCenter.default.post(name:PluginStore.willChange,object:id) }
    @objc private func installPackage() { choosePackage() }
    private func choosePackage(expectedID: String? = nil) {
        guard !busy,let window else { return }
        let picker = NSOpenPanel();picker.canChooseFiles = true;picker.canChooseDirectories = true;picker.message = L.text("Choose a plugin ZIP or package folder.")
        picker.beginSheetModal(for:window) { [weak self] reply in
            guard let self,reply == .OK,let url = picker.url else { return }
            self.perform("Validating plugin package…",work:{
                let candidate = try self.store.prepare(file:url)
                if let expectedID { guard candidate.package.manifest.id == expectedID else { throw PluginError.invalidPackage } }
                return candidate
            }) { self.review($0) }
        }
    }
    @objc private func installURL() {
        guard !busy,let window else { return }
        let alert = NSAlert();alert.messageText = L.text("Install from URL…");alert.informativeText = L.text("Enter the HTTPS URL of a plugin ZIP. You will review the package before installation.")
        let field = NSTextField(frame:NSRect(x:0,y:0,width:460,height:26));field.placeholderString = "https://example.com/plugin.zip";alert.accessoryView = field
        alert.addButton(withTitle:L.text("Download"));alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] reply in
            guard let self,reply == .alertFirstButtonReturn,let url = URL(string:field.stringValue) else { return }
            self.perform("Downloading plugin…",work:{ try self.store.prepare(url:url) }) { self.review($0) }
        }
    }
    private func review(_ candidate: PluginCandidate) {
        guard let window else { return }
        let manifest = candidate.package.manifest,old = registry.installed.first { $0.id == manifest.id }
        let alert = NSAlert();alert.messageText = L.text(old == nil ? "Install Plugin" : "Replace Plugin")+": "+manifest.name+" "+manifest.version
        let history = old.map { $0.version+" → "+manifest.version+"\n" } ?? ""
        let origin = candidate.downloadURL?.absoluteString ?? L.text("Local package")
        let identity = manifest.id+"\n"+history+origin
        let warning = L.text("Only install plugins you trust. Code runs with your account's access. Enabled plugins load in each workspace and after restart.")
        let permissions = manifest.permissions.isEmpty ? L.text("None") : manifest.permissions.joined(separator:", ")
        let permissionSummary = L.text("Editor permissions")+": "+permissions
        let execution = L.text(manifest.execution == "workspace" ? "Execution: project host, including SSH workspaces" : "Execution: this Mac")
        alert.informativeText = [identity,warning,permissionSummary+"\n"+execution].joined(separator:"\n\n")
        let enable = NSButton(checkboxWithTitle:L.text("Enable now and at startup"),target:nil,action:nil);enable.state = old?.enabled == false ? .off : .on;alert.accessoryView = enable
        alert.addButton(withTitle:L.text("Install Plugin"));alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] reply in
            guard let self,reply == .alertFirstButtonReturn else { return }
            let enabled = enable.state == .on,workspace = self.workspaceOwner?.pluginWorkspace
            self.pause(manifest.id)
            self.perform("Installing plugin…",work:{
                if enabled { try PluginInstallation.checkStartup(candidate.package,workspace:workspace) }
                return try self.store.install(candidate,expectedRevision:old?.revision,enabled:enabled)
            }) { record in self.tabs.selectedSegment = 0;self.sourceField.isHidden = true;self.search.stringValue = "";self.preferredSelection = record.id;self.announce(record.id) }
        }
    }
    @objc private func toggleEnabled() {
        guard let record = selected else { return };pause(record.id)
        let workspace = workspaceOwner?.pluginWorkspace
        perform("Updating plugin state…",work:{
            if !record.enabled { try PluginInstallation.checkStartup(self.store.package(record),workspace:workspace) }
            try self.store.setEnabled(record.id,!record.enabled,expectedRevision:record.revision)
        }) { self.announce(record.id) }
    }
    @objc private func reloadPlugin() { if let id = selected?.id { announce(id) } }
    @objc private func updatePlugin() {
        guard let record = selected else { return }
        if record.sourceID == nil && record.downloadURL == nil { choosePackage(expectedID:record.id);return }
        perform("Checking plugin update…",work:{ try self.store.updateCandidate(record) }) { self.review($0) }
    }
    @objc private func rollbackPlugin() {
        guard let record = selected,let window else { return }
        let alert = NSAlert();alert.messageText = L.text("Roll back to the previous plugin version?");alert.addButton(withTitle:L.text("Roll Back"));alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] reply in
            guard let self,reply == .alertFirstButtonReturn else { return };self.pause(record.id)
            self.perform("Rolling back plugin…",work:{ try self.store.rollback(record.id,expectedRevision:record.revision) }) { self.announce($0.id) }
        }
    }
    @objc private func uninstallPlugin() {
        guard let record = selected,let window else { return }
        let alert = NSAlert();alert.messageText = L.text("Uninstall Plugin")+": "+record.name
        alert.informativeText = L.text("The plugin and its rollback copy will be removed. Project settings and external CLI tools are kept.")
        let clear = NSButton(checkboxWithTitle:L.text("Also remove user settings and local stored state"),target:nil,action:nil);alert.accessoryView = clear
        alert.addButton(withTitle:L.text("Uninstall Plugin"));alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] reply in
            guard let self,reply == .alertFirstButtonReturn else { return };let removeData = clear.state == .on;self.pause(record.id)
            self.perform("Uninstalling plugin…",work:{ try self.store.uninstall(record.id,expectedRevision:record.revision);if removeData { try PluginPersistence().removeLocalData(pluginID:record.id) } }) { self.announce(record.id) }
        }
    }
    @objc private func settings() { if let id = selected?.id,let session = workspaceOwner?.pluginSessions[id] { workspaceOwner?.openPluginSettings(session) } }
    @objc private func logs() { if let id = selected?.id,let session = workspaceOwner?.pluginSessions[id] { workspaceOwner?.showPluginLogs(session) } }
    @objc private func checkUpdates() {
        let sources = registry.sources,installed = registry.installed
        perform("Refreshing plugin sources…",work:{ () -> ([String:PluginCatalog],[String:String],[String]) in
            var values: [String:PluginCatalog] = [:],offers: [String:String] = [:],errors: [String] = []
            for source in sources { do { values[source.id] = try self.store.catalog(source) } catch { errors.append(source.name+": "+error.localizedDescription) } }
            for record in installed {
                if let source = record.sourceID,let entry = values[source]?.plugins.first(where:{ $0.id == record.id }),let next = ReleaseVersion(entry.version),let old = ReleaseVersion(record.version),next > old { offers[record.id] = entry.version }
                else if record.sourceID == nil,record.downloadURL != nil {
                    do { if let version = try self.store.availableUpdate(record) { offers[record.id] = version } } catch { errors.append(record.name+": "+error.localizedDescription) }
                }
            }
            return (values,offers,errors)
        }) { values,offers,errors in self.catalogs = values;self.offers = offers;self.reload();self.status.stringValue = errors.isEmpty ? L.text("Plugin sources refreshed.") : errors.joined(separator:"\n") }
    }
    @objc private func installSelected() {
        guard available.indices.contains(table.selectedRow) else { return };let (source,entry) = available[table.selectedRow]
        perform("Downloading plugin…",work:{ try self.store.prepare(url:entry.url,entry:entry,sourceID:source.id) }) { self.review($0) }
    }
    @objc private func addSource() { saveSource(nil) }
    @objc private func editSource() { if listedSources.indices.contains(table.selectedRow) { saveSource(listedSources[table.selectedRow].id) } }
    private func saveSource(_ id: String?) {
        guard let url = URL(string:sourceField.stringValue),!sourceField.stringValue.isEmpty else { status.stringValue = L.text("Enter an HTTPS source catalog URL.");return }
        perform("Saving plugin source…",work:{ try self.store.saveSource(url:url,id:id) }) { source in self.preferredSelection = source.id;self.catalogs.removeAll();self.announce() }
    }
    @objc private func removeSource() {
        guard listedSources.indices.contains(table.selectedRow) else { return };let id = listedSources[table.selectedRow].id
        perform("Removing plugin source…",work:{ try self.store.removeSource(id) }) { self.catalogs.removeValue(forKey:id);self.announce() }
    }
}
