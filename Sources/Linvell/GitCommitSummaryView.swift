import AppKit
import LinvellCore

final class GitCommitSummaryView: NSView {
    private let navigation = NSStackView()
    private let metadata = Theme.label("",size:11,color:Theme.secondary)
    private let body = NSTextView()
    private let scroll = NSScrollView()
    private var height: NSLayoutConstraint!
    var onNavigate: ((String) -> Void)?
    var onBack: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame:frame)
        navigation.spacing = 5
        body.isEditable = false; body.font = .systemFont(ofSize:13)
        body.backgroundColor = Theme.canvas; body.textColor = Theme.foreground
        body.isVerticallyResizable = true; body.autoresizingMask = .width
        body.textContainer?.widthTracksTextView = true
        body.usesFindBar = true; body.isIncrementalSearchingEnabled = true
        scroll.documentView = body; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        height = scroll.heightAnchor.constraint(equalToConstant:60); height.isActive = true
        Theme.pin(Theme.stack([navigation,metadata,scroll],orientation:.vertical,spacing:5),in:self)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func render(_ commit: GitCommit,mergedIn: GitCommit?,canGoBack: Bool) {
        isHidden = false
        navigation.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let back = NSButton(title:L.text("Back"),target:self,action:#selector(goBack)); back.isEnabled = canGoBack
        navigation.addArrangedSubview(back)
        let copy = NSButton(title:String(commit.hash.prefix(12)),target:self,action:#selector(copyHash(_:)))
        copy.identifier = NSUserInterfaceItemIdentifier(commit.hash); copy.toolTip = commit.hash
        navigation.addArrangedSubview(copy)
        for parent in commit.parents {
            let button = NSButton(title:L.text("Parent")+" "+String(parent.prefix(8)),target:self,action:#selector(navigate(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(parent); button.toolTip = parent; navigation.addArrangedSubview(button)
        }
        if let mergedIn {
            let button = NSButton(title:L.text("Merged In")+" "+String(mergedIn.hash.prefix(8)),target:self,action:#selector(navigate(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(mergedIn.hash); button.toolTip = mergedIn.subject; navigation.addArrangedSubview(button)
        }
        metadata.stringValue = commit.author+" <"+commit.email+"> · "+GitCommitTimeMode.current.display(commit.date)
        metadata.toolTip = commit.date
        let message = commit.message.components(separatedBy:"\n").dropFirst().joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
        body.string = message
        scroll.isHidden = message.isEmpty
        height.constant = min(140,max(42,CGFloat(message.components(separatedBy:"\n").count)*18+12))
    }
    @objc private func navigate(_ button: NSButton) { if let hash = button.identifier?.rawValue { onNavigate?(hash) } }
    @objc private func goBack() { onBack?() }
    @objc private func copyHash(_ button: NSButton) {
        guard let hash = button.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hash,forType:.string)
    }
}
