import AppKit

enum EditorFonts {
    struct Option { let title: String; let value: String }
    static func resolve(_ value: String,size: CGFloat) -> NSFont? {
        if value == "SF Mono" { return .monospacedSystemFont(ofSize:size,weight:.regular) }
        return NSFont(name:value,size:size) ?? NSFontManager.shared.font(withFamily:value,traits:[],weight:5,size:size)
    }
    static func installedMonospace(selected: String) -> [Option] {
        var options = [Option(title:"SF Mono",value:"SF Mono")]
        for family in NSFontManager.shared.availableFontFamilies.sorted(by:{ $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            guard let font = NSFontManager.shared.font(withFamily:family,traits:[],weight:5,size:14),
                  font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace) else { continue }
            options.append(Option(title:family,value:font.fontName))
        }
        let value = selected == "SF Mono" ? selected : resolve(selected,size:14)?.fontName ?? selected
        if !options.contains(where:{ $0.value == value }) {
            let title = resolve(selected,size:14)?.displayName ?? L.format("%@ (not installed)",selected)
            options.append(Option(title:title,value:selected))
        }
        return options
    }
}
