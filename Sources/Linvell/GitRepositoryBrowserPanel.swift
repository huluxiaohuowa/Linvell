import AppKit
import LinvellCore

final class GitRepositoryOutlineView: NSOutlineView {
    var onOpen: (() -> Void)?,onRemove: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onOpen?(); return }
        if event.keyCode == 51 || event.keyCode == 117 { onRemove?(); return }
        super.keyDown(with:event)
    }
}

/// Hierarchical repository organization adapted from FoldGit (dufu, MIT).
final class GitRepositoryBrowserPanel: GitNativeSheet, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    final class Node: NSObject {
        let id: String,title: String,location: WorkspaceSession?
        var children: [Node]
        init(id: String,title: String,location: WorkspaceSession? = nil,children: [Node] = []) { self.id = id; self.title = title; self.location = location; self.children = children }
    }
    let search = NSSearchField(),outline = GitRepositoryOutlineView(),sort = NSPopUpButton()
    let onOpen: (WorkspaceSession) -> Void,onClone: () -> Void,onAdd: () -> Void,onGroup: (String?,Set<String>?) -> Void
    private var nodes: [Node] = [],worktreeSearch: [String:String] = [:],timer: Timer?
    private let defaults = UserDefaults.standard,dragType = NSPasteboard.PasteboardType("Linvell.RepositoryBrowser")
    private var loadingStates = false
    init(owner: NSWindow,onOpen: @escaping (WorkspaceSession) -> Void,onClone: @escaping () -> Void,onAdd: @escaping () -> Void,onGroup: @escaping (String?,Set<String>?) -> Void) {
        self.onOpen = onOpen; self.onClone = onClone; self.onAdd = onAdd; self.onGroup = onGroup
        super.init(title:"Repositories",owner:owner,width:780)
        search.placeholderString = L.text("Search repositories, groups and worktrees"); search.delegate = self
        search.widthAnchor.constraint(equalToConstant:730).isActive = true; body.addArrangedSubview(search)
        sort.addItems(withTitles:GitRepositorySort.allCases.map { L.text($0.title) }); sort.selectItem(at:GitRepositorySort.allCases.firstIndex(of:currentSort) ?? 0); sort.target = self; sort.action = #selector(changeSort)
        body.addArrangedSubview(Theme.stack([sort,button("Reverse Sort Direction",#selector(reverseSort))]))
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("repository")); column.width = 720; outline.addTableColumn(column); outline.outlineTableColumn = column; outline.headerView = nil; outline.rowHeight = 34
        outline.dataSource = self; outline.delegate = self; outline.onOpen = { [weak self] in self?.openSelected() }; outline.onRemove = { [weak self] in self?.removeRepositories() }; outline.allowsMultipleSelection = true; outline.target = self; outline.doubleAction = #selector(openSelected)
        let menu = NSMenu(); menu.delegate = self; outline.menu = menu; outline.registerForDraggedTypes([dragType]); outline.setDraggingSourceOperationMask(.move,forLocal:true)
        let scroll = NSScrollView(); scroll.documentView = outline; scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(equalToConstant:340).isActive = true; scroll.widthAnchor.constraint(equalToConstant:730).isActive = true; body.addArrangedSubview(scroll)
        for (title,action) in [("Open Repository…",#selector(add)),("Clone…",#selector(clone)),("New Group…",#selector(newGroup)),("Import Folder…",#selector(importFolder))] { footer.addArrangedSubview(button(title,action)) }
        reload(); refreshStates()
        timer = Timer.scheduledTimer(withTimeInterval:20,repeats:true) { [weak self] _ in self?.refreshStates() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    override func closeSheet() { timer?.invalidate(); timer = nil; super.closeSheet() }
    var currentSort: GitRepositorySort { defaults.string(forKey:"git.repositorySort").flatMap(GitRepositorySort.init(rawValue:)) ?? .manual }
    @objc func changeSort() { defaults.set(GitRepositorySort.allCases[max(0,sort.indexOfSelectedItem)].rawValue,forKey:"git.repositorySort"); reload() }
    @objc func reverseSort() { defaults.set(!defaults.bool(forKey:"git.repositorySortAscending"),forKey:"git.repositorySortAscending"); reload() }
    func controlTextDidChange(_ notification: Notification) { reload() }
    func reload() {
        let locations = GitRepositoryOrganization.locations(); GitRepositoryOrganization.register(locations)
        let groups = defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String] ?? [:],aliases = defaults.dictionary(forKey:"git.repositoryAliases") as? [String:String] ?? [:]
        let archived = Set(defaults.stringArray(forKey:"git.archivedRepositories") ?? []),query = search.stringValue
        let dateKey = currentSort == .recentlyAdded ? "git.repositoryAdded" : currentSort == .recentlyModified ? "git.repositoryModified" : "git.repositoryOpened"
        let dates = defaults.dictionary(forKey:dateKey) as? [String:Double] ?? [:],ascending = defaults.object(forKey:"git.repositorySortAscending") as? Bool ?? true
        let ordered = GitRepositoryOrganization.sorted(locations,mode:currentSort,ascending:ascending,aliases:aliases,dates:dates,order:defaults.stringArray(forKey:"git.repositoryOrder") ?? [])
        let names = Set(groups.values).union(defaults.stringArray(forKey:"git.repositoryGroupNames") ?? [])
        func children(_ values: [WorkspaceSession]) -> [Node] { values.filter { query.isEmpty || ((aliases[$0.repositoryID] ?? $0.title)+" "+$0.path+" "+(groups[$0.repositoryID] ?? "")+" "+(worktreeSearch[$0.repositoryID] ?? "")).localizedStandardContains(query) }.map { Node(id:$0.repositoryID,title:aliases[$0.repositoryID] ?? $0.title,location:$0) } }
        var result = names.map { name -> Node in
            let values = ordered.filter { groups[$0.repositoryID] == name },active = children(values.filter { !archived.contains($0.repositoryID) }),inactive = children(values.filter { archived.contains($0.repositoryID) })
            return Node(id:"group:"+name,title:name,children:active+(inactive.isEmpty ? [] : [Node(id:"inactive:"+name,title:L.text("Inactive"),children:inactive)]))
        }.filter { query.isEmpty || !$0.children.isEmpty || $0.title.localizedStandardContains(query) }
        let ranks = defaults.stringArray(forKey:"git.repositoryGroupOrder") ?? []
        result.sort { left,right in
            if currentSort == .manual { return (ranks.firstIndex(of:left.title) ?? Int.max,left.title) < (ranks.firstIndex(of:right.title) ?? Int.max,right.title) }
            if currentSort == .name { return ascending ? left.title.localizedStandardCompare(right.title) == .orderedAscending : left.title.localizedStandardCompare(right.title) == .orderedDescending }
            func newest(_ node: Node) -> Double { ordered.filter { groups[$0.repositoryID] == node.title }.compactMap { dates[$0.repositoryID] }.max() ?? 0 }
            return ascending ? newest(left) < newest(right) : newest(left) > newest(right)
        }
        let ungrouped = ordered.filter { groups[$0.repositoryID] == nil }
        result += children(ungrouped.filter { !archived.contains($0.repositoryID) })
        let inactive = children(ungrouped.filter { archived.contains($0.repositoryID) }); if !inactive.isEmpty { result.append(Node(id:"inactive:",title:L.text("Inactive"),children:inactive)) }
        if currentSort == .manual {
            let rootOrder = defaults.stringArray(forKey:"git.repositoryRootOrder") ?? []
            let ranks = Dictionary(rootOrder.enumerated().map { ($0.element,$0.offset) },uniquingKeysWith:min)
            result = result.enumerated().sorted { (ranks[$0.element.id] ?? (rootOrder.count+$0.offset)) < (ranks[$1.element.id] ?? (rootOrder.count+$1.offset)) }.map(\.element)
        }
        nodes = result; outline.reloadData(); fit()
        let collapsed = Set(defaults.stringArray(forKey:"git.repositoryCollapsedGroups") ?? [])
        for node in nodes where node.location == nil { if !query.isEmpty || !collapsed.contains(node.id) { outline.expandItem(node) }; for child in node.children where child.location == nil && (!query.isEmpty || !collapsed.contains(child.id)) { outline.expandItem(child) } }
    }
    func outlineView(_ outlineView: NSOutlineView,numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? nodes.count }
    func outlineView(_ outlineView: NSOutlineView,child index: Int,ofItem item: Any?) -> Any { ((item as? Node)?.children ?? nodes)[index] }
    func outlineView(_ outlineView: NSOutlineView,isItemExpandable item: Any) -> Bool { (item as? Node)?.location == nil }
    func outlineView(_ outlineView: NSOutlineView,viewFor tableColumn: NSTableColumn?,item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let error = node.location.flatMap { defaults.string(forKey:GitAutoFetchScheduler.key($0)+".error") }
        let label = Theme.label((error == nil ? "" : "⚠ ")+node.title,size:13); label.toolTip = node.location.map { $0.path+(error.map { "\n"+$0 } ?? "") } ?? node.title; return label
    }
    func outlineViewItemDidCollapse(_ notification: Notification) { storeExpansion(notification,false) }
    func outlineViewItemDidExpand(_ notification: Notification) { storeExpansion(notification,true) }
    private func storeExpansion(_ notification: Notification,_ expanded: Bool) { guard search.stringValue.isEmpty,let node = notification.userInfo?["NSObject"] as? Node else { return }; var values = Set(defaults.stringArray(forKey:"git.repositoryCollapsedGroups") ?? []); if expanded { values.remove(node.id) } else { values.insert(node.id) }; defaults.set(Array(values),forKey:"git.repositoryCollapsedGroups") }
    private var selected: [Node] { outline.selectedRowIndexes.compactMap { outline.item(atRow:$0) as? Node } }
    @objc func openSelected() { guard let node = selected.first,let location = node.location else { return }; closeSheet(); onOpen(location) }
    @objc func add() { closeSheet(); onAdd() }
    @objc func clone() { closeSheet(); onClone() }
    @objc func newGroup() { closeSheet(); onGroup(nil,Set(selected.compactMap { $0.location?.repositoryID })) }
    @objc func importFolder() {
        guard let window else { return }; let panel = NSOpenPanel(); panel.appearance = window.effectiveAppearance; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.beginSheetModal(for:window) { [self] response in guard response == .OK else { return }; let urls = panel.urls
            run("Discovering repositories…",{ try GitRepositoryGroupEditor.discovered(urls) }) { [self] found in
                guard !found.isEmpty else { message.stringValue = L.text("No Git repositories were found directly inside this folder."); return }
                let existing = GitRepositoryOrganization.locations(),editor = GitRepositoryGroupEditor(name:urls.first?.lastPathComponent ?? "",candidates:existing+found.filter { !existing.contains($0) },selected:Set(found.map(\.repositoryID)))
                let alert = GitNativeSheet.alert(owner:window); alert.messageText = L.text("Import Repository Folder"); alert.accessoryView = editor; alert.addButton(withTitle:L.text("Import")); alert.addButton(withTitle:L.text("Cancel"))
                editor.onValidationChanged = { [weak editor,weak alert] in alert?.buttons.first?.isEnabled = editor?.canSave == true }; editor.onValidationChanged?()
                alert.beginSheetModal(for:window) { [self] result in guard result == .alertFirstButtonReturn,editor.canSave else { return }
                    let name = editor.name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),selection = editor.selectedLocations
                    var groups = defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String] ?? [:]; for location in selection { groups[location.repositoryID] = name }; defaults.set(groups,forKey:"git.repositoryGroups")
                    var names = Set(defaults.stringArray(forKey:"git.repositoryGroupNames") ?? []); names.insert(name); defaults.set(Array(names),forKey:"git.repositoryGroupNames")
                    GitRepositoryOrganization.persist(existing+selection.filter { !existing.contains($0) }); reload(); refreshStates()
                }
            }
        }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if outline.clickedRow >= 0,!outline.selectedRowIndexes.contains(outline.clickedRow) { outline.selectRowIndexes(IndexSet(integer:outline.clickedRow),byExtendingSelection:false) }
        let values = selected
        func add(_ title: String,_ selector: Selector,_ object: Any? = nil) { let item = NSMenuItem(title:L.text(title),action:selector,keyEquivalent:""); item.target = self; item.representedObject = object; menu.addItem(item) }
        guard let first = values.first else { return }
        if first.location == nil,first.id.hasPrefix("group:") { add("Rename Group / Manage Repositories…",#selector(editGroup)); add("Dissolve Group",#selector(dissolveGroup)); return }
        guard values.contains(where:{ $0.location != nil }) else { return }
        add("Open",#selector(openSelected)); add("Copy Paths",#selector(copyPaths)); add("Rename Repository…",#selector(renameRepository)); add("New Group with Selection",#selector(newGroup))
        let groups = NSMenu(); for name in [""]+Set((defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String] ?? [:]).values).union(defaults.stringArray(forKey:"git.repositoryGroupNames") ?? []).sorted() { let item = NSMenuItem(title:name.isEmpty ? L.text("Ungrouped") : name,action:#selector(moveGroup(_:)),keyEquivalent:""); item.target = self; item.representedObject = name; groups.addItem(item) }; let move = NSMenuItem(title:L.text("Move to Group"),action:nil,keyEquivalent:""); move.submenu = groups; menu.addItem(move)
        add("Mark as Inactive",#selector(archive)); add("Mark as Active",#selector(restore)); add("Remove from List",#selector(removeRepositories)); add("Automatic Fetch…",#selector(fetchSettings)); add("Retry Fetch",#selector(retryFetch)); add("Enable Worktrees",#selector(toggleWorktrees))
    }
    @objc func copyPaths() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selected.compactMap { $0.location?.path }.joined(separator:"\n"),forType:.string) }
    @objc func archive() { setArchived(true) }; @objc func restore() { setArchived(false) }
    func setArchived(_ enabled: Bool) { let ids = Set(selected.compactMap { $0.location?.repositoryID }); var values = Set(defaults.stringArray(forKey:"git.archivedRepositories") ?? []); if enabled { values.formUnion(ids) } else { values.subtract(ids) }; GitRepositoryOrganization.persist(GitRepositoryOrganization.locations()); defaults.set(Array(values),forKey:"git.archivedRepositories"); reload() }
    @objc func removeRepositories() { GitRepositoryOrganization.remove(Set(selected.compactMap { $0.location?.repositoryID })); reload() }
    @objc func renameRepository() { guard let node = selected.first,let location = node.location,let window else { return }; let alert = GitNativeSheet.alert(owner:window); alert.messageText = L.text("Rename Repository"); let field = NSTextField(string:node.title); field.frame.size = NSSize(width:400,height:24); alert.accessoryView = field; alert.addButton(withTitle:L.text("Save")); alert.addButton(withTitle:L.text("Cancel")); alert.beginSheetModal(for:window) { [self] response in guard response == .alertFirstButtonReturn else { return }; var values = defaults.dictionary(forKey:"git.repositoryAliases") as? [String:String] ?? [:]; let value = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines); values[location.repositoryID] = value.isEmpty ? nil : value; defaults.set(values,forKey:"git.repositoryAliases"); reload() } }
    @objc func moveGroup(_ sender: NSMenuItem) { guard let name = sender.representedObject as? String else { return }; var groups = defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String] ?? [:]; for node in selected { if let location = node.location { groups[location.repositoryID] = name.isEmpty ? nil : name } }; defaults.set(groups,forKey:"git.repositoryGroups"); GitRepositoryOrganization.persist(GitRepositoryOrganization.locations()); reload() }
    @objc func editGroup() { guard let node = selected.first else { return }; closeSheet(); onGroup(node.title,nil) }
    @objc func dissolveGroup() { guard let node = selected.first else { return }; defaults.set((defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String] ?? [:]).filter { $0.value != node.title },forKey:"git.repositoryGroups"); defaults.set((defaults.stringArray(forKey:"git.repositoryGroupNames") ?? []).filter { $0 != node.title },forKey:"git.repositoryGroupNames"); reload() }
    @objc func fetchSettings() { guard let window else { return }; GitRepositorySettingsPanel.show(owner:window) }
    @objc func retryFetch() { for location in selected.compactMap(\.location) { GitAutoFetchScheduler.shared.fetchNow(location) }; reload() }
    @objc func toggleWorktrees() { let locations = selected.compactMap(\.location); let enabled = !locations.allSatisfy { GitRepositoryOrganization.showsWorktrees($0) }; for location in locations { GitRepositoryOrganization.setWorktreesEnabled(enabled,for:location) }; reload() }
    func outlineView(_ outlineView: NSOutlineView,pasteboardWriterForItem item: Any) -> NSPasteboardWriting? { guard currentSort == .manual,search.stringValue.isEmpty,let node = item as? Node else { return nil }; let writer = NSPasteboardItem(); writer.setString(node.id,forType:dragType); return writer }
    func outlineView(_ outlineView: NSOutlineView,validateDrop info: NSDraggingInfo,proposedItem item: Any?,proposedChildIndex index: Int) -> NSDragOperation { guard currentSort == .manual,search.stringValue.isEmpty,info.draggingSource as? NSOutlineView === outline,index >= 0 else { return [] }; return .move }
    func outlineView(_ outlineView: NSOutlineView,acceptDrop info: NSDraggingInfo,item: Any?,childIndex index: Int) -> Bool {
        guard let id = info.draggingPasteboard.string(forType:dragType) else { return false }
        if item == nil {
            if !id.hasPrefix("group:") {
                guard GitRepositoryOrganization.locations().contains(where:{ $0.repositoryID == id }) else { return false }
                var groups = defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String] ?? [:]; groups.removeValue(forKey:id); defaults.set(groups,forKey:"git.repositoryGroups")
            }
            let original = nodes.filter { !$0.id.hasPrefix("inactive:") }.map(\.id)
            let destination = max(0,index-((original.firstIndex(of:id).map { $0 < index ? 1 : 0 }) ?? 0))
            var roots = original.filter { $0 != id }
            roots.insert(id,at:min(destination,roots.count)); defaults.set(roots,forKey:"git.repositoryRootOrder")
        } else {
            guard let parent = item as? Node,parent.id.hasPrefix("group:"),let location = GitRepositoryOrganization.locations().first(where:{ $0.repositoryID == id }) else { return false }
            var groups = defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String] ?? [:]; groups[id] = parent.title; defaults.set(groups,forKey:"git.repositoryGroups")
            let original = parent.children.compactMap { $0.location?.repositoryID }
            let destination = max(0,index-((original.firstIndex(of:id).map { $0 < index ? 1 : 0 }) ?? 0))
            var ordered = original.filter { $0 != id }; ordered.insert(location.repositoryID,at:min(destination,ordered.count))
            var all = defaults.stringArray(forKey:"git.repositoryOrder") ?? GitRepositoryOrganization.locations().map(\.repositoryID); all.removeAll { ordered.contains($0) }; all += ordered; defaults.set(all,forKey:"git.repositoryOrder")
        }
        GitRepositoryOrganization.persist(GitRepositoryOrganization.locations())
        reload(); return true
    }
    func refreshStates() {
        guard !loadingStates else { return }; loadingStates = true; let locations = GitRepositoryOrganization.locations()
        DispatchQueue.global(qos:.utility).async { [weak self] in
            var search: [String:String] = [:],modified: [String:Double] = [:],families: [(WorkspaceSession,[GitWorktreeEntry])] = []
            for location in locations { guard let repo = try? GitRepositoryOrganization.repository(location) else { continue }; if let trees = try? repo.worktrees() { families.append((location,trees)); search[location.repositoryID] = trees.map { $0.path+" "+$0.branch }.joined(separator:" ") }; modified[location.repositoryID] = (try? repo.modificationDate())?.timeIntervalSince1970 }
            DispatchQueue.main.async { guard let self else { return }; self.loadingStates = false; for (location,trees) in families { GitRepositoryOrganization.registerWorktreeFamily(trees,location:location) }; self.worktreeSearch = search; self.defaults.set(modified,forKey:"git.repositoryModified"); self.reload() }
        }
    }
}
