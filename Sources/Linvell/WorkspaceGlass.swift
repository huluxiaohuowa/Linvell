import AppKit

enum WorkspaceGlass {
    static func installWindowBackdrop(in window: NSWindow, root: NSView) {
        window.isOpaque = false
        window.backgroundColor = .clear
        let backdrop = NSVisualEffectView()
        backdrop.material = .menu
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        Theme.pin(backdrop,in:root,positioned:.below)
    }

    static func surface(containing content: NSView, radius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.contentView = content
            return glass
        }
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .withinWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = radius
        material.layer?.masksToBounds = true
        Theme.pin(content,in:material)
        return material
    }

    static func tintEditor(_ surface: NSView) {
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.style = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? .regular : .clear
            glass.tintColor = Theme.canvas.withAlphaComponent(Theme.isDark ? 0.16 : 0.10)
        }
    }

    static func group(_ content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.contentView = content
            return container
        }
        return content
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
