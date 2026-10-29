import XCTest
import AppKit
@testable import Linvell
@testable import LinvellCore

final class LanguageBackendLifecycleTests: XCTestCase {
    func testJavaScriptAndTypeScriptShareOneMatchingBackendAndReleaseAllAliases() throws {
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = #"""
import sys,json
while True:
    size=0
    while True:
        line=sys.stdin.buffer.readline()
        if not line:sys.exit(0)
        if line==b'\r\n':break
        if line.lower().startswith(b'content-length:'):size=int(line.split(b':')[1])
    request=json.loads(sys.stdin.buffer.read(size))
    if request.get('method')=='exit':sys.exit(0)
    if 'id' not in request:continue
    result={'capabilities':{'workspaceSymbolProvider':True,'textDocumentSync':1}} if request.get('method')=='initialize' else None
    raw=json.dumps(dict(jsonrpc='2.0',id=request['id'],result=result)).encode()
    sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n'%len(raw)).encode()+raw);sys.stdout.buffer.flush()
"""#
        let file = root.appendingPathComponent("fixture_lsp.py"); try source.write(to:file,atomically:true,encoding:.utf8)
        let python = try XCTUnwrap(ToolCommand.executable("python3")),js = try XCTUnwrap(CodeLanguage.supported.first { $0.id == "javascript" }),ts = try XCTUnwrap(CodeLanguage.supported.first { $0.id == "typescript" })
        var profile = LanguageToolchain(); profile.runtime = python.path; profile.server = python.path; profile.arguments = ["-u",file.path]
        try LanguageTools.save(profile,language:js,remote:nil,root:root.path); try LanguageTools.save(profile,language:ts,remote:nil,root:root.path)
        let services = WorkspaceLanguageServices()
        defer { services.stop(); LanguageTools.invalidate(remote:nil,root:root.path) }
        let one = EditorCodeSnapshot(id:UUID(),uri:root.appendingPathComponent("a.js").absoluteString,path:root.appendingPathComponent("a.js").path,text:"const a = 1",version:0,language:js,root:root.path,remote:nil)
        let two = EditorCodeSnapshot(id:UUID(),uri:root.appendingPathComponent("b.ts").absoluteString,path:root.appendingPathComponent("b.ts").path,text:"const b = 1",version:0,language:ts,root:root.path,remote:nil)
        let sessions = try services.queue.sync { () throws -> (LanguageSession,LanguageSession) in
            let a = try services.session(language:js,root:root.path,remote:nil),b = try services.session(language:ts,root:root.path,remote:nil)
            a.synchronize(uri:one.uri,language:js.id,text:one.text,version:0); b.synchronize(uri:two.uri,language:ts.id,text:two.text,version:0)
            return (a,b)
        }
        XCTAssertTrue(sessions.0 === sessions.1)
        XCTAssertEqual(services.queue.sync { services.activeBackendCount },1)
        services.close(one); services.queue.sync {}
        XCTAssertEqual(sessions.1.openDocumentCount,1); XCTAssertTrue(sessions.1.rpc.isRunning)
        services.close(two); services.queue.sync {}
        XCTAssertEqual(services.queue.sync { services.activeBackendCount },0)
        XCTAssertEqual(services.queue.sync { services.activeWatchCount },0)
    }
}
