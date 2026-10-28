import Foundation
import Darwin

/// A single compressed rollback, never another discoverable .app alongside the installation.
public enum RollbackArchive {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!.appendingPathComponent("Linvell/Rollback",isDirectory:true)
    }
    @discardableResult public static func retain(previous: URL,directory: URL = defaultDirectory) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let lock = open(directory.appendingPathComponent(".lock").path,O_CREAT|O_RDWR,0o600)
        guard lock >= 0,flock(lock,LOCK_EX) == 0 else { if lock >= 0 { close(lock) }; throw CocoaError(.fileWriteUnknown) }
        defer { flock(lock,LOCK_UN); close(lock) }
        let destination = directory.appendingPathComponent("PreviousVersion.zip")
        if !fm.fileExists(atPath:previous.path),fm.fileExists(atPath:destination.path) { return destination }
        let infoURL = previous.appendingPathComponent("Contents/Info.plist")
        let info = try PropertyListSerialization.propertyList(from:Data(contentsOf:infoURL),format:nil) as? [String:Any]
        guard previous.pathExtension == "app",info?["CFBundleIdentifier"] as? String == "top.fuluwa.linvell" else { throw UpdateFailure.untrustedPackage }
        try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let work = directory.appendingPathComponent(UUID().uuidString+".noindex",isDirectory:true)
        try fm.createDirectory(at:work,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? fm.removeItem(at:work) }
        let app = work.appendingPathComponent("Linvell.app"),pending = work.appendingPathComponent("PreviousVersion.zip")
        try fm.copyItem(at:previous,to:app)
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ditto"),arguments:["-c","-k","--sequesterRsrc","--keepParent",app.path,pending.path],directory:nil,timeout:120)
        guard result.succeeded else { throw CocoaError(.fileWriteUnknown) }
        // Verify the archived app's important bytes before removing the unpacked copy.
        let verify = work.appendingPathComponent("verify",isDirectory:true)
        let extracted = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ditto"),arguments:["-x","-k",pending.path,verify.path],directory:nil,timeout:120)
        guard extracted.succeeded else { throw CocoaError(.fileReadCorruptFile) }
        for item in ["Contents/Info.plist","Contents/MacOS/Linvell"] {
            guard try Data(contentsOf:app.appendingPathComponent(item)) == Data(contentsOf:verify.appendingPathComponent("Linvell.app/"+item)) else { throw CocoaError(.fileReadCorruptFile) }
        }
        guard rename(pending.path,destination.path) == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
        unregister(previous)
        try fm.removeItem(at:previous)
        return destination
    }
    private static func version(of application: URL) -> ReleaseVersion? {
        guard let data = try? Data(contentsOf:application.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],info["CFBundleIdentifier"] as? String == "top.fuluwa.linvell",
              let text = info["LinvellReleaseVersion"] as? String else { return nil }
        return ReleaseVersion(text)
    }
    public static func migrateLegacyCopies(beside application: URL,directory: URL = defaultDirectory) throws {
        guard let current = version(of:application) else { return }
        let candidates = ((try? FileManager.default.contentsOfDirectory(at:application.deletingLastPathComponent(),includingPropertiesForKeys:nil)) ?? []).compactMap { url -> (URL,ReleaseVersion)? in
            guard url.lastPathComponent.hasPrefix(".Linvell-previous-"),url.pathExtension == "app",
                  let data = try? Data(contentsOf:url.appendingPathComponent("Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],info["CFBundleIdentifier"] as? String == "top.fuluwa.linvell",
                  let text = info["LinvellReleaseVersion"] as? String,let version = ReleaseVersion(text),version < current else { return nil }
            return (url,version)
        }
        guard let previous = candidates.max(by:{ $0.1 < $1.1 })?.0 else { return }
        _ = try retain(previous:previous,directory:directory); removeLegacyCopies(beside:application)
    }
    public static func unregister(_ app: URL) {
        _ = try? ToolCommand.run(URL(fileURLWithPath:"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"),arguments:["-u",app.path],directory:nil)
    }
    public static func removeLegacyCopies(beside application: URL) {
        guard let current = version(of:application) else { return }
        let fm = FileManager.default,parent = application.deletingLastPathComponent()
        for url in (try? fm.contentsOfDirectory(at:parent,includingPropertiesForKeys:nil)) ?? [] where url.lastPathComponent.hasPrefix(".Linvell-previous-") && url.pathExtension == "app" {
            guard let data = try? Data(contentsOf:url.appendingPathComponent("Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],info["CFBundleIdentifier"] as? String == "top.fuluwa.linvell",
                  let candidate = version(of:url),candidate < current else { continue }
            unregister(url); try? fm.removeItem(at:url)
        }
    }
}
