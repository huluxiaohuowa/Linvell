import AppKit

final class TabTitleButton: NSButton {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled,let row = superview as? DraggableTabRow else { super.mouseDown(with:event); return }
        row.trackPress(event,button:self)
    }
}

final class DraggableTabRow: NSStackView {
    weak var owner: WorkspaceController?
    var documentID: UUID?

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let button = arrangedSubviews.dropFirst().first as? TabTitleButton else { return }
        trackPress(event,button:button)
    }

    func trackPress(_ event: NSEvent,button: NSButton) {
        guard let window,let owner,let documentID else { return }
        let strip = owner.tabScroll
        let start = event.locationInWindow
        var point = start
        var dragging = false
        button.highlight(true)
        defer { button.highlight(false); strip.hideInsertionMarker(); alphaValue = 1 }
        while window.isVisible {
            let next = window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp,.keyDown],
                                        until:dragging ? Date(timeIntervalSinceNow:0.04) : .distantFuture,
                                        inMode:.eventTracking,dequeue:true)
            if let next {
                if next.type == .keyDown {
                    if next.keyCode == 53 { return }
                    continue
                }
                point = next.locationInWindow
                if next.type == .leftMouseUp {
                    if dragging,let boundary = strip.insertionBoundary(at:point) {
                        _ = owner.moveTab(documentID,toInsertion:boundary)
                    } else if !dragging,bounds.contains(convert(point,from:nil)) {
                        button.performClick(nil)
                    }
                    return
                }
                if !dragging,owner.documents.count > 1,hypot(point.x-start.x,point.y-start.y) >= 4 {
                    dragging = true
                    button.highlight(false)
                    alphaValue = 0.45
                }
            }
            if dragging { strip.showInsertionMarker(at:point) }
        }
    }
}

final class TabScrollView: ResponsiveScrollView {
    weak var owner: WorkspaceController?
    private let marker = TabInsertionMarker()

    override init(frame: NSRect) {
        super.init(frame:frame)
        marker.wantsLayer = true
        marker.layer?.cornerRadius = 1
        marker.isHidden = true
        addSubview(marker,positioned:.above,relativeTo:nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func insertionBoundary(at point: NSPoint) -> Int? {
        guard let owner,bounds.insetBy(dx:-8,dy:-8).contains(convert(point,from:nil)) else { return nil }
        let x = owner.tabs.convert(point,from:nil).x
        return owner.tabs.arrangedSubviews.firstIndex { x < $0.frame.midX } ?? owner.documents.count
    }

    func showInsertionMarker(at point: NSPoint) {
        guard let owner,insertionBoundary(at:point) != nil else { hideInsertionMarker(); return }
        let viewport = contentView
        let cursor = viewport.convert(point,from:nil)
        if cursor.x < viewport.bounds.minX+18 || cursor.x > viewport.bounds.maxX-18 {
            let direction: CGFloat = cursor.x < viewport.bounds.midX ? -1 : 1
            let proposed = NSPoint(x:viewport.bounds.minX+direction*12,y:viewport.bounds.minY)
            viewport.scroll(to:viewport.constrainBoundsRect(NSRect(origin:proposed,size:viewport.bounds.size)).origin)
            reflectScrolledClipView(viewport)
        }
        guard let boundary = insertionBoundary(at:point) else { return }
        let rows = owner.tabs.arrangedSubviews
        let edge = boundary < rows.count ? rows[boundary].frame.minX : rows.last?.frame.maxX ?? 0
        let x = convert(NSPoint(x:edge,y:0),from:owner.tabs).x
        marker.frame = NSRect(x:max(0,min(bounds.maxX-2,x-1)),y:5,width:2,height:max(0,bounds.height-10))
        marker.layer?.backgroundColor = Theme.accent.cgColor
        marker.isHidden = false
    }

    func hideInsertionMarker() { marker.isHidden = true }
}

private final class TabInsertionMarker: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
