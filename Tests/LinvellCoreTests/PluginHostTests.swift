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
    func package(permissions: [String] = ["document.read","document.write"],executable: String = "fixture",protocolVersion: Int = 1) throws -> PluginPackage {
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
    if req['method']=='initialize': result={'protocolVersion':1}
    else:
        cmd=p['command']
        if cmd=='fixture.hang': time.sleep(2)
        if cmd=='fixture.crash': sys.exit(1)
        result={'message':'中文 🐱'}
        if cmd=='fixture.transform': result['replacementText']=p.get('document',{}).get('text','unexpected').upper()
        if cmd=='fixture.read': result['message']='read' if 'document' in p else 'none'
    body=json.dumps({'jsonrpc':'2.0','id':req['id'],'result':result},ensure_ascii=False).encode()
    sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n'%len(body)).encode()+body);sys.stdout.buffer.flush()
"""#
        let fixture = directory.appendingPathComponent("fixture")
        try ("#!"+python.path+"\n"+script).write(to:fixture,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:fixture.path)
        let manifest: [String:Any] = ["id":"dev.fixture","name":"Fixture","version":"1","protocolVersion":protocolVersion,"executable":executable,"permissions":permissions,"commands":["transform","read","hang","crash"].map { ["id":"fixture."+$0,"title":$0] }]
        try JSONSerialization.data(withJSONObject:manifest).write(to:directory.appendingPathComponent("plugin.json"))
        return try PluginPackage(directory:directory)
    }
    func testHandshakeUnicodeAndMultipleCommands() throws {
        let session = PluginSession(package:try package()); defer { session.stop() }
        let result = try session.execute(command:"fixture.transform",document:PluginDocument(text:"hello 中文 🐱",revision:4))
        XCTAssertEqual(result.replacementText,"HELLO 中文 🐱"); XCTAssertEqual(result.message,"中文 🐱")
        XCTAssertEqual(try session.execute(command:"fixture.read").message,"none")
        XCTAssertThrowsError(try session.execute(command:"not.declared"))
    }
    func testReadAndWritePermissionsAreEnforcedByHost() throws {
        let session = PluginSession(package:try package(permissions:[])); defer { session.stop() }
        let document = PluginDocument(text:"secret",revision:0)
        XCTAssertEqual(try session.execute(command:"fixture.read",document:document).message,"none")
        XCTAssertThrowsError(try session.execute(command:"fixture.transform",document:document)) { XCTAssertEqual($0 as? PluginError,.permissionDenied) }
        let readOnly = PluginSession(package:try package(permissions:["document.read"])); defer { readOnly.stop() }
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
        let pkg = try package(),timeout = PluginSession(package:pkg)
        XCTAssertThrowsError(try timeout.execute(command:"fixture.hang",timeout:0.1))
        XCTAssertThrowsError(try timeout.execute(command:"fixture.read"))
        let crash = PluginSession(package:pkg)
        XCTAssertThrowsError(try crash.execute(command:"fixture.crash",timeout:1))
        let restarted = PluginSession(package:pkg)
        XCTAssertEqual(try restarted.execute(command:"fixture.read").message,"none")
        restarted.stop(); XCTAssertThrowsError(try restarted.execute(command:"fixture.read"))
    }
    func testStopInterruptsPendingCommand() throws {
        let session = PluginSession(package:try package()),done = expectation(description:"stopped")
        DispatchQueue.global().async {
            do { _ = try session.execute(command:"fixture.hang"); XCTFail("Expected cancellation") } catch {}
            done.fulfill()
        }
        DispatchQueue.global().asyncAfter(deadline:.now()+0.1) { session.stop() }
        wait(for:[done],timeout:2)
    }
}
