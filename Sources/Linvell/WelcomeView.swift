import AppKit

final class WelcomeView: NSView {
    private let scroll = ResponsiveScrollView()
    private let page: WelcomePage
    init(owner: WorkspaceController) {
        page = WelcomePage(owner:owner); super.init(frame:.zero)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = page; Theme.pin(scroll,in:self)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let width = max(398,scroll.contentSize.width)
        page.frame = NSRect(x:0,y:0,width:width,height:max(scroll.contentSize.height,width < 760 ? 600 : 440))
        page.needsLayout = true
    }
}

private final class WelcomePage: NSView {
    let hero: NSStackView
    let actions: WelcomeActions
    let footer = Theme.label("Native Swift · Thoughtfully made for macOS",size:11,color:Theme.secondary)
    override var isFlipped: Bool { true }
    init(owner: WorkspaceController) {
        let logo = NSImageView(image:NSImage(named:"Linvell") ?? NSImage())
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.widthAnchor.constraint(equalToConstant:88).isActive = true; logo.heightAnchor.constraint(equalToConstant:88).isActive = true
        let name = BrandWordmarkView()
        name.widthAnchor.constraint(equalToConstant:244).isActive = true
        name.heightAnchor.constraint(equalToConstant:73).isActive = true
        let brand = NSStackView(views:[logo,name]); brand.orientation = .horizontal; brand.spacing = 18; brand.alignment = .centerY
        let eyebrow = Theme.label("A LITTLE ROOM TO THINK",size:10,color:Theme.accent,weight:.semibold)
        let subtitle = NSTextField(wrappingLabelWithString:L.text("Make space for your next idea.")); subtitle.font = .systemFont(ofSize:23,weight:.medium); subtitle.textColor = Theme.foreground
        let description = NSTextField(wrappingLabelWithString:L.text("Open a project. Find your flow.\nA native workspace that stays out of your way."))
        description.font = .systemFont(ofSize:14); description.textColor = Theme.secondary
        hero = NSStackView(views:[eyebrow,brand,subtitle,description]); hero.orientation = .vertical; hero.alignment = .leading; hero.spacing = 16
        subtitle.widthAnchor.constraint(equalTo:hero.widthAnchor).isActive = true
        description.widthAnchor.constraint(equalTo:hero.widthAnchor).isActive = true
        actions = WelcomeActions(owner:owner)
        super.init(frame:.zero); wantsLayer = true; clipsToBounds = true
        hero.translatesAutoresizingMaskIntoConstraints = true
        actions.translatesAutoresizingMaskIntoConstraints = true
        footer.translatesAutoresizingMaskIntoConstraints = true
        addSubview(hero); addSubview(actions); addSubview(footer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let wide = bounds.width >= 760,width = wide ? 720 : min(360,bounds.width-48)
        let height: CGFloat = wide ? 310 : 484,top = max(32,(bounds.height-height)/2-16),left = (bounds.width-width)/2
        hero.frame = NSRect(x:left,y:top,width:wide ? 350 : width,height:wide ? 290 : 226)
        actions.frame = NSRect(x:wide ? left+390 : left,y:wide ? top+18 : top+250,width:wide ? 330 : width,height:234)
        actions.layoutSubtreeIfNeeded()
        footer.frame = NSRect(x:left,y:top+height+28,width:width,height:20)
    }
    override func draw(_ dirtyRect: NSRect) {
        Theme.canvas.setFill(); dirtyRect.fill()
        NSGraphicsContext.saveGraphicsState(); bounds.clip()
        let center = NSPoint(x:bounds.width*0.25,y:bounds.height*0.42)
        NSGradient(starting:Theme.accent.withAlphaComponent(Theme.profile.isDark ? 0.10 : 0.065),ending:Theme.canvas.withAlphaComponent(0))?.draw(fromCenter:center,radius:0,toCenter:center,radius:min(bounds.width,700)*0.7,options:[])
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class WelcomeActions: NSView {
    private let buttons: [WelcomeAction]
    override var isFlipped: Bool { true }
    init(owner: WorkspaceController) {
        buttons = [
            WelcomeAction(title:"Open a folder",detail:"Bring your project into focus.",symbol:"folder",shortcut:"⌘K ⌘O",owner:owner,action:#selector(WorkspaceController.openFolder)),
            WelcomeAction(title:"New file",detail:"Start with a blank canvas.",symbol:"square.and.pencil",shortcut:"⌘N",owner:owner,action:#selector(WorkspaceController.newFile)),
            WelcomeAction(title:"Open a file",detail:"Pick up where you left off.",symbol:"doc",shortcut:"⌘O",owner:owner,action:#selector(WorkspaceController.openFile))
        ]
        super.init(frame:.zero)
        for button in buttons { button.translatesAutoresizingMaskIntoConstraints = true; addSubview(button) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func layout() {
        super.layout()
        for (index,button) in buttons.enumerated() { button.frame = NSRect(x:0,y:CGFloat(index)*82,width:bounds.width,height:70) }
    }
}

private final class WelcomeAction: NSButton {
    let caption: String,detail: String,symbol: String,shortcut: String
    private var hovering = false
    private var tracking: NSTrackingArea?
    init(title: String,detail: String,symbol: String,shortcut: String,owner: WorkspaceController,action: Selector) {
        caption = L.text(title); self.detail = L.text(detail); self.symbol = symbol; self.shortcut = shortcut
        super.init(frame:.zero); self.title = caption; target = owner; self.action = action
        isBordered = false; setButtonType(.momentaryPushIn); setAccessibilityLabel(caption)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:10,yRadius:10)
        (hovering || isHighlighted ? Theme.selection : Theme.panel.withAlphaComponent(0.72)).setFill(); card.fill()
        Theme.accent.withAlphaComponent(hovering ? 0.65 : 0.22).setStroke(); card.lineWidth = 1; card.stroke()
        let image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(.init(paletteColors:[Theme.accent]))
        image?.draw(in:NSRect(x:18,y:23,width:24,height:24),from:.zero,operation:.sourceOver,fraction:1)
        (caption as NSString).draw(at:NSPoint(x:56,y:14),withAttributes:[.font:NSFont.systemFont(ofSize:14,weight:.semibold),.foregroundColor:Theme.foreground])
        (detail as NSString).draw(at:NSPoint(x:56,y:37),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:Theme.secondary])
        let keyFont = NSFont.monospacedSystemFont(ofSize:10,weight:.medium),size = (shortcut as NSString).size(withAttributes:[.font:keyFont])
        (shortcut as NSString).draw(at:NSPoint(x:bounds.width-size.width-16,y:16),withAttributes:[.font:keyFont,.foregroundColor:Theme.secondary])
    }
}

private final class BrandWordmarkView: NSView {
    private static let light = Bundle.main.url(forResource:"Wordmark",withExtension:"png").flatMap { NSImage(contentsOf:$0) }
    private static let dark = Bundle.main.url(forResource:"Wordmark-Dark",withExtension:"png").flatMap { NSImage(contentsOf:$0) }
    override init(frame: NSRect) { super.init(frame:frame); setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Linvell") }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        (Theme.profile.isDark ? Self.dark : Self.light)?.draw(in:bounds,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    }
}
