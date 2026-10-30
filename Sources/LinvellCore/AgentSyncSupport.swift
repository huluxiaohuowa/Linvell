import Foundation

/// Discovery only. An installed CLI does not prove that a project has synchronized.
public struct AgentSyncSupport: Equatable {
    public let executable: String?
    public static let installCommand = "brew install mutagen-io/mutagen/mutagen"
    public static let installationGuide = URL(string:"https://mutagen.io/documentation/introduction/installation/")!
    public static func detect(environment: [String:String] = AgentCLI.environment) -> AgentSyncSupport {
        let fm = FileManager.default
        let path = (environment["PATH"] ?? "").split(separator:":").map { URL(fileURLWithPath:String($0)).appendingPathComponent("mutagen").path }.first { path in
            var directory: ObjCBool = false
            return fm.fileExists(atPath:path,isDirectory:&directory) && !directory.boolValue && fm.isExecutableFile(atPath:path)
        }
        return AgentSyncSupport(executable:path)
    }
}
