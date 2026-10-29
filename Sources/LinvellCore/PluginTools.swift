import Foundation
import CryptoKit
import LinvellPluginKit

public enum PluginTools {
    public static let targets = Set(["macos-arm64","macos-x86_64","linux-aarch64","linux-x86_64"])
    public static var localTarget: String {
        #if arch(arm64)
        return "macos-arm64"
        #else
        return "macos-x86_64"
        #endif
    }
    public static func file(_ path: String,directory: URL) throws -> URL {
        guard !path.isEmpty,!path.hasPrefix("/"),!path.utf8.contains(0),!path.split(separator:"/").contains("..") else { throw PluginError.invalidPackage }
        let url = directory.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(directory.path+"/"),(try? url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile) == true else { throw PluginError.invalidPackage }
        return url
    }
    public static func path(_ program: PluginProgram,target: String) throws -> String {
        guard let path = program.executables?[target] ?? program.executable else { throw LanguageServiceError.message("Plugin has no executable for "+target+".") }; return path
    }
    public static func validate(_ manifest: PluginManifest,directory: URL) throws {
        guard manifest.execution == nil || ["local","workspace"].contains(manifest.execution!) else { throw PluginError.invalidPackage }
        let servers = manifest.languageServers ?? [],tasks = manifest.tasks ?? [],debuggers = manifest.debuggers ?? []
        for ids in [servers.map(\.id),tasks.map(\.id),debuggers.map(\.id)] { guard ids.count <= 32,Set(ids).count == ids.count,ids.allSatisfy(PluginContributions.validID) else { throw PluginError.invalidPackage } }
        func program(_ value: PluginProgram) throws {
            let paths = Array((value.executables ?? [:]).values)+(value.executable.map { [$0] } ?? [])
            guard !paths.isEmpty,Set(value.executables?.keys.map { $0 } ?? []).isSubset(of:targets),(value.arguments?.count ?? 0) <= 100,value.arguments?.allSatisfy({ $0.utf8.count <= 8192 && !$0.utf8.contains(0) }) ?? true else { throw PluginError.invalidPackage }
            for path in paths { let file = try file(path,directory:directory); guard FileManager.default.isExecutableFile(atPath:file.path) else { throw PluginError.invalidPackage } }
        }
        func title(_ value: String) -> Bool { !value.isEmpty && value.count <= 200 }
        if manifest.executables != nil { try program(PluginProgram(executable:manifest.executable,executables:manifest.executables)) }
        var languages = Set<String>(),extensions = Set<String>()
        for server in servers {
            guard title(server.title),!server.languages.isEmpty,server.languages.count <= 32,server.languages.allSatisfy(PluginContributions.validID),(server.fileExtensions?.count ?? 0) <= 50,(server.fileExtensions ?? []).allSatisfy(PluginContributions.validID),manifest.permissions.contains("document.read") else { throw PluginError.invalidPackage }
            for language in server.languages { guard languages.insert(language).inserted else { throw PluginError.invalidPackage } }
            for ext in server.fileExtensions ?? [] { guard extensions.insert(ext).inserted else { throw PluginError.invalidPackage } }
            try program(server.program)
        }
        for task in tasks { guard title(task.title) else { throw PluginError.invalidPackage }; try program(task.program) }
        for debugger in debuggers { guard title(debugger.title),debugger.launch["program"] != nil else { throw PluginError.invalidPackage }; try program(debugger.program) }
    }
    public static func expand(_ value: String,root: String) -> String { value.replacingOccurrences(of:"${workspaceFolder}",with:root) }
    public static func expand(_ value: Any,root: String) -> Any {
        if let text = value as? String { return expand(text,root:root) }
        if let array = value as? [Any] { return array.map { expand($0,root:root) } }
        if let object = value as? [String:Any] { return object.mapValues { expand($0,root:root) } }; return value
    }
}

