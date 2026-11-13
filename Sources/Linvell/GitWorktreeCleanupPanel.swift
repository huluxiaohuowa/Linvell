import AppKit
import LinvellCore

/// Native adaptation of FoldGit's cleanup review/result workflow (copyright (c) 2026 dufu, MIT).
final class GitWorktreeCleanupPanel: NSWindowController, NSWindowDelegate {
    private let repository: GitRepository
    private let target: String
    private let canRemove: (String) -> Bool
    private let onRemoved: () -> Void
    private let onWorktreeRemoved: ((String) -> Void)?
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private let status = Theme.label("",size:12,color:Theme.secondary)
    private let refresh = Theme.actionButton("Refresh",target:nil,action:nil)
    private let all = Theme.actionButton("Select All",target:nil,action:nil)
    private let remove = Theme.actionButton("Remove Selected Worktrees",target:nil,action:nil)
    private let closeButton = Theme.actionButton("Cancel",target:nil,action:nil)
    let deleteBranches = NSButton(checkboxWithTitle:L.text("Delete merged local branches"),target:nil,action:nil)
    private(set) var candidates: [GitRepository.CleanupCandidate] = []
    private(set) var selected: Set<String> = []
    private(set) var results: [(path: String,message: String,command: String?)] = []
    private(set) var isRunning = false
    private var loading = false
    private var hasLoaded = false
    private var finished = false

