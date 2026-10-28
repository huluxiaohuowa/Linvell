import Foundation
import AppKit
import WebKit

enum L {
    static let languageKey = "interfaceLanguage"
    static let changed = Notification.Name("Linvell.InterfaceLanguageChanged")
    private static var capturedArguments = false
    private static var originalArgumentLanguages: Any?
    static func configureLaunchLanguage() {
        var domain = UserDefaults.standard.volatileDomain(forName:UserDefaults.argumentDomain)
        if !capturedArguments { originalArgumentLanguages = domain["AppleLanguages"]; capturedArguments = true }
        if let choice = UserDefaults.standard.string(forKey:languageKey),["en","zh-Hans"].contains(choice) { domain["AppleLanguages"] = [choice] }
        else { domain["AppleLanguages"] = originalArgumentLanguages }
        UserDefaults.standard.setVolatileDomain(domain,forName:UserDefaults.argumentDomain)
    }
    static var language: String {
        let choice = UserDefaults.standard.string(forKey:languageKey) ?? "system"
        if ["en","zh-Hans"].contains(choice) { return choice }
        let preferences = UserDefaults.standard.stringArray(forKey:"AppleLanguages") ?? Locale.preferredLanguages
        return Bundle.preferredLocalizations(from:["en","zh-Hans"],forPreferences:preferences).first ?? "en"
    }
    static func text(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource:language,ofType:"lproj"),let bundle = Bundle(path:path) else { return key }
        return bundle.localizedString(forKey:key,value:key,table:nil)
    }
    static func format(_ key: String,_ values: CVarArg...) -> String { String(format:text(key),arguments:values) }
    private static let reverse: [String:String] = {
        var result: [String:String] = [:]
        for language in ["en","zh-Hans"] {
            guard let url = Bundle.main.url(forResource:"Localizable",withExtension:"strings",subdirectory:nil,localization:language),
                  let data = try? Data(contentsOf:url),let values = try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:String] else { continue }
            for (key,value) in values { result[value] = key; result[key] = key }
        }
        return result
    }()
    static func existing(_ value: String) -> String { text(reverse[value] ?? value) }
    static func apply(to view: NSView) {
        guard !(view is NSTextView),!(view is WKWebView),!(view is NSOutlineView),!(view is NSTableView) else { return }
        if let popup = view as? NSPopUpButton { popup.itemArray.forEach { $0.title = existing($0.title) } }
        else if let button = view as? NSButton,!["tabClicked:","closeTab:"].contains(button.action.map(NSStringFromSelector) ?? "") {
            if button.identifier?.rawValue == "Linvell.iconButton" { button.title = ""; button.imagePosition = .imageOnly }
            else if button.imagePosition != .imageOnly {
                let position = button.imagePosition; button.title = existing(button.title); button.imagePosition = position
            }
        }
        if let field = view as? NSTextField {
            if !field.isEditable { field.stringValue = existing(field.stringValue) }
            if let placeholder = field.placeholderString { field.placeholderString = existing(placeholder) }
        }
        if let segments = view as? NSSegmentedControl {
            for index in 0..<segments.segmentCount { if let label = segments.label(forSegment:index) { segments.setLabel(existing(label),forSegment:index) } }
        }
        if let tip = view.toolTip { view.toolTip = existing(tip) }
        if let button = view as? NSButton,button.identifier?.rawValue == "Linvell.iconButton",let tip = button.toolTip { button.setAccessibilityLabel(tip) }
        view.needsDisplay = true
        // Native controls own their private search buttons, popup arrows and text cells.
        guard !(view is NSControl) else { return }
        view.subviews.forEach { apply(to:$0) }
    }
}
