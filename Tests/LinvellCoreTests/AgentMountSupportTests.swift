import XCTest
@testable import LinvellCore

final class AgentMountSupportTests: XCTestCase {
    func testInstallationDetectionDistinguishesMissingExecutableAndFilesystemSupport() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/agent-test-fixtures/prerequisites-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let env = ["PATH":root.path],cli = root.appendingPathComponent("sshfs")
        XCTAssertNil(AgentMountSupport.detect(environment:env,filesystemRoot:root).sshfs)
        XCTAssertFalse(AgentMountSupport.detect(environment:env,filesystemRoot:root).macFUSEInstalled)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to:cli)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:cli.path)
        XCTAssertNil(AgentMountSupport.detect(environment:env,filesystemRoot:root).sshfs)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        XCTAssertEqual(AgentMountSupport.detect(environment:env,filesystemRoot:root).sshfs,cli.path)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Library/Filesystems/macfuse.fs"),withIntermediateDirectories:true)
        XCTAssertTrue(AgentMountSupport.detect(environment:env,filesystemRoot:root).macFUSEInstalled)
        try FileManager.default.removeItem(at:cli); try FileManager.default.createDirectory(at:cli,withIntermediateDirectories:true)
        XCTAssertNil(AgentMountSupport.detect(environment:env,filesystemRoot:root).sshfs,"A searchable directory is not an installed SSHFS executable.")
    }
}
