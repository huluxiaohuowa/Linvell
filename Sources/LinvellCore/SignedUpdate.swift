import Foundation
import Security
import Darwin

public struct InstallJob: Codable {
    public let application: URL
    public let replacement: URL
    public let parentPID: Int32
    public let relaunch: Bool
    public let archive: URL?
    public init(application: URL,replacement: URL,parentPID: Int32,relaunch: Bool,archive: URL? = nil) {
        self.application = application; self.replacement = replacement; self.parentPID = parentPID; self.relaunch = relaunch; self.archive = archive
    }
    public func unpackArchive(jobURL: URL) throws {
        guard let archive else { return }
        let root = jobURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let expected = root.appendingPathComponent("extracted/Linvell.app")
        guard archive.resolvingSymlinksInPath().path == root.appendingPathComponent("update.zip").path,
              replacement.standardizedFileURL.path == expected.path,
              replacement.resolvingSymlinksInPath().path == expected.path,
              application.resolvingSymlinksInPath().path != expected.path else { throw UpdateFailure.invalidArchive }
        try UpdateArchive.validate(Data(contentsOf:archive,options:.mappedIfSafe))
        RollbackArchive.unregister(replacement)
        try? FileManager.default.removeItem(at:replacement.deletingLastPathComponent())
        do {
            let unpack = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ditto"),arguments:["-xk",archive.path,replacement.deletingLastPathComponent().path],directory:nil,timeout:120)
            guard unpack.succeeded else { throw UpdateFailure.invalidArchive }
        } catch {
            RollbackArchive.unregister(replacement)
            try? FileManager.default.removeItem(at:replacement)
            throw error
        }
    }
}

public enum SignedUpdate {
    public static func validate(current: URL,candidate: URL) throws {
        var currentCode: SecStaticCode?,newCode: SecStaticCode?,requirement: SecRequirement?,info: CFDictionary?
        guard SecStaticCodeCreateWithPath(current.resolvingSymlinksInPath() as CFURL,[],&currentCode) == errSecSuccess,
              SecStaticCodeCreateWithPath(candidate.resolvingSymlinksInPath() as CFURL,[],&newCode) == errSecSuccess,
              let currentCode,let newCode,
              SecCodeCopySigningInformation(currentCode,SecCSFlags(rawValue:kSecCSSigningInformation),&info) == errSecSuccess,
              let team = (info as? [String:Any])?[kSecCodeInfoTeamIdentifier as String] as? String,!team.isEmpty,
              SecCodeCopyDesignatedRequirement(currentCode,[],&requirement) == errSecSuccess,let requirement,
              SecStaticCodeCheckValidity(currentCode,SecCSFlags(rawValue:kSecCSStrictValidate|kSecCSCheckAllArchitectures),nil) == errSecSuccess,
              SecStaticCodeCheckValidity(newCode,SecCSFlags(rawValue:kSecCSStrictValidate|kSecCSCheckAllArchitectures),requirement) == errSecSuccess else { throw UpdateFailure.untrustedPackage }
        let old = try plist(current),new = try plist(candidate)
        guard old["CFBundleIdentifier"] as? String == "top.fuluwa.linvell",new["CFBundleIdentifier"] as? String == "top.fuluwa.linvell",
              let ov = old["LinvellReleaseVersion"] as? String,let nv = new["LinvellReleaseVersion"] as? String,
              let oldVersion = ReleaseVersion(ov),let newVersion = ReleaseVersion(nv),newVersion > oldVersion,
              let minimum = new["LSMinimumSystemVersion"] as? String else { throw UpdateFailure.untrustedPackage }
        let pieces = minimum.split(separator:".").compactMap { Int($0) }
        guard pieces.count >= 2,ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion:pieces[0],minorVersion:pieces[1],patchVersion:pieces.count > 2 ? pieces[2] : 0)) else { throw UpdateFailure.untrustedPackage }
    }
    private static func plist(_ app: URL) throws -> [String:Any] {
        let data = try Data(contentsOf:app.appendingPathComponent("Contents/Info.plist"))
        guard let values = try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any] else { throw UpdateFailure.untrustedPackage }
        return values
    }
    /// Copies alongside the target, verifies again, then swaps directories atomically on the same volume.
    /// The previous version is retained at the returned URL for recovery.
    public static func install(current: URL,candidate: URL) throws -> URL {
        let current = current.resolvingSymlinksInPath(),parent = current.deletingLastPathComponent()
        guard current.pathExtension == "app",!current.path.hasPrefix("/Volumes/"),FileManager.default.isWritableFile(atPath:parent.path) else { throw UpdateFailure.notWritable }
        try validate(current:current,candidate:candidate)
        let stage = parent.appendingPathComponent(".Linvell-previous-\(UUID().uuidString).app")
        var installed = false
        defer {
            RollbackArchive.unregister(candidate)
            RollbackArchive.unregister(stage)
            if installed {
                _ = try? ToolCommand.run(URL(fileURLWithPath:"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"),arguments:["-f",current.path],directory:nil)
            }
        }
        try FileManager.default.copyItem(at:candidate,to:stage)
        do {
            try validate(current:current,candidate:stage)
            let assessment = Process(); assessment.executableURL = URL(fileURLWithPath:"/usr/sbin/spctl"); assessment.arguments = ["--assess","--type","execute",stage.path]
            assessment.standardOutput = FileHandle.nullDevice; assessment.standardError = FileHandle.nullDevice
            try assessment.run(); assessment.waitUntilExit()
            guard assessment.terminationStatus == 0 else { throw UpdateFailure.untrustedPackage }
            guard renameatx_np(AT_FDCWD,stage.path,AT_FDCWD,current.path,UInt32(RENAME_SWAP)) == 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
            installed = true
            return stage
        } catch {
            RollbackArchive.unregister(stage)
            try? FileManager.default.removeItem(at:stage); throw error
        }
    }
}
