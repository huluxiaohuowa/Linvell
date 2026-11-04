import AppKit
import LinvellCore

struct GitReference {
    let fullName: String
    var name: String {
        for prefix in ["refs/heads/","refs/remotes/","refs/tags/"] where fullName.hasPrefix(prefix) {
            return String(fullName.dropFirst(prefix.count))
        }
        return fullName
    }
    var category: String {
        if fullName.hasPrefix("refs/tags/") { return "Tags" }
        if fullName.hasPrefix("refs/remotes/") { return "Remote Branches" }
        return "Local Branches"
    }
}

extension GitWorkspace {
    @objc func browseReferences() {
        guard !running else { return }
        var options = [
            PickerOption(title:L.text("Compare References…"),detail:L.text("Compare any two branches or tags")) { [weak self] in self?.compareReferences() },
            operationOption("Create Branch"), operationOption("Create Tag"),
            PickerOption(title:L.text("Fetch Tags"),detail:"") { [weak self] in guard let self else { return }; self.performResult("Fetching tags…",{ try self.repository.fetch(tags:true) }) { _ in } },
            PickerOption(title:L.text("Create & Push Tag…"),detail:"") { [weak self] in self?.createAndPushTag() }
        ]
        options += references.map { reference in
            PickerOption(title:reference.name,detail:L.text(reference.category)) { [weak self] in self?.referenceActions(reference) }
        }
        showGitPicker("Branches and Tags",options)
    }

    private func referenceActions(_ ref: GitReference) {
        var options = [
            PickerOption(title:L.text("Copy Reference Name"),detail:ref.name) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ref.name,forType:.string) },
            operationOption("Compare References",values:["Base":"HEAD","Target":ref.fullName]),
            operationOption("Merge",values:["Revision":ref.fullName]),
            operationOption("Create Branch",values:["Revision":ref.fullName]),
            operationOption("Create Tag",values:["Revision":ref.fullName])
        ]
        if ref.category == "Local Branches" {
            let location: WorkspaceSession = repository.remote.map { .ssh(host:$0.host,path:repository.directory) } ?? .local(path:repository.directory)
            if GitRepositoryOrganization.showsWorktrees(location),let tree = worktrees.first(where:{ $0.branch == ref.name && $0.path != repository.directory && !$0.prunable }) {
                options.insert(PickerOption(title:L.text("Open Worktree"),detail:tree.path) { [weak self] in self?.onOpenWorktree?(tree.path) },at:0)
            } else { options.insert(operationOption("Switch Branch",values:["Branch":ref.name]),at:0) }
            options.append(operationOption("Rename Selected Branch",values:["Branch":ref.name]))
            options.append(operationOption("Delete Merged Branch",values:["Branch":ref.name]))
        } else if ref.category == "Tags" {
            options.insert(operationOption("Checkout Tag",values:["Revision":ref.fullName]),at:0)
            options.append(operationOption("Delete Tag",values:["Name":ref.name]))
        } else {
            options.insert(operationOption("Track Remote Branch",values:["Revision":ref.fullName]),at:0)
            options.append(operationOption("Delete Remote Tracking Branch",values:["Branch":ref.name]))
        }
        showGitPicker(ref.name,options)
    }

    private func compareReferences() {
        guard let window else { return }
        let refs = ["HEAD"]+references.map(\.fullName)
        let selection = GitComparisonSelection(refs:refs)
        let from = selection.from,to = selection.to
        let fields = selection
        let alert = GitNativeSheet.alert(owner:window); alert.messageText = L.text("Compare References…"); alert.accessoryView = fields
        alert.addButton(withTitle:L.text("Compare")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn,let self,
                  !from.stringValue.isEmpty,!to.stringValue.isEmpty else { return }
            self.openComparison(from.stringValue,to.stringValue)
        }
    }

    @objc func browseWorktrees() {
        let location: WorkspaceSession = repository.remote.map { .ssh(host:$0.host,path:repository.directory) } ?? .local(path:repository.directory)
        guard !running,let window,GitRepositoryOrganization.showsWorktrees(location) else { return }
        GitWorktreePanels.manage(repository:repository,owner:window,canRemove:{ [weak self] in self?.onCanRemoveWorktree?($0) != false },
            onOpen:{ [weak self] in self?.onOpenWorktree?($0) },onRelocated:{ [weak self] old,new in
                guard let self else { return }
                let location: WorkspaceSession = self.repository.remote.map { .ssh(host:$0.host,path:old) } ?? .local(path:old)
                if let error = GitRepositoryOrganization.relocate(location,to:new) { let alert = GitNativeSheet.alert(owner:window); alert.messageText = L.text("Worktree Metadata"); alert.informativeText = error; alert.runModal() }; self.onWorktreeRelocated?(old,new); self.reload()
            },onFinish:{ [weak self] in self?.finishWorktree($0) })
    }

    func worktreeOptions(_ entry: GitWorktreeEntry) -> [PickerOption] {
        var options: [PickerOption] = []
        if repository.remote == nil,!entry.prunable {
            options.append(PickerOption(title:L.text("Show in Finder"),detail:entry.path) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:entry.path)]) })
        }
        options.insert(PickerOption(title:L.text("Copy Path"),detail:entry.path) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.path,forType:.string)
        },at:0)
        let active = entry.path == repository.directory
        let isMain = worktrees.first?.path == entry.path
        if !active && !entry.prunable {
            options.append(PickerOption(title:L.text("Open Worktree"),detail:entry.path) { [weak self] in
                guard let self else { return }
                self.onOpenWorktree?(entry.path)
            })
        }
        if !isMain && !entry.prunable {
            if !entry.locked {
                options.append(operationOption("Move Worktree",path:entry.path))
                options.append(operationOption("Remove Clean Worktree",path:entry.path))
                if !entry.branch.isEmpty {
                    options.append(PickerOption(title:L.text("Finish Worktree…"),detail:L.text("Merge into a selected branch and remove the clean worktree")) { [weak self] in self?.finishWorktree(entry) })
                }
            }
            options.append(operationOption(entry.locked ? "Unlock Worktree" : "Lock Worktree",path:entry.path))
        }
        return options
    }

    func operationOption(_ title: String,path: String? = nil,values: [String:String] = [:]) -> PickerOption {
        PickerOption(title:L.text(title),detail:path ?? values.sorted(by:{ $0.key < $1.key }).map(\.value).joined(separator:" · ")) { [weak self] in
            self?.openOperation(title,path:path,values:values)
        }
    }

    func openOperation(_ title: String,path: String? = nil,values: [String:String] = [:]) {
        guard !running else { return }
        if title == "Compare References",let base = values["Base"],let target = values["Target"] {
            openComparison(base,target)
            return
        }
        if title == "Add Worktree" || title == "Add Worktree with New Branch" || title == "Add Detached Worktree" {
            guard let window else { return }; GitWorktreePanels.create(repository:repository,owner:window) { [weak self] path in self?.onOpenWorktree?(path); self?.reload() }; return
        }
        showOperations()
        actionsPage?.selectOperation(title,path:path,values:values)
    }

    func showGitPicker(_ title: String,_ options: [PickerOption]) {
        guard let window else { return }
        gitPicker = QuickPicker(title:L.text(title),options:options,owner:window)
    }
}

