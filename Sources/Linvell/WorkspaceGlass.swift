import AppKit

enum WorkspaceGlass {
    static let opacityKey = "workspaceGlassOpacity"
    static let opacityChanged = Notification.Name("Linvell.workspaceGlassOpacityChanged")

    static var opacity: Int {
        let stored = UserDefaults.standard.object(forKey:opacityKey) as? Int ?? 90
        return min(100,max(0,stored))
    }

    static func setOpacity(_ opacity: Int) {
        UserDefaults.standard.set(min(100,max(0,opacity)),forKey:opacityKey)
        NotificationCenter.default.post(name:opacityChanged,object:nil)
    }

    static func surface(containing content: NSView, radius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.contentView = content
            return glass
        }
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .withinWindow
        material.wantsLayer = true
        material.layer?.cornerRadius = radius
        material.layer?.masksToBounds = true
        Theme.pin(content,in:material)
        return material
    }

    static func tintEditor(_ surface: NSView, workspace: Bool = false) {
        let clear = workspace && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.style = clear ? .clear : .regular
            glass.tintColor = clear ? NSColor.clear : Theme.canvas.withAlphaComponent(Theme.isDark ? 0.60 : 0.52)
        } else {
            surface.layer?.backgroundColor = Theme.canvas.withAlphaComponent(clear ? 0.04 : 1).cgColor
        }
    }

    static func icon(_ symbol: String, help: String, target: AnyObject, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)!
            .withSymbolConfiguration(.init(pointSize:13,weight:.medium))!
        let button = NSButton(image:image,target:target,action:action)
        button.identifier = .init("Linvell.iconButton")
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = Theme.liveSecondary
        button.toolTip = L.text(help)
        button.setAccessibilityLabel(L.text(help))
        button.widthAnchor.constraint(equalToConstant:26).isActive = true
        button.heightAnchor.constraint(equalToConstant:26).isActive = true
        return button
    }
}
