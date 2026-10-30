import XCTest
import AppKit
import WebKit
@testable import Linvell
@testable import LinvellCore

final class AgentDSHTests: XCTestCase {
    private func wait(_ seconds: TimeInterval = 45,until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(),Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        return condition()
    }
    private func evaluate(_ web: WKWebView,_ script: String) throws -> Any? {
        var result: Result<Any?,Error>?
        web.evaluateJavaScript(script) { value,error in result = error.map(Result.failure) ?? .success(value) }
        XCTAssertTrue(wait(10) { result != nil })
        return try XCTUnwrap(result).get()
    }
    private func evaluateAsync(_ web: WKWebView,_ script: String,arguments: [String:Any] = [:]) throws -> Any? {
        var result: Result<Any,Error>?
        web.callAsyncJavaScript(script,arguments:arguments,in:nil,in:.page) { result = $0 }
        XCTAssertTrue(wait(30) { result != nil })
        return try XCTUnwrap(result).get()
    }
    func testLaunchURLHandlesTerminalWrappingAndRejectsOtherHosts() {
        XCTAssertEqual(AgentDSHView.launchURL(in:"dsh web: http://127.0.0.1:1234/?token=abc\r\ndef_123\n")?.query,"token=abcdef_123")
        XCTAssertNil(AgentDSHView.launchURL(in:"dsh web: https://example.com/?token=abc"))
    }
    func testInstalledDSHCreatesBlankAndDoubleClickRestoresExactConversation() throws {
        guard ProcessInfo.processInfo.environment["LINVELL_DSH_LIVE"] == "1" else { throw XCTSkip("Explicit installed DSH acceptance run required") }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/agent-test-fixtures/dsh-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let view = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:800),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.makeKeyAndOrderFront(nil)
        let keys = ["agentCLI.local.dsh.path","agentCLI.local.dsh.home"]
        let saved = keys.map { UserDefaults.standard.object(forKey:$0) }
        defer { view.shutdown(); window.close(); for (key,value) in zip(keys,saved) { UserDefaults.standard.set(value,forKey:key) }; try? FileManager.default.removeItem(at:root) }
        view.kindPicker.selectItem(at:AgentKind.allCases.firstIndex(of:.dsh)!)
        view.path.stringValue = "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"
        view.agentHome.stringValue = ""
        view.startNew()
        let runtime = try XCTUnwrap(view.activeRuntime),dsh = try XCTUnwrap(runtime.dshView)
        XCTAssertTrue(wait { dsh.ready || dsh.failed }); XCTAssertFalse(dsh.failed,dsh.failureStage)
        let id = try XCTUnwrap(runtime.sessionID)
        XCTAssertTrue(runtime.terminal.process.running)
        XCTAssertTrue(dsh.superview === view.terminalHost)
        XCTAssertTrue(wait { (try? self.evaluate(dsh.webView,"document.querySelector('[data-conversation-session]')?.getAttribute('data-conversation-session')")) as? String == id })
        XCTAssertEqual(try evaluate(dsh.webView,"JSON.parse(localStorage.getItem('dsh.sessions.current')).sessionId") as? String,id)
        let accountReady = try evaluateAsync(dsh.webView,"""
        async function rpc(method, args) {
            const rpcId = crypto.randomUUID();
            const response = await fetch('/api/'+method, {method:'POST', credentials:'include', headers:{'content-type':'application/json'},
                body:JSON.stringify({type:'client-request',rpcId,method,payload:{args}})});
            const envelope = await response.json();
            if (!envelope.result?.ok) throw new Error('DSH acceptance RPC failed');
            return envelope.result.value;
        }
        if ((await rpc('account/getState', {})).status !== 'credential-stored') return false;
        const result = await rpc('session/prompt', {request:{sessionId:id,requestId:crypto.randomUUID(),mode:'queue',
            content:[{type:'text',text:'Reply with exactly LINVELL_DSH_OK. Do not use tools.'}]}});
        return result.accepted === true;
        """,arguments:["id":id]) as? Bool
        XCTAssertEqual(accountReady,true,"The installed account must work without providing an API key.")
        XCTAssertTrue(wait(90) { (try? self.evaluate(dsh.webView,"Array.from(document.querySelectorAll('[data-chat-group-part=response]')).some(e => e.innerText.includes('LINVELL_DSH_OK'))")) as? Bool == true })
        // Exercise the real table's double action with no task entered.
        view.filtered = [AgentSession(id:id,title:"DSH acceptance",cwd:root.path,locator:id,updated:Date().timeIntervalSince1970)]
        view.table.reloadData(); view.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        NSApp.sendAction(try XCTUnwrap(view.table.doubleAction),to:view.table.target,from:view.table)
        XCTAssertTrue(view.activeRuntime === runtime)
        // A stopped historical conversation must also open without a task.
        view.stopAgent(); XCTAssertTrue(wait(5) { !runtime.terminal.process.running })
        NSApp.sendAction(try XCTUnwrap(view.table.doubleAction),to:view.table.target,from:view.table)
        let resumed = try XCTUnwrap(view.activeRuntime),resumedDSH = try XCTUnwrap(resumed.dshView)
        XCTAssertFalse(resumed === runtime)
        XCTAssertTrue(wait { resumedDSH.ready || resumedDSH.failed }); XCTAssertFalse(resumedDSH.failed,resumedDSH.failureStage)
        XCTAssertEqual(resumed.sessionID,id)
        XCTAssertTrue(wait { (try? self.evaluate(resumedDSH.webView,"document.querySelector('[data-conversation-session]')?.getAttribute('data-conversation-session')")) as? String == id })
        XCTAssertTrue(wait { (try? self.evaluate(resumedDSH.webView,"Array.from(document.querySelectorAll('[data-chat-group-part=response]')).some(e => e.innerText.includes('LINVELL_DSH_OK'))")) as? Bool == true })
    }
}
