import AppKit
import LinvellCore
import LinvellPluginKit

enum Theme {
    enum Profile: String, CaseIterable {
        case dark = "Linvell Dark", nord = "Nord", light = "Linvell Light", solarized = "Solarized Light"
        case catppuccinLatte = "Catppuccin Latte", catppuccinMocha = "Catppuccin Mocha"
        case tokyoNightDay = "Tokyo Night Day", tokyoNight = "Tokyo Night"
        case rosePineDawn = "Rosé Pine Dawn", rosePine = "Rosé Pine"
        case dracula = "Dracula", alucard = "Alucard"
        case seaGlass = "Linvell Sea Glass", ember = "Linvell Ember"

        case oneLight = "Atom One Light"
        case oneDark = "Atom One Dark"
        case githubLight = "GitHub Light"
        case githubDark = "GitHub Dark"
        case xcodeLight = "Xcode Light"
        case xcodeDark = "Xcode Dark"
        case gruvboxLight = "Gruvbox Light"
        case gruvboxDark = "Gruvbox Dark"
        case solarizedDark = "Solarized Dark"

        var isDark: Bool {
            switch self {
            case .light, .solarized, .catppuccinLatte, .tokyoNightDay, .rosePineDawn, .alucard, .seaGlass, .oneLight, .githubLight, .xcodeLight, .gruvboxLight: return false
            default: return true
            }
        }
        var colors: [UInt32] {
            switch self {
            case .dark: return [0x131A20,0x1B242C,0xD9E3E8,0x899BA6,0x6BD3AB,0xB8A3F2,0xF0BA78,0x2D4A50]
            case .nord: return [0x2E3440,0x3B4252,0xECEFF4,0xA5B0C2,0x88C0D0,0xB48EAD,0xEBCB8B,0x4C566A]
            case .light: return [0xFCFDFD,0xEEF2F1,0x24352D,0x60776B,0x247A57,0x7956A3,0xAA602E,0xD3E9DE]
            case .solarized: return [0xFDF6E3,0xEEE8D5,0x586E75,0x78878A,0x2A8578,0x6C71C4,0xCB4B16,0xE0DFC3]
            case .catppuccinLatte: return [0xEFF1F5,0xE6E9EF,0x4C4F69,0x656A81,0x245AA9,0x8839EF,0xAD440D,0xD5DBED]
            case .catppuccinMocha: return [0x1E1E2E,0x28283B,0xCDD6F4,0x9399B2,0x89B4FA,0xCBA6F7,0xFAB387,0x3C4160]
            case .tokyoNightDay: return [0xE8EAF2,0xDDE1EE,0x343B58,0x586184,0x275CA8,0x7741C2,0x995100,0xCCD6F0]
            case .tokyoNight: return [0x1A1B26,0x24283B,0xC0CAF5,0x929BC2,0x7AA2F7,0xBB9AF7,0xFF9E64,0x33456A]
            case .rosePineDawn: return [0xFAF4ED,0xF2E9E1,0x575279,0x706782,0x286983,0x286983,0xA14E65,0xE8D9E1]
            case .rosePine: return [0x191724,0x26233A,0xE0DEF4,0xA19CB6,0x9CCFD8,0x82BBD4,0xEB6F92,0x41344F]
            case .dracula: return [0x282A36,0x343746,0xF8F8F2,0xA6AFCE,0x8BE9FD,0xFF79C6,0xBD93F9,0x454A64]
            case .alucard: return [0xFFFBEB,0xF2E9CF,0x27252A,0x6C664B,0x036A96,0xA3144D,0x644AC9,0xE4D9B7]
            case .seaGlass: return [0xF0F8F7,0xE0F0ED,0x173C42,0x49676D,0x006F72,0x7140A0,0x9A4C28,0xCBE8E2]
            case .ember: return [0x211B20,0x2E252B,0xF5E6DE,0xBDA5A9,0xF2B17D,0xF3A9C3,0xF6C879,0x513845]
            case .oneLight: return [0xFAFAFA,0xF0F0F0,0x383A42,0x676C78,0x245CAA,0xA626A4,0x986801,0xDCE8F8]
            case .oneDark: return [0x282C34,0x30353F,0xABB2BF,0x9DA5B3,0x61AFEF,0xC678DD,0xD19A66,0x3E4C64]
            case .githubLight: return [0xFFFFFF,0xF6F8FA,0x24292F,0x57606A,0x0969DA,0xCF222E,0x0550AE,0xDDF4FF]
            case .githubDark: return [0x0D1117,0x161B22,0xE6EDF3,0x9CA7B5,0x58A6FF,0xFF7B72,0x79C0FF,0x253B58]
            case .xcodeLight: return [0xFFFFFF,0xF0F3F6,0x242834,0x606578,0x1146B3,0xAC3261,0x286DAB,0xD8E7FC]
            case .xcodeDark: return [0x1F2430,0x282E3D,0xE7EAF3,0xA2AAC4,0x78A9F4,0xED80A8,0xDE9F2E,0x3A4C70]
            case .gruvboxLight: return [0xFBF1C7,0xF2E5BC,0x3C3836,0x6B5B4D,0x076678,0x9D0006,0x8F3F71,0xE5D5A7]
            case .gruvboxDark: return [0x282828,0x32302F,0xEBDBB2,0xA89984,0x83A598,0xFB4934,0xD3869B,0x504945]
            case .solarizedDark: return [0x002B36,0x073642,0x93A1A1,0x839496,0x62AFE0,0xB2BE48,0xE483AF,0x174653]
            }
        }
    }
    private static var pluginPalette: [UInt32]?
    static var pluginTheme: (UUID,PluginTheme)? { didSet {
        pluginPalette = pluginTheme.map { entry in PluginContributions.colorKeys.map { UInt32(entry.1.colors[$0]!.dropFirst(),radix:16)! } }
    } }
    static var isDark: Bool { pluginTheme?.1.isDark ?? profile.isDark }
    static var palette: [UInt32] { pluginPalette ?? profile.colors }
    static var profile: Profile {
        get { Profile(rawValue:UserDefaults.standard.string(forKey:"theme") ?? "") ?? .dark }
        set { pluginTheme = nil; UserDefaults.standard.set(newValue.rawValue,forKey:"theme") }
    }
    static func selectProfile(_ value: Profile,store: PluginStore) {
        profile = value
        DispatchQueue.global(qos:.utility).async { try? store.selectTheme(plugin:nil,id:nil) }
        PreferencesSync.shared.changed()
    }
    static func color(_ value: UInt32) -> NSColor { NSColor(calibratedRed:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:1) }
    static var canvas: NSColor { color(palette[0]) }
    static var panel: NSColor { color(palette[1]) }
    static var foreground: NSColor { color(palette[2]) }
    static var secondary: NSColor { color(palette[3]) }
    static var accent: NSColor { color(palette[4]) }
    static var keyword: NSColor { color(palette[5]) }
    static var number: NSColor { color(palette[6]) }
    static var selection: NSColor { color(palette[7]) }
    static func syntaxHex(_ kind: SourceTokenKind, palette: [UInt32], profile: Profile?) -> UInt32 {
        switch kind {
        case .keyword: return palette[5]
        case .number: return palette[6]
        case .comment: return palette[3]
        default: break
        }
        guard let profile else { return kind == .string ? palette[4] : palette[5] }
        // Strings, types, directives. Theme-specific tones are also used in Markdown.
        let tones: (UInt32,UInt32,UInt32)
        switch profile {
        case .dark: tones = (0xA6CC91,0x83C6EA,0xED97AA)
        case .light: tones = (0x386D3C,0x255E91,0xA83D65)
        case .nord: tones = (0xA3BE8C,0x8FBCBB,0xEBCB8B)
        case .solarized: tones = (0x267B6F,0x2C6995,0xA6471A)
        case .catppuccinLatte: tones = (0x347524,0x8E5312,0xAB3E82)
        case .catppuccinMocha: tones = (0xA6E3A1,0xF9E2AF,0xF5C2E7)
        case .tokyoNightDay: tones = (0x4E6E32,0x007197,0x9B3C60)
        case .tokyoNight: tones = (0x9ECE6A,0x2AC3DE,0xE0AF68)
        case .rosePineDawn: tones = (0x8F5D16,0x3C6F79,0x8A6299)
        case .rosePine: tones = (0xF6C177,0x9CCFD8,0xC4A7E7)
        case .dracula: tones = (0xF1FA8C,0x8BE9FD,0xFFB86C)
        case .alucard: tones = (0x756014,0x036A96,0xA34D14)
        case .seaGlass: tones = (0x317043,0x236197,0x9E3F66)
        case .ember: tones = (0xBCD6A5,0x9BCED2,0xD5B6F1)
        case .oneLight: tones = (0x3A7438,0x8C5600,0xA626A4)
        case .oneDark: tones = (0x98C379,0xE5C07B,0xC678DD)
        case .githubLight: tones = (0x0A3069,0x953800,0xCF222E)
        case .githubDark: tones = (0xA5D6FF,0xFFA657,0xFF7B72)
        case .xcodeLight: tones = (0xB33421,0x853CC1,0x805F24)
        case .xcodeDark: tones = (0xEF8772,0xC793F7,0xDE9F2E)
        case .gruvboxLight: tones = (0x59600F,0x87550C,0xAF3A03)
        case .gruvboxDark: tones = (0xB8BB26,0xFABD2F,0xFE8019)
        case .solarizedDark: tones = (0x56C5AE,0xE2B853,0xF08357)
        }
        switch kind {
        case .string: return tones.0
        case .type: return tones.1
        default: return tones.2
        }
    }
    static func syntaxColor(_ kind: SourceTokenKind) -> NSColor {
        color(syntaxHex(kind,palette:palette,profile:pluginTheme == nil ? profile : nil))
    }
    static let defaultFontSize: CGFloat = 14
    static var fontSize: CGFloat {
        get { let value = UserDefaults.standard.double(forKey: "editorFontSize"); return value == 0 ? defaultFontSize : max(11, min(30, value)) }
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
        b.bezelStyle = .inline; b.isBordered = false; b.contentTintColor = liveSecondary
        b.toolTip = L.text(help); b.setAccessibilityLabel(L.text(help))
        b.widthAnchor.constraint(equalToConstant: 32).isActive = true
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }
    static func actionButton(_ title: String,target: AnyObject?,action: Selector?,primary: Bool = false) -> NSButton {
        let button = ActionButton(title:L.text(title),target:target,action:action)
        button.primary = primary
        button.isBordered = false; button.setButtonType(.momentaryPushIn); button.font = .systemFont(ofSize:12,weight:.medium)
        return button
    }
    static func choiceButton() -> NSPopUpButton {
        let popup = NSPopUpButton(frame:.zero,pullsDown:false)
        popup.controlSize = .regular
        stylePopup(popup)
        popup.font = .systemFont(ofSize:13)
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant:96).isActive = true
        return popup
    }
    static func activityButton(_ symbol: String,help: String,target: AnyObject,action: Selector) -> NSButton {
        let button = ActivityIconButton(image:NSImage(systemSymbolName:symbol,accessibilityDescription:nil)!,target:target,action:action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""; button.imagePosition = .imageOnly; button.identifier = NSUserInterfaceItemIdentifier("Linvell.iconButton")
        button.isBordered = false; button.setButtonType(.pushOnPushOff); button.toolTip = L.text(help); button.setAccessibilityLabel(L.text(help))
        button.widthAnchor.constraint(equalToConstant:34).isActive = true; button.heightAnchor.constraint(equalToConstant:34).isActive = true
        return button
    }
    static func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation = .horizontal, spacing: CGFloat = 10) -> NSStackView {
        let s = NSStackView(views: views); s.orientation = orientation; s.spacing = spacing; s.distribution = .fill; s.clipsToBounds = true
        s.alignment = orientation == .vertical ? .leading : .centerY
        if orientation == .vertical {
            for view in views { view.widthAnchor.constraint(equalTo:s.widthAnchor).isActive = true }
        }
        return s
    }
    static func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0, positioned: NSWindow.OrderingMode = .above) {
        // Detached containers need a viable provisional size before AppKit installs constraints.
        if parent.frame.width == 0 || parent.frame.height == 0 {
            parent.setFrameSize(NSSize(width:parent.frame.width == 0 ? 1200 : parent.frame.width,
                                       height:parent.frame.height == 0 ? 800 : parent.frame.height))
        }
        child.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(child,positioned:positioned,relativeTo:nil)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
}

