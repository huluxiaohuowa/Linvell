import AppKit
import LinvellCore

/// The file list remains available while reviewing source, history and patches.
final class GitReviewPanel: NSWindowController, NSWindowDelegate {
    struct File {
        let path: String
        let patch: (() throws -> String)?
    }

    private let repository: GitRepository
    private let files: [File]
    private let outline = NSStackView()
    private let search = NSSearchField()
    private let modes = NSSegmentedControl(labels:[L.text("File Content"),L.text("File History"),L.text("Diff")],
                                           trackingMode:.selectOne,target:nil,action:nil)
    private let revisions = NSPopUpButton()
    private let more = NSButton(title:L.text("Load More"),target:nil,action:nil)
    private let openFile: ((URL) -> Void)?
    private let text = NSTextView.scrollableTextView()
    private let sections = NSStackView()
    private let detail = NSView()
    private let multi = NSView()
    private let toggle = NSButton(title:L.text("Multiple Diffs"),target:nil,action:nil)
    private var active: File?
    private var commits: [GitCommit] = []
    private var expanded: Set<String> = []
    private var folders: Set<String> = []
    private var generation = UUID()
    private weak var parentWindow: NSWindow?

    init(repository: GitRepository,files: [File],owner: NSWindow,onOpen: ((URL) -> Void)? = nil) {
        self.repository = repository
        self.files = files
        self.parentWindow = owner
        self.openFile = onOpen
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:1040,height:680),
                            styleMask:[.titled,.resizable,.closable],backing:.buffered,defer:false)
        super.init(window:panel)
        panel.title = L.text("Repository Review")
        panel.delegate = self
        panel.appearance = NSAppearance(named:Theme.isDark ? .darkAqua : .aqua)
        search.placeholderString = L.text("Filter files")
        search.target = self; search.action = #selector(renderFileList)
        search.sendsSearchStringImmediately = true
        modes.target = self; modes.action = #selector(refreshDetail)
        modes.selectedSegment = files.contains { $0.patch != nil } ? 2 : 0
        revisions.target = self; revisions.action = #selector(showRevision)
        revisions.isHidden = true
        more.isHidden = true; more.target = self; more.action = #selector(loadMore)
        configure(outline)
        configure(sections)
        let sidebar = Theme.stack([search,scrolling(outline)],orientation:.vertical,spacing:8)
        search.heightAnchor.constraint(equalToConstant:26).isActive = true
        if let view = text.documentView as? NSTextView { configurePreview(view) }
        Theme.pin(text,in:detail)
        let multiple = scrolling(sections)
        Theme.pin(multiple,in:multi)
        multi.isHidden = true
        Theme.pin(multi,in:detail)
        toggle.target = self; toggle.action = #selector(toggleMultiple)
        toggle.isHidden = !files.contains { $0.patch != nil }
        let expand = NSButton(title:L.text("Expand Diffs"),target:self,action:#selector(expandDiffs))
        let collapse = NSButton(title:L.text("Collapse Diffs"),target:self,action:#selector(collapseDiffs))
        let close = NSButton(title:L.text("Close"),target:self,action:#selector(closeReview))
        expand.isHidden = toggle.isHidden; collapse.isHidden = toggle.isHidden
        let bar = Theme.stack([modes,NSView(),close],spacing:5)
        bar.heightAnchor.constraint(equalToConstant:30).isActive = true
        let open = NSButton(title:L.text("Open File"),target:self,action:#selector(openActiveFile))
        open.isHidden = onOpen == nil
        let controls = Theme.stack([toggle,expand,collapse,revisions,more,NSView(),open],spacing:5)
        controls.heightAnchor.constraint(equalToConstant:30).isActive = true
        let right = Theme.stack([bar,controls,detail],orientation:.vertical,spacing:8)
        let panes = ResizablePanes(); panes.position = 280; panes.secondMinimum = 520
        let leftPane = Surface(Theme.panel),rightPane = Surface(Theme.canvas)
        Theme.pin(sidebar,in:leftPane,inset:8)
        Theme.pin(right,in:rightPane,inset:8)
        panes.addArrangedSubview(leftPane); panes.addArrangedSubview(rightPane)
        Theme.pin(panes,in:panel.contentView!)
        renderFileList()
        if let first = files.first { select(first) }
        if !toggle.isHidden,UserDefaults.standard.bool(forKey:"git.expandReviewDiffs") { expandDiffs() }
        owner.beginSheet(panel)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ stack: NSStackView) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
    }

    private func scrolling(_ stack: NSStackView) -> NSScrollView {
        ReviewStackScroll(stack:stack)
    }

    @objc private func renderFileList() {
        outline.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let query = search.stringValue
        let filtered = files.filter { query.isEmpty || $0.path.localizedStandardContains(query) }
        let groups = Dictionary(grouping:filtered) { ($0.path as NSString).deletingLastPathComponent }
        for directory in groups.keys.sorted() {
            if !directory.isEmpty {
                let row = NSButton(title:(folders.contains(directory) ? "▸ " : "▾ ")+directory,target:self,action:#selector(toggleFolder(_:)))
                row.identifier = NSUserInterfaceItemIdentifier(directory)
                outline.addArrangedSubview(row)
            }
            guard !folders.contains(directory) || !query.isEmpty else { continue }
            for file in groups[directory] ?? [] {
                let row = NSButton(title:(file.path as NSString).lastPathComponent,target:self,action:#selector(selectFile(_:)))
                row.toolTip = file.path
                row.identifier = NSUserInterfaceItemIdentifier(file.path)
                outline.addArrangedSubview(row)
            }
        }
        (outline.enclosingScrollView as? ReviewStackScroll)?.fitDocument()
    }

    @objc private func toggleFolder(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        if folders.remove(path) == nil { folders.insert(path) }
        renderFileList()
    }

    @objc private func selectFile(_ sender: NSButton) {
        guard let file = files.first(where:{ $0.path == sender.identifier?.rawValue }) else { return }
        select(file)
    }

    private func select(_ file: File) {
        active = file
        multi.isHidden = true
        text.isHidden = false
        refreshDetail()
    }

    @objc private func refreshDetail() {
        guard let active else { return }
        generation = UUID()
        multi.isHidden = true; text.isHidden = false; revisions.isHidden = true; more.isHidden = true
        let repo = repository
        switch modes.selectedSegment {
        case 0: readText(sourcePath:active.path) { try repo.workingFilePreview(active.path) }
        case 1: readHistory(for:active,offset:0)
        default:
            if let patch = active.patch { readText(patch) }
            else { show(L.text("Select a revision in File History to view its diff.")) }
        }
    }

    @objc private func openActiveFile() {
        guard let active else { return }
        closeReview()
        openFile?(repository.root.appendingPathComponent(active.path))
    }

    @objc private func loadMore() {
        guard let active else { return }
        readHistory(for:active,offset:commits.count)
    }

    private func readHistory(for file: File,offset: Int) {
        let request = UUID(),repo = repository,pageSize = 100
        generation = request
        more.isEnabled = false
        if offset == 0 { show(L.text("Reading repository…")) }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try repo.fileHistory(file.path,limit:pageSize+1,offset:offset) }
            DispatchQueue.main.async {
                guard let self,self.generation == request else { return }
                self.more.isEnabled = true
                switch result {
                case .success(let page):
                    let items = Array(page.prefix(pageSize))
                    if offset == 0 { self.commits = []; self.revisions.removeAllItems() }
                    self.commits += items
                    self.revisions.addItems(withTitles:items.map { String($0.hash.prefix(12))+"  "+$0.subject })
                    self.revisions.isHidden = self.commits.isEmpty
                    self.more.isHidden = page.count <= pageSize
                    if self.commits.isEmpty { self.show(L.text("No commits yet")) }
                    else if offset == 0 { self.showRevision() }
                case .failure(let error): self.show(error.localizedDescription)
                }
            }
        }
    }

    @objc private func showRevision() {
        let index = revisions.indexOfSelectedItem
        guard let active,commits.indices.contains(index) else { return }
        let repo = repository,hash = commits[index].hash
        readText { try repo.commitDiff(hash,path:active.path) }
    }

    private func readText(sourcePath: String? = nil,_ load: @escaping () throws -> String) {
        let request = UUID()
        generation = request
        show(L.text("Reading repository…"))
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result(catching:load)
            let tokens = sourcePath.flatMap { path in
                (try? result.get()).map { SourceSyntax.analyze($0,path:path).tokens }
            }
            DispatchQueue.main.async {
                guard let self,self.generation == request else { return }
                let value = (try? result.get()) ?? self.errorText(result)
                guard let view = self.text.documentView as? NSTextView else { return }
                guard let tokens else {
                    self.paintPatch(value,in:view)
                    return
                }
                let styled = NSMutableAttributedString(string:value,attributes:[.font:Theme.editorFont,.foregroundColor:Theme.foreground])
                for token in tokens {
                    let color: NSColor
                    switch token.kind {
                    case .keyword,.type,.directive: color = Theme.keyword
                    case .string: color = Theme.accent
                    case .number: color = Theme.number
                    case .comment: color = Theme.secondary
                    }
                    styled.addAttribute(.foregroundColor,value:color,range:token.range)
                }
                view.textStorage?.setAttributedString(styled)
            }
        }
    }

    private func errorText(_ result: Result<String,Error>) -> String {
        if case .failure(let error) = result { return error.localizedDescription }
        return ""
    }

    private func configurePreview(_ view: NSTextView) {
        view.isEditable = false
        view.font = Theme.editorFont
        view.backgroundColor = Theme.canvas
        view.textColor = Theme.foreground
        view.textContainerInset = NSSize(width:8,height:8)
    }

    private func paintPatch(_ value: String,in view: NSTextView) {
        let patch = NSMutableAttributedString(string:value,attributes:[.font:Theme.editorFont,.foregroundColor:Theme.foreground])
        let text = value as NSString
        text.enumerateSubstrings(in:NSRange(location:0,length:text.length),options:.byLines) { line,range,_,_ in
            guard let line else { return }
            let color: NSColor
            if line.hasPrefix("+"),!line.hasPrefix("+++ ") { color = .systemGreen }
            else if line.hasPrefix("-"),!line.hasPrefix("--- ") { color = .systemRed }
            else { return }
            patch.addAttribute(.backgroundColor,value:color.withAlphaComponent(0.13),range:range)
        }
        InlineDiff.highlight(patch,removed:.systemRed,added:.systemGreen)
        view.textStorage?.setAttributedString(patch)
    }

    private func show(_ value: String) { (text.documentView as? NSTextView)?.string = value }

    @objc private func toggleMultiple() {
        if multi.isHidden { renderSections() }
        else { refreshDetail() }
    }

    @objc private func expandDiffs() {
        expanded = Set(files.filter { $0.patch != nil }.map(\.path))
        renderSections()
    }

    @objc private func collapseDiffs() {
        expanded.removeAll()
        renderSections()
    }

    @objc private func toggleSection(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        if expanded.remove(path) == nil { expanded.insert(path) }
        renderSections()
    }

    private func renderSections() {
        generation = UUID()
        modes.selectedSegment = 2
        revisions.isHidden = true; more.isHidden = true; text.isHidden = true; multi.isHidden = false
        sections.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var pending: [((() throws -> String),NSTextView)] = []
        for file in files {
            guard let patch = file.patch else { continue }
            let row = NSButton(title:(expanded.contains(file.path) ? "▾ " : "▸ ")+file.path,target:self,action:#selector(toggleSection(_:)))
            row.identifier = NSUserInterfaceItemIdentifier(file.path)
            sections.addArrangedSubview(row)
            if expanded.contains(file.path) {
                let preview = NSTextView.scrollableTextView()
                preview.heightAnchor.constraint(equalToConstant:ReviewStackScroll.patchHeight).isActive = true
                sections.addArrangedSubview(preview)
                let width = preview.widthAnchor.constraint(equalTo:sections.widthAnchor)
                width.priority = .defaultHigh
                width.isActive = true
                if let view = preview.documentView as? NSTextView {
                    configurePreview(view)
                    view.string = L.text("Reading repository…")
                    pending.append((patch,view))
                }
            }
        }
        (sections.enclosingScrollView as? ReviewStackScroll)?.fitDocument()
        let request = generation,loads = pending
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            for (load,view) in loads {
                let result = Result(catching:load)
                DispatchQueue.main.async {
                    guard let self,self.generation == request else { return }
                    self.paintPatch((try? result.get()) ?? self.errorText(result),in:view)
                }
            }
        }
    }

    @objc private func closeReview() { if let window { parentWindow?.endSheet(window) } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeReview(); return false }
}


private final class ReviewStackScroll: NSScrollView {
    static let patchHeight: CGFloat = 170
    private final class Document: NSView { override var isFlipped: Bool { true } }
    private let stack: NSStackView

    init(stack: NSStackView) {
        self.stack = stack
        super.init(frame:.zero)
        hasVerticalScroller = true
        drawsBackground = false
        let document = Document()
        documentView = document
        stack.translatesAutoresizingMaskIntoConstraints = true
        document.addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        fitDocument()
    }

    func fitDocument() {
        guard let documentView else { return }
        let width = max(0,contentSize.width)
        let rows = stack.arrangedSubviews
        let height = rows.reduce(CGFloat(0)) { total,row in
            total + (row is NSScrollView ? Self.patchHeight : row.intrinsicContentSize.height)
        } + CGFloat(max(0,rows.count-1))*stack.spacing
        let size = NSSize(width:width,height:max(contentSize.height,height+8))
        if documentView.frame.size != size { documentView.setFrameSize(size) }
        let frame = NSRect(x:4,y:4,width:max(0,width-8),height:height)
        if stack.frame != frame { stack.frame = frame }
    }
}
