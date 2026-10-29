import Foundation
import CryptoKit

public struct LanguageInstallTarget: Codable {
    public let platform: String,architecture: String,libc: String,node: String,nodeVersion: String
    public var nodePlatform: String { platform == "darwin" ? "darwin" : "linux" }
    public var nodeArchitecture: String { ["aarch64","arm64"].contains(architecture) ? "arm64" : "x64" }
    public var supported: Bool { ["linux","darwin"].contains(platform) && ["aarch64","arm64","x86_64","amd64"].contains(architecture) && (platform != "linux" || libc != "musl") }
}
public struct ManagedLanguageRecipe {
    public let provider: String,version: String,packages: [(String,String)],entry: String,minimumNode: [Int]
    public static func forLanguage(_ id: String) -> ManagedLanguageRecipe? {
        switch id {
        case "python": return Self(provider:"pyright",version:"1.1.414",packages:[("pyright","1.1.414")],entry:"pyright/dist/pyright-langserver.js",minimumNode:[14,0,0])
        case "javascript","typescript": return Self(provider:"typescript",version:"6.0.2",packages:[("typescript-language-server","6.0.2"),("typescript","6.0.3")],entry:"typescript-language-server/lib/cli.mjs",minimumNode:[22,22,2])
        default: return nil
        }
    }
    public func acceptsNode(_ version: String) -> Bool {
        let pieces = version.trimmingCharacters(in:CharacterSet(charactersIn:"v \n")).split(separator:".").prefix(3).compactMap { Int($0) }
        guard pieces.count == 3 else { return false }
        for i in 0..<3 { if pieces[i] != minimumNode[i] { return pieces[i] > minimumNode[i] } }; return true
    }
}
public struct ManagedLanguageResult: Decodable {
    public let root: String,server: String
    public let arguments: [String]
}
public final class LanguageInstallCancellation {
    private let lock = NSLock()
    private var stopped = false,process: Process?
    public init() {}
    public func cancel() { lock.lock(); stopped = true; let process = process; lock.unlock(); if process?.isRunning == true { process?.terminate() } }
    public func check() throws { lock.lock(); let value = stopped; lock.unlock(); if value || Task.isCancelled { throw CancellationError() } }
    public func started(_ process: Process) { lock.lock(); self.process = process; let stopped = stopped; lock.unlock(); if stopped { process.terminate() } }
}

