import XCTest
import AppKit
@testable import LinvellCore
@testable import Linvell

final class RemoteLanguageServicesTests: XCTestCase {
    struct Fixture: Decodable { let host: String,root: String,local: String }
    func testTargetToolchainsPersistentServiceAndNonblockingAutoSave() throws {
        guard let file = ProcessInfo.processInfo.environment["LINVELL_REMOTE_LANGUAGE_FIXTURE"] else { throw XCTSkip("Requires an explicitly synced disposable SSH fixture.") }
        let fixture = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:file)))
        let remote = try SSHRemote(host:fixture.host)
        let listed = try remote.listDirectory(fixture.root,force:true),root = try XCTUnwrap(listed.path)
        let available = try LanguageTools.discover(remote:remote,root:root)
        let python = try XCTUnwrap(available["python3"]),shell = try XCTUnwrap(available["bash"])
        var p = LanguageToolchain(); p.runtime = python; p.server = python; p.arguments = ["-u",root+"/fixture_lsp.py"]
        var s = LanguageToolchain(); s.runtime = shell; s.enabled = false
        let py = try XCTUnwrap(CodeLanguage.supported.first { $0.id == "python" }),sh = try XCTUnwrap(CodeLanguage.supported.first { $0.id == "shellscript" })
        try LanguageTools.save(p,language:py,remote:remote,root:root)
        try LanguageTools.save(s,language:sh,remote:remote,root:root)
        let settings = try ProjectLanguageSettings.read(root:root,remote:remote)
        XCTAssertEqual(try JSONCSettings(settings.data).setting("python").runtime,python)
        XCTAssertEqual(try JSONCSettings(settings.data).setting("shellscript").runtime,shell)
        let session = try LanguageTools.launch(p,language:py,root:root,remote:remote)
        defer { session.rpc.stop(); LanguageTools.invalidate(remote:remote,root:root) }
        let uri = URL(fileURLWithPath:root+"/note.txt").absoluteString
        session.synchronize(uri:uri,language:"python",text:"value = 1\n",version:1)
        for _ in 0..<2 {
            let hover = try session.request("textDocument/hover",uri:uri,position:CodePosition(line:0,character:1)) as? [String:Any]
            XCTAssertEqual((hover?["contents"] as? [String:Any])?["value"] as? String,python)
            XCTAssertEqual(hover?["pathHead"] as? String,URL(fileURLWithPath:python).deletingLastPathComponent().path)
        }
        _ = try remote.listDirectory(root,force:true)
        let cachedAt = Date()
        for _ in 0..<100 { XCTAssertEqual(remote.cachedDirectory(root)?.path,root) }
        XCTAssertLessThan(Date().timeIntervalSince(cachedAt),0.1)
        let path = root+"/note.txt",reply = try remote.request("read",path:path)
        let document = try RemoteDocument(connection:remote,path:path,digest:try XCTUnwrap(reply.digest),data:try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(reply.content))),cacheRoot:URL(fileURLWithPath:fixture.local))
        _ = NSApplication.shared
        let previous = UserDefaults.standard.object(forKey:"autoSave"); UserDefaults.standard.set("true",forKey:"autoSave")
        let workspace = WorkspaceController(),open = OpenDocument(try DocumentBuffer(url:document.localURL)); open.remote = document
        workspace.remoteConnection = remote; workspace.remoteDirectory = root; workspace.activate(open)
        defer {
            UserDefaults.standard.set(previous,forKey:"autoSave")
            workspace.autoSaveWork.values.forEach { $0.cancel() }; workspace.languageServices.stop(); workspace.recoveryTimer?.invalidate(); workspace.window?.orderOut(nil)
        }
        var previousTick = Date(),largestGap: TimeInterval = 0
        let timer = Timer(timeInterval:0.01,repeats:true) { _ in let now = Date(); largestGap = max(largestGap,now.timeIntervalSince(previousTick)); previousTick = now }
        RunLoop.main.add(timer,forMode:.common)
        open.buffer.update("saved remotely by native auto-save\n"); workspace.scheduleAutoSave(open)
        let deadline = Date().addingTimeInterval(15)
        while open.buffer.isModified,Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        timer.invalidate()
        XCTAssertFalse(open.buffer.isModified)
        XCTAssertLessThan(largestGap,0.25,"SSH auto-save must not block the UI event loop")
        let saved = try remote.request("read",path:path)
        XCTAssertEqual(Data(base64Encoded:try XCTUnwrap(saved.content)),Data("saved remotely by native auto-save\n".utf8))
        // A remote edit must survive the client's next automatic save attempt.
        _ = try remote.request("write",path:path,content:Data("external edit\n".utf8),digest:saved.digest)
        open.buffer.update("stale local edit\n"); workspace.scheduleAutoSave(open)
        let conflictDeadline = Date().addingTimeInterval(15)
        while (!workspace.autoSaveWork.isEmpty || !workspace.autoSaving.isEmpty),Date() < conflictDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(open.buffer.isModified)
        XCTAssertEqual(Data(base64Encoded:try XCTUnwrap(remote.request("read",path:path).content)),Data("external edit\n".utf8))
        let source = "class RemoteSample:\n    def sample(self):\n        value = '{ignored}'\n        return value\n\n"
        let syntaxPath = root+"/syntax.py"
        _ = try remote.request("create",path:syntaxPath)
        let original = try remote.request("read",path:syntaxPath)
        _ = try remote.request("write",path:syntaxPath,content:Data(source.utf8),digest:original.digest)
        let loaded = try remote.request("read",path:syntaxPath)
        let cached = try RemoteDocument(connection:remote,path:syntaxPath,digest:try XCTUnwrap(loaded.digest),data:Data(source.utf8),cacheRoot:URL(fileURLWithPath:fixture.local))
        let remoteSource = OpenDocument(try DocumentBuffer(url:cached.localURL)); remoteSource.remote = cached
        workspace.activate(remoteSource)
        let syntaxDeadline = Date().addingTimeInterval(5)
        while remoteSource.syntax.version != remoteSource.buffer.revision,Date() < syntaxDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        XCTAssertNotNil(remoteSource.syntax.analysis.fold(atLine:0))
        workspace.activePane?.toggleFold(line:0)
        XCTAssertFalse(workspace.activePane?.folding.hidden.isEmpty ?? true)
        XCTAssertEqual(remoteSource.storage.string,source); XCTAssertFalse(remoteSource.buffer.isModified)
        print("Remote acceptance: cached 100 directory reads; persistent language requests; autosave; conflict protection; maximum UI timer gap:",largestGap)
    }
}
