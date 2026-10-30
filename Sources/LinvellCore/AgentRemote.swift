import Foundation

public struct AgentRemoteSnapshot: Decodable {
    public let installations: [AgentInstallation]
    public let sessions: [AgentSession]
    public let error: String?
    public var projects: [String]? = nil
}

extension SSHRemote {
    public func agentSnapshot(project: String,kind: AgentKind? = nil,executable: String? = nil,agentHome: String? = nil) throws -> AgentRemoteSnapshot {
        if kind == .dsh {
            let found = try agentSnapshot(project:project)
            guard let selected = executable ?? found.installations.first(where:{ $0.kind == .dsh })?.path else { return found }
            var env = AgentCLI.environment; env.removeValue(forKey:"DSH_HOME"); if let agentHome,!agentHome.isEmpty { env["DSH_HOME"] = agentHome }
            return AgentRemoteSnapshot(installations:found.installations,sessions:try AgentDSHSessions.list(executable:selected,project:project,environment:env,remote:self),error:nil)
        }
        if kind == .codex {
            let found = try agentSnapshot(project:project)
            if let selected = executable ?? found.installations.first(where:{ $0.kind == .codex })?.path {
                var env = AgentCLI.environment; env.removeValue(forKey:"CODEX_HOME"); if let agentHome,!agentHome.isEmpty { env["CODEX_HOME"] = agentHome }
                if let sessions = try? AgentCodexSessions.list(executable:selected,project:project,environment:env,remote:self,projects:found.projects) { return AgentRemoteSnapshot(installations:found.installations,sessions:sessions,error:nil) }
            }
        }
        var request = ["project":project]
        request["kind"] = kind?.rawValue; request["executable"] = executable; request["agentHome"] = agentHome
        let command = RunTasks.remoteCommand(directory:project,command:"python3 -c "+Self.quote(Self.agentSessionProbe))
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:transportArguments(command:command),directory:nil,timeout:60,input:try JSONSerialization.data(withJSONObject:request),maximumOutputBytes:16*1024*1024)
        guard result.succeeded else { throw GitError.command(result.timedOut ? "Agent discovery over SSH timed out." : result.output) }
        guard let line = result.output.components(separatedBy:.newlines).last(where:{ $0.hasPrefix("LINVELL_AGENTS:") }) else { throw GitError.command("Agent discovery requires Python 3 on the SSH host.") }
        let snapshot = try JSONDecoder().decode(AgentRemoteSnapshot.self,from:Data(line.dropFirst("LINVELL_AGENTS:".count).utf8))
        if let error = snapshot.error { throw GitError.command(error) }; return snapshot
    }
    public static let agentSessionProbe = #"""
