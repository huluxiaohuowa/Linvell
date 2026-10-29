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

public struct RemoteEntry: Decodable, Equatable {
    public let name: String
    public let path: String
    public let directory: Bool
}
public struct RemoteReply: Decodable {
    public let installTarget: LanguageInstallTarget?
    public let path: String?
    public let entries: [RemoteEntry]?
    public let content: String?
    public let digest: String?
    public let error: String?
    public let tasks: [RunTask]?
    public let tools: [String:String]?
}
public struct SSHRemote {
    public let host: String
    private static let multiplexOptions: [String] = {
        let directory = FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("Linvell/ssh",isDirectory:true)
        let pattern = directory.appendingPathComponent("%C").path
        guard pattern.utf8.count+38 < 104 else { return [] }
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
            return ["-o","ControlMaster=auto","-o","ControlPersist=120","-o","ControlPath="+pattern]
        } catch { return [] }
    }()
    public init(host: String) throws {
        guard SSHConfig.validAlias(host),!host.contains("*"),!host.contains("?"),!host.contains("!") else { throw GitError.command("Choose a concrete SSH host.") }
        self.host = host
    }
    public static func quote(_ value: String) -> String {
        // Quoted segments reconstruct the same argument in POSIX shells and fish.
        // fish interprets backslashes inside single quotes differently from POSIX.
        var result = "'"
        for character in value {
            if character == "'" { result += "'\"'\"'" }
            else if character == "\\" { result += "'\"\\\\\"'" }
            else { result.append(character) }
        }
        return result+"'"
    }
    public func transportArguments(command: String) -> [String] {
        ["-T","-o","BatchMode=yes","-o","ConnectTimeout=10","-o","ServerAliveInterval=10","-o","ServerAliveCountMax=2"]+Self.multiplexOptions+["--",host,command]
    }
    public func request(_ operation: String,path: String,content: Data? = nil,digest: String? = nil) throws -> RemoteReply {
        var request: [String:String] = ["operation":operation,"path":path]
        if let content { request["content"] = content.base64EncodedString() }
        if let digest { request["digest"] = digest }
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:transportArguments(command:"python3 -c "+Self.quote(Self.agent)),directory:nil,timeout:45,input:try JSONSerialization.data(withJSONObject:request),maximumOutputBytes:32*1024*1024)
        guard result.succeeded else { throw GitError.command(result.timedOut ? "SSH operation timed out." : result.output) }
        guard let line = result.output.components(separatedBy:.newlines).last(where:{ $0.hasPrefix("LINVELL_JSON:") }) else { throw GitError.command("The remote host needs Python 3 to browse and edit files. Open its SSH terminal to check authentication and Python availability.") }
        let reply = try JSONDecoder().decode(RemoteReply.self,from:Data(line.dropFirst("LINVELL_JSON:".count).utf8))
        if let error = reply.error { throw GitError.command(error) }
        if operation == "create" || operation == "settings-write" { RemoteDirectoryCache.shared.invalidate(host:host) }
        return reply
    }
    public static func gitCommand(_ arguments: [String],directory: String) -> String {
        let command = (directory == "~" ? "cd && " : "")+"exec env GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 git "+GitRepository.arguments(directory:directory == "~" ? "." : directory,arguments:arguments).map(quote).joined(separator:" ")
        return "/bin/sh -c "+quote(command)
    }
    public func git(_ arguments: [String],directory: String,input: Data? = nil,timeout: TimeInterval = 30) throws -> String {
        guard (directory.hasPrefix("/") || directory == "~"),!directory.utf8.contains(0) else { throw GitError.invalidPath }
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:transportArguments(command:Self.gitCommand(arguments,directory:directory)),directory:nil,timeout:timeout+10,input:input,trimOutput:false,maximumOutputBytes:16*1024*1024)
        guard result.succeeded else { throw GitError.command(result.timedOut ? "SSH Git operation timed out." : result.output) }
        return result.output
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
        path=os.path.realpath(path)
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
    elif op in ('settings-read','settings-write'):
        base=os.path.realpath(path)
        folder=os.path.join(base,'.linvell')
        config=os.path.join(folder,'settings.json')
        if not os.path.isdir(base): raise ValueError('Open a project folder before saving project settings.')
        if os.path.islink(folder) or os.path.islink(config): raise ValueError('Project settings cannot use a symlink.')
        def readsettings():
            if not os.path.exists(config): return b'{}\n','missing'
            if os.path.getsize(config)>1024*1024: raise ValueError('Project settings exceed 1 MiB.')
            with open(config,'rb') as source: value=source.read(1024*1024+1)
            return value,digest(value)
        if op=='settings-write':
            import fcntl
            value=base64.b64decode(req['content'],validate=True)
            if len(value)>1024*1024: raise ValueError('Project settings exceed 1 MiB.')
            os.makedirs(folder,mode=0o700,exist_ok=True)
            lockfd=os.open(os.path.join(folder,'.settings.lock'),os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
            with os.fdopen(lockfd,'wb') as lock:
                fcntl.flock(lock.fileno(),fcntl.LOCK_EX)
                previous,expected=readsettings()
                if expected!=req.get('digest'): raise ValueError('Project settings changed. Reload them before saving.')
                fd,temporary=tempfile.mkstemp(dir=folder,prefix='.settings-')
                try:
                    with os.fdopen(fd,'wb') as target: target.write(value);target.flush();os.fsync(target.fileno())
                    os.replace(temporary,config)
                finally:
                    if os.path.exists(temporary): os.unlink(temporary)
        value,checksum=readsettings()
        reply=dict(path=config,content=base64.b64encode(value).decode(),digest=checksum)
    elif op=='language-tool-probe':
        import platform,shutil,subprocess
        node=shutil.which('node') or ''
        version=''
        if node:
            probe=subprocess.run([node,'--version'],capture_output=True,timeout=10)
            if probe.returncode==0:version=probe.stdout.decode().strip()
        reply=dict(path=os.path.realpath(path),installTarget=dict(platform=sys.platform,architecture=platform.machine().lower(),libc=platform.libc_ver()[0],node=node,nodeVersion=version))
    elif op=='toolchains':
        import shutil
        names=['swift','sourcekit-lsp','python3','python','pyright-langserver','basedpyright-langserver','pylsp','node','typescript-language-server','clang','gcc','clangd','go','gopls','rustc','rust-analyzer','java','jdtls','dotnet','csharp-ls','ruby','ruby-lsp','php','phpactor','bash','zsh','bash-language-server','lua','luajit','lua-language-server','R','vscode-html-language-server','vscode-css-language-server','vscode-json-language-server','clang++','g++','iverilog','verilator','verible-verilog-ls','ghdl','vhdl_ls','dart']
        tools={name:shutil.which(name) for name in names if shutil.which(name)}
        for relative in ['.venv/bin/python','venv/bin/python']:
            candidate=os.path.join(path,relative)
            if os.path.isfile(candidate) and os.access(candidate,os.X_OK): tools[relative]=candidate
        if 'swift' in tools and 'sourcekit-lsp' not in tools:
            candidate=os.path.join(os.path.dirname(tools['swift']),'sourcekit-lsp')
            if os.path.isfile(candidate) and os.access(candidate,os.X_OK): tools['sourcekit-lsp']=candidate
        tools['__home']=os.path.expanduser('~')
        tools['__root']=os.path.realpath(path)
        reply=dict(path=path,tools=tools)
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
