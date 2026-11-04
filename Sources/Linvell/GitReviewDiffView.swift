import AppKit
import LinvellCore

final class GitReviewDiffView: NSView {
    let editor = GitPatchTextView()
    private let scroll = NSScrollView()
    private let split = GitSplitDiff()
    private let mode = NSSegmentedControl(labels:[L.text("Auto"),L.text("Unified"),L.text("Side by Side")],trackingMode:.selectOne,target:nil,action:nil)
    private let wrap = NSButton(checkboxWithTitle:L.text("Wrap Lines"),target:nil,action:nil)
    private let host = NSView()
    private let indexActions = NSStackView()
    var apply: ((GitHunk?) -> Void)? { didSet { editor.apply = apply; indexActions.isHidden = apply == nil } }
    var unstaging = false {
        didSet {
            editor.unstaging = unstaging
            for (index,view) in indexActions.arrangedSubviews.enumerated() {
                guard let button = view as? NSButton else { continue }
                button.title = (unstaging ? "− " : "+ ")+L.text(["Selected Lines","Hunk","File"][index])
                button.toolTip = L.text((unstaging ? "Unstage " : "Stage ")+["Selected Lines","Hunk","File"][index])
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame:frame)
        editor.isEditable = false; editor.font = Theme.editorFont
        editor.backgroundColor = Theme.canvas; editor.textColor = Theme.foreground
        editor.isVerticallyResizable = true; editor.usesFindBar = true; editor.isIncrementalSearchingEnabled = true
        editor.textContainerInset = NSSize(width:8,height:8)
        scroll.documentView = editor; scroll.hasVerticalScroller = true
        scroll.verticalRulerView = GitDiffLineRuler(scroll:scroll,editor:editor)
        scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        mode.selectedSegment = UserDefaults.standard.object(forKey:"git.diffMode") as? Int ?? 1
        mode.target = self; mode.action = #selector(updateMode(_:))
        wrap.state = UserDefaults.standard.bool(forKey:"git.wrapDiff") ? .on : .off
        wrap.target = self; wrap.action = #selector(updateMode(_:))
        for (title,action) in [("Selected Lines",#selector(applyLines)),("Hunk",#selector(applyHunk)),("File",#selector(applyFile))] {
            let button = NSButton(title:L.text(title),target:self,action:action)
            indexActions.addArrangedSubview(button)
        }
        indexActions.isHidden = true; indexActions.spacing = 4
        let bar = Theme.stack([mode,wrap,NSView(),indexActions],spacing:4)
        bar.heightAnchor.constraint(equalToConstant:28).isActive = true
        Theme.pin(scroll,in:host); Theme.pin(split,in:host)
        Theme.pin(Theme.stack([bar,host],orientation:.vertical,spacing:3),in:self)
        updateMode(nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); resolveLayout() }
    func render(_ patch: NSAttributedString) {
        editor.textStorage?.setAttributedString(patch)
        split.render(patch)
        scroll.verticalRulerView?.needsDisplay = true
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
        resolveLayout()
    }
    private func resolveLayout() {
        let sideBySide = mode.selectedSegment == 2 || (mode.selectedSegment == 0 && bounds.width >= 700)
        split.isHidden = !sideBySide; scroll.isHidden = sideBySide
        if wrap.state == .on { editor.setFrameSize(NSSize(width:max(1,scroll.contentSize.width),height:max(1,editor.frame.height))) }
    }
    private func selectedRange() -> NSRange? { split.isHidden ? editor.selectedRange() : split.sourceSelection() }
    @objc private func applyLines() {
        guard let range = selectedRange() else { return }
        do { apply?(try GitHunk.selection(in:editor.string,range:range,unstage:unstaging)) }
        catch { if let window { NSAlert(error:error).beginSheetModal(for:window) } }
    }
    @objc private func applyHunk() {
        guard let range = selectedRange() else { return }
        editor.setSelectedRange(range); editor.applyHunk()
    }
    @objc private func applyFile() { apply?(nil) }
}