extension WorkspaceController {
    private func withGitWorkspace(_ action: (GitWorkspace) -> Void) {
        if gitWorkspaceView == nil || editors.arrangedSubviews.first !== gitWorkspaceView { gitWorkspace() }
        guard let git = gitWorkspaceView,editors.arrangedSubviews.first === git,!git.running else { return }
        action(git)
    }

    @objc func showGitCommitGraph() { withGitWorkspace { $0.showCommitGraph() } }
    @objc func showGitReferences() { withGitWorkspace { $0.browseReferences() } }
    @objc func showGitWorktrees() { withGitWorkspace { $0.browseWorktrees() } }
    @objc func showGitTools() { withGitWorkspace { $0.browseTools() } }
    @objc func reviewRepositoryFiles() { withGitWorkspace { $0.openRepositoryReview() } }
    @objc func reviewGitChanges() { withGitWorkspace { $0.openChangesReview() } }
    @objc func showGitJournal() { withGitWorkspace { $0.openGitJournal() } }
    @objc func fetchGitRepository() { withGitWorkspace { $0.fetchRepository() } }
    @objc func openGitSettings() { withGitWorkspace { $0.showGitSettings() } }
    @objc func jumpToGitHead() { withGitWorkspace { $0.jumpToHead() } }


    @objc func browseGitRepositories() {
        guard let window else { return }
        _ = GitRepositoryBrowserPanel(owner:window,onOpen:{ [weak self] location in
            guard let self else { return }; self.openRecentProject(location)
            switch location {
            case .local(let path): guard self.root?.url.path == path,self.remoteConnection == nil else { return }
            case .ssh(let host,let path): guard self.remoteConnection?.host == host,self.remoteDirectory == path else { return }
            }; self.gitWorkspace()
        },
            onClone:{ [weak self] in self?.cloneGitRepository() },onAdd:{ [weak self] in self?.openFolder() },
            onGroup:{ [weak self] name,selection in self?.editGitGroup(name,locations:GitRepositoryOrganization.locations(),selection:selection) })
    }

    @objc func cloneGitRepositoryFromMenu() { cloneGitRepository() }
    @objc func createGitRepositoryGroup() { editGitGroup(nil,locations:GitRepositoryOrganization.locations()) }

    private func cloneGitRepository() {
        guard let window else { return }
        _ = GitClonePanel(owner:window) { [weak self] destination in self?.setProject(destination); self?.gitWorkspace() }
    }

    func cloneGitRepository(from url: String,into destination: URL,completion: ((Bool) -> Void)? = nil) {
        status.stringValue = L.text("Cloning repository…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let repo = GitRepository(root:destination.deletingLastPathComponent())
            let result = Result { try repo.run(["clone","--",url,destination.path],timeout:600) }
            DispatchQueue.main.async {
                guard let self else { completion?(false); return }
                switch result {
                case .success:
                    self.setProject(destination)
                    let selected = self.root?.url == destination.resolvingSymlinksInPath()
                    if selected { self.gitWorkspace() }
                    completion?(selected)
                case .failure:
                    self.status.stringValue = L.text("Clone failed. Check the repository URL and Git credentials.")
                    completion?(false)
                }
            }
        }
    }
}

