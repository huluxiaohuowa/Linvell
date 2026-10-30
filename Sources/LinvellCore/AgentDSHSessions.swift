import Foundation

/// Reuses DSH's installed Node runtime for its versioned Zstandard session logs.
/// No runtime, codec or DSH code is copied into Linvell.
public enum AgentDSHSessions {
    public static func list(executable: String,project: String,environment: [String:String] = AgentCLI.environment,remote: SSHRemote? = nil) throws -> [AgentSession] {
        var request: [String:Any] = ["project":project,"executable":executable,"script":script]
        if let home = environment["DSH_HOME"] { request["home"] = home }
        let result: ToolResult
        if let remote {
            let command = RunTasks.remoteCommand(directory:project,command:"python3 -c "+SSHRemote.quote(remoteLauncher))
            result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:remote.transportArguments(command:command),directory:nil,timeout:60,input:try JSONSerialization.data(withJSONObject:request),maximumOutputBytes:16*1024*1024)
        } else {
            let real = URL(fileURLWithPath:executable).resolvingSymlinksInPath().path
            var runtime: URL?
            if let boundary = real.range(of:".app/Contents/") {
                let app = String(real[..<boundary.lowerBound])+".app"
                let candidate = URL(fileURLWithPath:app+"/Contents/Resources/runtime/primary-runtime/dependencies/node/bin/node")
                if FileManager.default.isExecutableFile(atPath:candidate.path) { runtime = candidate }
            }
            if runtime == nil {
                runtime = (environment["PATH"] ?? "").components(separatedBy:":").map { URL(fileURLWithPath:$0).appendingPathComponent("node") }.first { FileManager.default.isExecutableFile(atPath:$0.path) }
            }
            guard let runtime else { throw GitError.command("DSH session discovery requires its installed Node runtime.") }
            result = try ToolCommand.run(runtime,arguments:["-e",script],directory:URL(fileURLWithPath:project),timeout:60,environment:environment,input:try JSONSerialization.data(withJSONObject:request),maximumOutputBytes:16*1024*1024)
        }
        guard result.succeeded else { throw GitError.command(result.timedOut ? "DSH session discovery timed out." : result.output) }
        guard let line = result.output.components(separatedBy:.newlines).last(where:{ $0.hasPrefix("LINVELL_DSH:") }),let value = try JSONSerialization.jsonObject(with:Data(line.dropFirst("LINVELL_DSH:".count).utf8)) as? [String:Any] else { throw GitError.command("Unsupported DSH session metadata response.") }
        if let error = value["error"] as? String { throw GitError.command(error) }
        return try JSONDecoder().decode([AgentSession].self,from:JSONSerialization.data(withJSONObject:value["sessions"] ?? []))
    }
    public static let remoteLauncher = #"""
import os,sys,json,shutil,subprocess
try:
    req=json.load(sys.stdin)
    real=os.path.realpath(req['executable'])
    runtime=None
    if '.app/Contents/' in real:
        candidate=real.split('.app/Contents/')[0]+'.app/Contents/Resources/runtime/primary-runtime/dependencies/node/bin/node'
        if os.path.isfile(candidate) and os.access(candidate,os.X_OK):runtime=candidate
    runtime=runtime or shutil.which('node')
    if not runtime:raise ValueError('DSH session discovery requires its installed Node runtime.')
    subprocess.run([runtime,'-e',req['script']],input=json.dumps(req).encode(),stdout=sys.stdout,stderr=sys.stderr,timeout=50,check=True)
