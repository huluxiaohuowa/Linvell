import Foundation
import Darwin

public enum SSHConfig {
    public static func hosts(at config: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")) -> [String] {
        var visited = Set<String>(),hosts = Set<String>()
        func read(_ file: URL,depth: Int) {
            guard depth < 12,visited.insert(file.path).inserted,let text = try? String(contentsOf:file,encoding:.utf8) else { return }
            for line in text.components(separatedBy:.newlines) {
                let words = tokens(line)
                guard let key = words.first?.lowercased() else { continue }
                if key == "host" {
                    for host in words.dropFirst() where validAlias(host) && !host.contains("*") && !host.contains("?") && !host.hasPrefix("!") { hosts.insert(host) }
                } else if key == "include" {
                    for name in words.dropFirst() {
                        let expanded = (name as NSString).expandingTildeInPath
                        let pattern = expanded.hasPrefix("/") ? expanded : config.deletingLastPathComponent().appendingPathComponent(expanded).path
                        var result = glob_t()
                        if glob(pattern,0,nil,&result) == 0,let paths = result.gl_pathv {
                            for index in 0..<Int(result.gl_pathc) { if let path = paths[index] { read(URL(fileURLWithPath:String(cString:path)),depth:depth+1) } }
                        }
                        globfree(&result)
                    }
                }
            }
        }
        read(config,depth:0)
        return hosts.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    public static func validAlias(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.utf8.count <= 255 && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-@:*?!".unicodeScalars.contains($0) }
    }
    public static func tokens(_ line: String) -> [String] {
        var result: [String] = [],word = "",quote: Character?,escaped = false
        for c in line {
            if escaped { word.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if let q = quote { if c == q { quote = nil } else { word.append(c) }; continue }
            if c == "\"" || c == "'" { quote = c; continue }
            if c == "#" { break }
            if c.isWhitespace || c == "=" { if !word.isEmpty { result.append(word); word = "" } }
            else { word.append(c) }
        }
        if !word.isEmpty { result.append(word) }; return result
    }
}

public struct RemoteEntry: Decodable {
    public let name: String
    public let path: String
    public let directory: Bool
}
public struct RemoteReply: Decodable {
    public let path: String?
    public let entries: [RemoteEntry]?
    public let content: String?
    public let digest: String?
    public let error: String?
    public let tasks: [RunTask]?
}
public struct SSHRemote {
    public let host: String
    public init(host: String) throws {
        guard SSHConfig.validAlias(host),!host.contains("*"),!host.contains("?"),!host.contains("!") else { throw GitError.command("Choose a concrete SSH host.") }
        self.host = host
    }
    public static func quote(_ value: String) -> String { "'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'" }
    public func request(_ operation: String,path: String,content: Data? = nil,digest: String? = nil) throws -> RemoteReply {
        var request: [String:String] = ["operation":operation,"path":path]
        if let content { request["content"] = content.base64EncodedString() }
        if let digest { request["digest"] = digest }
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:["-T","-o","BatchMode=yes","-o","ConnectTimeout=10","-o","ServerAliveInterval=10","-o","ServerAliveCountMax=2","--",host,"python3 -c "+Self.quote(Self.agent)],directory:nil,timeout:45,input:try JSONSerialization.data(withJSONObject:request),maximumOutputBytes:32*1024*1024)
        guard result.succeeded else { throw GitError.command(result.timedOut ? "SSH operation timed out." : result.output) }
        guard let line = result.output.components(separatedBy:.newlines).last(where:{ $0.hasPrefix("LINVELL_JSON:") }) else { throw GitError.command("The remote host needs Python 3 to browse and edit files. Open its SSH terminal to check authentication and Python availability.") }
        let reply = try JSONDecoder().decode(RemoteReply.self,from:Data(line.dropFirst("LINVELL_JSON:".count).utf8))
        if let error = reply.error { throw GitError.command(error) }
        return reply
    }
    // Fixed stdlib-only protocol. No server installation, shell interpolation or credentials are sent.
    public static let agent = #"""
import os,sys,json,base64,hashlib,tempfile,stat
def digest(data): return hashlib.sha256(data).hexdigest()
try:
    req=json.load(sys.stdin)
    path=os.path.abspath(os.path.expanduser(req['path'] or '~'))
    op=req['operation']
    if op=='list':
        entries=[]
        with os.scandir(path) as scan:
            for e in scan:
                if len(entries)>=20000: raise ValueError('Directory contains more than 20,000 entries; open a smaller directory.')
                entries.append(dict(name=e.name,path=e.path,directory=e.is_dir()))
        reply=dict(path=path,entries=sorted(entries,key=lambda e:(not e['directory'],e['name'].lower())))
    elif op=='files':
        entries=[]
        excluded={'.git','node_modules','dist','build','.build','DerivedData','vendor','__pycache__','.venv'}
        for base,dirs,files in os.walk(path,followlinks=False):
            dirs[:]=[name for name in dirs if name not in excluded and not os.path.islink(os.path.join(base,name))]
            for name in files:
                full=os.path.join(base,name)
                if not os.path.islink(full): entries.append(dict(name=os.path.relpath(full,path),path=full,directory=False))
                if len(entries)>=20000: break
            if len(entries)>=20000: break
        reply=dict(path=path,entries=entries)
    elif op=='tasks':
        tasks=[]
        manifest=os.path.join(path,'package.json')
        if os.path.isfile(manifest):
            with open(manifest) as f: scripts=json.load(f).get('scripts',{})
            import shlex
            tasks += [dict(label='npm: '+k,command='npm run '+shlex.quote(k)) for k in sorted(scripts)]
        if os.path.isfile(os.path.join(path,'Package.swift')): tasks += [dict(label='Swift: run',command='swift run'),dict(label='Swift: test',command='swift test')]
        if os.path.isfile(os.path.join(path,'Makefile')): tasks.append(dict(label='Make',command='make'))
        reply=dict(path=path,tasks=tasks)
    elif op=='create':
        with open(path,'xb') as f: pass
        reply=dict(path=path,digest=digest(b''))
    elif op=='read':
        path=os.path.realpath(path)
        if os.path.getsize(path)>16*1024*1024: raise ValueError('Remote editor limit: 16 MiB per file.')
        with open(path,'rb') as f: data=f.read(16*1024*1024+1)
        if len(data)>16*1024*1024: raise ValueError('Remote file exceeds 16 MiB.')
        reply=dict(path=path,content=base64.b64encode(data).decode(),digest=digest(data))
    elif op=='write':
        path=os.path.realpath(path)
        with open(path,'rb') as f: previous=f.read(16*1024*1024+1)
        if digest(previous)!=req['digest']: raise ValueError('The remote file changed. Save a local copy and reopen before replacing remote content.')
        data=base64.b64decode(req['content'],validate=True)
        if len(data)>16*1024*1024: raise ValueError('Remote file exceeds 16 MiB.')
        mode=stat.S_IMODE(os.stat(path).st_mode)
        fd,tmp=tempfile.mkstemp(prefix='.linvell-',dir=os.path.dirname(path))
        try:
            with os.fdopen(fd,'wb') as f:
                f.write(data); f.flush(); os.fsync(f.fileno())
            os.chmod(tmp,mode)
            with open(path,'rb') as f: current=f.read(16*1024*1024+1)
            if digest(current)!=req['digest']: raise ValueError('The remote file changed during save.')
            os.replace(tmp,path)
        finally:
            if os.path.exists(tmp): os.unlink(tmp)
        reply=dict(path=path,digest=digest(data))
    else: raise ValueError('Unsupported operation')
except Exception as e: reply=dict(error=str(e))
print('LINVELL_JSON:'+json.dumps(reply))
"""#
}
