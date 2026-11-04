import AppKit
import LinvellCore

/// Native adaptation of FoldGit's RepositoryGroupEditor and immediate-child discovery (MIT).
final class GitRepositoryGroupEditor: NSView, NSTextFieldDelegate {
    let name = NSTextField()
    let filter = NSSearchField()
    private let rows = NSStackView()
    private let scroll = NSScrollView()
    private let add = NSButton(title:L.text("Add Repositories from Finder"),target:nil,action:nil)
    private let count = Theme.label("",size:12,color:Theme.secondary)
    private let error = NSTextField(wrappingLabelWithString:"")
    private(set) var candidates: [WorkspaceSession]
    private(set) var selected: Set<String>
    private let aliases: [String:String]
    private var loading = false
    var onValidationChanged: (() -> Void)?
    func controlTextDidChange(_ notification: Notification) { onValidationChanged?() }
    var onImport: (([WorkspaceSession]) -> Void)?

    init(name: String,candidates: [WorkspaceSession],selected: Set<String>) {
        self.candidates = candidates; self.selected = selected
        aliases = UserDefaults.standard.dictionary(forKey:"git.repositoryAliases") as? [String:String] ?? [:]
        super.init(frame:NSRect(x:0,y:0,width:540,height:365))
        self.name.delegate = self
        self.name.stringValue = name; self.name.placeholderString = L.text("Group Name")
        filter.placeholderString = L.text("Filter Repositories")
        filter.target = self; filter.action = #selector(render); filter.sendsSearchStringImmediately = true
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 6
        scroll.hasVerticalScroller = true; scroll.documentView = rows
        scroll.heightAnchor.constraint(equalToConstant:230).isActive = true
        add.target = self; add.action = #selector(chooseDirectories)
        error.textColor = .systemRed; error.font = .systemFont(ofSize:11); error.maximumNumberOfLines = 2
        Theme.pin(Theme.stack([self.name,filter,scroll,Theme.stack([add,NSView(),count]),error],orientation:.vertical,spacing:6),in:self)
        render()
    }
    required init?(coder: NSCoder) { fatalError() }
    var selectedLocations: [WorkspaceSession] { candidates.filter { selected.contains($0.repositoryID) } }
    var canSave: Bool { !loading && !name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }

    @objc private func render() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for location in candidates {
            let title = aliases[location.repositoryID] ?? location.title
            guard filter.stringValue.isEmpty || (title+" "+location.path).localizedStandardContains(filter.stringValue) else { continue }
            let button = NSButton(checkboxWithTitle:title,target:self,action:#selector(toggle(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(location.repositoryID)
            button.toolTip = location.path; button.state = selected.contains(location.repositoryID) ? .on : .off
            rows.addArrangedSubview(button)
        }
        rows.frame = NSRect(x:0,y:0,width:max(1,scroll.contentSize.width),height:max(230,CGFloat(rows.arrangedSubviews.count)*28))
        count.stringValue = L.format("%d repositories selected",selected.count)
    }
    @objc private func toggle(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if sender.state == .on { selected.insert(id) } else { selected.remove(id) }
        count.stringValue = L.format("%d repositories selected",selected.count)
    }
    @objc private func chooseDirectories() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.title = L.text("Add Repositories from Finder")
        panel.beginSheetModal(for:window) { [weak self] response in
            if response == .OK { self?.importDirectories(panel.urls) }
        }
    }
    func importDirectories(_ urls: [URL],completion: (() -> Void)? = nil) {
        guard !loading else { return }; loading = true; add.isEnabled = false; error.stringValue = ""; onValidationChanged?()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            var found: [WorkspaceSession] = []
            for input in urls {
                let directory = input.standardizedFileURL.resolvingSymlinksInPath()
                let children = FileManager.default.fileExists(atPath:directory.appendingPathComponent(".git").path) ? [directory] :
                    ((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:.skipsHiddenFiles)) ?? [])
                for file in children {
                    guard (try? file.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
                    guard FileManager.default.fileExists(atPath:file.appendingPathComponent(".git").path),
                          let resolved = try? GitRepository(root:file).resolvedWorkingTree(),
                          resolved.root.resolvingSymlinksInPath() == file.resolvingSymlinksInPath() else { continue }
                    let value = WorkspaceSession.local(path:resolved.directory)
                    if !found.contains(value) { found.append(value) }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false; self.add.isEnabled = true
                for value in found {
                    if !self.candidates.contains(value) { self.candidates.append(value) }
                    self.selected.insert(value.repositoryID)
                }
                if found.isEmpty { self.error.stringValue = L.text("No Git repositories were found directly inside this folder.") }
                self.render(); self.onImport?(found); self.onValidationChanged?(); completion?()
            }
        }
    }
}
