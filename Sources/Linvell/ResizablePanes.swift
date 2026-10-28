import AppKit

/// Native frame-based panes. Inner content uses Auto Layout; pane widths have one owner.
final class ResizablePanes: NSView {
    var isVertical = true
    var firstMinimum: CGFloat = 120
    var secondMinimum: CGFloat = 120
    var position: CGFloat?
    var onResize: ((CGFloat) -> Void)?
    var arrangedSubviews: [NSView] { subviews.filter { $0 !== handle } }
    private lazy var handle = PaneHandle(owner:self)
    override var isFlipped: Bool { true }
    func addArrangedSubview(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = true
        addSubview(view,positioned:.below,relativeTo:subviews.contains(handle) ? handle : nil)
        if !subviews.contains(handle) { addSubview(handle) }
        needsLayout = true
    }
    func adjustSubviews() { needsLayout = true; layoutSubtreeIfNeeded() }
    func setPosition(_ value: CGFloat,ofDividerAt index: Int) {
        let total = isVertical ? bounds.width : bounds.height
        position = min(max(firstMinimum,value),max(firstMinimum,total-secondMinimum-1))
        needsLayout = true; layoutSubtreeIfNeeded(); onResize?(position ?? value)
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) { needsLayout = true }
    override func layout() {
        super.layout()
        let panes = arrangedSubviews.filter { !$0.isHidden }
        guard !panes.isEmpty else { handle.isHidden = true; return }
        guard panes.count == 2 else { panes[0].frame = bounds; handle.isHidden = true; return }
        handle.isHidden = false
        let total = isVertical ? bounds.width : bounds.height
        let p = min(max(firstMinimum,position ?? total/2),max(firstMinimum,total-secondMinimum-1))
        if isVertical {
            panes[0].frame = NSRect(x:0,y:0,width:p,height:bounds.height)
            panes[1].frame = NSRect(x:p+1,y:0,width:max(0,total-p-1),height:bounds.height)
            handle.frame = NSRect(x:p-4,y:0,width:9,height:bounds.height)
        } else {
            panes[0].frame = NSRect(x:0,y:0,width:bounds.width,height:p)
            panes[1].frame = NSRect(x:0,y:p+1,width:bounds.width,height:max(0,total-p-1))
            handle.frame = NSRect(x:0,y:p-4,width:bounds.width,height:9)
        }
        handle.setAccessibilityValue(NSNumber(value:Double(p))); handle.needsDisplay = true
    }
}

final class PaneHandle: NSView {
    weak var owner: ResizablePanes?
    init(owner: ResizablePanes) {
        self.owner = owner; super.init(frame:.zero)
        setAccessibilityElement(true); setAccessibilityRole(.splitter); setAccessibilityLabel("Resize panes"); setAccessibilityEnabled(true)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { (owner?.isVertical == true ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set(); addCursorRect(bounds,cursor:owner?.isVertical == true ? .resizeLeftRight : .resizeUpDown) }
    override func draw(_ dirtyRect: NSRect) {
        Theme.secondary.withAlphaComponent(0.2).setFill()
        (owner?.isVertical == true ? NSRect(x:4,y:0,width:1,height:bounds.height) : NSRect(x:0,y:4,width:bounds.width,height:1)).fill()
    }
    override func mouseDown(with event: NSEvent) {
        guard let owner,let window else { return }
        window.makeFirstResponder(self)
        while let next = window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = owner.convert(next.locationInWindow,from:nil)
            owner.setPosition(owner.isVertical ? point.x : point.y,ofDividerAt:0)
        }
    }
    override func keyDown(with event: NSEvent) {
        guard let owner else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 40 : 10
        if [123,126].contains(event.keyCode) { owner.setPosition((owner.position ?? 260)-step,ofDividerAt:0) }
        else if [124,125].contains(event.keyCode) { owner.setPosition((owner.position ?? 260)+step,ofDividerAt:0) }
        else { super.keyDown(with:event) }
    }
}
