import XCTest
@testable import LinvellCore

final class RemoteDirectoryCacheTests: XCTestCase {
    private func reply(_ path: String = "/project",name: String = "src") throws -> RemoteReply {
        let object: [String:Any] = ["path":path,"entries":[["name":name,"path":path+"/"+name,"directory":true]]]
        return try JSONDecoder().decode(RemoteReply.self,from:JSONSerialization.data(withJSONObject:object))
    }
    func testWarmNavigationAndCanonicalAliasAvoidNetwork() throws {
        let cache = RemoteDirectoryCache(); var requests = 0
        let load = { requests += 1; return try self.reply() }
        _ = try cache.list(host:"a",path:"~",load:load)
        _ = try cache.list(host:"a",path:"/project",load:load)
        XCTAssertEqual(requests,1)
        XCTAssertEqual(cache.snapshot(host:"a",path:"~")?.entries?.first?.name,"src")
        XCTAssertNil(cache.snapshot(host:"b",path:"~"))
        _ = try cache.list(host:"a",path:"~",force:true,load:load)
        XCTAssertEqual(requests,2)
        cache.invalidate(host:"a")
        XCTAssertNil(cache.snapshot(host:"a",path:"/project"))
        _ = try cache.list(host:"a",path:"~",load:load)
        XCTAssertEqual(requests,3)
    }
    func testStaleSnapshotSurvivesRefreshFailureAndRefreshUpdates() throws {
        let cache = RemoteDirectoryCache(lifetime:0)
        _ = try cache.list(host:"a",path:"/project") { try reply() }
        XCTAssertThrowsError(try cache.list(host:"a",path:"/project") { throw NSError(domain:"offline",code:1) })
        XCTAssertEqual(cache.snapshot(host:"a",path:"/project")?.entries?.first?.name,"src")
        _ = try cache.list(host:"a",path:"/project") { try reply(name:"new") }
        XCTAssertEqual(cache.snapshot(host:"a",path:"/project")?.entries?.first?.name,"new")
    }
    func testBoundedDirectoryStorage() throws {
        let cache = RemoteDirectoryCache(maximumDirectories:2)
        for i in 0..<3 { _ = try cache.list(host:"a",path:"/\(i)") { try reply("/\(i)") } }
        XCTAssertNil(cache.snapshot(host:"a",path:"/0"))
        XCTAssertNotNil(cache.snapshot(host:"a",path:"/2"))
    }
    func testLiveCachedNavigationAvoidsRepeatedSSHLatency() throws {
        guard let file = ProcessInfo.processInfo.environment["LINVELL_SSH_FIXTURE"] else { throw XCTSkip("Disposable SSH fixture required.") }
        let object = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as! [String:String]
        let remote = try SSHRemote(host:try XCTUnwrap(object["host"])),path = try XCTUnwrap(object["root"])
        RemoteDirectoryCache.shared.invalidate(host:remote.host)
        let start = ProcessInfo.processInfo.systemUptime
        let cold = try remote.listDirectory(path)
        let coldTime = ProcessInfo.processInfo.systemUptime-start
        let warmStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { XCTAssertEqual(try remote.listDirectory(path).entries,cold.entries) }
        let warmTime = (ProcessInfo.processInfo.systemUptime-warmStart)/100
        XCTAssertLessThan(warmTime,0.01)
        if let output = ProcessInfo.processInfo.environment["LINVELL_DIRECTORY_RESULT"] {
            let data = try JSONSerialization.data(withJSONObject:["coldMilliseconds":coldTime*1000,"warmMilliseconds":warmTime*1000,"warmRepetitions":100],options:[.prettyPrinted,.sortedKeys])
            try data.write(to:URL(fileURLWithPath:output),options:.atomic)
        }
    }

}
