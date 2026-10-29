import Foundation

/// A program bundled with the package. Arguments are argv, never shell fragments.
public struct PluginProgram: Codable, Equatable {
    public let executable: String?
    /// Keys: macos-arm64, macos-x86_64, linux-aarch64, linux-x86_64.
    public let executables: [String:String]?
    public let arguments: [String]?
    public init(executable: String? = nil,executables: [String:String]? = nil,arguments: [String] = []) { self.executable = executable; self.executables = executables; self.arguments = arguments }
}
public struct PluginLanguageServer: Codable, Equatable {
    public let id: String,title: String
    public let languages: [String]
    public let fileExtensions: [String]?
    public let program: PluginProgram
    public let settings: [String:PluginValue]?
}
public struct PluginTask: Codable, Equatable {
    public let id: String,title: String
    public let program: PluginProgram
}
public struct PluginDebugger: Codable, Equatable {
    public let id: String,title: String
    public let program: PluginProgram
    /// DAP launch request parameters. ${workspaceFolder} expands recursively.
    public let launch: [String:PluginValue]
}
public struct PluginLog: Codable {
    public let level: String,message: String
    public init(level: String = "info",message: String) { self.level = level; self.message = message }
}
