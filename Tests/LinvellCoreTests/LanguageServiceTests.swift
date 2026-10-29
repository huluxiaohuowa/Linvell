import XCTest
@testable import LinvellCore

final class LanguageServiceTests: XCTestCase {
    func testByteFramingHandlesFragmentedUnicodeAndCombinedMessages() throws {
        let first: [String:Any] = ["jsonrpc":"2.0","id":1,"result":"中文 🐱"],second: [String:Any] = ["id":2,"result":true]
        let bytes = try LSPFrames.encode(first)+LSPFrames.encode(second)
        var parser = LSPFrames(),values: [[String:Any]] = []
        for byte in bytes { values += try parser.append(Data([byte])) }
        XCTAssertEqual(values.count,2); XCTAssertEqual(values[0]["result"] as? String,"中文 🐱")
        var invalid = LSPFrames()
        XCTAssertThrowsError(try invalid.append(Data("Content-Length:\r\n\r\n".utf8)))
        invalid = LSPFrames()
        XCTAssertThrowsError(try invalid.append(Data("Content-Length: 999999999\r\n\r\n".utf8)))
    }
    func testUTF16RangesAndOverlappingRenameEdits() throws {
        let text = "let 🐱 = 1\nhello(🐱)\n"
        XCTAssertEqual(try CodePosition(line:0,character:6).offset(in:text),6)
        XCTAssertThrowsError(try CodePosition(line:0,character:5).offset(in:text))
        XCTAssertThrowsError(try CodePosition(line:20,character:0).offset(in:text))
        let edits = try JSONDecoder().decode([CodeTextEdit].self,from:Data(#"[{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":5}},"newText":"greet"}]"#.utf8))
        XCTAssertEqual(try CodeTextEdit.applying(edits,to:text),"let 🐱 = 1\ngreet(🐱)\n")
        XCTAssertThrowsError(try CodeTextEdit.applying(edits+edits,to:text))
    }
    func testWorkspaceEditsKeepVersionsAndRejectResourceOperations() throws {
        let value: [String:Any] = ["documentChanges":[["textDocument":["uri":"file:///fixture.swift","version":7],"edits":[]]]]
        XCTAssertEqual(try CodeWorkspaceEdit.parse(value).first?.version,7)
        XCTAssertThrowsError(try CodeWorkspaceEdit.parse(["documentChanges":[["kind":"delete","uri":"file:///fixture.swift"]]]))
        XCTAssertThrowsError(try CodeWorkspaceEdit.parse(["changes":["https://example.invalid/source":[]]]))
    }
    func testSaveSnapshotDoesNotClearEditsMadeDuringBackgroundSave() throws {
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("file.txt"); try "original".write(to:file,atomically:true,encoding:.utf8)
        let buffer = try DocumentBuffer(url:file); buffer.update("first edit")
        let snapshot = try buffer.saveSnapshot(); buffer.update("newer edit")
        buffer.completeSave(snapshot,digest:try snapshot.write())
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"first edit")
        XCTAssertEqual(buffer.text,"newer edit"); XCTAssertTrue(buffer.isModified)
        try buffer.save(); XCTAssertFalse(buffer.isModified)
        buffer.update("pending"); let next = try buffer.saveSnapshot()
        try "external".write(to:file,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try next.write()); XCTAssertTrue(buffer.isModified)
    }
    func testPersistentRPCSynchronizesUnsavedTextAndReceivesSemanticResults() throws {
        guard let python = ToolCommand.executable("python3") else { throw XCTSkip("Python fixture runtime unavailable") }
        let source = #"""
import sys,json
text=''
uri=''
def send(value):
    raw=json.dumps(value,ensure_ascii=False).encode()
    sys.stdout.buffer.write(('Content-Length: %d\r\n\r\n'%len(raw)).encode()+raw);sys.stdout.buffer.flush()
while True:
    length=None
    while True:
        line=sys.stdin.buffer.readline()
        if not line: sys.exit(0)
        if line==b'\r\n': break
        if line.lower().startswith(b'content-length:'): length=int(line.split(b':')[1])
    value=json.loads(sys.stdin.buffer.read(length));method=value.get('method');p=value.get('params',{})
    if method=='exit': break
    if method=='textDocument/didOpen': text=p['textDocument']['text'];uri=p['textDocument']['uri']
    if method=='textDocument/didChange': text=p['contentChanges'][0]['text']
    if 'id' not in value or method is None: continue
    result=None
    if method=='initialize': result={'capabilities':{'positionEncoding':'utf-16','hoverProvider':True,'renameProvider':True}}
    elif method=='textDocument/hover': result={'contents':{'kind':'plaintext','value':text}}
    elif method=='textDocument/definition': result={'uri':uri,'range':{'start':{'line':0,'character':5},'end':{'line':0,'character':10}}}
    send({'jsonrpc':'2.0','id':value['id'],'result':result})
"""#
        let rpc = try LanguageRPC(executable:python,arguments:["-u","-c",source],directory:nil); defer { rpc.stop() }
        let session = try LanguageSession(rpc:rpc,root:"/fixture",runtime:python.path)
        session.synchronize(uri:"file:///fixture/demo.py",language:"python",text:"first",version:0)
        session.synchronize(uri:"file:///fixture/demo.py",language:"python",text:"unsaved 中文",version:1)
        let hover = try session.request("textDocument/hover",uri:"file:///fixture/demo.py",position:CodePosition(line:0,character:0)) as? [String:Any]
        XCTAssertEqual((hover?["contents"] as? [String:Any])?["value"] as? String,"unsaved 中文")
        let locations = try CodeLocation.locations(session.request("textDocument/definition",uri:"file:///fixture/demo.py",position:CodePosition(line:0,character:0)))
        XCTAssertEqual(locations.first?.uri,"file:///fixture/demo.py")
    }
}