public enum ManagedLanguageTools {
    public static let nodeVersion = "v22.23.4"
    private struct NPMMetadata: Decodable { struct Dist: Decodable { let tarball: URL,integrity: String }; let dist: Dist }
    private static func download(_ url: URL,session: URLSession,maximum: Int,cancel: LanguageInstallCancellation) async throws -> Data {
        try cancel.check()
        let (temporary,response) = try await session.download(from:url)
        defer { try? FileManager.default.removeItem(at:temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,(try temporary.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= maximum else { throw LanguageServiceError.message("The language tool download is invalid or too large.") }
        try cancel.check(); return try Data(contentsOf:temporary)
    }
    public static func install(language: String,remote: SSHRemote?,root: String,storage: LanguageToolStorage = .project,addGitIgnore: Bool = true,cancel: LanguageInstallCancellation = LanguageInstallCancellation(),temporaryDirectory: URL = FileManager.default.temporaryDirectory,progress: @escaping (String) -> Void = { _ in }) async throws -> ManagedLanguageResult {
        guard let recipe = ManagedLanguageRecipe.forLanguage(language) else { throw LanguageServiceError.message("Automatic installation is not available for this language. Choose its installed SDK or language server.") }
        progress("Checking remote platform…")
        let target: LanguageInstallTarget,canonical: String
        if let remote {
            let reply = try remote.request("language-tool-probe",path:root,content:try JSONSerialization.data(withJSONObject:["storage":storage.rawValue]))
            guard let value = reply.installTarget,let path = reply.path else { throw LanguageServiceError.message("Could not inspect the target host.") }; target = value; canonical = path
        } else { canonical = URL(fileURLWithPath:root).resolvingSymlinksInPath().path; target = try NativeToolRelay.probe(root:canonical,storage:storage) }
        guard target.supported else { throw LanguageServiceError.message("Automatic installation supports macOS and glibc Linux on x64 or ARM64.") }
        let work = temporaryDirectory.appendingPathComponent("linvell-tool-relay-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        // No package or HTTP cache is retained on the client, including on failure.
        defer { try? FileManager.default.removeItem(at:work) }
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.httpCookieStorage = nil; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 900
        let session = URLSession(configuration:config); defer { session.invalidateAndCancel() }
        var artifacts: [[String:String]] = []
        func save(_ data: Data,_ name: String,kind: String,package: String = "",member: String = "") throws {
            try data.write(to:work.appendingPathComponent(name),options:.atomic)
            artifacts.append(["file":name,"kind":kind,"package":package,"member":member,"sha256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()])
        }
        let reuseNode = !target.node.isEmpty && recipe.acceptsNode(target.nodeVersion)
        if !reuseNode {
            progress("Downloading the target host’s runtime on this Mac…")
            let filename = "node-"+nodeVersion+"-"+target.nodePlatform+"-"+target.nodeArchitecture+".tar.gz"
            let base = URL(string:"https://nodejs.org/dist/"+nodeVersion+"/")!
            let sums = try await download(base.appendingPathComponent("SHASUMS256.txt"),session:session,maximum:1024*1024,cancel:cancel)
            guard let expected = UpdateOffer.checksum(String(decoding:sums,as:UTF8.self),filename:filename) else { throw UpdateFailure.untrustedPackage }
            let bytes = try await download(base.appendingPathComponent(filename),session:session,maximum:128*1024*1024,cancel:cancel)
            guard SHA256.hash(data:bytes).map({ String(format:"%02x",$0) }).joined() == expected else { throw UpdateFailure.untrustedPackage }
            try save(bytes,"runtime.tgz",kind:"node",member:String(filename.dropLast(7))+"/bin/node")
        }
        for (package,version) in recipe.packages {
            progress("Downloading language service on this Mac…")
            let raw = try await download(URL(string:"https://registry.npmjs.org/"+package+"/"+version)!,session:session,maximum:2*1024*1024,cancel:cancel)
            let metadata = try JSONDecoder().decode(NPMMetadata.self,from:raw)
            guard metadata.dist.tarball.scheme == "https",metadata.dist.tarball.host == "registry.npmjs.org",metadata.dist.tarball.user == nil,metadata.dist.tarball.password == nil,metadata.dist.tarball.path.hasPrefix("/"+package+"/-/") else { throw UpdateFailure.untrustedPackage }
            let bytes = try await download(metadata.dist.tarball,session:session,maximum:64*1024*1024,cancel:cancel)
            guard metadata.dist.integrity == "sha512-"+Data(SHA512.hash(data:bytes)).base64EncodedString() else { throw UpdateFailure.untrustedPackage }
            try save(bytes,package+".tgz",kind:"npm",package:package)
        }
        try cancel.check()
        let manifest: [String:Any] = ["provider":recipe.provider,"version":recipe.version,"entry":recipe.entry,"root":canonical,"storage":storage.rawValue,"addIgnore":addGitIgnore,"node":reuseNode ? target.node : "","nodeVersion":nodeVersion,"platform":target.platform,"architecture":target.architecture,"artifacts":artifacts]
        let manifestData = try JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys)
        if remote == nil { progress("Installing in the selected location…"); return try NativeToolRelay.install(spec:manifest,work:work) }
        try manifestData.write(to:work.appendingPathComponent("manifest.json"))
        let bundle = work.appendingPathComponent("upload.tar")
        let names = artifacts.map { $0["file"]! }+["manifest.json"]
        let archive = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/tar"),arguments:["-cf",bundle.path,"-C",work.path]+names,directory:nil,environment:["COPYFILE_DISABLE":"1"])
        guard archive.succeeded else { throw LanguageServiceError.message("Could not prepare the language service transfer.") }
        progress("Uploading and installing in this project…")
        let payload = manifestData.base64EncodedString()
        let command = "python3 -c "+SSHRemote.quote(ManagedToolRelay.agent)+" "+SSHRemote.quote(payload)
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:remote!.transportArguments(command:command),directory:nil,timeout:900,inputFile:bundle,maximumOutputBytes:1024*1024,started:cancel.started)
        try cancel.check()
        guard result.succeeded,let line = result.output.split(separator:"\n").last(where:{ $0.hasPrefix("LINVELL_TOOL:") }) else { throw LanguageServiceError.message(String(result.output.suffix(2000))) }
        let installed = try JSONDecoder().decode(ManagedLanguageResult.self,from:Data(line.dropFirst("LINVELL_TOOL:".count).utf8))
        RemoteDirectoryCache.shared.invalidate(host:remote!.host)
        return installed
    }
    public static func remove(language: String,remote: SSHRemote?,root: String,storage: LanguageToolStorage = .project) throws {
        guard let remote else { try NativeToolRelay.remove(language:language,root:root,storage:storage); return }
        guard let recipe = ManagedLanguageRecipe.forLanguage(language) else { throw LanguageServiceError.message("This language service is not managed by Linvell.") }
        let data = try JSONSerialization.data(withJSONObject:["root":root,"provider":recipe.provider,"storage":storage.rawValue,"remove":true])
        let command = "python3 -c "+SSHRemote.quote(ManagedToolRelay.agent)+" "+SSHRemote.quote(data.base64EncodedString())
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:remote.transportArguments(command:command),directory:nil,timeout:60)
        guard result.succeeded else { throw LanguageServiceError.message(String(result.output.suffix(2000))) }
        RemoteDirectoryCache.shared.invalidate(host:remote.host)
    }
    public static func addIgnore(remote: SSHRemote?,root: String) throws {
        guard let remote else { try NativeToolRelay.addIgnore(root:URL(fileURLWithPath:root)); return }
        let data = try JSONSerialization.data(withJSONObject:["root":root,"ignoreOnly":true])
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:remote.transportArguments(command:"python3 -c "+SSHRemote.quote(ManagedToolRelay.agent)+" "+SSHRemote.quote(data.base64EncodedString())),directory:nil,timeout:30)
        guard result.succeeded else { throw LanguageServiceError.message(String(result.output.suffix(2000))) }
        RemoteDirectoryCache.shared.invalidate(host:remote.host)
    }
}
