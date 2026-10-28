import XCTest
@testable import LinvellCore

final class ToolCommandTests: XCTestCase {
    func testArgumentsAreNotInterpretedByAShell() throws {
        let value = "literal; $(not-a-command)"
        let result = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/printf"),arguments:["%s",value],directory:nil)
        XCTAssertTrue(result.succeeded); XCTAssertEqual(result.output,value)
    }
    func testCommandTimeout() throws {
        let started = Date()
        let result = try ToolCommand.run(URL(fileURLWithPath:"/bin/sleep"),arguments:["5"],directory:nil,timeout:0.1)
        XCTAssertTrue(result.timedOut); XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started),3)
    }
}
