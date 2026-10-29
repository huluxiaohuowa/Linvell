import XCTest
@testable import LinvellCore

final class GitOperationsTests: XCTestCase {
    func testBranchStashAndRecoveryOperationsOnRealRepository() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath:NSHomeDirectory()+"/dev/build/linvell/test-fixtures").appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at:root,withIntermediateDirectories:true); defer { try? fm.removeItem(at:root) }
        let repo = GitRepository(root:root)
        _ = try repo.run(["init","-b","main"]); _ = try repo.run(["config","user.name","Linvell Fixture"]); _ = try repo.run(["config","user.email","fixture@example.invalid"])
        let file = root.appendingPathComponent("file with spaces.txt")
        try "original\n".write(to:file,atomically:true,encoding:.utf8)
        func execute(_ title: String,_ values: [String:String] = [:]) throws {
            let operation = try XCTUnwrap(GitOperation.all.first { $0.title == title })
            _ = try repo.run(operation.arguments(values))
        }
        try execute("Stage All"); try execute("Commit",["Message":"Initial fixture"])
        try execute("Create Branch",["Name":"feature","Revision":"HEAD"]); try execute("Switch Branch",["Branch":"feature"])
        XCTAssertEqual(try repo.run(["branch","--show-current"]).trimmingCharacters(in:.whitespacesAndNewlines),"feature")
        try "edited\n".write(to:file,atomically:true,encoding:.utf8)
        try execute("Stash Changes",["Message":"preserve working file"])
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"original\n")
        try execute("Apply Stash",["Stash":"stash@{0}"])
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"edited\n")
        try execute("Restore File",["Path":file.lastPathComponent])
        XCTAssertEqual(try String(contentsOf:file,encoding:.utf8),"original\n")
        try execute("Drop Stash",["Stash":"stash@{0}"])
        XCTAssertEqual(try repo.run(["stash","list"]),"")
        XCTAssertThrowsError(try GitOperation.customArguments("[\"status\", \"bad\\u0000path\"]"))
        XCTAssertEqual(try GitOperation.customArguments("[\"status\", \"--\", \"a; $(echo shell)\"]"),["status","--","a; $(echo shell)"])
    }
}
