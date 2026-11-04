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
            if let tree = worktrees.first(where:{ $0.branch == ref.name && $0.path != repository.directory && !$0.prunable }) {
                options.insert(PickerOption(title:L.text("Open Worktree"),detail:tree.path) { [weak self] in self?.onOpenWorktree?(tree.path) },at:0)
            } else { options.insert(operationOption("Switch Branch",values:["Branch":ref.name]),at:0) }
            options.append(operationOption("Rename Selected Branch",values:["Branch":ref.name]))
            options.append(operationOption("Delete Merged Branch",values:["Branch":ref.name]))
        } else if ref.category == "Tags" {
            options.append(operationOption("Delete Tag",values:["Name":ref.name]))
        } else {
            options.insert(operationOption("Track Remote Branch",values:["Revision":ref.fullName]),at:0)
        }
        showGitPicker(ref.name,options)
    }

    private func compareReferences() {
        guard let window else { return }
        let refs = ["HEAD"]+references.map(\.fullName)
        let selection = GitComparisonSelection(refs:refs)
        let from = selection.from,to = selection.to
        let fields = selection
        let alert = NSAlert(); alert.messageText = L.text("Compare References…"); alert.accessoryView = fields
        alert.addButton(withTitle:L.text("Compare")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] response in
            guard response == .alertFirstButtonReturn,let self,
                  !from.stringValue.isEmpty,!to.stringValue.isEmpty else { return }
            self.openComparison(from.stringValue,to.stringValue)
        }
    }

    @objc func browseWorktrees() {
        guard !running else { return }
        var options = [operationOption("Add Worktree with New Branch"),operationOption("Add Worktree"),operationOption("Prune Worktrees")]
        if repository.remote == nil,let onNewTask {
            options.insert(PickerOption(title:L.text("New Task Workspace…"),detail:L.text("Isolate a task in its own branch and directory"),invoke:onNewTask),at:0)
        }
        options += worktrees.map { entry in
            let label = entry.branch.isEmpty ? L.text("Detached HEAD") : entry.branch
            let state = entry.locked ? " · "+L.text("Locked") : entry.prunable ? " · "+L.text("Prunable") : ""
            return PickerOption(title:label+state,detail:entry.path) { [weak self] in guard let self else { return }
                self.showGitPicker("Worktrees",self.worktreeOptions(entry)) }
        }
        showGitPicker("Worktrees",options)
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
        if !isMain && !active && !entry.prunable {
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
        let defaults = UserDefaults.standard
        let groups = defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String] ?? [:]
        let sortMode = defaults.string(forKey:"git.repositorySort").flatMap(GitRepositorySort.init(rawValue:))
            ?? (defaults.bool(forKey:"git.repositorySortByName") ? .name : .manual)
        let ascending = defaults.object(forKey:"git.repositorySortAscending") as? Bool ?? (sortMode == .name || sortMode == .manual)
        let aliases = defaults.dictionary(forKey:"git.repositoryAliases") as? [String:String] ?? [:]
        let archived = Set(defaults.stringArray(forKey:"git.archivedRepositories") ?? [])
        let order = defaults.stringArray(forKey:"git.repositoryOrder") ?? []
        let savedKey = "git.savedRepositories"
        let saved = defaults.data(forKey:savedKey).flatMap { try? JSONDecoder().decode([WorkspaceSession].self,from:$0) } ?? []
        func save(_ locations: [WorkspaceSession]) {
            GitRepositoryOrganization.register(locations)
            if let encoded = try? JSONEncoder().encode(locations) { defaults.set(encoded,forKey:savedKey) }
        }
        var locations = WorkspaceSession.recent()
        locations += saved.filter { !locations.contains($0) }
        func key(_ location: WorkspaceSession) -> String {
            switch location {
            case .local(let path): return "local:"+path
            case .ssh(let host,let path): return "ssh:"+host+":"+path
            }
        }
        GitRepositoryOrganization.register(locations)
        let dateKey = sortMode == .recentlyAdded ? "git.repositoryAdded" : sortMode == .recentlyModified ? "git.repositoryModified" : "git.repositoryOpened"
        let dates = defaults.dictionary(forKey:dateKey) as? [String:Double] ?? [:]
        locations = GitRepositoryOrganization.sorted(locations,mode:sortMode,ascending:ascending,aliases:aliases,dates:dates,order:order)
        func option(_ location: WorkspaceSession,group: String) -> PickerOption {
            let display = aliases[key(location)] ?? location.title
            return PickerOption(title:group.isEmpty ? display : group+" / "+display,detail:location.path,reorderID:key(location)) { [weak self] in
                guard let self else { return }
                self.openRecentProject(location)
                switch location {
                case .local(let path): guard self.root?.url.path == path,self.remoteConnection == nil else { return }
                case .ssh(let host,let path): guard self.remoteConnection?.host == host,self.remoteDirectory == path else { return }
                }
                self.gitWorkspace()
            }
        }
        var options = [
            PickerOption(title:L.text("Manage Groups…"),detail:"") { [weak self] in self?.manageGitGroups(locations) },
            PickerOption(title:L.text("Clone Repository…"),detail:"") { [weak self] in self?.cloneGitRepository() },
            PickerOption(title:L.text("Open Repository…"),detail:"") { [weak self] in self?.openFolder() },
            PickerOption(title:L.text("Import Repository Folder…"),detail:L.text("Group Git repositories directly inside a folder")) { [weak self] in
                guard let self else { return }
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.beginSheetModal(for:window) { [weak self] result in
                    guard result == .OK,let folder = panel.url,let self else { return }
                    let children = (try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles])) ?? []
                    let repositories = children.filter { FileManager.default.fileExists(atPath:$0.appendingPathComponent(".git").path) }
                    guard !repositories.isEmpty else {
                        self.status.stringValue = L.text("No Git repositories were found directly inside this folder.")
                        return
                    }
                    var updated = groups
                    var imported = saved
                    for repository in repositories {
                        let location = WorkspaceSession.local(path:repository.path)
                        if !imported.contains(location) { imported.append(location) }
                        if updated[key(location)] == nil { updated[key(location)] = folder.lastPathComponent }
                    }
                    save(imported)
                    defaults.set(updated,forKey:"git.repositoryGroups")
                }
            },
            PickerOption(title:L.text("Sort Repositories…"),detail:L.text(sortMode.title)) { [weak self] in
                guard let self else { return }
                self.picker = QuickPicker(title:L.text("Sort Repositories…"),options:GitRepositorySort.allCases.map { mode in
                    PickerOption(title:L.text(mode.title),detail:"") { [weak self] in
                        defaults.set(mode.rawValue,forKey:"git.repositorySort")
                        defaults.set(mode == .name || mode == .manual,forKey:"git.repositorySortAscending")
                        self?.browseGitRepositories()
                    }
                },owner:window)
            },
            PickerOption(title:L.text(ascending ? "Sort Descending" : "Sort Ascending"),detail:"") { [weak self] in
                defaults.set(!ascending,forKey:"git.repositorySortAscending")
                self?.browseGitRepositories()
            }
        ]
        if let current = locations.first(where:{
            switch $0 {
            case .local(let path): return remoteConnection == nil && root?.url.path == path
            case .ssh(let host,let path): return remoteConnection?.host == host && remoteDirectory == path
            }
        }) {
            options.append(PickerOption(title:L.text("Rename Repository Display Name…"),detail:aliases[key(current)] ?? current.title) {
                let alert = NSAlert(); alert.messageText = L.text("Rename Repository Display Name…")
                let name = NSTextField(frame:NSRect(x:0,y:0,width:350,height:24))
                name.stringValue = aliases[key(current)] ?? ""
                alert.accessoryView = name
                alert.addButton(withTitle:L.text("Save")); alert.addButton(withTitle:L.text("Cancel"))
                alert.beginSheetModal(for:window) { response in
                    guard response == .alertFirstButtonReturn else { return }
                    var updated = aliases
                    let value = name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
                    updated[key(current)] = value.isEmpty ? nil : value
                    defaults.set(updated,forKey:"git.repositoryAliases")
                }
            })
            options.append(PickerOption(title:L.text(archived.contains(key(current)) ? "Restore Archived Repository" : "Archive Repository"),detail:current.title) {
                var updated = archived
                if updated.remove(key(current)) == nil {
                    updated.insert(key(current))
                    if !saved.contains(current) { save(saved+[current]) }
                }
                defaults.set(Array(updated),forKey:"git.archivedRepositories")
            })
            options.append(PickerOption(title:L.text(saved.contains(current) ? "Unpin Repository" : "Pin Repository"),detail:current.title) {
                var updated = saved.filter { $0 != current }
                if !saved.contains(current) { updated.append(current) }
                save(updated)
            })
            options.append(PickerOption(title:L.text("Set Repository Group…"),detail:groups[key(current)] ?? current.title) {
                let alert = NSAlert(); alert.messageText = L.text("Set Repository Group…")
                let name = NSTextField(frame:NSRect(x:0,y:0,width:350,height:24))
                name.stringValue = groups[key(current)] ?? ""
                alert.accessoryView = name
                alert.addButton(withTitle:L.text("Save")); alert.addButton(withTitle:L.text("Cancel"))
                alert.beginSheetModal(for:window) { response in
                    guard response == .alertFirstButtonReturn else { return }
                    var updated = defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String] ?? [:]
                    let group = name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
                    updated[key(current)] = group.isEmpty ? nil : group
                    defaults.set(updated,forKey:"git.repositoryGroups")
                }
            })
        }
        let archivedLocations = locations.filter { archived.contains(key($0)) }
        if !archivedLocations.isEmpty {
            options.append(PickerOption(title:L.text("Archived Repositories…"),detail:String(archivedLocations.count)) { [weak self] in
                self?.picker = QuickPicker(title:L.text("Archived Repositories…"),options:archivedLocations.map { option($0,group:groups[key($0)] ?? "") },owner:window)
            })
        }
        options += locations.filter { !archived.contains(key($0)) }.map { option($0,group:groups[key($0)] ?? "") }
        let browser = QuickPicker(title:L.text("Repositories…"),options:options,owner:window)
        browser.rowActions = { option in
            guard let id = option.reorderID,let location = locations.first(where:{ $0.repositoryID == id }) else { return [] }
            return [PickerOption(title:L.text("Copy Path"),detail:location.path) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(location.path,forType:.string)
            }]
        }
        browser.selectionActions = [
            ("Copy Paths",{ ids in
                let paths = locations.filter { ids.contains($0.repositoryID) }.map(\.path)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(paths.joined(separator:"\n"),forType:.string)
            }),
            ("New Group with Selection",{ [weak self] ids in self?.editGitGroup(nil,locations:locations,selection:Set(ids)) }),
            ("Move Selection to Group…",{ [weak self] ids in
                guard let self else { return }
                let names = Set(groups.values).union(defaults.stringArray(forKey:"git.repositoryGroupNames") ?? []).sorted()
                self.picker = QuickPicker(title:L.text("Move Selection to Group…"),options:([""]+names).map { group in
                    PickerOption(title:L.text(group.isEmpty ? "Ungrouped" : group),detail:"") {
                        var updated = defaults.dictionary(forKey:"git.repositoryGroups") as? [String:String] ?? [:]
                        for id in ids { updated[id] = group.isEmpty ? nil : group }
                        defaults.set(updated,forKey:"git.repositoryGroups")
                    }
                },owner:window)
            }),
            ("Archive Selection",{ ids in
                defaults.set(Array(archived.union(ids)),forKey:"git.archivedRepositories")
                save(saved+locations.filter { ids.contains(key($0)) && !saved.contains($0) })
            })
        ]
        browser.onReorder = { ids in
            defaults.set(ids,forKey:"git.repositoryOrder")
            defaults.set(false,forKey:"git.repositorySortByName")
            defaults.set(GitRepositorySort.manual.rawValue,forKey:"git.repositorySort")
        }
        if sortMode == .recentlyModified {
            let refresh = GitRepositoryPickerRefresh(picker:browser,locations:locations,aliases:aliases,ascending:ascending,order:order)
            browser.onDismiss = { refresh.stop() }
            refresh.start()
        }
        picker = browser
    }

    private func cloneGitRepository() {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = L.text("Clone Repository…")
        let address = NSTextField(frame:NSRect(x:0,y:0,width:430,height:24))
        address.placeholderString = L.text("Repository URL")
        alert.accessoryView = address
        alert.addButton(withTitle:L.text("Choose Destination…")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] response in
            let url = address.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn,!url.isEmpty,let self else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "repository"
            panel.beginSheetModal(for:window) { [weak self] response in
                guard response == .OK,let destination = panel.url,let self else { return }
                guard !FileManager.default.fileExists(atPath:destination.path) else {
                    self.status.stringValue = L.text("Choose a new folder for the clone.")
                    return
                }
                self.cloneGitRepository(from:url,into:destination)
            }
        }
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
        let alert = NSAlert(); alert.messageText = L.text(oldName == nil ? "New Group…" : "Manage Repositories…")
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
        let alert = NSAlert(); alert.messageText = L.text("Create & Push Tag…"); alert.accessoryView = form
        alert.addButton(withTitle:L.text("Create & Push")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] result in
            guard let self,result == .alertFirstButtonReturn else { return }
            let values = (name.stringValue,revision.stringValue,remote.stringValue)
            self.performResult("Creating tag…",{ try self.repository.createAndPushTag(values.0,revision:values.1,remote:values.2) }) { _ in }
        }
    }
}
