import XCTest
@testable import LinvellCore

final class AgentSyncSupportTests: XCTestCase {
    func testOptionalMutagenDetectionRequiresAnExecutableFile() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/agent-test-fixtures/prerequisites-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let env = ["PATH":root.path],cli = root.appendingPathComponent("mutagen")
        XCTAssertNil(AgentSyncSupport.detect(environment:env).executable)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to:cli)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:cli.path)
        XCTAssertNil(AgentSyncSupport.detect(environment:env).executable)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        XCTAssertEqual(AgentSyncSupport.detect(environment:env).executable,cli.path)
        try FileManager.default.removeItem(at:cli); try FileManager.default.createDirectory(at:cli,withIntermediateDirectories:true)
        XCTAssertNil(AgentSyncSupport.detect(environment:env).executable,"A searchable directory is not an installed Mutagen executable.")
    }
}