private final class ActivityIconButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        if state == .on {
            Theme.accent.withAlphaComponent(0.16).setFill(); NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:7,yRadius:7).fill()
        }
        super.draw(dirtyRect)
    }
}

private final class ActionButton: NSButton {
    var primary = false
    override var intrinsicContentSize: NSSize {
        NSSize(width:max(32,(title as NSString).size(withAttributes:[.font:font ?? NSFont.systemFont(ofSize:12)]).width+22),height:28)
    }
    override func draw(_ dirtyRect: NSRect) {
        let face = NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:8,yRadius:8)
        let fill = isHighlighted || primary ? Theme.accent : Theme.foreground
        let opacity: CGFloat = isEnabled ? (isHighlighted ? 0.28 : primary ? 0.18 : 0.07) : 0.035
        fill.withAlphaComponent(opacity).setFill()
        face.fill()
        Theme.foreground.withAlphaComponent(isEnabled ? 0.10 : 0.045).setStroke()
        face.lineWidth = 1
        face.stroke()
        let foreground = primary && isEnabled ? Theme.accent : Theme.foreground
        let attributes: [NSAttributedString.Key:Any] = [
            .font:font ?? NSFont.systemFont(ofSize:12),
            .foregroundColor:foreground.withAlphaComponent(isEnabled ? 1 : 0.42)
        ]
        let size = (title as NSString).size(withAttributes:attributes)
        (title as NSString).draw(at:NSPoint(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2),withAttributes:attributes)
        if window?.firstResponder === self {
            Theme.accent.setStroke()
            face.stroke()
        }
    }
}

class Surface: NSView {
    let isPanel: Bool
    init(_ color: NSColor) { isPanel = color == Theme.panel; super.init(frame: .zero); wantsLayer = true; clipsToBounds = true; layer?.masksToBounds = true; layer?.backgroundColor = color.cgColor }
    func refreshTheme() { layer?.backgroundColor = (isPanel ? Theme.panel : Theme.canvas).cgColor }
    required init?(coder: NSCoder) { fatalError() }
}

final class ThemedLabel: NSTextField {
    var role = 0
    func refreshTheme() { textColor = role == 1 ? Theme.secondary : role == 2 ? Theme.accent : Theme.foreground }
}