import os,sys,json,glob,shutil,subprocess
result=dict(installations=[],sessions=[])
try:
    req=json.load(sys.stdin)
    home=os.path.expanduser('~')
    paths=[os.path.join(home,p) for p in ['.local/bin','.npm-global/bin','.opencode/bin','.bun/bin','dev/envs/conda/bin']]
    paths+=glob.glob(home+'/.nvm/versions/node/*/bin')+glob.glob(home+'/.local/share/mise/installs/node/*/bin')
    os.environ['PATH']=os.environ.get('PATH','')+os.pathsep+os.pathsep.join(paths)
    for kind in ['codex','opencode','pi','claude','dsh']:
        executable=shutil.which(kind)
        if executable:result['installations'].append(dict(kind=kind,path=executable,source='CLI'))
    kind=req.get('kind')
    if req.get('agentHome'):
        variable={'codex':'CODEX_HOME','claude':'CLAUDE_CONFIG_DIR','pi':'PI_CODING_AGENT_DIR'}.get(kind)
        if variable:os.environ[variable]=req['agentHome']
    project=os.path.realpath(os.path.expanduser(req['project']))
    def readtext(filename):
        try:
            with open(filename) as source:return source.read().strip()
        except OSError:return None
    def gitdir(directory):
        marker=os.path.join(directory,'.git')
        if os.path.isdir(marker):return os.path.realpath(marker)
        text=readtext(marker)
        if text and text.startswith('gitdir: '):return os.path.realpath(os.path.join(directory,text[8:]))
    projects={project};common=gitdir(project)
    if common:
        relative=readtext(os.path.join(common,'commondir'))
        if relative:common=os.path.realpath(os.path.join(common,relative))
        for entry in glob.glob(os.path.join(common,'worktrees','*')):
            pointer=readtext(os.path.join(entry,'gitdir'))
            if pointer:
                candidate=os.path.dirname(os.path.realpath(os.path.join(entry,pointer)))
                if gitdir(candidate)==os.path.realpath(entry):projects.add(candidate)
        if os.path.basename(common)=='.git' and gitdir(os.path.dirname(common))==common:projects.add(os.path.dirname(common))
    result['projects']=sorted(projects)
    if kind=='opencode':
        executable=req.get('executable') or shutil.which('opencode')
        if not executable:raise ValueError('Choose an installed OpenCode CLI path.')
        env=dict(os.environ)
        env['PATH']=os.path.dirname(executable)+os.pathsep+env['PATH']
        process=subprocess.run([executable,'session','list','--format','json'],cwd=project,env=env,capture_output=True,timeout=30)
        if process.returncode:raise ValueError(process.stderr.decode(errors='replace')[:2000] or 'OpenCode session discovery failed.')
        for value in json.loads(process.stdout):
            directory=value.get('directory','')
            if os.path.realpath(directory) not in projects:continue
            identity=value.get('id','')
            if not identity or identity.startswith('-'):continue
            result['sessions'].append(dict(id=identity,title=value.get('title') or identity,cwd=directory,locator=identity,updated=(value.get('time',{}).get('updated') or value.get('updated') or 0)/1000))
    elif kind:
        if kind=='codex':
            base=os.environ.get('CODEX_HOME',home+'/.codex');roots=[base+'/sessions',base+'/archived_sessions']
        elif kind=='claude':roots=[os.environ.get('CLAUDE_CONFIG_DIR',home+'/.claude')+'/projects']
        elif kind=='pi':roots=[os.environ.get('PI_CODING_AGENT_SESSION_DIR',os.environ.get('PI_CODING_AGENT_DIR',home+'/.pi/agent')+'/sessions')]
        else:raise ValueError('Unsupported agent')
        sessions={}
        for root in roots:
            for directory,dirs,files in os.walk(root,followlinks=False):
                dirs[:]=[d for d in dirs if not d.startswith('.') and d!='subagents' and not os.path.islink(os.path.join(directory,d))]
                for name in files:
                    if not name.endswith('.jsonl'):continue
                    filename=os.path.join(directory,name)
                    if os.path.islink(filename):continue
                    try:
                        with open(filename,'rb') as source:data=source.read(256*1024)
                        identity=None;cwd=None;title=None
                        def usertext(content):
                            if isinstance(content,str):return content.strip()[:120] or None
                            if isinstance(content,list):
                                for block in content:
                                    if isinstance(block,dict) and isinstance(block.get('text'),str) and block['text'].strip():return block['text'].strip()[:120]
                            return None
                        for line in data.splitlines():
                            try:value=json.loads(line)
                            except (ValueError,UnicodeError):continue
                            if not isinstance(value,dict):continue
                            entry=value.get('type');payload=value.get('payload') or {}
                            if not isinstance(payload,dict):payload={}
                            if kind=='codex' and entry=='session_meta':identity=payload.get('id');cwd=payload.get('cwd')
                            elif kind=='pi' and entry=='session':identity=value.get('id');cwd=value.get('cwd')
                            elif kind=='claude' and not value.get('isSidechain'):
                                identity=identity or value.get('sessionId');cwd=cwd or value.get('cwd')
                            if entry=='custom-title':title=value.get('customTitle')
                            if entry=='session_info':title=value.get('name')
                            message=value.get('message') or {}
                            if isinstance(message,dict) and title is None and (entry=='user' or (entry=='message' and message.get('role')=='user')):title=usertext(message.get('content'))
                            if title is None and kind=='codex' and entry=='event_msg' and payload.get('type')=='user_message':title=str(payload.get('message',''))[:120]
                            if title is None and kind=='codex' and entry=='response_item' and payload.get('role')=='user':
                                text=usertext(payload.get('content'))
                                if text and not text.startswith(('# AGENTS.md','<environment_context>','<permissions instructions>','<INSTRUCTIONS>')):title=text
                        if not identity or identity.startswith('-') or not cwd or not cwd.startswith('/') or os.path.realpath(cwd) not in projects:continue
                        if kind in ('claude','pi'):
                            with open(filename,'rb') as source:
                                for line in source:
                                    try:value=json.loads(line)
                                    except (ValueError,UnicodeError):continue
                                    if not isinstance(value,dict):continue
                                    entry=value.get('type')
                                    name=value.get('customTitle') if entry=='custom-title' else value.get('name') if entry=='session_info' else None
                                    if isinstance(name,str) and name.strip():title=name
                                    elif not title:
                                        message=value.get('message') or {}
                                        if isinstance(message,dict) and (entry=='user' or message.get('role')=='user'):title=usertext(message.get('content'))
                        updated=os.path.getmtime(filename)
                        session=dict(id=identity,title=str(title or identity).replace('\n',' '),cwd=cwd,locator=filename if kind=='pi' else identity,updated=updated)
                        if identity not in sessions or sessions[identity]['updated']<updated:sessions[identity]=session
                    except (OSError,ValueError,TypeError):continue
        if kind=='codex':
            for base in set(os.path.dirname(root) for root in roots):
                try:
                    with open(os.path.join(base,'session_index.jsonl')) as source:
                        for line in source:
                            try:value=json.loads(line)
                            except ValueError:continue
                            identity=value.get('id');title=value.get('thread_name')
                            if identity in sessions and isinstance(title,str) and title.strip():sessions[identity]['title']=title.replace('\n',' ')
                except OSError:pass
        result['sessions']=list(sessions.values())
    result['sessions'].sort(key=lambda s:s['updated'],reverse=True)
except Exception as error:result['error']=str(error)
print('LINVELL_AGENTS:'+json.dumps(result))
"""#
}