except Exception as error:print('LINVELL_DSH:'+json.dumps(dict(sessions=[],error=str(error))))
"""#
    public static let script = #"""
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),zlib=require('node:zlib'),readline=require('node:readline'),{Readable}=require('node:stream');
(async()=>{
 const req=JSON.parse(fs.readFileSync(0,'utf8'));const root=path.join(req.home||process.env.DSH_HOME||path.join(os.homedir(),'.dsh'),'sessions');
 const canonical=p=>{try{return fs.realpathSync(p)}catch{return path.resolve(p)}};const project=canonical(req.project),sessions=new Map(),projects=new Set([project]);
 const readtext=p=>{try{return fs.readFileSync(p,'utf8').trim()}catch{return null}};
 const gitdir=p=>{const marker=path.join(p,'.git');try{if(fs.statSync(marker).isDirectory())return canonical(marker)}catch{}const text=readtext(marker);return text?.startsWith('gitdir: ')?canonical(path.resolve(p,text.slice(8))):null};
 let common=gitdir(project);if(common){const relative=readtext(path.join(common,'commondir'));if(relative)common=canonical(path.resolve(common,relative));const worktrees=path.join(common,'worktrees');let names=[];try{names=fs.readdirSync(worktrees)}catch{}
  for(const name of names){const entry=path.join(worktrees,name),pointer=readtext(path.join(entry,'gitdir'));if(pointer){const candidate=path.dirname(canonical(path.resolve(entry,pointer)));if(gitdir(candidate)===canonical(entry))projects.add(candidate)}}
  if(path.basename(common)==='.git'&&gitdir(path.dirname(common))===common)projects.add(path.dirname(common));}
 async function* decodedChunks(file){
  let pending=Buffer.alloc(0);const input=fs.createReadStream(file,{highWaterMark:65536});
  try{for await(const chunk of input){
   if(!file.endsWith('.zstd')){yield chunk;continue}
   pending=Buffer.concat([pending,chunk]);
   while(pending.length){
    let result;try{result=zlib.zstdDecompressSync(pending,{info:true,maxOutputLength:16*1024*1024})}
    catch(error){if(error.code==='Z_BUF_ERROR')break;throw error}
    const consumed=result.engine.bytesWritten;
    if(!consumed||consumed>pending.length)throw Error('Invalid DSH compressed frame.');
    yield result.buffer;pending=pending.subarray(consumed);
   }
   if(pending.length>16*1024*1024)throw Error('DSH compressed frame exceeds the metadata limit.');
  }}finally{input.destroy()}
  // Newer Node codecs consume concatenated frames in one call. At EOF retain
  // their complete output even when a writer has left the last frame unfinished.
  if(pending.length){const result=zlib.zstdDecompressSync(pending,{finishFlush:zlib.constants.ZSTD_e_flush,maxOutputLength:16*1024*1024});if(result.length)yield result}
 }
 async function scan(directory){
  let entries;try{entries=await fs.promises.readdir(directory,{withFileTypes:true})}catch(e){if(e.code==='ENOENT')return;throw e}
  const logs=entries.filter(e=>e.isFile()&&/^session(?:\.v\d+)?\.jsonl(?:\.zstd)?$/.test(e.name)).sort((a,b)=>Number((b.name.match(/\.v(\d+)/)||[])[1]||0)-Number((a.name.match(/\.v(\d+)/)||[])[1]||0));
  if(logs.length){
   const file=path.join(directory,logs[0].name);
   if(file.endsWith('.zstd')&&!zlib.zstdDecompressSync)throw Error('DSH session logs require Node with Zstandard support. Select the runtime shipped with DSH.');
   const stream=Readable.from(decodedChunks(file)),source=stream;
   let header,title,first;const lines=readline.createInterface({input:source,crlfDelay:Infinity});
   try{for await(const line of lines){let value;try{value=JSON.parse(line)}catch{continue}
    if(value.type==='session'&&!header){header=value;if(!header.cwd||!projects.has(canonical(header.cwd))||header.origin==='subagent'||header.delegationDepth>0){stream.destroy();lines.close();return}}
    if(value.type==='session/title'&&typeof value.data?.title==='string'&&value.data.title.trim())title=value.data.title.trim();
    if(!first&&value.type==='user/message'&&value.data?.source?.kind==='user'){first=(value.data.content||[]).filter(b=>b.type==='text').map(b=>b.text).join(' ').trim().slice(0,160)}
   }}catch(e){if(!header)throw e}finally{stream.destroy()}
   if(header?.id&&header.cwd&&projects.has(canonical(header.cwd))){const stats=await fs.promises.stat(file);sessions.set(header.id,{id:header.id,title:(title||first||'Untitled session').replace(/\s+/g,' '),cwd:header.cwd,locator:header.id,updated:stats.mtimeMs/1000})}
  }else for(const entry of entries)if(entry.isDirectory()&&!entry.name.startsWith('.'))await scan(path.join(directory,entry.name));
 }
 await scan(root);console.log('LINVELL_DSH:'+JSON.stringify({sessions:[...sessions.values()].sort((a,b)=>b.updated-a.updated)}));
})().catch(error=>{console.log('LINVELL_DSH:'+JSON.stringify({sessions:[],error:String(error.message||error)}))});
"""#
}
