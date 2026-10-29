import AppKit
import LinvellCore

final class GitSubmoduleView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private(set) var repository: GitRepository
    let table = ResponsiveTableView(),search = NSSearchField()
    let caption = NSTextField(wrappingLabelWithString:"")
    let recursive = NSButton(checkboxWithTitle:L.text("Include nested submodules"),target:nil,action:nil)
    let detail = NSTextField(wrappingLabelWithString:"")
    var modules: [GitSubmodule] = [],filtered: [GitSubmodule] = []
    var onOpenRepository: ((GitRepository) -> Void)?
    var onChange: (() -> Void)?
    var onBusyChange: ((Bool) -> Void)?
    var onMore: ((String?) -> Void)?
    private var controls: [NSControl] = []
    private var busy = false,generation = UUID()
    private var updateButton: NSButton!,openButton: NSButton!
    var selected: GitSubmodule? { filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow] : nil }
    init(repository: GitRepository) {
        self.repository = repository; super.init(frame:.zero)
        search.placeholderString = L.text("Filter submodules"); search.delegate = self
        recursive.state = .on; caption.font = .systemFont(ofSize:12); caption.textColor = Theme.secondary
        detail.font = .monospacedSystemFont(ofSize:12,weight:.regular); detail.textColor = Theme.secondary; detail.maximumNumberOfLines = 5
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("submodule")); table.addTableColumn(column); table.headerView = nil
        table.rowHeight = 65; table.backgroundColor = Theme.panel; table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(openRepository); table.setAccessibilityLabel(L.text("Git submodules"))
        let scroll = ResponsiveScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        updateButton = button("Initialize / Update",#selector(updateSelected)); openButton = button("Open Repository",#selector(openRepository))
        let first = Theme.stack([button("Add Submodule…",#selector(addModule)),button("Refresh",#selector(reload)),NSView()],spacing:8)
        let all = Theme.stack([button("Initialize / Update All",#selector(updateAll)),button("More Operations…",#selector(moreOperations)),NSView()],spacing:8)
        let actions = Theme.stack([updateButton,button("Sync URLs",#selector(syncSelected)),NSView()],spacing:8)
        let reference = Theme.stack([button("Stage Reference",#selector(stageReference)),openButton,NSView()],spacing:8)
        let advanced = Theme.stack([button("Tracking Branch…",#selector(changeBranch)),button("Change URL…",#selector(changeURL)),NSView()],spacing:8)
        let removal = Theme.stack([button("Update to Branch Tip…",#selector(updateRemote)),button("Remove…",#selector(removeSelected)),NSView()],spacing:8)
        let help = NSTextField(wrappingLabelWithString:L.text("Update checks out the commit recorded by the parent repository. Stage Reference records a changed submodule commit; commit it in the parent repository. Local changes are never force-discarded.")); help.font = .systemFont(ofSize:12); help.textColor = Theme.secondary
        let outer = ResponsiveScrollView(); outer.hasVerticalScroller = true; outer.drawsBackground = false
        let document = SubmoduleDocument(); document.translatesAutoresizingMaskIntoConstraints = false; outer.documentView = document
        Theme.pin(outer,in:self)
        scroll.heightAnchor.constraint(equalToConstant:260).isActive = true
        Theme.pin(Theme.stack([first,all,search,recursive,scroll,detail,actions,reference,advanced,removal,help,caption],orientation:.vertical,spacing:10),in:document)
        document.widthAnchor.constraint(equalTo:outer.contentView.widthAnchor).isActive = true
        document.heightAnchor.constraint(greaterThanOrEqualTo:outer.contentView.heightAnchor).isActive = true
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func button(_ title: String,_ selector: Selector) -> NSButton { let button = Theme.actionButton(title,target:self,action:selector); controls.append(button); return button }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("submodule-row"),module = filtered[row]
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier:id,owner:nil) as? NSTableCellView { cell = reused }
        else {
            cell = NSTableCellView(); cell.identifier = id
            let label = NSTextField(wrappingLabelWithString:""); label.maximumNumberOfLines = 3; label.font = .systemFont(ofSize:12); cell.textField = label; Theme.pin(label,in:cell,inset:8)
        }
        cell.textField?.stringValue = module.path+"  ·  "+L.text(module.state)+"\n"+(module.currentBranch.isEmpty ? L.text("Detached HEAD") : module.currentBranch)+"  "+String(module.currentCommit.prefix(10))+"\n"+module.url
        cell.textField?.textColor = module.conflicted || module.dirty ? .systemOrange : Theme.foreground; return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    func controlTextDidChange(_ notification: Notification) { filter() }
    private func filter() {
        let path = selected?.path,query = search.stringValue
        filtered = modules.filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if let row = filtered.firstIndex(where:{ $0.path == path }) ?? (filtered.isEmpty ? nil : 0) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
        updateSelection()
    }
    private func updateSelection() {
        updateButton.isEnabled = !busy && selected != nil; openButton.isEnabled = !busy && selected?.initialized == true
        guard let module = selected else { detail.stringValue = L.text("Select a submodule to manage it."); return }
        detail.stringValue = module.path+"\n"+L.text(module.state)+"\n"+L.text("Recorded commit")+": "+module.recordedCommit+"\n"+L.text("Current commit")+": "+module.currentCommit
    }
    @objc func reload() {
        guard !busy else { return }; let request = UUID(); generation = request; caption.stringValue = L.text("Reading submodules…")
        let repo = repository
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            guard let self else { return }; let result = Result { () throws -> (GitRepository,[GitSubmodule]) in let resolved = try repo.resolvedWorkingTree(); return (resolved,try resolved.submodules()) }
            DispatchQueue.main.async {
                guard self.generation == request else { return }
                switch result {
                case .success(let (resolved,modules)): self.repository = resolved; self.modules = modules; self.filter(); self.caption.stringValue = modules.isEmpty ? L.text("No submodules yet. Add a repository to get started.") : L.format("%d submodules",modules.count)
                case .failure(let error): self.caption.stringValue = String(error.localizedDescription.suffix(4000))
                }
            }
        }
    }
    private func perform(_ work: @escaping () throws -> Void) {
        guard !busy else { return }; busy = true; onBusyChange?(true); controls.forEach { $0.isEnabled = false }; search.isEnabled = false; recursive.isEnabled = false
        caption.stringValue = L.text("Updating submodules…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false; self.onBusyChange?(false); self.controls.forEach { $0.isEnabled = true }; self.search.isEnabled = true; self.recursive.isEnabled = true; self.updateSelection()
                switch result { case .success: self.reload(); self.onChange?(); case .failure(let error): self.caption.stringValue = String(error.localizedDescription.suffix(4000)) }
            }
        }
    }
    @objc func updateSelected() { guard let path = selected?.path else { return }; let repo = repository,nested = recursive.state == .on; perform { try repo.updateSubmodules(path:path,recursive:nested) } }
    @objc func moreOperations() { onMore?(selected?.path) }
    @objc func updateAll() { let repo = repository,nested = recursive.state == .on; perform { try repo.updateSubmodules(recursive:nested) } }
    @objc func syncSelected() { let repo = repository,path = selected?.path,nested = recursive.state == .on; perform { try repo.syncSubmodules(path:path,recursive:nested) } }
    @objc func stageReference() { guard let path = selected?.path else { return }; let repo = repository; perform { try repo.stageSubmodule(path:path) } }
    @objc func openRepository() { guard let module = selected,module.initialized,let child = try? repository.childRepository(module.path) else { return }; onOpenRepository?(child) }
    @objc func changeBranch() { guard let module = selected else { return }; input(title:"Tracking Branch",value:module.trackingBranch) { [weak self] value in guard let self else { return }; let repo = self.repository; self.perform { try repo.setSubmoduleBranch(path:module.path,branch:value) } } }
    @objc func changeURL() { guard let module = selected else { return }; input(title:"Submodule URL",value:module.url) { [weak self] value in guard let self else { return }; let repo = self.repository; self.perform { try repo.setSubmoduleURL(path:module.path,url:value) } } }
    @objc func updateRemote() {
        guard let module = selected else { return }
        confirm(title:"Update to Branch Tip",text:"This fetches the configured branch and changes the submodule commit. Review and stage the new reference in the parent repository.") { [weak self] in guard let self else { return }; let repo = self.repository,nested = self.recursive.state == .on; self.perform { try repo.updateSubmodules(path:module.path,recursive:nested,remoteTip:true) } }
    }
    @objc func removeSelected() {
        guard let module = selected else { return }
        confirm(title:"Remove Submodule",text:"The clean checkout will be removed and the removal staged in the parent repository. Git object history is retained. Modified, conflicted or unrecorded commits block removal.") { [weak self] in guard let self else { return }; let repo = self.repository; self.perform { try repo.removeSubmodule(path:module.path) } }
    }
    @objc func addModule() {
        guard let window else { return }; let alert = NSAlert(); alert.messageText = L.text("Add Submodule")
        let url = NSTextField(),path = NSTextField(),branch = NSTextField(); url.placeholderString = "https://… / git@…"; path.placeholderString = "vendor/library"; branch.placeholderString = L.text("Default branch")
        let stack = Theme.stack([Theme.label("Repository URL",size:12),url,Theme.label("Folder inside this repository",size:12),path,Theme.label("Branch (optional)",size:12),branch],orientation:.vertical,spacing:8)
        stack.frame = NSRect(x:0,y:0,width:460,height:180); alert.accessoryView = stack
        alert.addButton(withTitle:L.text("Add")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] response in guard let self,response == .alertFirstButtonReturn else { return }; let repo = self.repository,u = url.stringValue,p = path.stringValue,b = branch.stringValue; self.perform { try repo.addSubmodule(url:u,path:p,branch:b) } }
    }
    private func input(title: String,value: String,accept: @escaping (String) -> Void) {
        guard let window else { return }; let alert = NSAlert(); alert.messageText = L.text(title)
        let field = NSTextField(frame:NSRect(x:0,y:0,width:440,height:28)); field.stringValue = value; alert.accessoryView = field
        alert.addButton(withTitle:L.text("Apply")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { response in if response == .alertFirstButtonReturn { accept(field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)) } }
    }
    private func confirm(title: String,text: String,accept: @escaping () -> Void) {
        guard let window else { return }; let alert = NSAlert(); alert.messageText = L.text(title); alert.informativeText = L.text(text)
        alert.addButton(withTitle:L.text("Continue")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { response in if response == .alertFirstButtonReturn { accept() } }
    }
}

private final class SubmoduleDocument: NSView { override var isFlipped: Bool { true } }
