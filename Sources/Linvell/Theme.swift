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
        return name == "SF Mono" ? .monospacedSystemFont(ofSize:fontSize,weight:.regular) : NSFont(name:name,size:fontSize) ?? .monospacedSystemFont(ofSize:fontSize,weight:.regular)
    }
    static func label(_ text: String, size: CGFloat = 13, color: NSColor = foreground, weight: NSFont.Weight = .regular) -> NSTextField {
        let v = ThemedLabel(labelWithString: text)
        v.role = color == secondary ? 1 : color == accent ? 2 : 0
        v.font = .systemFont(ofSize: size, weight: weight); v.textColor = color
        return v
    }
    static func button(_ symbol: String, help: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, target: target, action: action)
        b.bezelStyle = .inline; b.isBordered = false; b.contentTintColor = secondary
        b.toolTip = help; b.setAccessibilityLabel(help)
        b.widthAnchor.constraint(equalToConstant: 32).isActive = true
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }
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
