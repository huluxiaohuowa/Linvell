import Foundation
import LinvellPluginKit

public enum PluginContributions {
    public static let colorKeys = ["canvas","panel","foreground","secondary","accent","keyword","number","selection"]
    public static func validID(_ value: String) -> Bool { value.utf8.count <= 128 && value.range(of:"\\A[A-Za-z0-9][A-Za-z0-9._-]*\\z",options:.regularExpression) != nil }
    public static func validate(_ manifest: PluginManifest,directory: URL) throws {
        let views = manifest.views ?? [],settings = manifest.settings ?? [],themes = manifest.themes ?? [],icons = manifest.icons ?? [],snippets = manifest.snippets ?? []
        let commands = Set(manifest.commands.map(\.id)),iconIDs = Set(icons.map(\.id))
        func unique(_ ids: [String],limit: Int) -> Bool { ids.count <= limit && Set(ids).count == ids.count && ids.allSatisfy(validID) }
        func title(_ value: String) -> Bool { !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && value.count <= 200 }
        func command(_ value: String?) -> Bool { value == nil || commands.contains(value!) }
        guard unique(views.map(\.id),limit:16),unique(themes.map(\.id),limit:16),unique(icons.map(\.id),limit:100),unique(snippets.map(\.id),limit:100),
              settings.count <= 32,Set(settings.map(\.key)).count == settings.count else { throw PluginError.invalidPackage }
        for icon in icons { guard (icon.fileExtensions?.count ?? 0) <= 100,icon.fileExtensions?.allSatisfy({ !$0.isEmpty && $0.count <= 32 && $0.range(of:"\\A[a-z0-9]+\\z",options:.regularExpression) != nil }) ?? true else { throw PluginError.invalidPackage }; guard (icon.path == nil) != (icon.symbol == nil),validID(icon.id) else { throw PluginError.invalidPackage }; if icon.path != nil { _ = try iconURL(icon,directory:directory) }; if let symbol = icon.symbol { guard !symbol.isEmpty,symbol.count <= 100 else { throw PluginError.invalidPackage } } }
        for view in views {
            guard title(view.title),command(view.command),command(view.refreshCommand),view.icon == nil || iconIDs.contains(view.icon!), (view.text?.utf8.count ?? 0) <= 64*1024 else { throw PluginError.invalidPackage }
            guard view.kind != .status || (view.text?.count ?? 0) <= 200 else { throw PluginError.invalidPackage }
            try validateItems(view.items ?? [],kind:view.kind,commands:commands,icons:iconIDs)
        }
        for setting in settings {
            guard validID(setting.key),title(setting.title),(setting.description?.count ?? 0) <= 1000 else { throw PluginError.invalidPackage }
            if setting.kind == .choice { guard let choices = setting.choices,!choices.isEmpty,choices.count <= 50,Set(choices).count == choices.count,choices.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else { throw PluginError.invalidPackage } }
            if let value = manifest.configuration?[setting.key] { try validateSetting(value,field:setting) }
        }
        for theme in themes { guard title(theme.title),Set(theme.colors.keys) == Set(colorKeys),theme.colors.values.allSatisfy({ $0.range(of:"\\A#[0-9a-fA-F]{6}\\z",options:.regularExpression) != nil }) else { throw PluginError.invalidPackage } }
        for snippet in snippets { guard title(snippet.title),(snippet.prefix?.count ?? 0) <= 64,(snippet.scope?.count ?? 0) <= 50,snippet.scope?.allSatisfy({ validID($0) }) ?? true else { throw PluginError.invalidPackage }; _ = try PluginSnippetExpansion(snippet.body) }
    }
    public static func validateSetting(_ value: PluginValue,field: PluginSetting) throws {
        switch (field.kind,value) {
        case (.string,.string(let text)): guard text.utf8.count <= 4096 else { throw PluginError.invalidState }
        case (.boolean,.bool): break
        case (.number,.number(let number)): guard number.isFinite else { throw PluginError.invalidState }
        case (.choice,.string(let option)): guard field.choices?.contains(option) == true else { throw PluginError.invalidState }
        default: throw PluginError.invalidState
        }
    }
    public static func validate(_ updates: [PluginViewUpdate],manifest: PluginManifest) throws {
        guard updates.count <= 16,Set(updates.map(\.id)).count == updates.count else { throw PluginError.invalidState }
        for update in updates {
            guard let view = manifest.views?.first(where:{ $0.id == update.id }),(update.text?.utf8.count ?? 0) <= 64*1024 else { throw PluginError.invalidState }
            guard view.kind != .status || (update.text?.count ?? 0) <= 200 else { throw PluginError.invalidState }
            try validateItems(update.items ?? [],kind:view.kind,commands:Set(manifest.commands.map(\.id)),icons:Set((manifest.icons ?? []).map(\.id)))
        }
    }
    private static func validateItems(_ items: [PluginItem],kind: PluginView.Kind,commands: Set<String>,icons: Set<String>) throws {
        var ids = Set<String>(),count = 0
        func visit(_ items: [PluginItem],depth: Int) throws {
            guard depth <= 16 else { throw PluginError.invalidState }
            for item in items {
                count += 1
                guard count <= 2000,validID(item.id),ids.insert(item.id).inserted,!item.title.isEmpty,item.title.count <= 200,(item.detail?.count ?? 0) <= 1000,
                      item.command == nil || commands.contains(item.command!),item.icon == nil || icons.contains(item.icon!),kind == .tree || (item.children ?? []).isEmpty else { throw PluginError.invalidState }
                try visit(item.children ?? [],depth:depth+1)
            }
        }
        guard kind != .status || items.isEmpty else { throw PluginError.invalidState }
        try visit(items,depth:0)
    }
    public static func iconURL(_ icon: PluginIcon,directory: URL) throws -> URL {
        guard let path = icon.path,!path.hasPrefix("/"),!path.split(separator:"/").contains("..") else { throw PluginError.invalidPackage }
        let file = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(directory.resolvingSymlinksInPath().path+"/"),file.pathExtension.lowercased() == "png",(try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])).isRegularFile == true,
              let size = try file.resourceValues(forKeys:[.fileSizeKey]).fileSize,size <= 1024*1024 else { throw PluginError.invalidPackage }
        let data = try Data(contentsOf:file)
        guard data.count >= 24,data.prefix(8) == Data([137,80,78,71,13,10,26,10]),String(data:data[12..<16],encoding:.ascii) == "IHDR" else { throw PluginError.invalidPackage }
        let width = data[16..<20].reduce(UInt32(0)) { $0<<8|UInt32($1) },height = data[20..<24].reduce(UInt32(0)) { $0<<8|UInt32($1) }
        guard width > 0,height > 0,width <= 1024,height <= 1024 else { throw PluginError.invalidPackage }; return file
    }
}
