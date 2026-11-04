import AppKit
import LinvellCore

final class GitReviewDiffView: NSView {
    let editor = GitPatchTextView()
    private let scroll = GitReviewCodeScroll()
    private let split = GitSplitDiff()
    private let mode = NSSegmentedControl(labels:[L.text("Auto"),L.text("Unified"),L.text("Side by Side")],trackingMode:.selectOne,target:nil,action:nil)
    private let wrap = NSButton(checkboxWithTitle:L.text("Wrap Lines"),target:nil,action:nil)
    private let host = NSView()
    private let indexActions = NSStackView()
    private let controlsBar = NSStackView()
    var showsControls = true { didSet { controlsBar.isHidden = !showsControls; measure() } }
    private var defaultsObserver: NSObjectProtocol?
    private var measuring = false
    private var patch = "",path: String?
    var continuous = false { didSet { scroll.continuous = continuous; scroll.hasVerticalScroller = !continuous; split.continuous = continuous; measure() } }
    private(set) var measuredHeight: CGFloat = 70
    var onHeightChange: (() -> Void)?
    var apply: ((GitHunk?) -> Void)? { didSet { editor.apply = apply; indexActions.isHidden = apply == nil } }
    var unstaging = false { didSet {
        editor.unstaging = unstaging
        for (index,view) in indexActions.arrangedSubviews.enumerated() {
            guard let button = view as? NSButton else { continue }
            button.title = (unstaging ? "− " : "+ ")+L.text(["Selected Lines","Hunk","File"][index])
            button.toolTip = L.text((unstaging ? "Unstage " : "Stage ")+["Selected Lines","Hunk","File"][index])
        }
    } }
    var visibleEditor: NSTextView { split.isHidden ? editor : split.visibleEditor }

    override init(frame: NSRect) {
        super.init(frame:frame)
        editor.isEditable = false; editor.font = Theme.editorFont
        editor.backgroundColor = Theme.canvas; editor.textColor = Theme.foreground
        editor.isVerticallyResizable = true; editor.usesFindBar = true; editor.isIncrementalSearchingEnabled = true
        editor.textContainerInset = NSSize(width:8,height:8)
        scroll.documentView = editor; scroll.hasVerticalScroller = true
        scroll.verticalRulerView = GitDiffLineRuler(scroll:scroll,editor:editor)
        scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        mode.target = self; mode.action = #selector(updateMode(_:))
        wrap.target = self; wrap.action = #selector(updateMode(_:))
        for (title,action) in [("Selected Lines",#selector(applyLines)),("Hunk",#selector(applyHunk)),("File",#selector(applyFile))] {
            indexActions.addArrangedSubview(NSButton(title:L.text(title),target:self,action:action))
        }
        indexActions.isHidden = true; indexActions.spacing = 4
        controlsBar.spacing = 4; controlsBar.alignment = .centerY; controlsBar.distribution = .fill; controlsBar.clipsToBounds = true
        for control in [mode,wrap,NSView(),indexActions] as [NSView] { controlsBar.addArrangedSubview(control) }
        controlsBar.heightAnchor.constraint(equalToConstant:28).isActive = true
        Theme.pin(scroll,in:host); Theme.pin(split,in:host)
        Theme.pin(Theme.stack([controlsBar,host],orientation:.vertical,spacing:3),in:self)
        split.onHeightChange = { [weak self] in self?.measure() }
        defaultsObserver = NotificationCenter.default.addObserver(forName:UserDefaults.didChangeNotification,object:nil,queue:.main) { [weak self] _ in self?.preferencesChanged() }
        preferencesChanged()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) } }
    override func layout() { super.layout(); resolveLayout(); measure() }
    func render(_ patch: NSAttributedString) {
        self.patch = patch.string
        editor.textStorage?.setAttributedString(patch)
        split.render(patch); scroll.verticalRulerView?.needsDisplay = true
        measure()
    }
    func render(_ patch: String,path: String? = nil) {
        self.path = path
        render(GitDiffRendering.styled(patch,path:path))
    }
    private func preferencesChanged() {
        let selected = UserDefaults.standard.object(forKey:"git.diffMode") as? Int ?? 1
        let wrapped = UserDefaults.standard.bool(forKey:"git.wrapDiff")
        let styleChanged = editor.font != Theme.editorFont
        mode.selectedSegment = selected; wrap.state = wrapped ? .on : .off
        updateMode(nil)
        if styleChanged,!patch.isEmpty { render(patch,path:path) }
    }
    @objc private func updateMode(_ sender: Any?) {
        if sender != nil {
            UserDefaults.standard.set(mode.selectedSegment,forKey:"git.diffMode")
            UserDefaults.standard.set(wrap.state == .on,forKey:"git.wrapDiff")
        }
        editor.isHorizontallyResizable = wrap.state != .on
        editor.autoresizingMask = wrap.state == .on ? .width : []
        editor.textContainer?.widthTracksTextView = wrap.state == .on
        editor.textContainer?.containerSize = NSSize(width:wrap.state == .on ? max(1,scroll.contentSize.width-16) : 100000,height:CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = wrap.state != .on
        split.setWrap(wrap.state == .on)
        resolveLayout(); measure()
    }
    private func resolveLayout() {
        let sideBySide = mode.selectedSegment == 2 || (mode.selectedSegment == 0 && bounds.width >= 700)
        split.isHidden = !sideBySide; scroll.isHidden = sideBySide
        if wrap.state == .on { editor.setFrameSize(NSSize(width:max(1,scroll.contentSize.width),height:max(1,editor.frame.height))) }
    }
    private func measure() {
        guard !measuring else { return }; measuring = true; defer { measuring = false }
        let controlsHeight: CGFloat = showsControls ? 31 : 0
        var height = split.measuredHeight+controlsHeight
        if split.isHidden,let manager = editor.layoutManager,let container = editor.textContainer {
            manager.ensureLayout(for:container)
            height = max(39,ceil(manager.usedRect(for:container).height)+24+(wrap.state == .on ? 0 : 16))+controlsHeight
            if continuous { editor.setFrameSize(NSSize(width:max(editor.frame.width,scroll.contentSize.width),height:max(1,height-controlsHeight))) }
        }
        if abs(height-measuredHeight) > 1 { measuredHeight = height; onHeightChange?() }
    }
    func find() {
        let view = visibleEditor
        window?.makeFirstResponder(view)
        let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue; view.performFindPanelAction(item)
    }
    private func selectedRange(allowCaret: Bool = false) -> NSRange? { split.isHidden ? editor.selectedRange() : split.sourceSelection(allowCaret:allowCaret) }
    @objc private func applyLines() {
        guard let range = selectedRange() else { return }
        do { apply?(try GitHunk.selection(in:editor.string,range:range,unstage:unstaging)) }
        catch { if let window { NSAlert(error:error).beginSheetModal(for:window) } }
    }
    @objc private func applyHunk() {
        guard let range = selectedRange(allowCaret:true) else { return }
        editor.setSelectedRange(range); editor.applyHunk()
    }
    @objc private func applyFile() { apply?(nil) }
}
