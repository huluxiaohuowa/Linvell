import XCTest
import AppKit
import LinvellCore
@testable import Linvell

final class RunWorkflowTests: XCTestCase {
    func waitUntil(_ condition: @escaping () -> Bool,timeout: TimeInterval = 15) -> Bool {
        let limit = Date().addingTimeInterval(timeout)
        while !condition(),Date() < limit { RunLoop.current.run(until:Date().addingTimeInterval(0.1)) }
        return condition()
    }
    func testRemoteRunForwardPreviewAndStop() throws {
        guard let file = ProcessInfo.processInfo.environment["LINVELL_SSH_FIXTURE"] else { throw XCTSkip("A disposable SSH fixture was not selected.") }
        _ = NSApplication.shared
        let object = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as! [String:String]
        let remote = try SSHRemote(host:try XCTUnwrap(object["host"])),root = try XCTUnwrap(object["root"])
        let panel = RunWorkspace(directory:root,remote:remote)
        defer { panel.shutdown() }
        let portFile = "port-"+UUID().uuidString+".txt"
        panel.command.stringValue = "python3 server.py "+SSHRemote.quote(portFile); panel.run()
        var port: Int?
        for _ in 0..<8 {
            RunLoop.current.run(until:Date().addingTimeInterval(0.25))
            if let reply = try? remote.request("read",path:root+"/"+portFile),let value = reply.content,let data = Data(base64Encoded:value) { port = Int(String(decoding:data,as:UTF8.self)); break }
        }
        let serverPort = try XCTUnwrap(port)
        panel.url.stringValue = "http://127.0.0.1:\(serverPort)/index.html"
        panel.showPreview()
        XCTAssertTrue(waitUntil({ panel.preview.url != nil },timeout:20))
        let localURL = try XCTUnwrap(panel.preview.url)
        XCTAssertNotEqual(localURL.port,serverPort)
        let html = try String(contentsOf:localURL,encoding:.utf8)
        XCTAssertTrue(html.contains("Linvell Remote Preview"))
        panel.stop(); XCTAssertTrue(waitUntil({ !panel.running },timeout:8))
        let probe = "import socket; s=socket.socket(); s.settimeout(1); exit(1 if s.connect_ex(('127.0.0.1',\(serverPort)))==0 else 0)"
        let stopped = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/ssh"),arguments:["-T","-o","BatchMode=yes","--",remote.host,"python3 -c "+SSHRemote.quote(probe)],directory:nil)
        XCTAssertTrue(stopped.succeeded,"The remote service must stop, not just its SSH client.")
        panel.shutdown(); XCTAssertNil(panel.forward)
    }
    func testLocalRunAndStop() throws {
        _ = NSApplication.shared
        let panel = RunWorkspace(directory:FileManager.default.temporaryDirectory.path,remote:nil)
        defer { panel.shutdown() }
        panel.command.stringValue = "printf 'Linvell task running\\n'; sleep 30"
        panel.run(); XCTAssertTrue(waitUntil({ panel.running }))
        panel.stop(); XCTAssertTrue(waitUntil({ !panel.running },timeout:8))
    }
}
