import AppKit

enum Theme {
    enum Profile: String, CaseIterable {
        case dark = "Linvell Dark", nord = "Nord", light = "Linvell Light", solarized = "Solarized Light"
        var isDark: Bool { self == .dark || self == .nord }
        var colors: [UInt32] {
            switch self {
            case .dark: return [0x131A20,0x1B242C,0xD9E3E8,0x899BA6,0x6BD3AB,0xB8A3F2,0xF0BA78,0x2D4A50]
            case .nord: return [0x2E3440,0x3B4252,0xECEFF4,0xA5B0C2,0x88C0D0,0xB48EAD,0xEBCB8B,0x4C566A]
            case .light: return [0xFCFDFD,0xEEF2F1,0x24352D,0x60776B,0x247A57,0x7956A3,0xAA602E,0xD3E9DE]
            case .solarized: return [0xFDF6E3,0xEEE8D5,0x586E75,0x78878A,0x2A8578,0x6C71C4,0xCB4B16,0xE0DFC3]
            }
        }
    }
    static var profile: Profile {
        get { Profile(rawValue:UserDefaults.standard.string(forKey:"theme") ?? "") ?? .dark }
        set { UserDefaults.standard.set(newValue.rawValue,forKey:"theme") }
    }
    static func color(_ value: UInt32) -> NSColor { NSColor(calibratedRed:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:1) }
    static var canvas: NSColor { color(profile.colors[0]) }
    static var panel: NSColor { color(profile.colors[1]) }
    static var foreground: NSColor { color(profile.colors[2]) }
    static var secondary: NSColor { color(profile.colors[3]) }
    static var accent: NSColor { color(profile.colors[4]) }
    static var keyword: NSColor { color(profile.colors[5]) }
    static var number: NSColor { color(profile.colors[6]) }
    static var selection: NSColor { color(profile.colors[7]) }
    static var fontSize: CGFloat {
        get { let value = UserDefaults.standard.double(forKey: "editorFontSize"); return value == 0 ? 15 : max(11, min(30, value)) }
        set { UserDefaults.standard.set(newValue, forKey: "editorFontSize") }
    }
    static var editorFont: NSFont {
        let name = UserDefaults.standard.string(forKey:"editorFontFamily") ?? "SF Mono"
        return EditorFonts.resolve(name,size:fontSize) ?? .monospacedSystemFont(ofSize:fontSize,weight:.regular)
    }
    static func label(_ text: String, size: CGFloat = 13, color: NSColor = foreground, weight: NSFont.Weight = .regular) -> NSTextField {
        let v = ThemedLabel(labelWithString: L.text(text))
        v.role = color == secondary ? 1 : color == accent ? 2 : 0
        v.font = .systemFont(ofSize: size, weight: weight); v.textColor = color
        return v
    }
    static func button(_ symbol: String, help: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, target: target, action: action)
        b.title = ""; b.imagePosition = .imageOnly; b.identifier = NSUserInterfaceItemIdentifier("Linvell.iconButton")
        b.bezelStyle = .inline; b.isBordered = false; b.contentTintColor = secondary
        b.toolTip = L.text(help); b.setAccessibilityLabel(L.text(help))
        b.widthAnchor.constraint(equalToConstant: 32).isActive = true
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }
    static func actionButton(_ title: String,target: AnyObject,action: Selector) -> NSButton {
        let button = ActionButton(title:L.text(title),target:target,action:action)
        button.isBordered = false; button.setButtonType(.momentaryPushIn); button.font = .systemFont(ofSize:13,weight:.medium)
        return button
    }
    static func choiceButton() -> NSPopUpButton { ChoiceButton(frame:.zero,pullsDown:false) }
    static func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation = .horizontal, spacing: CGFloat = 10) -> NSStackView {
        let s = NSStackView(views: views); s.orientation = orientation; s.spacing = spacing; s.distribution = .fill; s.clipsToBounds = true
        s.alignment = orientation == .vertical ? .leading : .centerY
        if orientation == .vertical {
            for view in views { view.widthAnchor.constraint(equalTo:s.widthAnchor).isActive = true }
        }
        return s
    }
    static func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
}

private final class ChoiceButton: NSPopUpButton {
    override var intrinsicContentSize: NSSize {
        NSSize(width:min(300,max(160,((titleOfSelectedItem ?? "") as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13)]).width+46)),height:34)
    }
    override func draw(_ dirtyRect: NSRect) {
        let face = NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:6,yRadius:6)
        Theme.selection.setFill(); face.fill(); Theme.accent.withAlphaComponent(0.7).setStroke(); face.lineWidth = 1; face.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
        let title = titleOfSelectedItem ?? "",attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:13,weight:.medium),.foregroundColor:Theme.foreground,.paragraphStyle:paragraph]
        let size = (title as NSString).size(withAttributes:attributes)
        (title as NSString).draw(in:NSRect(x:12,y:(bounds.height-size.height)/2,width:max(0,bounds.width-46),height:size.height),withAttributes:attributes)
        let arrow = NSImage(systemSymbolName:"chevron.down",accessibilityDescription:nil)?.withSymbolConfiguration(.init(paletteColors:[Theme.accent]))
        arrow?.draw(in:NSRect(x:bounds.width-25,y:(bounds.height-12)/2,width:12,height:12),from:.zero,operation:.sourceOver,fraction:1)
    }
}

private final class ActionButton: NSButton {
    override var intrinsicContentSize: NSSize { NSSize(width:max(34,(title as NSString).size(withAttributes:[.font:font ?? NSFont.systemFont(ofSize:13)]).width+26),height:32) }
    override func draw(_ dirtyRect: NSRect) {
        let face = NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:6,yRadius:6)
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        (isHighlighted ? Theme.accent.withAlphaComponent(0.22) : Theme.selection.withAlphaComponent(0.65)).withAlphaComponent(alpha).setFill(); face.fill()
        Theme.accent.withAlphaComponent(isEnabled ? 0.65 : 0.25).setStroke(); face.lineWidth = 1; face.stroke()
        let attributes: [NSAttributedString.Key:Any] = [.font:font ?? NSFont.systemFont(ofSize:13),.foregroundColor:Theme.foreground.withAlphaComponent(alpha)]
        let size = (title as NSString).size(withAttributes:attributes)
        (title as NSString).draw(at:NSPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2),withAttributes:attributes)
        if window?.firstResponder === self { Theme.accent.setStroke(); let ring = NSBezierPath(roundedRect:bounds.insetBy(dx:3,dy:3),xRadius:4,yRadius:4); ring.lineWidth = 1; ring.stroke() }
    }
}

final class Surface: NSView {
    let isPanel: Bool
    init(_ color: NSColor) { isPanel = color == Theme.panel; super.init(frame: .zero); wantsLayer = true; clipsToBounds = true; layer?.masksToBounds = true; layer?.backgroundColor = color.cgColor }
    func refreshTheme() { layer?.backgroundColor = (isPanel ? Theme.panel : Theme.canvas).cgColor }
    required init?(coder: NSCoder) { fatalError() }
}

final class ThemedLabel: NSTextField {
    var role = 0
    func refreshTheme() { textColor = role == 1 ? Theme.secondary : role == 2 ? Theme.accent : Theme.foreground }
}
