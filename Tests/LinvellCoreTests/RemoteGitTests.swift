import XCTest
@testable import LinvellCore

final class RemoteGitTests: XCTestCase {
    func testLiveSSHReadWriteRoundTripWhenFixtureIsProvided() throws {
        guard let file = ProcessInfo.processInfo.environment["LINVELL_SSH_FIXTURE"] else { throw XCTSkip("A disposable SSH fixture was not selected.") }
        let object = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as! [String:String]
        let connection = try SSHRemote(host:try XCTUnwrap(object["host"])),root = try XCTUnwrap(object["root"])
        let listed = try connection.request("list",path:root)
        XCTAssertTrue(listed.entries?.contains(where:{ $0.name == "sample.txt" }) == true)
        let path = root+"/sample.txt",read = try connection.request("read",path:path)
        let original = try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(read.content)))
        let written = try connection.request("write",path:path,content:Data("remote changed 中文\n".utf8),digest:read.digest)
        let received = try connection.request("read",path:path)
        XCTAssertEqual(received.content,Data("remote changed 中文\n".utf8).base64EncodedString())
        XCTAssertThrowsError(try connection.request("write",path:path,content:original,digest:read.digest))
        _ = try connection.request("write",path:path,content:original,digest:written.digest)
    }
    func testSSHConfigIncludesAliasesWithoutWildcardEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try "Host included\n HostName localhost\nInclude config\n".write(to:root.appendingPathComponent("extra.conf"),atomically:true,encoding:.utf8)
        try "Host primary secondary\nHost *.example !ignored\nInclude extra*.conf\nHost=quoted # comment\n".write(to:root.appendingPathComponent("config"),atomically:true,encoding:.utf8)
        XCTAssertEqual(SSHConfig.hosts(at:root.appendingPathComponent("config")),["included","primary","quoted","secondary"])
        XCTAssertFalse(SSHConfig.validAlias("-oProxyCommand=bad"))
        XCTAssertFalse(SSHConfig.validAlias("host; touch /tmp/bad"))
        XCTAssertEqual(SSHRemote.quote("a'b"),"'a'\\''b'")
    }
    func testRemoteProtocolReadsWritesAndRejectsExternalChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let path = root.appendingPathComponent("a ' 中文.txt")
        try Data("first\r\n".utf8).write(to:path)
        let python = try XCTUnwrap(ToolCommand.executable("python3"))
        func request(_ object: [String:String]) throws -> RemoteReply {
            let result = try ToolCommand.run(python,arguments:["-c",SSHRemote.agent],directory:root,input:try JSONSerialization.data(withJSONObject:object))
            XCTAssertTrue(result.succeeded)
            let marker = try XCTUnwrap(result.output.range(of:"LINVELL_JSON:"))
            return try JSONDecoder().decode(RemoteReply.self,from:Data(result.output[marker.upperBound...].utf8))
        }
        let listing = try request(["operation":"list","path":root.path]); XCTAssertEqual(listing.entries?.count,1)
        let read = try request(["operation":"read","path":path.path]); XCTAssertEqual(Data(base64Encoded:try XCTUnwrap(read.content)),Data("first\r\n".utf8))
        let saved = try request(["operation":"write","path":path.path,"content":Data("updated\n".utf8).base64EncodedString(),"digest":try XCTUnwrap(read.digest)])
        XCTAssertNil(saved.error); XCTAssertEqual(try String(contentsOf:path,encoding:.utf8),"updated\n")
        let stale = try request(["operation":"write","path":path.path,"content":Data("overwrite".utf8).base64EncodedString(),"digest":try XCTUnwrap(read.digest)])
        XCTAssertNotNil(stale.error); XCTAssertEqual(try String(contentsOf:path,encoding:.utf8),"updated\n")
    }
    func testGitStageUnstageCommitRenameAndMergeGraph() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"]); _ = try repo.run(["config","user.name","Linvell Test"]); _ = try repo.run(["config","user.email","linvell@example.invalid"])
        let file = root.appendingPathComponent("[literal] space.txt")
        try "base\n".write(to:file,atomically:true,encoding:.utf8)
        let change = try XCTUnwrap(repo.changes().first)
        try repo.stage(change); XCTAssertTrue(try XCTUnwrap(repo.changes().first).staged)
        try repo.unstage(try XCTUnwrap(repo.changes().first)); XCTAssertFalse(try XCTUnwrap(repo.changes().first).staged)
        try repo.stage(change); try repo.commit("initial")
        _ = try repo.run(["switch","-c","feature"])
        try "feature\n".write(to:file,atomically:true,encoding:.utf8); try repo.stage(try XCTUnwrap(repo.changes().first)); try repo.commit("feature change")
        _ = try repo.run(["switch","main"])
        try "other".write(to:root.appendingPathComponent("other.txt"),atomically:true,encoding:.utf8)
        try repo.stage(try XCTUnwrap(repo.changes().first)); try repo.commit("main change")
        _ = try repo.run(["merge","--no-ff","feature","-m","merge feature"])
        let commits = try repo.history(),graph = GitGraph.layout(commits)
        XCTAssertEqual(commits.count,4); XCTAssertEqual(commits.first?.parents.count,2)
        XCTAssertEqual(graph.count,4); XCTAssertEqual(graph.first?.lower.count,2)
        XCTAssertTrue(graph.contains(where:{ $0.width >= 2 }))
        _ = try repo.run(["mv","--","[literal] space.txt","renamed.txt"])
        let renamed = try XCTUnwrap(repo.changes().first); XCTAssertEqual(renamed.originalPath,"[literal] space.txt")
        try repo.unstage(renamed); XCTAssertTrue(try repo.changes().allSatisfy { !$0.staged })
    }
    func testStatusParserPreservesWhitespaceAndRenameNames() {
        let changes = GitRepository.parseStatus(" M  leading.txt\0R  new\nname.txt\0old name.txt\0?? [abc].txt\0")
        XCTAssertEqual(changes.count,3); XCTAssertEqual(changes[0].index," "); XCTAssertEqual(changes[0].path," leading.txt")
        XCTAssertEqual(changes[1].originalPath,"old name.txt"); XCTAssertEqual(changes[1].path,"new\nname.txt")
    }
    func testTaskDiscoveryDoesNotMisapplyUnsupportedVSCodeOptions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".vscode"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let config: [String:Any] = ["tasks":[
            ["label":"plain","type":"shell","command":"printf hello"],
            ["label":"process","type":"process","command":"/path with spaces/tool","args":["one argument"]],
            ["label":"variable","command":"${workspaceFolder}/tool"],
            ["label":"options","command":"tool","options":["cwd":"/elsewhere"]],
            ["label":"dependency","command":"tool","dependsOn":"plain"]
        ]]
        try JSONSerialization.data(withJSONObject:config).write(to:root.appendingPathComponent(".vscode/tasks.json"))
        let tasks = RunTasks.discover(at:root)
        XCTAssertEqual(tasks.map(\.label),["plain","process"])
        XCTAssertEqual(tasks[1].command,"'/path with spaces/tool' 'one argument'")
    }
    func testRemoteCommandWorksWithPOSIXAndFishLoginShells() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linvell ' shell "+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let command = RunTasks.remoteCommand(directory:root.path,command:"printf LINVELL_SHELL_READY")
        var shells = [URL(fileURLWithPath:"/bin/sh")]
        if let fish = ToolCommand.executable("fish") { shells.append(fish) }
        for shell in shells {
            let result = try ToolCommand.run(shell,arguments:["-c",command],directory:nil,environment:["SHELL":shell.path])
            XCTAssertTrue(result.succeeded); XCTAssertEqual(result.output,"LINVELL_SHELL_READY")
            let terminal = try ToolCommand.run(shell,arguments:["-c",RunTasks.remoteShell(directory:root.path)],directory:nil,environment:["SHELL":shell.path],input:Data("printf LINVELL_TERMINAL_READY\nexit\n".utf8))
            XCTAssertTrue(terminal.succeeded); XCTAssertEqual(terminal.output,"LINVELL_TERMINAL_READY")
        }
    }
    func testColumnSelectionKeepsGraphemesAndTabsWhole() throws {
        let text = "a😀bc\naXYZ\na中bc"
        let ranges = ColumnSelection.ranges(in:text,anchor:1,head:9)
        XCTAssertEqual(ranges.map { (text as NSString).substring(with:$0) },["😀b","XY"])
        let block = ColumnSelection.ranges(in:"abcd\na\nabc",anchor:1,head:9,inclusive:true)
        XCTAssertEqual(block.count,3)
        XCTAssertTrue(block.allSatisfy { Range($0,in:"abcd\na\nabc") != nil })
        XCTAssertEqual(RunTasks.directoryExpression("~/a ' b"),"\"$HOME\"/'a '\\'' b'")
    }
}
