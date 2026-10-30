import Foundation

public enum UpdateInstallationSource: Equatable {
    case direct
    case homebrew(tap: String?)

    public var supportsSelfUpdates: Bool { self == .direct }
    public var upgradeCommand: String? {
        guard case .homebrew(let tap) = self else { return nil }
        let cask = tap.map { $0 == "homebrew/cask" ? "linvell" : $0+"/linvell" } ?? "linvell"
        return "brew upgrade --cask "+cask
    }
    public var metadataURL: URL? {
        switch self {
        case .homebrew(tap:"homebrew/cask"):
            return URL(string:"https://formulae.brew.sh/api/cask/linvell.json")
        case .homebrew(tap:"huluxiaohuowa/tap"):
            return URL(string:"https://raw.githubusercontent.com/huluxiaohuowa/homebrew-tap/main/Casks/linvell.rb")
        default: return nil
        }
    }
    public func availableVersion(in data: Data) -> String? {
        let value: String?
        switch self {
        case .homebrew(tap:"homebrew/cask"):
            value = (try? JSONSerialization.jsonObject(with:data) as? [String:Any])?["version"] as? String
        case .homebrew(tap:"huluxiaohuowa/tap"):
            guard let text = String(data:data,encoding:.utf8),let range = text.range(of:#"(?m)^\s*version "(\d+\.\d+\.\d+)"\s*$"#,options:.regularExpression) else { return nil }
            value = text[range].split(separator:"\"").dropFirst().first.map(String.init)
        default: return nil
        }
        guard let value,let version = ReleaseVersion(value),version.prerelease.isEmpty else { return nil }
        return value
    }
    /// Match the actual app artifact, not merely the presence of Homebrew on the Mac.
    public static func detect(application: URL = Bundle.main.bundleURL,prefixes: [URL]? = nil) -> Self {
        var defaults = ["/opt/homebrew","/usr/local"]
        if let custom = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"],custom.hasPrefix("/") { defaults.insert(custom,at:0) }
        let fm = FileManager.default,current = application.resolvingSymlinksInPath().standardizedFileURL
        for prefix in prefixes ?? defaults.map({ URL(fileURLWithPath:$0,isDirectory:true) }) {
            let cask = prefix.appendingPathComponent("Caskroom/linvell",isDirectory:true)
            guard let versions = try? fm.contentsOfDirectory(at:cask,includingPropertiesForKeys:nil,options:.skipsHiddenFiles),
                  versions.contains(where:{ version in
                      let artifact = version.appendingPathComponent("Linvell.app",isDirectory:true)
                      return fm.fileExists(atPath:artifact.path) && artifact.resolvingSymlinksInPath().standardizedFileURL == current
                  }) else { continue }
            let receipt = cask.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
            if let data = try? Data(contentsOf:receipt),
               let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
               let source = object["source"] as? [String:Any],let tap = source["tap"] as? String,
               tap.range(of:#"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$"#,options:.regularExpression) != nil {
                return .homebrew(tap:tap)
            }
            // A damaged receipt must not let the in-app updater overwrite a managed app.
            return .homebrew(tap:nil)
        }
        return .direct
    }
}
