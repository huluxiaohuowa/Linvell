import Foundation

public struct PluginItem: Codable, Equatable {
    public let id: String
    public let title: String
    public let detail: String?
    public let icon: String?
    public let command: String?
    public let children: [PluginItem]?
    public init(id: String,title: String,detail: String? = nil,icon: String? = nil,command: String? = nil,children: [PluginItem]? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.icon = icon; self.command = command; self.children = children
    }
}
public struct PluginView: Codable, Equatable {
    public enum Kind: String, Codable { case tree, list, status, panel }
    public let id: String
    public let title: String
    public let kind: Kind
    public let text: String?
    public let icon: String?
    public let command: String?
    public let refreshCommand: String?
    public let items: [PluginItem]?
}
public struct PluginViewUpdate: Codable, Equatable {
    public let id: String
    public let text: String?
    public let items: [PluginItem]?
    public init(id: String,text: String? = nil,items: [PluginItem]? = nil) { self.id = id; self.text = text; self.items = items }
}
public struct PluginUIEvent: Codable {
    public let viewID: String
    public let kind: String
    public let itemID: String?
    public init(viewID: String,kind: String,itemID: String? = nil) { self.viewID = viewID; self.kind = kind; self.itemID = itemID }
}
public struct PluginSetting: Codable, Equatable {
    public enum Kind: String, Codable { case string, boolean, number, choice }
    public let key: String
    public let title: String
    public let kind: Kind
    public let description: String?
    public let choices: [String]?
}
public struct PluginTheme: Codable, Equatable {
    public let id: String
    public let title: String
    public let isDark: Bool
    /// canvas, panel, foreground, secondary, accent, keyword, number, selection, each #RRGGBB.
    public let colors: [String:String]
}
public struct PluginIcon: Codable, Equatable {
    public let id: String
    public let path: String?
    public let symbol: String?
    public let fileExtensions: [String]?
}
public struct PluginSnippet: Codable, Equatable {
    public let id: String
    public let title: String
    public let prefix: String?
    public let scope: [String]?
    public let body: String
}
