import AppKit
import Foundation
import CryptoKit
import LinvellCore

final class UpdateManager {
    static let shared = UpdateManager()
    static let changed = Notification.Name("Linvell.UpdateStatusChanged")
    struct Prepared: Codable { let tag: String; let replacement: URL }
    private var statusKey = "Updates are delivered through GitHub Releases."
    private var statusValues: [CVarArg] = []
    var status: String { String(format:L.text(statusKey),arguments:statusValues.map { ($0 as? String).map(L.existing) ?? $0 }) }
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
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey:"LinvellReleaseVersion") as? String ?? "0.0.0" }
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
           UpdateStaging.owns(candidate:value.replacement,in:directory),
           let next = ReleaseVersion(value.tag),let current = ReleaseVersion(Self.currentVersion),next > current,FileManager.default.fileExists(atPath:value.replacement.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("update.zip").path) {
            prepared = value; setStatus("%@ is ready to install.",value.tag)
        } else { UserDefaults.standard.removeObject(forKey:"preparedUpdate") }
        let updateDirectory = directory, candidate = prepared?.replacement
        DispatchQueue.global(qos:.utility).async {
            if let candidate {
                RollbackArchive.unregister(candidate)
                try? FileManager.default.removeItem(at:candidate)
            }
            UpdateStaging.prune(in:updateDirectory,keeping:candidate)
        }
        timer = Timer.scheduledTimer(withTimeInterval:6*60*60,repeats:true) { [weak self] _ in self?.checkAutomatically() }
        DispatchQueue.main.asyncAfter(deadline:.now()+30) { [weak self] in self?.checkAutomatically() }
    }
    private func checkAutomatically() {
        guard automaticChecks else { return }
        let last = UserDefaults.standard.double(forKey:"updateLastChecked")
        if Date().timeIntervalSince1970-last >= 6*60*60 { check() }
    }
    private func notify() { NotificationCenter.default.post(name:Self.changed,object:nil) }
    private func setStatus(_ key: String,_ values: CVarArg...) { statusKey = key; statusValues = values; notify() }
    func check() {
        guard !busy else { return }; busy = true; setStatus("Checking GitHub Releases…")
        let previews = includePreviews
        Task { @MainActor in
            do {
                let releases = try await UpdateTransport.firstValid(URL(string:"https://api.github.com/repos/huluxiaohuowa/Linvell/releases?per_page=100")!,load:{ try await self.metadata($0,limit:4*1024*1024) },validate:{ try JSONDecoder().decode([GitHubRelease].self,from:$0) })
                offer = UpdateOffer.select(releases,installed:Self.currentVersion,previews:previews)
                UserDefaults.standard.set(Date().timeIntervalSince1970,forKey:"updateLastChecked")
                busy = false
                if let offer { setStatus("%@ is available.",offer.tag) }
                else if let prepared { setStatus("%@ is ready to install.",prepared.tag) }
                else { setStatus("No newer eligible public release was found.") }
                if offer != nil && automaticDownloads { download() }
            } catch { busy = false; setStatus("Could not check for updates. %@",error.localizedDescription) }
        }
    }
    func download() {
        guard !busy,let offer else { return }; busy = true; setStatus("Downloading %@…",offer.tag)
        Task { @MainActor in
            var downloadRoot: URL?
            do {
                let expected = try await UpdateTransport.firstValid(offer.checksum.browser_download_url,load:{ try await self.metadata($0,limit:64*1024) },validate:{ data -> String in
                    guard let text = String(data:data,encoding:.utf8),let digest = UpdateOffer.checksum(text,filename:offer.archive.name) else { throw UpdateFailure.invalidResponse }; return digest
                })
                let root = directory.appendingPathComponent(UUID().uuidString+".noindex",isDirectory:true)
                downloadRoot = root
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                let zip = root.appendingPathComponent("update.zip")
                var downloaded = false,lastError: Error = UpdateFailure.invalidResponse
                for endpoint in UpdateTransport.candidates(offer.archive.browser_download_url) {
                    do {
                        try? FileManager.default.removeItem(at:zip)
                        let receiver = BoundedDownload(destination:zip,limit:offer.archive.size)
                        try await receiver.fetch(endpoint)
                        let valid = try await Task.detached(priority:.utility) {
                            let bytes = try Data(contentsOf:zip,options:.mappedIfSafe)
                            return Data(SHA256.hash(data:bytes)).map { String(format:"%02x",$0) }.joined() == expected
                        }.value
                        guard valid else { throw UpdateFailure.untrustedPackage }
                        downloaded = true; break
                    } catch { lastError = error }
                }
                guard downloaded else { throw lastError }
                setStatus("Verifying %@…",offer.tag)
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
                    defer {
                        RollbackArchive.unregister(candidate)
                        try? FileManager.default.removeItem(at:candidate)
                    }
                    try SignedUpdate.validate(current:current,candidate:candidate)
                    let info = try PropertyListSerialization.propertyList(from:Data(contentsOf:candidate.appendingPathComponent("Contents/Info.plist")),format:nil) as? [String:Any]
                    guard (info?["LinvellReleaseVersion"] as? String) == String(offer.tag.dropFirst(offer.tag.hasPrefix("v") ? 1 : 0)) else { throw UpdateFailure.untrustedPackage }
                    return candidate
                }.value
                prepared = Prepared(tag:offer.tag,replacement:replacement)
                UserDefaults.standard.set(try JSONEncoder().encode(prepared),forKey:"preparedUpdate")
                busy = false; setStatus("%@ verified. %@",offer.tag,automaticInstall ? "It will install when Linvell quits." : "Ready to install and restart.")
            } catch {
                if let downloadRoot {
                    let updateDirectory = directory
                    await Task.detached(priority:.utility) { UpdateStaging.remove(downloadRoot,in:updateDirectory) }.value
                }
                busy = false; setStatus("Update download was not accepted. %@",error.localizedDescription)
            }
        }
    }
    func requestInstall() {
        guard prepared != nil else { return }
        installRequested = true; NSApp.terminate(nil)
        // NSApplication may cancel termination when the user cancels a save/session dialog.
        installRequested = false
    }
    private func metadata(_ url: URL,limit: Int64) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("linvell-update-metadata-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:file) }
        let receiver = BoundedDownload(destination:file,limit:limit,exact:false)
        try await receiver.fetch(url)
        return try Data(contentsOf:file)
    }
    func scheduleInstallation() throws {
        guard let prepared else { return }
        guard UpdateStaging.owns(candidate:prepared.replacement,in:directory) else { throw UpdateFailure.invalidArchive }
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard !current.path.hasPrefix("/Volumes/"),FileManager.default.isWritableFile(atPath:current.deletingLastPathComponent().path) else { throw UpdateFailure.notWritable }
        let archive = prepared.replacement.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("update.zip")
        guard FileManager.default.fileExists(atPath:archive.path) else { throw UpdateFailure.invalidArchive }
        let helper = current.appendingPathComponent("Contents/Helpers/LinvellUpdater")
        guard FileManager.default.isExecutableFile(atPath:helper.path) else { throw UpdateFailure.untrustedPackage }
        let job = InstallJob(application:current,replacement:prepared.replacement,parentPID:getpid(),relaunch:installRequested,archive:archive)
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
    let exact: Bool
    private var continuation: CheckedContinuation<Void,Error>?
    private var downloadError: Error?
    private var session: URLSession?
    init(destination: URL,limit: Int64,exact: Bool = true) { self.destination = destination; self.limit = limit; self.exact = exact }
    func fetch(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = exact ? 600 : 20; config.httpCookieStorage = nil
            let session = URLSession(configuration:config,delegate:self,delegateQueue:nil); self.session = session
            session.downloadTask(with:url).resume()
        }
    }
    func urlSession(_ session: URLSession,downloadTask: URLSessionDownloadTask,didWriteData bytesWritten: Int64,totalBytesWritten: Int64,totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadError = UpdateFailure.invalidResponse; downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession,downloadTask: URLSessionDownloadTask,didFinishDownloadingTo location: URL) {
        do {
            let size = try location.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,size > 0,size <= limit,!exact || size == limit else { throw UpdateFailure.invalidResponse }
            try FileManager.default.moveItem(at:location,to:destination)
        } catch { downloadError = error }
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,didCompleteWithError error: Error?) {
        let result = downloadError ?? error
        if let result { continuation?.resume(throwing:result) } else { continuation?.resume() }
        continuation = nil; session.finishTasksAndInvalidate(); self.session = nil
    }
}
