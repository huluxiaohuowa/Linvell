import Foundation

/// Installation detection is advisory; only AgentPathMapping.validate proves a live mount.
public struct AgentMountSupport: Equatable {
    public let sshfs: String?
    public let macFUSEInstalled: Bool
    public static let installCommand = "brew install --cask sshfs-mac"
    public static let installationGuide = URL(string:"https://github.com/macfuse/macfuse/wiki/Getting-Started")!
    public static func detect(environment: [String:String] = AgentCLI.environment,filesystemRoot: URL = URL(fileURLWithPath:"/")) -> AgentMountSupport {
        let fm = FileManager.default
        let executable = (environment["PATH"] ?? "").components(separatedBy:":").filter { !$0.isEmpty }.map { URL(fileURLWithPath:$0).appendingPathComponent("sshfs").path }.first { path in
            var directory: ObjCBool = false
            return fm.fileExists(atPath:path,isDirectory:&directory) && !directory.boolValue && fm.isExecutableFile(atPath:path)
        }
        let installed = ["Library/Filesystems/macfuse.fs","Library/Filesystems/osxfuse.fs"].contains { fm.fileExists(atPath:filesystemRoot.appendingPathComponent($0).path) }
        return AgentMountSupport(sshfs:executable,macFUSEInstalled:installed)
    }
}
