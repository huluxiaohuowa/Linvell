import XCTest
import LinvellPluginKit
@testable import LinvellCore

final class PluginP45Tests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws { root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/p45-tests/"+UUID().uuidString); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
    func script(_ content: String,name: String = "tool") throws {
        let url = root.appendingPathComponent(name); try ("#!/usr/bin/env python3\n"+content).write(to:url,atomically:true,encoding:.utf8); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:url.path)
    }
    func package(_ overrides: [String:Any] = [:]) throws -> PluginPackage {
        var m: [String:Any] = ["id":"dev.p45","name":"P45","version":"1","protocolVersion":1,"commands":[],"permissions":["document.read"],"tasks":[["id":"task","title":"Task","program":["executable":"tool"]]]]
        m.merge(overrides,uniquingKeysWith:{ _,new in new }); try JSONSerialization.data(withJSONObject:m).write(to:root.appendingPathComponent("plugin.json")); return try PluginPackage(directory:root)
    }
    func testProgramValidationTargetsAndLogs() throws {
        try script("print('ok')")
        let pkg = try package(); XCTAssertNil(pkg.executableURL)
        XCTAssertThrowsError(try package(["execution":"automatic"]))
        XCTAssertThrowsError(try package(["tasks":[["id":"escape","title":"Escape","program":["executable":"../tool"]]]]))
        XCTAssertThrowsError(try package(["executables":["windows-x86_64":"tool"]]))
        let program = PluginProgram(executables:["linux-x86_64":"tool"])
        XCTAssertEqual(try PluginTools.path(program,target:"linux-x86_64"),"tool"); XCTAssertThrowsError(try PluginTools.path(program,target:"linux-aarch64"))
        let logs = PluginLogBuffer(); for _ in 0..<100 { logs.append(String(repeating:"x",count:8192)) }; XCTAssertLessThanOrEqual(logs.text.utf8.count,256*1024)
        let runtime = PluginRuntime(package:pkg,workspace:PluginWorkspace(root:root.path)); XCTAssertEqual(try runtime.command(PluginProgram(executable:"tool",arguments:["${workspaceFolder}/a b"])) .1,[root.path+"/a b"])
        runtime.stop(); XCTAssertThrowsError(try runtime.prepare())
    }
    func testStderrCaptureAndProcessStop() throws {
        try script("import sys,time\nprint('tool diagnostic',file=sys.stderr,flush=True)\ntime.sleep(20)")
        let runtime = PluginRuntime(package:try package(),workspace:nil),logs = PluginLogBuffer()
        let diagnostic = expectation(description:"stderr captured")
        let rpc = try runtime.launch(PluginProgram(executable:"tool"),log:{ text in logs.append(text); if text.contains("tool diagnostic") { diagnostic.fulfill() } })
        wait(for:[diagnostic],timeout:5)
        let done = expectation(description:"request stopped")
        DispatchQueue.global().async { do { _ = try rpc.request("waiting",params:[:],timeout:5); XCTFail("Expected stop") } catch {}; done.fulfill() }
        DispatchQueue.global().asyncAfter(deadline:.now()+0.2) { runtime.stop() }
        wait(for:[done],timeout:3); XCTAssertTrue(logs.text.contains("tool diagnostic")); XCTAssertFalse(rpc.isRunning)
    }
    func testPluginLanguageServerUsesRealClangd() throws {
        guard ProcessInfo.processInfo.environment["LINVELL_REAL_PLUGIN_TOOLS"] == "1" else { throw XCTSkip("Real plugin toolchain acceptance is opt-in") }
        let found = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/xcrun"),arguments:["--find","clangd"],directory:nil)
        guard found.succeeded else { throw XCTSkip("clangd unavailable") }
        try script("import os\nos.execv("+String(reflecting:found.output)+",["+String(reflecting:found.output)+",'--background-index=false','--log=error'])")
        let pkg = try package(["languageServers":[["id":"c","title":"C","languages":["c"],"program":["executable":"tool"]]]])
        let runtime = PluginRuntime(package:pkg,workspace:PluginWorkspace(root:root.path)); defer { runtime.stop() }
        let session = try LanguageSession(rpc:runtime.launch(pkg.manifest.languageServers![0].program),root:root.path,runtime:"")
        let file = root.appendingPathComponent("main.c"),text = "int value = 7;\nint main(void) { return value; }\n"
        try text.write(to:file,atomically:true,encoding:.utf8); session.synchronize(uri:file.absoluteString,language:"c",text:text,version:1)
        let position = CodePosition(line:1,character:25)
        let locations = try CodeLocation.locations(session.request("textDocument/definition",uri:file.absoluteString,position:position)); XCTAssertEqual(locations.first?.range.start.line,0)
        let rename = try CodeWorkspaceEdit.parse(session.request("textDocument/rename",uri:file.absoluteString,position:position,extra:["newName":"renamed"]))
        XCTAssertTrue(try CodeTextEdit.applying(XCTUnwrap(rename.first).edits,to:text).contains("return renamed"))
        XCTAssertFalse(try session.request("textDocument/hover",uri:file.absoluteString,position:position) is NSNull)
        _ = try session.rpc.request("textDocument/formatting",params:["textDocument":["uri":file.absoluteString],"options":["tabSize":4,"insertSpaces":true]])
        let cancellation = LanguageRequestCancellation(); cancellation.cancel(); XCTAssertThrowsError(try session.rpc.request("workspace/symbol",params:["query":"value"],cancellation:cancellation))
    }
    func testRealDAPLaunchStackEvaluateAndDisconnect() throws {
        guard ProcessInfo.processInfo.environment["LINVELL_REAL_PLUGIN_TOOLS"] == "1" else { throw XCTSkip("Real plugin debugger acceptance is opt-in") }
        let found = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/xcrun"),arguments:["--find","lldb-dap"],directory:nil)
        guard found.succeeded else { throw XCTSkip("lldb-dap unavailable") }
        try script("import os\nos.execv("+String(reflecting:found.output)+",["+String(reflecting:found.output)+"])")
        let source = root.appendingPathComponent("main.c"),binary = root.appendingPathComponent("main")
        try "int main(void) {\n int count = 7;\n return count;\n}\n".write(to:source,atomically:true,encoding:.utf8)
        let compile = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/cc"),arguments:["-g",source.path,"-o",binary.path],directory:root); XCTAssertTrue(compile.succeeded)
        let pkg = try package(["debuggers":[["id":"lldb","title":"LLDB","program":["executable":"tool"],"launch":["program":binary.path,"stopOnEntry":true]]]])
        let runtime = PluginRuntime(package:pkg,workspace:PluginWorkspace(root:root.path)); defer { runtime.stop() }
        let debugger = pkg.manifest.debuggers![0],debug = try PluginDebugSession(runtime:runtime,debugger:debugger,logs:PluginLogBuffer())
        let stopped = expectation(description:"debuggee stopped")
        debug.event = { event,_ in if event == "stopped" { stopped.fulfill() } }
        try debug.start(debugger,root:root.path,breakpoints:[source.path:[3]])
        wait(for:[stopped],timeout:10)
        let threads = try debug.request("threads") as? [String:Any]
        let id = try XCTUnwrap((threads?["threads"] as? [[String:Any]])?.first?["id"] as? Int)
        let stack = try debug.request("stackTrace",arguments:["threadId":id]) as? [String:Any]
        let frame = try XCTUnwrap((stack?["stackFrames"] as? [[String:Any]])?.first?["id"] as? Int)
        _ = try debug.request("scopes",arguments:["frameId":frame]); _ = try debug.request("evaluate",arguments:["expression":"1+2","frameId":frame,"context":"repl"])
        debug.disconnect(); XCTAssertFalse(debug.rpc.isRunning)
    }
    func testRemoteTransferExecutionDisconnectAndReconnect() throws {
        guard let host = ProcessInfo.processInfo.environment["LINVELL_PLUGIN_TEST_SSH"] else { throw XCTSkip("Real SSH plugin acceptance is opt-in") }
        try script(Self.echo)
        let pkg = try package(["execution":"workspace","executable":"tool","commands":[["id":"probe","title":"Probe"]]])
        let workspace = PluginWorkspace(root:"/tmp",remote:try SSHRemote(host:host))
        let persistence = PluginPersistence(directory:root.appendingPathComponent("state"))
        let session = PluginSession(package:pkg,persistence:persistence,workspace:workspace)
        XCTAssertEqual(try session.execute(command:"probe").message,"linux")
        let rpc = try session.runtime.launch(PluginProgram(executable:"tool"))
        rpc.stop(); XCTAssertThrowsError(try rpc.request("commands/execute",params:[:]))
        session.stop(); XCTAssertThrowsError(try session.execute(command:"probe"))
        let reconnected = PluginSession(package:pkg,persistence:persistence,workspace:workspace); defer { reconnected.stop() }
        XCTAssertEqual(try reconnected.execute(command:"probe").message,"linux")
    }
    func testSSHTransportStopReapsRemoteProgramGroup() throws {
        guard let host = ProcessInfo.processInfo.environment["LINVELL_PLUGIN_TEST_SSH"] else { throw XCTSkip("Real SSH process cleanup is opt-in") }
        let marker = "~/dev/build/linvell/p45-tests/"+UUID().uuidString+".pid"
        try script("import os\np=os.path.expanduser("+String(reflecting:marker)+")\nos.makedirs(os.path.dirname(p),exist_ok=True)\nopen(p,'w').write(str(os.getpid()))\n"+Self.echo)
        let runtime = PluginRuntime(package:try package(["execution":"workspace"]),workspace:PluginWorkspace(root:"/tmp",remote:try SSHRemote(host:host)))
        defer { runtime.stop() }
        let rpc = try runtime.launch(PluginProgram(executable:"tool"))
        _ = try rpc.request("initialize",params:["protocolVersion":1])
        rpc.stop()
        let verify = "import os,time; p=os.path.expanduser("+String(reflecting:marker)+"); pid=int(open(p).read());\nfor _ in range(40):\n try: os.kill(pid,0)\n except ProcessLookupError: print('reaped');break\n time.sleep(0.1)\nelse: print('alive')\nos.unlink(p)"
        let remote = try SSHRemote(host:host)
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:remote.transportArguments(command:"python3 -c "+SSHRemote.quote(verify)),directory:nil,timeout:10)
        XCTAssertTrue(result.succeeded); XCTAssertEqual(result.output,"reaped")
    }
    func testLinuxSwiftSDKPackageThroughSSHHost() throws {
        guard let host = ProcessInfo.processInfo.environment["LINVELL_PLUGIN_TEST_SSH"],let path = ProcessInfo.processInfo.environment["LINVELL_PLUGIN_LINUX_PACKAGE"] else { throw XCTSkip("Built Linux SDK example acceptance is opt-in") }
        let pkg = try PluginPackage(directory:URL(fileURLWithPath:path))
        let workspace = PluginWorkspace(root:"/tmp",remote:try SSHRemote(host:host))
        let session = PluginSession(package:pkg,persistence:PluginPersistence(directory:root.appendingPathComponent("state")),workspace:workspace); defer { session.stop() }
        XCTAssertTrue(try session.execute(command:"hello.greet",workspace:workspace).message?.contains("#1") == true)
        XCTAssertEqual(try session.execute(command:"hello.uppercase",document:PluginDocument(text:"Linux 中文",revision:1),workspace:workspace).replacementText,"LINUX 中文")
    }
    static let echo = #"""
import sys,json
while True:
    size=0
    while True:
        line=sys.stdin.buffer.readline()
        if not line:sys.exit(0)
        if line==b'\r\n':break
        if line.lower().startswith(b'content-length:'):size=int(line.split(b':')[1])
    req=json.loads(sys.stdin.buffer.read(size))
    result={'protocolVersion':1} if req['method']=='initialize' else {'message':sys.platform}
    body=json.dumps({'jsonrpc':'2.0','id':req['id'],'result':result}).encode()
    sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n'%len(body)).encode()+body);sys.stdout.buffer.flush()
"""#
}
