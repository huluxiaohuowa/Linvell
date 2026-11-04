import AppKit

/// Repository-wide settings management adapted from FoldGit (dufu, MIT).
final class GitRepositorySettingsPanel: GitNativeSheet {
    let defaults = UserDefaults.standard
    let enable = NSButton(checkboxWithTitle:L.text("Enable Worktrees"),target:nil,action:nil),status = NSButton(checkboxWithTitle:L.text("Show Worktree Status in Sidebar"),target:nil,action:nil),autoFetch = NSButton(checkboxWithTitle:L.text("Auto Fetch by Default"),target:nil,action:nil)
    let interval = NSTextField(),list = NSStackView()
    private var timer: Timer?
    static func show(owner: NSWindow) { _ = GitRepositorySettingsPanel(owner:owner) }
    init(owner: NSWindow) {
        super.init(title:"Repository Settings",owner:owner,width:760)
        enable.state = defaults.object(forKey:"git.enableWorktrees") as? Bool == false ? .off : .on
        status.state = defaults.object(forKey:"git.showWorktreeStatus") as? Bool == false ? .off : .on
        autoFetch.state = defaults.bool(forKey:"git.defaultAutoFetch") ? .on : .off
        interval.stringValue = String(defaults.object(forKey:"git.defaultFetchMinutes") as? Int ?? 5)
        for button in [enable,status,autoFetch] { button.target = self; button.action = #selector(saveGlobal); body.addArrangedSubview(button) }; row("Default interval in minutes",interval)
        body.addArrangedSubview(button("Save Default Interval",#selector(saveGlobal)))
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 10
        let scroll = NSScrollView(); installDocumentStack(list,in:scroll); scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(equalToConstant:300).isActive = true; scroll.widthAnchor.constraint(equalToConstant:710).isActive = true; body.addArrangedSubview(scroll)
        footer.addArrangedSubview(button("Restore Git Defaults…",#selector(reset))); render()
        timer = Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in self?.render() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    override func closeSheet() { timer?.invalidate(); super.closeSheet() }
    @objc func saveGlobal() { defaults.set(enable.state == .on,forKey:"git.enableWorktrees"); defaults.set(status.state == .on,forKey:"git.showWorktreeStatus"); defaults.set(autoFetch.state == .on,forKey:"git.defaultAutoFetch"); defaults.set(min(1440,max(1,interval.integerValue)),forKey:"git.defaultFetchMinutes"); render() }
    private var locations: [WorkspaceSession] { GitRepositoryOrganization.locations() }
    func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index,location) in locations.enumerated() {
            let key = GitAutoFetchScheduler.key(location),row = NSStackView(); row.spacing = 8
            let choice = NSPopUpButton(); choice.addItems(withTitles:[L.text("Use Default"),L.text("Off")]+[1,5,15,30,60].map { L.format("%d min",$0) }+[L.text("Custom…")])
            if let enabled = defaults.object(forKey:key) as? Bool {
                let minutes = defaults.object(forKey:key+".minutes") as? Int ?? defaults.object(forKey:"git.defaultFetchMinutes") as? Int ?? 5
                choice.selectItem(at:enabled ? ([1,5,15,30,60].firstIndex(of:minutes).map { $0+2 } ?? 7) : 1)
                if enabled,choice.indexOfSelectedItem == 7 { choice.item(at:7)?.title = L.format("%d min",minutes)+" · "+L.text("Custom…") }
            }
            choice.target = self; choice.action = #selector(changeInterval(_:)); choice.tag = index
            let label = Theme.label(location.title,size:12); label.toolTip = location.path; row.addArrangedSubview(label); row.addArrangedSubview(choice)
            let fetch = button("Fetch Now",#selector(fetch(_:))); fetch.tag = index; fetch.isEnabled = !GitAutoFetchScheduler.shared.running.contains(key); row.addArrangedSubview(fetch)
            let worktrees = NSButton(checkboxWithTitle:L.text("Worktrees"),target:self,action:#selector(changeWorktrees(_:))); worktrees.tag = index; worktrees.state = GitRepositoryOrganization.showsWorktrees(location) ? .on : .off; worktrees.isEnabled = enable.state == .on; row.addArrangedSubview(worktrees); list.addArrangedSubview(row)
            let value: String
            if GitAutoFetchScheduler.shared.running.contains(key) { value = L.text("Fetching…") }
            else if let error = defaults.string(forKey:key+".error") { value = error }
            else if let date = defaults.object(forKey:key+".lastSuccess") as? Date { value = L.text("Last successful Fetch")+" · "+DateFormatter.localizedString(from:date,dateStyle:.medium,timeStyle:.short) }
            else { value = L.text("Last successful Fetch")+" · "+L.text("Never") }
            let detail = NSTextField(wrappingLabelWithString:value); detail.textColor = defaults.string(forKey:key+".error") == nil ? .secondaryLabelColor : .systemOrange; detail.maximumNumberOfLines = 3; detail.toolTip = value; list.addArrangedSubview(detail)
        }
        fit()
    }
    @objc func changeInterval(_ sender: NSPopUpButton) { guard locations.indices.contains(sender.tag) else { return }; let key = GitAutoFetchScheduler.key(locations[sender.tag]),index = sender.indexOfSelectedItem
        if index == 7,let window {
            let alert = GitNativeSheet.alert(owner:window); alert.messageText = L.text("Custom Interval…"); let value = NSTextField(string:String(defaults.object(forKey:key+".minutes") as? Int ?? 5)); value.frame.size = NSSize(width:250,height:24); alert.accessoryView = value; alert.informativeText = L.text("Fetch interval in minutes"); alert.addButton(withTitle:L.text("Save")); alert.addButton(withTitle:L.text("Cancel"))
            alert.beginSheetModal(for:window) { [self] response in guard response == .alertFirstButtonReturn else { render(); return }; defaults.set(true,forKey:key); defaults.set(min(1440,max(1,value.integerValue)),forKey:key+".minutes"); render() }; return
        }
        if index == 0 { defaults.removeObject(forKey:key); defaults.removeObject(forKey:key+".minutes") }
        else { defaults.set(index != 1,forKey:key); if index > 1 { defaults.set([1,5,15,30,60][index-2],forKey:key+".minutes") } }; render()
    }
    @objc func changeWorktrees(_ sender: NSButton) { guard locations.indices.contains(sender.tag) else { return }; GitRepositoryOrganization.setWorktreesEnabled(sender.state == .on,for:locations[sender.tag]); render() }
    @objc func fetch(_ sender: NSButton) { guard locations.indices.contains(sender.tag) else { return }; GitAutoFetchScheduler.shared.fetchNow(locations[sender.tag]); render() }
    @objc func reset() {
        guard let window else { return }; let alert = GitNativeSheet.alert(owner:window); alert.messageText = L.text("Restore Git Default Settings?")
        alert.informativeText = L.text("Restore graph, commit time, diff layout, expansion, wrapping, snippets, worktree visibility, all automatic fetch overrides, external applications and repository sorting. Repositories, groups, names, order and files are kept."); alert.addButton(withTitle:L.text("Restore Defaults")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [self] response in guard response == .alertFirstButtonReturn else { return }
            let preserved = Set(["git.savedRepositories","git.repositoryGroups","git.repositoryGroupNames","git.repositoryAliases","git.repositoryOrder","git.repositoryRootOrder","git.repositoryGroupOrder","git.repositoryCollapsedGroups","git.archivedRepositories","git.repositoryAdded","git.repositoryOpened","git.repositoryModified"])
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("git.") && !preserved.contains(key) { defaults.removeObject(forKey:key) }
            enable.state = .on; status.state = .on; autoFetch.state = .off; interval.stringValue = "5"; render()
        }
    }
}
