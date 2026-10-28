import AppKit
import Foundation
import CryptoKit
import LinvellCore

final class UpdateManager {
    static let shared = UpdateManager()
    static let changed = Notification.Name("Linvell.UpdateStatusChanged")
    struct Prepared: Codable { let tag: String; let replacement: URL }
    private(set) var status = "Updates are delivered through GitHub Releases."
    private(set) var offer: UpdateOffer?
    private(set) var prepared: Prepared?
    private(set) var busy = false
    private(set) var installRequested = false
    private var timer: Timer?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        return URLSession(configuration:config)
    }()
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey:"LinvellReleaseVersion") as? String ?? "0.1.0-preview.2" }
    var automaticChecks: Bool {
        get { UserDefaults.standard.object(forKey:"updateAutomaticChecks") == nil || UserDefaults.standard.bool(forKey:"updateAutomaticChecks") }
        set { UserDefaults.standard.set(newValue,forKey:"updateAutomaticChecks"); notify() }
    }
    var automaticDownloads: Bool {
        get { UserDefaults.standard.bool(forKey:"updateAutomaticDownloads") }
        set { UserDefaults.standard.set(newValue,forKey:"updateAutomaticDownloads"); notify() }
    }
    var automaticInstall: Bool {
        get { UserDefaults.standard.bool(forKey:"updateAutomaticInstall") }
        set { UserDefaults.standard.set(newValue,forKey:"updateAutomaticInstall"); notify() }
    }
    var includePreviews: Bool {
        get { UserDefaults.standard.object(forKey:"updateIncludePreviews") == nil ? !((ReleaseVersion(Self.currentVersion)?.prerelease.isEmpty) ?? true) : UserDefaults.standard.bool(forKey:"updateIncludePreviews") }
        set { UserDefaults.standard.set(newValue,forKey:"updateIncludePreviews"); offer = nil; notify() }
    }
    var shouldInstallOnQuit: Bool { prepared != nil && (automaticInstall || installRequested) }
    private var directory: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Linvell/Updates",isDirectory:true) }
    func start() {
        if let data = UserDefaults.standard.data(forKey:"preparedUpdate"),let value = try? JSONDecoder().decode(Prepared.self,from:data),
           let next = ReleaseVersion(value.tag),let current = ReleaseVersion(Self.currentVersion),next > current,FileManager.default.fileExists(atPath:value.replacement.path) {
            prepared = value; status = "\(value.tag) is ready to install."
        } else { UserDefaults.standard.removeObject(forKey:"preparedUpdate") }
        timer = Timer.scheduledTimer(withTimeInterval:6*60*60,repeats:true) { [weak self] _ in self?.checkAutomatically() }
        DispatchQueue.main.asyncAfter(deadline:.now()+30) { [weak self] in self?.checkAutomatically() }
    }
    private func checkAutomatically() {
        guard automaticChecks else { return }
        let last = UserDefaults.standard.double(forKey:"updateLastChecked")
        if Date().timeIntervalSince1970-last >= 6*60*60 { check() }
    }
    private func notify() { NotificationCenter.default.post(name:Self.changed,object:nil) }
    private func setStatus(_ value: String) { status = value; notify() }
    func check() {
        guard !busy else { return }; busy = true; setStatus("Checking GitHub Releases…")
        let previews = includePreviews
        Task { @MainActor in
            do {
                var request = URLRequest(url:URL(string:"https://api.github.com/repos/huluxiaohuowa/Linvell/releases?per_page=100")!)
                request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
                request.setValue("Linvell/\(Self.currentVersion)",forHTTPHeaderField:"User-Agent")
                let (data,response) = try await session.data(for:request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,data.count < 4*1024*1024 else { throw UpdateFailure.invalidResponse }
                let releases = try JSONDecoder().decode([GitHubRelease].self,from:data)
                offer = UpdateOffer.select(releases,installed:Self.currentVersion,previews:previews)
                UserDefaults.standard.set(Date().timeIntervalSince1970,forKey:"updateLastChecked")
                busy = false
                setStatus(offer.map { "\($0.tag) is available." } ?? (prepared == nil ? "No newer eligible public release was found." : "\(prepared!.tag) is ready to install."))
                if offer != nil && automaticDownloads { download() }
            } catch { busy = false; setStatus("Could not check for updates. \(error.localizedDescription)") }
        }
    }
    func download() {
        guard !busy,let offer else { return }; busy = true; setStatus("Downloading \(offer.tag)…")
        Task { @MainActor in
            do {
                let (checksumData,response) = try await session.data(from:offer.checksum.browser_download_url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,checksumData.count < 64*1024,
                      let text = String(data:checksumData,encoding:.utf8),let expected = UpdateOffer.checksum(text,filename:offer.archive.name) else { throw UpdateFailure.invalidResponse }
                let root = directory.appendingPathComponent(UUID().uuidString,isDirectory:true)
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let zip = root.appendingPathComponent("update.zip")
                let receiver = BoundedDownload(destination:zip,limit:offer.archive.size)
                try await receiver.fetch(offer.archive.browser_download_url)
                setStatus("Verifying \(offer.tag)…")
                let current = Bundle.main.bundleURL
                let replacement: URL = try await Task.detached(priority:.utility) {
                    let bytes = try Data(contentsOf:zip,options:.mappedIfSafe)
                    guard bytes.count == offer.archive.size,Data(SHA256.hash(data:bytes)).map({ String(format:"%02x",$0) }).joined() == expected else { throw UpdateFailure.untrustedPackage }
                    if let digest = offer.archive.digest, digest.lowercased() != "sha256:"+expected { throw UpdateFailure.untrustedPackage }
                    try UpdateArchive.validate(bytes)
                    let extracted = root.appendingPathComponent("extracted",isDirectory:true)
                    let unzip = Process(); unzip.executableURL = URL(fileURLWithPath:"/usr/bin/ditto"); unzip.arguments = ["-xk",zip.path,extracted.path]
                    unzip.standardOutput = FileHandle.nullDevice; unzip.standardError = FileHandle.nullDevice
                    try unzip.run(); unzip.waitUntilExit()
                    guard unzip.terminationStatus == 0 else { throw UpdateFailure.invalidArchive }
                    let candidate = extracted.appendingPathComponent("Linvell.app")
                    try SignedUpdate.validate(current:current,candidate:candidate)
                    let info = try PropertyListSerialization.propertyList(from:Data(contentsOf:candidate.appendingPathComponent("Contents/Info.plist")),format:nil) as? [String:Any]
                    guard (info?["LinvellReleaseVersion"] as? String) == String(offer.tag.dropFirst(offer.tag.hasPrefix("v") ? 1 : 0)) else { throw UpdateFailure.untrustedPackage }
                    return candidate
                }.value
                prepared = Prepared(tag:offer.tag,replacement:replacement)
                UserDefaults.standard.set(try JSONEncoder().encode(prepared),forKey:"preparedUpdate")
                busy = false; setStatus("\(offer.tag) verified. " + (automaticInstall ? "It will install when Linvell quits." : "Ready to install and restart."))
            } catch { busy = false; setStatus("Update download was not accepted. \(error.localizedDescription)") }
        }
    }
    func requestInstall() {
        guard prepared != nil else { return }
        installRequested = true; NSApp.terminate(nil)
        // NSApplication may cancel termination when the user cancels a save/session dialog.
        installRequested = false
    }
    func scheduleInstallation() throws {
        guard let prepared else { return }
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard !current.path.hasPrefix("/Volumes/"),FileManager.default.isWritableFile(atPath:current.deletingLastPathComponent().path) else { throw UpdateFailure.notWritable }
        try SignedUpdate.validate(current:current,candidate:prepared.replacement)
        let helper = current.appendingPathComponent("Contents/Helpers/LinvellUpdater")
        guard FileManager.default.isExecutableFile(atPath:helper.path) else { throw UpdateFailure.untrustedPackage }
        let job = InstallJob(application:current,replacement:prepared.replacement,parentPID:getpid(),relaunch:installRequested)
        let jobURL = prepared.replacement.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("install-job.json")
        try JSONEncoder().encode(job).write(to:jobURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:jobURL.path)
        let process = Process(); process.executableURL = helper; process.arguments = [jobURL.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; try process.run()
    }
}

private final class BoundedDownload: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let limit: Int64
    private var continuation: CheckedContinuation<Void,Error>?
    private var downloadError: Error?
    private var session: URLSession?
    init(destination: URL,limit: Int64) { self.destination = destination; self.limit = limit }
    func fetch(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 600; config.httpCookieStorage = nil
            let session = URLSession(configuration:config,delegate:self,delegateQueue:nil); self.session = session
            session.downloadTask(with:url).resume()
        }
    }
    func urlSession(_ session: URLSession,downloadTask: URLSessionDownloadTask,didWriteData bytesWritten: Int64,totalBytesWritten: Int64,totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadError = UpdateFailure.invalidResponse; downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession,downloadTask: URLSessionDownloadTask,didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,(try location.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) == limit else { throw UpdateFailure.invalidResponse }
            try FileManager.default.moveItem(at:location,to:destination)
        } catch { downloadError = error }
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,didCompleteWithError error: Error?) {
        let result = downloadError ?? error
        if let result { continuation?.resume(throwing:result) } else { continuation?.resume() }
        continuation = nil; session.finishTasksAndInvalidate(); self.session = nil
    }
}