extension WorkspaceController {
    func manageGitGroups(_ locations: [WorkspaceSession]) {
        guard let window else { return }
        let defaults = UserDefaults.standard
        let groups = defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String] ?? [:]
        let names = Set(groups.values).union(defaults.stringArray(forKey:"git.repositoryGroupNames") ?? []).sorted()
        let add = PickerOption(title:L.text("New Group…"),detail:"") { [weak self] in self?.editGitGroup(nil,locations:locations) }
        picker = QuickPicker(title:L.text("Manage Groups…"),options:[add]+names.map { name in
            PickerOption(title:name,detail:String(groups.values.filter { $0 == name }.count)) { [weak self] in
                guard let self else { return }
                self.picker = QuickPicker(title:name,options:[
                    PickerOption(title:L.text("Manage Repositories…"),detail:"") { [weak self] in self?.editGitGroup(name,locations:locations) },
                    PickerOption(title:L.text("Dissolve Group"),detail:"") { [weak self] in
                        defaults.set(groups.filter { $0.value != name },forKey:"git.repositoryGroups")
                        defaults.set(names.filter { $0 != name },forKey:"git.repositoryGroupNames")
                        self?.browseGitRepositories()
                    }
                ],owner:window)
            }
        },owner:window)
    }

    private func editGitGroup(_ oldName: String?,locations: [WorkspaceSession],selection: Set<String>? = nil) {
        guard let window else { return }
        let defaults = UserDefaults.standard
        let groups = defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String] ?? [:]
        let selected = selection ?? Set(locations.filter { oldName != nil && groups[$0.repositoryID] == oldName }.map(\.repositoryID))
        let editor = GitRepositoryGroupEditor(name:oldName ?? "",candidates:locations,selected:selected)
        let alert = GitNativeSheet.alert(owner:window); alert.messageText = L.text(oldName == nil ? "New Group…" : "Manage Repositories…")
        alert.accessoryView = editor
        alert.addButton(withTitle:L.text("Save")); alert.addButton(withTitle:L.text("Cancel"))
        editor.onValidationChanged = { [weak editor,weak alert] in alert?.buttons.first?.isEnabled = editor?.canSave == true }
        editor.onValidationChanged?()
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn,editor.canSave else { return }
            let title = editor.name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            var updated = (defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String] ?? [:]).filter { oldName == nil || $0.value != oldName }
            for value in editor.selectedLocations { updated[value.repositoryID] = title }
            var names = Set(defaults.stringArray(forKey:"git.repositoryGroupNames") ?? [])
            if let oldName { names.remove(oldName) }; names.insert(title)
            if let oldName,oldName != title {
                defaults.set((defaults.stringArray(forKey:"git.repositoryRootOrder") ?? []).map { $0 == "group:"+oldName ? "group:"+title : $0 },forKey:"git.repositoryRootOrder")
                defaults.set((defaults.stringArray(forKey:"git.repositoryGroupOrder") ?? []).map { $0 == oldName ? title : $0 },forKey:"git.repositoryGroupOrder")
            }
            defaults.set(Array(names),forKey:"git.repositoryGroupNames")
            defaults.set(updated,forKey:"git.repositoryGroups")
            let saved = defaults.data(forKey:"git.savedRepositories").flatMap { try? JSONDecoder().decode([WorkspaceSession].self,from:$0) } ?? []
            let combined = saved+editor.selectedLocations.filter { !saved.contains($0) }
            if let data = try? JSONEncoder().encode(combined) { defaults.set(data,forKey:"git.savedRepositories") }
            GitRepositoryOrganization.register(combined)
            self?.browseGitRepositories()
        }
    }

}

extension GitWorkspace {
    func createAndPushTag() {
        guard let window else { return }
        let name = NSTextField(string:""),revision = NSTextField(string:"HEAD"),remote = NSTextField(string:"origin")
        let form = NSView(frame:NSRect(x:0,y:0,width:400,height:110))
        Theme.pin(Theme.stack([Theme.stack([Theme.label("Name"),name]),
                               Theme.stack([Theme.label("Revision"),revision]),
                               Theme.stack([Theme.label("Remote"),remote])],orientation:.vertical,spacing:6),in:form)
        let alert = GitNativeSheet.alert(owner:window); alert.messageText = L.text("Create & Push Tag…"); alert.accessoryView = form
        alert.addButton(withTitle:L.text("Create & Push")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] result in
            guard let self,result == .alertFirstButtonReturn else { return }
            let values = (name.stringValue,revision.stringValue,remote.stringValue)
            self.performResult("Creating tag…",{ try self.repository.createAndPushTag(values.0,revision:values.1,remote:values.2) }) { _ in }
        }
    }
}