/// Memory-only bounded output; never persists document contents or credentials to disk.
public final class PluginLogBuffer {
    private let lock = NSLock()
    private var value = ""
    public init() {}
    public func append(_ text: String) { lock.lock(); value += String(text.prefix(8192))+"\n"; if value.utf8.count > 256*1024 { value = String(value.suffix(64*1024)) }; lock.unlock() }
    public var text: String { lock.lock(); defer { lock.unlock() }; return value }
}

/// Explicitly loaded package, optionally staged onto its SSH workspace host.
public final class PluginRuntime {
    private let package: PluginPackage,workspace: PluginWorkspace?
    private let lock = NSLock(),prepareLock = NSLock()
    private var channels: [LanguageRPC] = []
    private var transfers: [Process] = []
    private var stopped = false
    private var remoteDirectory: String?,target: String?
    public init(package: PluginPackage,workspace: PluginWorkspace?) { self.package = package; self.workspace = workspace }
    public var remote: SSHRemote? { package.manifest.execution == "workspace" ? workspace?.remote : nil }
    public var root: String { workspace?.remote != nil && remote == nil ? package.directory.path : workspace?.root ?? package.directory.path }
    private func check() throws { lock.lock(); defer { lock.unlock() }; if stopped { throw PluginError.unavailable } }
    public func prepare() throws -> (directory: String,target: String) {
        prepareLock.lock(); defer { prepareLock.unlock() }; try check()
        guard let remote else { return (package.directory.path,PluginTools.localTarget) }
        if let remoteDirectory,let target { return (remoteDirectory,target) }
        let probe = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:remote.transportArguments(command:"python3 -c "+SSHRemote.quote(Self.probe)),directory:nil,timeout:20,started:track)
        guard probe.succeeded,PluginTools.targets.contains(probe.output) else { throw LanguageServiceError.message("Unsupported plugin host; Python 3 and Linux x86_64/aarch64 are required.") }
        let target = probe.output
        let m = package.manifest
        var programs = (m.languageServers ?? []).map(\.program)+(m.tasks ?? []).map(\.program)+(m.debuggers ?? []).map(\.program)
        if package.executableURL != nil { programs.append(PluginProgram(executable:m.executable,executables:m.executables)) }
        let paths = Set(try programs.map { try PluginTools.path($0,target:target) })
        var files: [[String:String]] = []; var size = 0
        for path in paths.sorted() {
            try check()
            let url = try PluginTools.file(path,directory:package.directory)
            guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 64*1024*1024 else { throw PluginError.invalidPackage }
            let data = try Data(contentsOf:url); size += data.count
            guard size <= 128*1024*1024 else { throw PluginError.invalidPackage }
            files.append(["path":path,"content":data.base64EncodedString(),"sha256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()])
        }
        let payload = try JSONSerialization.data(withJSONObject:["id":m.id,"files":files],options:.sortedKeys)
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:remote.transportArguments(command:"python3 -c "+SSHRemote.quote(Self.stage)),directory:nil,timeout:60,input:payload,maximumOutputBytes:8192,started:track)
        guard result.succeeded,result.output.hasPrefix("/"),!result.output.contains("\n") else { throw LanguageServiceError.message("Remote plugin transfer or checksum verification failed.") }
        try check(); self.remoteDirectory = result.output; self.target = target; return (result.output,target)
    }
    public func command(_ program: PluginProgram) throws -> (String,[String]) {
        let location = try prepare(),path = try PluginTools.path(program,target:location.target)
        _ = try PluginTools.file(path,directory:package.directory)
        return (location.directory+"/"+path,(program.arguments ?? []).map { PluginTools.expand($0,root:root) })
    }
    public func launch(_ program: PluginProgram,log: ((String) -> Void)? = nil,dap: Bool = false) throws -> LanguageRPC {
        let (executable,arguments) = try command(program)
        let rpc: LanguageRPC
        if let remote {
            let spec = try JSONSerialization.data(withJSONObject:["argv":[executable]+arguments,"cwd":root])
            let command = "python3 -c "+SSHRemote.quote(Self.runner)+" "+SSHRemote.quote(spec.base64EncodedString())
            rpc = try LanguageRPC(executable:URL(fileURLWithPath:"/usr/bin/ssh"),arguments:remote.transportArguments(command:command),directory:nil,stderr:log,dap:dap)
        } else { rpc = try LanguageRPC(executable:URL(fileURLWithPath:executable),arguments:arguments,directory:URL(fileURLWithPath:root),stderr:log,dap:dap) }
        lock.lock(); if stopped { lock.unlock(); rpc.stop(); throw PluginError.unavailable }; channels.removeAll { !$0.isRunning }; channels.append(rpc); lock.unlock(); return rpc
    }
    private func track(_ process: Process) {
        lock.lock(); transfers.removeAll { !$0.isRunning }; let cancel = stopped
        if !cancel { transfers.append(process) }; lock.unlock()
        if cancel { process.terminate() }
    }
    public func stop() {
        lock.lock(); stopped = true; let values = channels,operations = transfers; channels.removeAll(); transfers.removeAll(); lock.unlock()
        values.forEach { $0.closePluginChannel() }
        operations.filter(\.isRunning).forEach { $0.terminate() }
    }
    deinit { stop() }
    public static let probe = "import platform,sys; print(('linux-' if sys.platform=='linux' else 'unsupported-')+{'arm64':'aarch64','aarch64':'aarch64','x86_64':'x86_64'}.get(platform.machine(),'unsupported'))"
    public static let stage = #"""
import os,sys,json,base64,hashlib,tempfile,shutil
req=json.load(sys.stdin)
blob=json.dumps(req,sort_keys=True,separators=(',',':')).encode()
key=hashlib.sha256(blob).hexdigest()
base=os.path.expanduser('~/dev/build/linvell/plugins')
os.makedirs(base,mode=0o700,exist_ok=True)
tmp=tempfile.mkdtemp(prefix='.transfer-',dir=base)
try:
    for f in req['files']:
        rel=f['path']
        if os.path.isabs(rel) or '..' in rel.split('/') or '\x00' in rel:raise ValueError('Invalid path')
        data=base64.b64decode(f['content'],validate=True)
        if hashlib.sha256(data).hexdigest()!=f['sha256']:raise ValueError('Checksum mismatch')
        out=os.path.join(tmp,rel);os.makedirs(os.path.dirname(out),exist_ok=True)
        with open(out,'xb') as dst:dst.write(data)
        os.chmod(out,0o700)
    dest=os.path.join(base,key)
    # A fresh verified copy replaces a previous interrupted or modified transfer.
    if os.path.lexists(dest):
        if os.path.islink(dest):raise ValueError('Invalid staging path')
        shutil.rmtree(dest)
    os.rename(tmp,dest);tmp=None
    print(dest)
finally:
    if tmp:shutil.rmtree(tmp)
"""#
    /// Remains the SSH child and reaps the plugin process group on EOF, HUP or TERM.
    public static let runner = #"""
import os,sys,json,base64,subprocess,threading,signal,select
spec=json.loads(base64.b64decode(sys.argv[1]));child=None
def end(signum,frame):raise SystemExit(128+signum)
for s in (signal.SIGHUP,signal.SIGTERM,signal.SIGINT):signal.signal(s,end)
def copy(src,dst):
    try:
        while True:
            b=os.read(src,65536)
            if not b:break
            view=memoryview(b)
            while view:
                n=os.write(dst,view);view=view[n:]
    except (OSError,BrokenPipeError):pass
try:
    child=subprocess.Popen(spec['argv'],cwd=os.path.expanduser(spec['cwd']),stdin=subprocess.PIPE,stdout=subprocess.PIPE,start_new_session=True)
    threading.Thread(target=copy,args=(child.stdout.fileno(),1),daemon=True).start()
    while child.poll() is None:
        if not select.select([0],[],[],0.2)[0]:continue
        b=os.read(0,65536)
        if not b:break
        child.stdin.write(b);child.stdin.flush()
finally:
    if child:
        try:os.killpg(child.pid,signal.SIGTERM)
        except ProcessLookupError:pass
        try:child.wait(timeout=1)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGKILL);child.wait()
"""#
}
