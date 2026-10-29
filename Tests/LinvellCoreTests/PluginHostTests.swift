import XCTest
import LinvellPluginKit
@testable import LinvellCore

final class PluginHostTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/plugin-tests/"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:directory) }
    func package(permissions: [String] = ["document.read","document.write"],executable: String = "fixture",protocolVersion: Int = 1, events: [String] = [],views: [[String:Any]] = []) throws -> PluginPackage {
        guard let python = ToolCommand.executable("python3") else { throw XCTSkip("Python fixture runtime unavailable") }
        let script = #"""
import sys,json,time
while True:
    length=None
    while True:
        line=sys.stdin.buffer.readline()
        if not line: sys.exit(0)
        if line==b'\r\n': break
        if line.lower().startswith(b'content-length:'): length=int(line.split(b':')[1])
    req=json.loads(sys.stdin.buffer.read(length));p=req['params']
    if req['method']=='initialize': result={'protocolVersion':1,'capabilities':['documentEvents']}
    elif req['method']=='documents/event':
        log=p['environment']['globalState'].get('events',[])+[[p['kind'],p['revision']]]
        result={'stateUpdates':[{'scope':'global','key':'events','value':log}]}
    else:
        cmd=p['command']
        if cmd=='fixture.hang': time.sleep(2)
        if cmd=='fixture.crash': sys.exit(1)
        result={'message':'中文 🐱'}
        if cmd=='fixture.transform': result['replacementText']=p.get('document',{}).get('text','unexpected').upper()
        if cmd=='fixture.read': result['message']='read' if 'document' in p else 'none'
        if cmd=='fixture.events': result['message']=json.dumps(p['environment']['globalState'].get('events',[]))
        if cmd=='fixture.range': result={'edits':[{'location':0,'length':0,'text':'Hi '}],'documentRevision':p['document']['revision']}
        if cmd=='fixture.state': result={'stateUpdates':[{'scope':'global','key':'count','value':1}]}
        if cmd=='fixture.ui': result={'message':p.get('uiEvent',{}).get('itemID','none'),'viewUpdates':[{'id':'list','items':[{'id':'new','title':'Native result','command':'fixture.read'}]}]}
        if cmd=='fixture.invalidUI': result={'viewUpdates':[{'id':'unknown','text':'bad'}]}
    body=json.dumps({'jsonrpc':'2.0','id':req['id'],'result':result},ensure_ascii=False).encode()
    sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n'%len(body)).encode()+body);sys.stdout.buffer.flush()
"""#
        let fixture = directory.appendingPathComponent("fixture")
        try ("#!"+python.path+"\n"+script).write(to:fixture,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:fixture.path)
        let manifest: [String:Any] = ["id":"dev.fixture","name":"Fixture","version":"1","protocolVersion":protocolVersion,"executable":executable,"permissions":permissions,"events":events,"views":views,"commands":["transform","read","hang","crash","events","range","state","ui","invalidUI"].map { ["id":"fixture."+$0,"title":$0] }]
        try JSONSerialization.data(withJSONObject:manifest).write(to:directory.appendingPathComponent("plugin.json"))
        return try PluginPackage(directory:directory)
    }
    func testHandshakeUnicodeAndMultipleCommands() throws {
        let session = PluginSession(package:try package(),persistence:PluginPersistence(directory:directory.appendingPathComponent("state"))); defer { session.stop() }
        let result = try session.execute(command:"fixture.transform",document:PluginDocument(text:"hello 中文 🐱",revision:4))
        XCTAssertEqual(result.replacementText,"HELLO 中文 🐱"); XCTAssertEqual(result.message,"中文 🐱")
        XCTAssertEqual(try session.execute(command:"fixture.read").message,"none")
        XCTAssertThrowsError(try session.execute(command:"not.declared"))
    }
    func testReadAndWritePermissionsAreEnforcedByHost() throws {
        let session = PluginSession(package:try package(permissions:[]),persistence:PluginPersistence(directory:directory.appendingPathComponent("state"))); defer { session.stop() }
        let document = PluginDocument(text:"secret",revision:0)
        XCTAssertEqual(try session.execute(command:"fixture.read",document:document).message,"none")
        XCTAssertThrowsError(try session.execute(command:"fixture.transform",document:document)) { XCTAssertEqual($0 as? PluginError,.permissionDenied) }
        let readOnly = PluginSession(package:try package(permissions:["document.read"]),persistence:PluginPersistence(directory:directory.appendingPathComponent("state"))); defer { readOnly.stop() }
        XCTAssertThrowsError(try readOnly.execute(command:"fixture.transform",document:document))
    }
    func testRejectsProtocolPathEscapeAndSymlinkEscape() throws {
        XCTAssertThrowsError(try package(protocolVersion:2))
        XCTAssertThrowsError(try package(executable:"../fixture"))
        XCTAssertThrowsError(try package(permissions:["network"]))
        XCTAssertThrowsError(try package(permissions:["document.write"]))
        try FileManager.default.createSymbolicLink(at:directory.appendingPathComponent("outside"),withDestinationURL:URL(fileURLWithPath:"/bin/sh"))
        XCTAssertThrowsError(try package(executable:"outside"))
    }
    func testTimeoutCrashStopAndRestart() throws {
        let pkg = try package(),timeout = PluginSession(package:pkg,persistence:PluginPersistence(directory:directory.appendingPathComponent("state")))
        XCTAssertThrowsError(try timeout.execute(command:"fixture.hang",timeout:0.1))
        XCTAssertThrowsError(try timeout.execute(command:"fixture.read"))
        let crash = PluginSession(package:pkg,persistence:PluginPersistence(directory:directory.appendingPathComponent("state")))
        XCTAssertThrowsError(try crash.execute(command:"fixture.crash",timeout:1))
        let restarted = PluginSession(package:pkg,persistence:PluginPersistence(directory:directory.appendingPathComponent("state")))
        XCTAssertEqual(try restarted.execute(command:"fixture.read").message,"none")
        restarted.stop(); XCTAssertThrowsError(try restarted.execute(command:"fixture.read"))
    }
    func testStopInterruptsPendingCommand() throws {
        let session = PluginSession(package:try package(),persistence:PluginPersistence(directory:directory.appendingPathComponent("state"))),done = expectation(description:"stopped")
        DispatchQueue.global().async {
            do { _ = try session.execute(command:"fixture.hang"); XCTFail("Expected cancellation") } catch {}
            done.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline:.now()+0.1) { session.stop() }
        wait(for:[done],timeout:2)
    }
    func testRangeResultsAndStoragePermission() throws {
        let session = PluginSession(package:try package(),persistence:PluginPersistence(directory:directory.appendingPathComponent("state")))
        defer { session.stop() }
        let result = try session.execute(command:"fixture.range",document:PluginDocument(text:"中文 🐱",revision:2))
        XCTAssertEqual(result.edits?.first?.text,"Hi "); XCTAssertEqual(result.documentRevision,2)
        XCTAssertThrowsError(try session.execute(command:"fixture.state")) { XCTAssertEqual($0 as? PluginError,.permissionDenied) }
    }
    func testEventLifecycleOrderingAndChangeCoalescing() throws {
        let session = PluginSession(package:try package(permissions:["document.read","storage"],events:["open","change","save","close"]),persistence:PluginPersistence(directory:directory.appendingPathComponent("state")))
        defer { session.stop() }
        session.enqueue(PluginDocumentEvent(kind:.open,documentID:"doc",revision:0))
        for revision in 1...200 { session.enqueue(PluginDocumentEvent(kind:.change,documentID:"doc",revision:revision)) }
        session.enqueue(PluginDocumentEvent(kind:.save,documentID:"doc",revision:200))
        session.enqueue(PluginDocumentEvent(kind:.close,documentID:"doc",revision:200))
        let result = try session.execute(command:"fixture.events")
        let log = try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(try XCTUnwrap(result.message).utf8)) as? [[Any]])
        XCTAssertEqual(log.first?.first as? String,"open"); XCTAssertEqual(log.last?.first as? String,"close")
        let changes = log.filter { $0[0] as? String == "change" }
        XCTAssertEqual(changes.last?[1] as? Int,200); XCTAssertLessThan(changes.count,200)
        XCTAssertEqual(log[log.count-2][0] as? String,"save")
    }

    func testNativeUIResponsesValidateDeclaredViewsAndForwardItemIdentity() throws {
        let session = PluginSession(package:try package(views:[["id":"list","title":"List","kind":"list"]]),persistence:PluginPersistence(directory:directory.appendingPathComponent("state")))
        defer { session.stop() }; var updates: [PluginViewUpdate] = []
        session.uiUpdated = { updates = $0 }
        let result = try session.execute(command:"fixture.ui",uiEvent:PluginUIEvent(viewID:"list",kind:"activate",itemID:"selected"))
        XCTAssertEqual(result.message,"selected"); XCTAssertEqual(updates.first?.items?.first?.title,"Native result")
        XCTAssertThrowsError(try session.execute(command:"fixture.invalidUI")); XCTAssertTrue(session.isStopped)
        XCTAssertEqual(updates.first?.id,"list")
    }

}
