import AppKit

extension Theme {
    static var appearance: NSAppearance? { NSAppearance(named:isDark ? .darkAqua : .aqua) }

    static func openPanel() -> NSOpenPanel { let panel = NSOpenPanel(); panel.appearance = appearance; return panel }
    static func savePanel() -> NSSavePanel { let panel = NSSavePanel(); panel.appearance = appearance; return panel }

    static func errorAlert(_ error: Error) -> NSAlert {
        let alert = NSAlert(error:error)
        alert.window.appearance = appearance
        return alert
    }

    static func searchField() -> NSSearchField {
        let field = NSSearchField()
        field.controlSize = .small
        field.font = .systemFont(ofSize:12)
        styleInput(field)
        return field
    }

    static func stylePopup(_ popup: NSPopUpButton) {
        popup.bezelStyle = .rounded
        popup.bezelColor = livePanel
        if #available(macOS 26.0, *) { popup.tintProminence = .none }
    }

    static func placeholder(_ title: String) -> NSAttributedString {
        NSAttributedString(string:L.text(title),attributes:[.foregroundColor:liveSecondary])
    }

    static func styleInput(_ field: NSTextField) {
        field.textColor = liveForeground
        field.backgroundColor = livePanel
        field.drawsBackground = true
        field.focusRingType = .default
    }

    static func segmented(_ labels: [String]) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels:labels,trackingMode:.selectOne,target:nil,action:nil)
        control.controlSize = .small
        control.segmentStyle = .capsule
        control.selectedSegmentBezelColor = liveSelection
        return control
    }

    static func refreshViews(_ root: NSView) {
        (root as? Surface)?.refreshTheme()
        (root as? ThemedLabel)?.refreshTheme()
        if let popup = root as? NSPopUpButton { stylePopup(popup) }
        if let field = root as? NSTextField, field.isEditable { styleInput(field) }
        if let segments = root as? NSSegmentedControl { segments.selectedSegmentBezelColor = Theme.selection }
        root.needsDisplay = true
        // Native controls handle their own internal views.
        if !(root is NSControl) { root.subviews.forEach(refreshViews) }
    }

    static let liveCanvas = NSColor(name:nil) { _ in Theme.canvas }
    static let liveSecondary = NSColor(name:nil) { _ in Theme.secondary }
    static let liveAccent = NSColor(name:nil) { _ in Theme.accent }
    static let liveForeground = NSColor(name:nil) { _ in Theme.foreground }
    static let livePanel = NSColor(name:nil) { _ in Theme.panel }
    static let liveSelection = NSColor(name:nil) { _ in Theme.selection }
}

/// Applies the current palette to application-owned windows and sheets.
enum ThemedWindow {
    private static let windows = NSMapTable<NSWindow,NSNumber>.weakToStrongObjects()

    static func install(_ window: NSWindow, panel: Bool = false) {
        windows.setObject(NSNumber(value:panel),forKey:window)
        apply(window,panel:panel)
    }

    static func refreshAll() {
        for window in windows.keyEnumerator().allObjects.compactMap({ $0 as? NSWindow }) {
            apply(window,panel:windows.object(forKey:window)?.boolValue == true)
            if let content = window.contentView { Theme.refreshViews(content) }
        }
    }

    private static func apply(_ window: NSWindow,panel: Bool) {
        window.appearance = Theme.appearance
        window.backgroundColor = panel ? Theme.panel : Theme.canvas
    }
}

/// Keep native alert layout and button semantics, including modal alerts without a parent.
final class ThemedAlert: NSAlert {
    override func runModal() -> NSApplication.ModalResponse {
        prepare()
        return super.runModal()
    }

    override func beginSheetModal(for sheetWindow: NSWindow, completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        prepare()
        super.beginSheetModal(for:sheetWindow,completionHandler:handler)
    }

    private func prepare() {
        window.appearance = Theme.appearance
        if let accessoryView { Theme.refreshViews(accessoryView) }
    }
}
