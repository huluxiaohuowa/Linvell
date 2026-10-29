import Foundation
import LinvellPluginKit

public enum PluginEdits {
    public static func apply(_ edits: [PluginTextEdit],to text: String) throws -> MultiEdit.Result {
        let count = text.utf16.count
        guard edits.count <= 1000,edits.reduce(0,{ $0+$1.text.utf8.count }) <= 2*1024*1024 else { throw DocumentError.invalidRange }
        let sorted = edits.sorted { $0.location < $1.location }
        var previousEnd = -1,previousStart = -1
        for edit in sorted {
            guard edit.location >= 0,edit.length >= 0,edit.location <= count,edit.length <= count-edit.location,
                  edit.location >= previousEnd,edit.location != previousStart else { throw DocumentError.invalidRange }
            previousStart = edit.location; previousEnd = edit.location+edit.length
        }
        let result = try MultiEdit.apply(sorted.map { NSRange(location:$0.location,length:$0.length) },replacements:sorted.map(\.text),to:text)
        guard result.text.utf8.count <= 2*1024*1024 else { throw DocumentError.invalidRange }
        return result
    }
}

public struct PluginKeybinding: Equatable {
    public let key: String
    public let modifiers: Set<String>
    public init(_ value: String) throws {
        let parts = value.lowercased().split(separator:"+",omittingEmptySubsequences:false).map(String.init)
        guard let key = parts.last,key.utf8.count == 1,key.range(of:"^[a-z0-9]$",options:.regularExpression) != nil else { throw PluginError.invalidPackage }
        let mods = Array(parts.dropLast())
        guard !mods.isEmpty,Set(mods).count == mods.count,Set(mods).isSubset(of:["cmd","ctrl","option","shift"]),mods.contains("cmd") || mods.contains("ctrl") else { throw PluginError.invalidPackage }
        self.key = key; modifiers = Set(mods)
    }
}
