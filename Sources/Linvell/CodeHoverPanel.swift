import AppKit

/// A code tooltip must never become the keyboard target or a modal interaction.
final class CodeHoverPanel: NSPanel {
    private var resignObserver: NSObjectProtocol?
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear; hasShadow = true
        animationBehavior = .none; hidesOnDeactivate = true; isExcludedFromWindowsMenu = true
        collectionBehavior = [.transient,.fullScreenAuxiliary]
    }
    func show(relativeTo rect: NSRect,of view: NSView,preferredEdge: NSRectEdge) {
        guard let parent = view.window,parent.isVisible,parent.isKeyWindow,parent.attachedSheet == nil,let controller = contentViewController else { return }
        close()
        _ = controller.view
        let size = controller.preferredContentSize,anchor = parent.convertToScreen(view.convert(rect,to:nil))
        let screen = parent.screen?.visibleFrame ?? NSRect(x:0,y:0,width:1920,height:1080)
        let x = max(screen.minX+8,min(anchor.minX,screen.maxX-size.width-8))
        let below = anchor.minY-size.height-6
        let y = max(screen.minY+8,min(below >= screen.minY+8 ? below : anchor.maxY+6,screen.maxY-size.height-8))
        setFrame(NSRect(origin:NSPoint(x:x,y:y),size:size),display:false); appearance = parent.appearance
        controller.view.wantsLayer = true; controller.view.layer?.cornerRadius = 7; controller.view.layer?.masksToBounds = true
        controller.view.layer?.borderWidth = 1; controller.view.layer?.borderColor = Theme.secondary.withAlphaComponent(0.24).cgColor
        parent.addChildWindow(self,ordered:.above); orderFront(nil)
        resignObserver = NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:parent,queue:.main) { [weak self] _ in self?.close() }
    }
    override func close() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        parent?.removeChildWindow(self); super.close()
    }
    deinit { if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) } }
}
