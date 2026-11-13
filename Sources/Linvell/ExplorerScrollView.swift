import AppKit

/// Shows the ancestors of the first visible row inside the explorer's scroll area.
final class ExplorerScrollView: ResponsiveScrollView {
    private let pinned = NSStackView()
    private var boundsObserver: NSObjectProtocol?
    private var preferenceObserver: NSObjectProtocol?
    private var displayed: [ObjectIdentifier] = []
    var folder: ((Any) -> (path: String,name: String)?)?
    var canPin: (() -> Bool)?

    override init(frame: NSRect) {
        super.init(frame:frame)
        pinned.orientation = .vertical
        pinned.alignment = .leading
        pinned.spacing = 0
        pinned.wantsLayer = true
        addSubview(pinned,positioned:.above,relativeTo:nil)
        contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:contentView,queue:.main) { [weak self] _ in self?.updatePinned() }
        preferenceObserver = NotificationCenter.default.addObserver(forName:PreferencesSync.didApply,object:nil,queue:.main) { [weak self] _ in self?.updatePinned() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
    }

    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        updatePinned()
    }
    override func layout() {
        super.layout()
        updatePinned()
    }

    static func ancestors(in tree: NSOutlineView,above top: CGFloat) -> [Any] {
        let first = tree.row(at:NSPoint(x:2,y:top+1))
        guard first >= 0,let row = tree.item(atRow:first) else { return [] }
        var items: [Any] = []
        var parent = tree.parent(forItem:row)
        while let item = parent {
            let index = tree.row(forItem:item)
            if index >= 0,tree.rect(ofRow:index).maxY <= top { items.append(item) }
            parent = tree.parent(forItem:item)
        }
        return Array(items.reversed().suffix(3))
    }

    func updatePinned() {
        guard let tree = documentView as? NSOutlineView,let folder,
              PreferencesSync.value("pinExplorerFolders") == "true",canPin?() != false else {
            pinned.isHidden = true; return
        }
        let top = tree.visibleRect.minY
        let items = Self.ancestors(in:tree,above:top)
        let folders = items.compactMap { item -> (AnyObject,String)? in
            guard let info = folder(item) else { return nil }
            return (item as AnyObject,info.name)
        }
        let identity = folders.map { ObjectIdentifier($0.0) }
        pinned.isHidden = identity.isEmpty
        if identity != displayed {
            displayed = identity
            pinned.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (item,name) in folders {
                let button = PinnedFolderButton(title:name,target:nil,action:nil)
                button.target = button
                button.action = #selector(PinnedFolderButton.reveal)
                button.showFolder = { [weak tree] in
                    guard let tree else { return }
                    let row = tree.row(forItem:item)
                    if row >= 0 { tree.scrollRowToVisible(row) }
                }
                button.alignment = .left
                button.isBordered = false
                button.lineBreakMode = .byTruncatingMiddle
                button.image = NSImage(systemSymbolName:"folder",accessibilityDescription:nil)
                button.imagePosition = .imageLeading
                button.setAccessibilityLabel(name)
                button.heightAnchor.constraint(equalToConstant:23).isActive = true
                pinned.addArrangedSubview(button)
                button.widthAnchor.constraint(lessThanOrEqualTo:pinned.widthAnchor,constant:-12).isActive = true
            }
        }
        let clip = contentView.frame
        let height = CGFloat(identity.count)*23
        pinned.layer?.backgroundColor = Theme.panel.cgColor
        pinned.frame = NSRect(x:clip.minX,y:isFlipped ? clip.minY : clip.maxY-height,width:clip.width,height:height)
    }
}

private final class PinnedFolderButton: NSButton {
    var showFolder: (() -> Void)?
    @objc func reveal() { showFolder?() }
}
