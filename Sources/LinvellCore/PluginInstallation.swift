import Foundation
import LinvellPluginKit

public enum PluginInstallation {
    /// Run only after trust approval. Checks a command host handshake without invoking commands or document events.
    public static func checkStartup(_ package: PluginPackage,workspace: PluginWorkspace?) throws {
        let runtime = PluginRuntime(package:package,workspace:workspace);defer { runtime.stop() }
        let location = try runtime.prepare()
        let manifest = package.manifest
        let tools = (manifest.languageServers ?? []).map(\.program)+(manifest.tasks ?? []).map(\.program)+(manifest.debuggers ?? []).map(\.program)
        for program in tools { _ = try PluginTools.path(program,target:location.target) }
        guard package.executableURL != nil else { return }
        let rpc = try runtime.launch(PluginProgram(executable:manifest.executable,executables:manifest.executables))
        let reply = try rpc.request("initialize",params:["protocolVersion":1],timeout:10) as? [String:Any]
        guard reply?["protocolVersion"] as? Int == 1,(manifest.events ?? []).isEmpty || (reply?["capabilities"] as? [String] ?? []).contains("documentEvents") else { throw PluginError.unsupportedProtocol }
    }
}
