import XCTest
@testable import LinvellCore

final class SystemSamplerTests: XCTestCase {
    func testLiveSamplesHaveBoundedCoreUtilization() throws {
        let sampler = SystemSampler(),first = try sampler.sample()
        XCTAssertNil(first.cpuLoads); XCTAssertGreaterThan(first.activeMemory,0)
        let second = try sampler.sample(),loads = try XCTUnwrap(second.cpuLoads)
        XCTAssertFalse(loads.isEmpty); XCTAssertTrue(loads.allSatisfy { (0...1).contains($0) })
    }
}
