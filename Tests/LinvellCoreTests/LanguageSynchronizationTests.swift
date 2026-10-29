import XCTest
@testable import LinvellCore

final class LanguageSynchronizationTests: XCTestCase {
    func testMinimalChangesRespectUTF16AndPreserveUnicodeAndLineEndings() throws {
        for (old,new) in [("let 🐱 = 1\r\nnext()","let 🐶 = 2\r\nnext()"),("hello",""),("","中文"),("a\nb","a\nx\nb"),("same","same")] {
            guard let change = LanguageDocumentChange.between(old,new) else { XCTAssertEqual(old,new); continue }
            let data = try JSONSerialization.data(withJSONObject:change)
            struct Change: Decodable { let range: CodeRange,text: String }
            let parsed = try JSONDecoder().decode(Change.self,from:data)
            let range = try parsed.range.range(in:old)
            XCTAssertEqual((old as NSString).replacingCharacters(in:range,with:parsed.text),new)
        }
    }
    func testNegotiatedSyncConfigurationAndPullDiagnosticResultIDs() throws {
        let python = try XCTUnwrap(ToolCommand.executable("python3"))
        let source = #"""
import sys,json
messages=[];settings={}
def send(value):
    raw=json.dumps(value).encode();sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n'%len(raw)).encode()+raw);sys.stdout.buffer.flush()
while True:
    size=0
    while True:
        line=sys.stdin.buffer.readline()
        if not line:sys.exit(0)
        if line==b'\r\n':break
        if line.lower().startswith(b'content-length:'):size=int(line.split(b':')[1])
    value=json.loads(sys.stdin.buffer.read(size));method=value.get('method');p=value.get('params',{})
    if method=='exit':sys.exit(0)
    if method and method.startswith('textDocument/did'):messages.append(dict(method=method,params=p))
    if method=='workspace/didChangeConfiguration':settings=p['settings']
    if 'id' not in value:continue
    result=None
    if method=='initialize':result={'capabilities':{'textDocumentSync':{'openClose':True,'change':2,'save':{'includeText':False}},'diagnosticProvider':{'interFileDependencies':True,'workspaceDiagnostics':False}}}
    elif method=='textDocument/diagnostic':result={'kind':'unchanged','resultId':'one'} if p.get('previousResultId')=='one' else {'kind':'full','resultId':'one','items':[]}
    elif method=='fixture/state':result={'messages':messages,'settings':settings}
    send(dict(jsonrpc='2.0',id=value['id'],result=result))
"""#
        let rpc = try LanguageRPC(executable:python,arguments:["-u","-c",source],directory:nil); defer { rpc.stop() }
        let session = try LanguageSession(rpc:rpc,root:"/fixture",runtime:"/fixture/python",configuration:["python":["analysis":["typeCheckingMode":"strict"]]])
        let uri = "file:///fixture/main.py"
        session.synchronize(uri:uri,language:"python",text:"value = 1",version:0)
        session.synchronize(uri:uri,language:"python",text:"value = 2",version:1)
        session.saved(uri:uri,text:"value = 2")
        XCTAssertEqual(try session.pullDiagnostics(uri:uri)?["kind"] as? String,"full")
        XCTAssertEqual(try session.pullDiagnostics(uri:uri)?["kind"] as? String,"unchanged")
        let state = try XCTUnwrap(rpc.request("fixture/state",params:[:]) as? [String:Any])
        let messages = try XCTUnwrap(state["messages"] as? [[String:Any]])
        let changed = try XCTUnwrap(messages.first { $0["method"] as? String == "textDocument/didChange" }?["params"] as? [String:Any])
        XCTAssertNotNil((changed["contentChanges"] as? [[String:Any]])?.first?["range"])
        let saved = try XCTUnwrap(messages.first { $0["method"] as? String == "textDocument/didSave" }?["params"] as? [String:Any])
        XCTAssertNil(saved["text"])
        let pythonSettings = try XCTUnwrap((state["settings"] as? [String:Any])?["python"] as? [String:Any])
        XCTAssertEqual(pythonSettings["pythonPath"] as? String,"/fixture/python")
        XCTAssertEqual((pythonSettings["analysis"] as? [String:Any])?["typeCheckingMode"] as? String,"strict")
        session.close(uri:uri); XCTAssertEqual(session.openDocumentCount,0)
    }
    func testStoppingBackendIsNotBlockedByAFullInputPipe() throws {
        let python = try XCTUnwrap(ToolCommand.executable("python3"))
        let rpc = try LanguageRPC(executable:python,arguments:["-c","import time; time.sleep(60)"],directory:nil)
        rpc.notify("fixture/blocked",params:["text":String(repeating:"x",count:2*1024*1024)])
        Thread.sleep(forTimeInterval:0.05); rpc.stop()
        let deadline = Date().addingTimeInterval(2)
        while !rpc.hasExited,Date() < deadline { Thread.sleep(forTimeInterval:0.01) }
        XCTAssertTrue(rpc.hasExited,"A nonreading server must not prevent shutdown")
    }
    func testWireCancellationUnblocksOutstandingRequestImmediately() throws {
        let python = try XCTUnwrap(ToolCommand.executable("python3"))
        let source = #"""
import sys,json
while True:
    size=0
    while True:
        line=sys.stdin.buffer.readline()
        if not line:sys.exit(0)
        if line==b'\r\n':break
        if line.lower().startswith(b'content-length:'):size=int(line.split(b':')[1])
    value=json.loads(sys.stdin.buffer.read(size))
    if value.get('method')=='exit':sys.exit(0)
    if value.get('method')=='fixture/barrier':
        reply=json.dumps(dict(jsonrpc='2.0',id=value['id'],result=True)).encode()
        sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n'%len(reply)).encode()+reply);sys.stdout.buffer.flush()
"""#
        let rpc = try LanguageRPC(executable:python,arguments:["-u","-c",source],directory:nil); defer { rpc.stop() }
        let cancelled = LanguageRequestCancellation(),finished = expectation(description:"Cancelled RPC returns")
        DispatchQueue.global().async {
            do { _ = try rpc.request("textDocument/hover",params:[:],timeout:20,cancellation:cancelled); XCTFail("Must cancel") }
            catch is CancellationError { }
            catch { XCTFail("Unexpected error \(error)") }
            finished.fulfill()
        }
        Thread.sleep(forTimeInterval:0.05)
        let start = Date(); cancelled.cancel(); wait(for:[finished],timeout:1)
        XCTAssertLessThan(Date().timeIntervalSince(start),0.5)
        XCTAssertEqual(try rpc.request("fixture/barrier",params:[:]) as? Bool,true,"Transport must remain usable after cancelling a request")
    }
}