    init(repository: GitRepository,target: String,owner: NSWindow,canRemove: @escaping (String) -> Bool,onRemoved: @escaping () -> Void,onWorktreeRemoved: ((String) -> Void)? = nil) {
        self.repository = repository; self.target = target; self.canRemove = canRemove; self.onRemoved = onRemoved; self.onWorktreeRemoved = onWorktreeRemoved
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:700,height:500),styleMask:[.titled,.resizable,.closable],backing:.buffered,defer:false)
        super.init(window:panel)
        panel.title = L.text("Clean Up Merged Worktrees…"); panel.delegate = self; panel.minSize = NSSize(width:640,height:380)
        ThemedWindow.install(panel,panel:true)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 8
        list.frame = NSRect(x:0,y:0,width:650,height:350)
        scroll.documentView = list; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        for (button,action) in [(refresh,#selector(reloadCandidates)),(all,#selector(toggleAllCandidates)),(remove,#selector(runCleanup)),(closeButton,#selector(closePanel))] {
            button.target = self; button.action = action
        }
        closeButton.keyEquivalent = "\u{1b}"; remove.keyEquivalent = "\r"
        let caution = NSTextField(wrappingLabelWithString:L.text("Ignored files will be deleted. Squash/rebase branches are kept; remote branches are never deleted."))
        caution.font = .systemFont(ofSize:12); caution.textColor = Theme.secondary
        let content = Theme.stack([Theme.stack([Theme.label(target,size:16,weight:.semibold),NSView(),refresh]),
                                   all,scroll,deleteBranches,caution,status,Theme.stack([NSView(),closeButton,remove])],orientation:.vertical,spacing:10)
        let surface = Surface(Theme.panel)
        surface.frame = panel.contentView!.bounds
        panel.contentView = surface
        Theme.pin(content,in:surface,inset:16)
        owner.beginSheet(panel)
        reloadCandidates()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isRunning }
    @objc private func closePanel() {
        guard !isRunning,let window else { return }
        window.sheetParent?.endSheet(window); window.orderOut(nil)
    }
    @objc func reloadCandidates() {
        guard !isRunning,!loading,!finished else { return }
        loading = true; status.stringValue = L.text("Reading repository…"); updateControls()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result { try self.repository.cleanupCandidates(into:self.target) }
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let values):
                    let previous = Set(self.candidates.map { $0.entry.path })
                    self.candidates = values.filter { self.canRemove($0.entry.path) }
                    self.selected = Set(self.candidates.filter { self.hasLoaded && previous.contains($0.entry.path) ? self.selected.contains($0.entry.path) : $0.selectedByDefault }.map { $0.entry.path })
                    self.hasLoaded = true
                    self.status.stringValue = self.candidates.isEmpty ? L.text("No eligible worktrees") : L.format("%d worktrees available",self.candidates.count)
                case .failure(let error): self.status.stringValue = error.localizedDescription
                }
                self.render(); self.updateControls()
            }
        }
    }
    /// Adapted from FoldGit IgnoredGroup.groups (MIT).
    static func ignoredGroups(_ paths: [String]) -> [String] {
        var groups: [String:Int] = [:]
        for path in paths {
            let parts = path.split(separator:"/",maxSplits:1)
            groups[parts.count == 2 ? String(parts[0])+"/" : path,default:0] += 1
        }
        return groups.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { $0.key+" ("+String($0.value)+")" }
    }
    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if finished {
            for result in results {
                let label = NSTextField(wrappingLabelWithString:result.path+"\n"+result.message)
                label.maximumNumberOfLines = 4; label.toolTip = result.message
                list.addArrangedSubview(label)
                label.widthAnchor.constraint(lessThanOrEqualToConstant:620).isActive = true
                if let command = result.command {
                    let copy = Theme.actionButton("Copy Delete Command",target:self,action:#selector(copyCommand(_:)))
                    copy.identifier = NSUserInterfaceItemIdentifier(command); list.addArrangedSubview(copy)
                }
            }
        } else {
            for candidate in candidates {
                let name = candidate.entry.branch.isEmpty ? L.text("Detached HEAD") : candidate.entry.branch
                let choice = NSButton(checkboxWithTitle:name+" · "+candidate.entry.path,target:self,action:#selector(toggle(_:)))
                choice.identifier = NSUserInterfaceItemIdentifier(candidate.entry.path)
                choice.toolTip = candidate.entry.path; choice.state = selected.contains(candidate.entry.path) ? .on : .off
                choice.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
                choice.widthAnchor.constraint(lessThanOrEqualToConstant:620).isActive = true
                list.addArrangedSubview(choice)
                if !candidate.selectedByDefault {
                    list.addArrangedSubview(Theme.label("Recent activity, unstarted worktrees or ignored files require an explicit choice.",size:11,color:Theme.secondary))
                }
                if !candidate.ignored.isEmpty {
                    let label = NSTextField(wrappingLabelWithString:L.text("Ignored files will be deleted")+" · "+Self.ignoredGroups(candidate.ignored).joined(separator:", "))
                    label.maximumNumberOfLines = 4; label.toolTip = candidate.ignored.joined(separator:"\n")
                    label.widthAnchor.constraint(lessThanOrEqualToConstant:620).isActive = true
                    list.addArrangedSubview(label)
                }
            }
        }
        list.frame = NSRect(origin:.zero,size:NSSize(width:max(620,scroll.contentSize.width),height:max(260,list.fittingSize.height)))
    }
    private func updateControls() {
        refresh.isEnabled = !isRunning && !loading && !finished
        all.isEnabled = !isRunning && !loading && !finished && !candidates.isEmpty
        deleteBranches.isEnabled = !isRunning && !loading && !finished
        closeButton.isEnabled = !isRunning
        window?.standardWindowButton(.closeButton)?.isEnabled = !isRunning
        closeButton.title = L.text(finished ? "Done" : "Cancel")
        remove.isHidden = finished
        remove.isEnabled = !isRunning && !loading && !selected.isEmpty
        remove.title = L.format("Remove %d Worktrees",selected.count)
        all.title = L.text(!candidates.isEmpty && selected.count == candidates.count ? "Deselect All" : "Select All")
        for button in list.arrangedSubviews.compactMap({ $0 as? NSButton }) { button.isEnabled = !isRunning && !loading }
    }
    @objc func toggleAllCandidates() {
        guard !loading,!isRunning,!finished else { return }
        selected = selected.count == candidates.count ? [] : Set(candidates.map { $0.entry.path })
        render(); updateControls()
    }
    @objc private func toggle(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        if sender.state == .on { selected.insert(path) } else { selected.remove(path) }
        updateControls()
    }
    @objc private func copyCommand(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value,forType:.string)
    }
    private func deleteCommand(path: String,branch: String? = nil) -> String {
        let argv = branch.map { ["branch","-d","--",$0] } ?? ["worktree","remove","--",path]
        if let remote = repository.remote { return "ssh -- "+SSHRemote.quote(remote.host)+" "+SSHRemote.quote(SSHRemote.gitCommand(argv,directory:repository.directory)) }
        return "git -C "+SSHRemote.quote(repository.directory)+" "+argv.map(SSHRemote.quote).joined(separator:" ")
    }
    @objc func runCleanup() {
        guard !isRunning,!loading,!finished,!selected.isEmpty else { return }
        let choices = candidates.filter { selected.contains($0.entry.path) }
        let delete = deleteBranches.state == .on
        isRunning = true; status.stringValue = L.text("Cleaning Worktrees…"); updateControls()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            guard let self else { return }
            var rows: [(String,String,String?)] = []
            var removedPaths: [String] = []
            for candidate in choices {
                do {
                    let allowed = DispatchQueue.main.sync { self.canRemove(candidate.entry.path) }
                    guard allowed else { throw GitError.command("Close the worktree window and stop its agents before finishing.") }
                    let outcome = try self.repository.removeCleanupCandidate(candidate,into:self.target,deleteBranch:delete)
                    let message: String,command: String?
                    switch outcome {
                    case .kept: message = L.text("Worktree removed; branch kept."); command = nil
                    case .deleted: message = L.text("Worktree and merged local branch removed."); command = nil
                    case .detached: message = L.text("Detached worktree removed."); command = nil
                    case .keptContentMerged: message = L.text("Worktree removed; squash/rebase branch kept."); command = nil
                    case .keptChanged: message = L.text("Worktree removed; changed branch kept."); command = nil
                    case .failed(let error): message = L.text("Worktree removed; branch deletion failed.")+" "+error; command = self.deleteCommand(path:candidate.entry.path,branch:candidate.entry.branch)
                    }
                    rows.append((candidate.entry.path,message,command)); removedPaths.append(candidate.entry.path)
                } catch { rows.append((candidate.entry.path,error.localizedDescription,self.deleteCommand(path:candidate.entry.path))) }
            }
            DispatchQueue.main.async {
                for path in removedPaths {
                    let location: WorkspaceSession = self.repository.remote.map { .ssh(host:$0.host,path:path) } ?? .local(path:path)
                    if let error = GitRepositoryOrganization.relocate(location,to:nil),let index = rows.firstIndex(where:{ $0.0 == path }) { rows[index].1 += "\n"+L.text("Worktree Metadata")+" · "+error }
                    self.onWorktreeRemoved?(path)
                }
                self.results = rows; self.isRunning = false; self.finished = true
                self.status.stringValue = L.format("%d worktrees processed",rows.count)
                self.render(); self.updateControls(); self.onRemoved()
            }
        }
    }
}
