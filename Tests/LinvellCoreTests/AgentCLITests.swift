import XCTest
@testable import LinvellCore

final class AgentCLITests: XCTestCase {
    func fixture() throws -> URL {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/agent-test-fixtures/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }; return root
    }
    func jsonl(_ values: [[String:Any]]) throws -> Data {
        var data = Data()
        for value in values { data.append(try JSONSerialization.data(withJSONObject:value)); data.append(10) }; return data
    }
    func write(_ data: Data,to file: URL) throws {
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true); try data.write(to:file)
    }
    func testCodexProjectIsolationArchiveDedupAndIncompleteTail() throws {
        let root = try fixture(),project = root.appendingPathComponent("project")
        let store = root.appendingPathComponent("sessions"),archive = root.appendingPathComponent("archive")
        var data = try jsonl([["type":"session_meta","payload":["id":"session-a","cwd":project.path]], ["type":"event_msg","payload":["type":"user_message","message":"Continue editing"]]])
        data.append(Data("{\"type\":".utf8))
        try write(data,to:store.appendingPathComponent("2026/10/a.jsonl")); try write(data,to:archive.appendingPathComponent("a.jsonl"))
        try write(jsonl([["type":"session_meta","payload":["id":"other","cwd":project.path+"-other"]]]),to:store.appendingPathComponent("other.jsonl"))
        try FileManager.default.createSymbolicLink(at:store.appendingPathComponent("linked.jsonl"),withDestinationURL:archive.appendingPathComponent("a.jsonl"))
        let sessions = try AgentCLI.sessions(kind:.codex,project:project.path,storage:[store,archive])
        XCTAssertEqual(sessions.count,1); XCTAssertEqual(sessions.first?.id,"session-a"); XCTAssertEqual(sessions.first?.title,"Continue editing")
        XCTAssertEqual(AgentKind.codex.arguments(session:sessions.first),["resume","session-a"])
    }
    func testClaudeAndPiMetadataAndNativeResumeArguments() throws {
        let claude = try XCTUnwrap(AgentCLI.parseSession(jsonl([["type":"user","sessionId":"claude-a","cwd":"/work/project","message":["content":"Fix navigation"]],["type":"custom-title","customTitle":"Navigation"]]),kind:.claude,file:"/store/a.jsonl",updated:10))
        XCTAssertEqual(claude.title,"Navigation"); XCTAssertEqual(AgentKind.claude.arguments(session:claude),["--resume","claude-a"])
        let pi = try XCTUnwrap(AgentCLI.parseSession(jsonl([["type":"session","id":"pi-a","cwd":"/work/project"],["type":"session_info","name":"Parser"]]),kind:.pi,file:"/store/tree.jsonl",updated:12))
        XCTAssertEqual(pi.title,"Parser"); XCTAssertEqual(AgentKind.pi.arguments(session:pi),["--session","/store/tree.jsonl"])
        XCTAssertNil(AgentCLI.parseSession(try jsonl([["type":"user","sessionId":"child","cwd":"/work/project","isSidechain":true]]),kind:.claude,file:"a",updated:0))
    }
    func testAllJSONLProvidersUseSavedNamesIncludingLateRenames() throws {
        let root = try fixture(),project = root.appendingPathComponent("project")
        for kind in [AgentKind.claude,.pi] {
            let store = root.appendingPathComponent(kind.rawValue)
            var data = try jsonl(kind == .pi ? [["type":"session","id":"named","cwd":project.path],["type":"message","message":["role":"user","content":[["type":"text","text":"First task"]]]]] : [["type":"user","sessionId":"named","cwd":project.path,"message":["content":[["type":"text","text":"First task"]]]]])
            data.append(try jsonl([["type":"ignored","padding":String(repeating:"x",count:300_000)]]))
            data.append(try jsonl(kind == .pi ? [["type":"session_info","name":"Saved Pi title"]] : [["type":"custom-title","customTitle":"Saved Claude title"]]))
            try write(data,to:store.appendingPathComponent("named.jsonl"))
            let session = try XCTUnwrap(AgentCLI.sessions(kind:kind,project:project.path,storage:[store]).first)
            XCTAssertEqual(session.title,kind == .pi ? "Saved Pi title" : "Saved Claude title")
        }
        let store = root.appendingPathComponent("codex/sessions")
        try write(jsonl([["type":"session_meta","payload":["id":"named","cwd":project.path]]]),to:store.appendingPathComponent("named.jsonl"))
        try write(jsonl([["id":"named","thread_name":"Saved Codex title"]]),to:store.deletingLastPathComponent().appendingPathComponent("session_index.jsonl"))
        XCTAssertEqual(try AgentCLI.sessions(kind:.codex,project:project.path,storage:[store]).first?.title,"Saved Codex title")
    }
    func testCodexUsesOfficialThreadListTitlesPaginationAndArchives() throws {
        let root = try fixture(),cli = root.appendingPathComponent("codex")
        let script = #"""
#!/usr/bin/python3
import sys,json
for line in sys.stdin:
    req=json.loads(line)
    if 'id' not in req:continue
    if req['method']=='initialize':result={}
    else:
        params=req['params'];archived=params['archived'];cursor=params.get('cursor')
        identity='archive' if archived else 'second' if cursor else 'first'
        result=dict(data=[dict(id=identity,cwd=params['cwd'],name='Named '+identity,preview='Preview',updatedAt=1)],nextCursor=None if archived or cursor else 'next')
    print(json.dumps(dict(id=req['id'],result=result)),flush=True)
"""#
        try write(Data(script.utf8),to:cli); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        let sessions = try AgentCodexSessions.list(executable:cli.path,project:root.path)
        XCTAssertEqual(Set(sessions.map(\.title)),["Named first","Named second","Named archive"])
        XCTAssertEqual(AgentCodexSessions.parseThread(["id":"preview","cwd":root.path,"preview":"First user task"],project:root.path)?.title,"First user task")
    }
    func testDSHCompressedSessionUsesLatestTitleAndResumesWithTask() throws {
        let root = try fixture(),project = root.appendingPathComponent("project"),home = root.appendingPathComponent("dsh")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        guard let node = ToolCommand.executable("node") else { throw XCTSkip("Node is not installed") }
        let log = home.appendingPathComponent("sessions/project/session-a/session.v4.jsonl.zstd")
        let data = try jsonl([["type":"session","version":4,"id":"session-a","cwd":project.path,"delegationDepth":0], ["type":"user/message","data":["source":["kind":"user"],"content":[["type":"text","text":"Original task"]]]], ["type":"session/title","data":["title":"Earlier title"]], ["type":"assistant/message","data":["text":String(repeating:"content",count:20000)]], ["type":"session/title","data":["title":"Saved DSH title"]]])
        try FileManager.default.createDirectory(at:log.deletingLastPathComponent(),withIntermediateDirectories:true)
        let compressed = try ToolCommand.run(node,arguments:["-e","const fs=require('fs'),z=require('zlib');fs.writeFileSync(process.argv[1],Buffer.concat(fs.readFileSync(0,'utf8').trimEnd().split('\\n').map(line=>z.zstdCompressSync(Buffer.from(line+'\\n')))))",log.path],directory:project,input:data)
        XCTAssertTrue(compressed.succeeded)
        // The writer may be appending another frame during discovery.
        let handle = try FileHandle(forWritingTo:log); try handle.seekToEnd()
        try handle.write(contentsOf:Data([0x28,0xb5,0x2f,0xfd])); try handle.close()
        var env = AgentCLI.environment; env["DSH_HOME"] = home.path
        let sessions = try AgentDSHSessions.list(executable:"/fixture/dsh",project:project.path,environment:env)
        XCTAssertEqual(sessions.first?.title,"Saved DSH title")
        XCTAssertEqual(AgentKind.dsh.arguments(session:sessions.first,task:"--literal; $(task)"),["headless","--session-id","session-a","--","--literal; $(task)"])
    }
    func testOpenCodeJSONUsesExactDirectoryAndUpdatedTime() throws {
        let data = try JSONSerialization.data(withJSONObject:[["id":"ses_a","directory":"/work/project","title":"Task","time":["updated":4000]],["id":"ses_b","directory":"/work/project-other","title":"Other"]])
        let sessions = try AgentCLI.openCodeSessions(data,project:"/work/project")
        XCTAssertEqual(sessions.map(\.id),["ses_a"]); XCTAssertEqual(sessions.first?.updated,4)
        XCTAssertEqual(AgentKind.opencode.arguments(session:sessions.first),["--session","ses_a"])
        XCTAssertThrowsError(try AgentCLI.openCodeSessions(Data("{}".utf8),project:"/work/project"))
    }
    func testDesktopDiscoveryOnlyAcceptsKnownExecutableCLI() throws {
        let root = try fixture(),app = root.appendingPathComponent("Codex.app")
        let cli = app.appendingPathComponent("Contents/Resources/codex")
        try write(Data("#!/bin/sh\nexit 0\n".utf8),to:cli); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        let gui = app.appendingPathComponent("Contents/MacOS/Codex")
        try write(Data("#!/bin/sh\nexit 0\n".utf8),to:gui); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:gui.path)
        let found = AgentCLI.discover(home:root,applicationDirectories:[root]).filter { $0.source == "Codex.app" }
        XCTAssertEqual(found.count,1); XCTAssertTrue(AgentCLI.sameProject(try XCTUnwrap(found.first).path,cli.path))
    }
    func testSyncMappingsRejectUnregisteredCopiesAndMapOnlyDescendants() throws {
        let mapping = AgentSyncMapping(host:"example",remoteRoot:"/work/project",localRoot:"/Volumes/project")
        XCTAssertEqual(mapping.remotePath(for:"/Volumes/project/src/a.swift"),"/work/project/src/a.swift")
        XCTAssertNil(mapping.remotePath(for:"/Volumes/project/../secret"))
        XCTAssertThrowsError(try AgentSyncMapping(host:"example",remoteRoot:"/work/project",localRoot:fixture().path).validate())
    }
    func testRemoteProbeMatchesLocalParsingWithoutInstallingServer() throws {
        let root = try fixture(),store = root.appendingPathComponent("agent/sessions"),project = root.appendingPathComponent("project ' with spaces")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let data = try jsonl([["type":"session_meta","payload":["id":"resume-a","cwd":project.path]],["type":"event_msg","payload":["type":"user_message","message":"Continue"]]])
        try write(data,to:store.appendingPathComponent("a.jsonl"))
        let input = try JSONSerialization.data(withJSONObject:["project":project.path,"kind":"codex","agentHome":root.appendingPathComponent("agent").path])
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/python3"),arguments:["-c",SSHRemote.agentSessionProbe],directory:project,input:input)
        XCTAssertTrue(result.succeeded)
        let line = try XCTUnwrap(result.output.components(separatedBy:.newlines).last { $0.hasPrefix("LINVELL_AGENTS:") })
        let remote = try JSONDecoder().decode(AgentRemoteSnapshot.self,from:Data(line.dropFirst("LINVELL_AGENTS:".count).utf8))
        XCTAssertNil(remote.error)
        let local = try AgentCLI.sessions(kind:.codex,project:project.path,storage:[store])
        XCTAssertEqual(remote.sessions.map(\.id),local.map(\.id)); XCTAssertEqual(remote.sessions.map(\.title),local.map(\.title)); XCTAssertEqual(remote.sessions.map(\.cwd),local.map(\.cwd))
        XCTAssertEqual(try XCTUnwrap(remote.sessions.first?.updated),try XCTUnwrap(local.first?.updated),accuracy:0.001)
        let command = AgentCLI.command(executable:"/opt/agent's bin/codex",kind:.codex,session:local.first)
        let shell = try ToolCommand.run(URL(fileURLWithPath:"/bin/sh"),arguments:["-c","set -- "+command+"; printf '%s\\n' \"$@\""],directory:nil)
        XCTAssertEqual(shell.output,"/opt/agent's bin/codex\nresume\nresume-a")
    }
    func testSSHAgentUsesTargetWorkspaceAndOfficialMetadataProtocol() throws {
        guard let file = ProcessInfo.processInfo.environment["LINVELL_SSH_FIXTURE"] else { throw XCTSkip("Disposable SSH agent fixture required") }
        let fixture = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as! [String:String]
        let root = try XCTUnwrap(fixture["root"]),remote = try SSHRemote(host:try XCTUnwrap(fixture["host"]))
        let snapshot = try remote.agentSnapshot(project:root,kind:.codex,executable:root+"/fixture-codex")
        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.sessions.count,1)
        XCTAssertEqual(snapshot.sessions.first?.id,"agent-ssh-acceptance")
        XCTAssertEqual(snapshot.sessions.first?.cwd,root)
        XCTAssertEqual(snapshot.sessions.first?.title,"SSH Agent acceptance")
    }
    func testInstalledCodexMetadataAPIWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["LINVELL_LIVE_AGENTS"] == "1",let project = ProcessInfo.processInfo.environment["LINVELL_AGENT_PROJECT"],let cli = AgentCLI.discover().first(where:{ $0.kind == .codex }) else { throw XCTSkip("Set LINVELL_LIVE_AGENTS and LINVELL_AGENT_PROJECT for installed-CLI acceptance") }
        let sessions = try AgentCodexSessions.list(executable:cli.path,project:project)
        XCTAssertFalse(sessions.isEmpty); XCTAssertTrue(sessions.allSatisfy { !$0.title.isEmpty && $0.title != $0.id })
    }
    func testRemoteEditorProbeReturnsOnlyRequestedFileAndDirectoryMetadata() throws {
        let root = try fixture(),file = root.appendingPathComponent("source with spaces.txt"),missing = root.appendingPathComponent("missing.txt")
        try Data("fixture".utf8).write(to:file)
        let paths = try JSONSerialization.data(withJSONObject:[file.path,root.path,missing.path]).base64EncodedString()
        let input = try JSONSerialization.data(withJSONObject:["operation":"editor-file-states","path":root.path,"content":paths])
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/python3"),arguments:["-c",SSHRemote.agent],directory:root,input:input)
        let line = try XCTUnwrap(result.output.components(separatedBy:.newlines).last { $0.hasPrefix("LINVELL_JSON:") })
        let reply = try JSONDecoder().decode(RemoteReply.self,from:Data(line.dropFirst("LINVELL_JSON:".count).utf8))
        XCTAssertNil(reply.error); XCTAssertEqual(reply.fileStates?.count,3)
        XCTAssertEqual(reply.fileStates?[missing.path],"missing"); XCTAssertNotNil(reply.fileStates?[file.path]); XCTAssertNil(reply.content)
    }
    func testRegisteredDesktopWorktreesBelongToTheProjectWithoutRunningGit() throws {
        let root = try fixture(),main = root.appendingPathComponent("main"),linked = root.appendingPathComponent("desktop-worktree")
        let metadata = main.appendingPathComponent(".git/worktrees/desktop")
        try write(Data(("gitdir: "+metadata.path+"\n").utf8),to:linked.appendingPathComponent(".git"))
        try write(Data((linked.appendingPathComponent(".git").path+"\n").utf8),to:metadata.appendingPathComponent("gitdir"))
        try write(Data("../..\n".utf8),to:metadata.appendingPathComponent("commondir"))
        XCTAssertEqual(Set(AgentCLI.projectDirectories(main.path)),[main.path,linked.path])
        XCTAssertEqual(Set(AgentCLI.projectDirectories(linked.path)),[main.path,linked.path])
        let store = root.appendingPathComponent("sessions")
        try write(jsonl([["type":"session_meta","payload":["id":"desktop","cwd":linked.path]]]),to:store.appendingPathComponent("desktop.jsonl"))
        XCTAssertEqual(try AgentCLI.sessions(kind:.codex,project:main.path,storage:[store]).map(\.id),["desktop"])
        let req = try JSONSerialization.data(withJSONObject:["project":main.path,"kind":"codex","agentHome":root.path])
        let reply = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/python3"),arguments:["-c",SSHRemote.agentSessionProbe],directory:main,input:req)
        let line = try XCTUnwrap(reply.output.components(separatedBy:.newlines).last { $0.hasPrefix("LINVELL_AGENTS:") })
        let snapshot = try JSONDecoder().decode(AgentRemoteSnapshot.self,from:Data(line.dropFirst("LINVELL_AGENTS:".count).utf8))
        XCTAssertEqual(Set(snapshot.projects ?? []),[main.path,linked.path]); XCTAssertEqual(snapshot.sessions.map(\.id),["desktop"])
    }
}
