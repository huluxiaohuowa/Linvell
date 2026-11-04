import AppKit

/// A pinned review message has its own document; changing file-history selection never replaces it.
final class GitReviewContextMessageView: NSScrollView {
    let text = NSTextView()
    init(message: String) {
        super.init(frame:NSRect(x:0,y:0,width:640,height:140))
        identifier = NSUserInterfaceItemIdentifier("gitReviewContextMessage")
        hasVerticalScroller = true; hasHorizontalScroller = false; drawsBackground = false
        text.isEditable = false; text.isSelectable = true; text.isRichText = false
        text.font = .systemFont(ofSize:13); text.textColor = Theme.foreground
        text.drawsBackground = false; text.textContainerInset = NSSize(width:8,height:8)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.minSize = .zero; text.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = .width; text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width:624,height:CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel(L.text("Commit Message")); text.string = message
        documentView = text
        let approximateLines = message.components(separatedBy:"\n").count+message.utf16.count/90
        heightAnchor.constraint(equalToConstant:min(140,max(44,CGFloat(approximateLines)*18+16))).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let width = max(1,contentSize.width)
        if abs(text.frame.width-width) > 0.5 { text.setFrameSize(NSSize(width:width,height:max(1,text.frame.height))) }
        guard let manager = text.layoutManager,let container = text.textContainer else { return }
        manager.ensureLayout(for:container)
        let height = max(contentSize.height,ceil(manager.usedRect(for:container).height)+16)
        if abs(text.frame.height-height) > 0.5 { text.setFrameSize(NSSize(width:width,height:height)) }
    }
}
