import XCTest
@testable import Linvell

final class GitOrganizationTests: XCTestCase {
    func testEverySortModeAndDirectionPreservesIdentityAndManualOrder() {
        let a = WorkspaceSession.local(path:"/a"),b = WorkspaceSession.ssh(host:"host",path:"/b")
        let aliases = [a.repositoryID:"Z",b.repositoryID:"A"]
        for mode in GitRepositorySort.allCases {
            let ascending = GitRepositoryOrganization.sorted([a,b],mode:mode,ascending:true,aliases:aliases,
                dates:[a.repositoryID:1,b.repositoryID:2],order:[b.repositoryID,a.repositoryID])
            let descending = GitRepositoryOrganization.sorted([a,b],mode:mode,ascending:false,aliases:aliases,
                dates:[a.repositoryID:1,b.repositoryID:2],order:[b.repositoryID,a.repositoryID])
            XCTAssertEqual(ascending.first,mode == .name || mode == .manual ? b : a)
            XCTAssertEqual(descending.first,mode == .manual ? b : mode == .name ? a : b)
        }
    }
    func testHybridSevenDayBoundaryAndFutureDates() {
        let now = Date()
        XCTAssertFalse(GitCommitTimeMode.hybrid.usesAbsolute(now.addingTimeInterval(-6*86400),now:now))
        XCTAssertTrue(GitCommitTimeMode.hybrid.usesAbsolute(now.addingTimeInterval(-7*86400),now:now))
        XCTAssertTrue(GitCommitTimeMode.hybrid.usesAbsolute(now.addingTimeInterval(1),now:now))
        XCTAssertFalse(GitCommitTimeMode.relative.usesAbsolute(now.addingTimeInterval(-100*86400),now:now))
    }
}

extension GitOrganizationTests {
    func testMultilineSnippetMigrationKeepsStableIdentityAndFavorites() throws {
        let name = "Linvell.SnippetTest."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        defaults.set(["Subject\n\nBody 中文"],forKey:"git.commitSnippets")
        var values = GitCommitSnippet.load(defaults:defaults)
        let first = try XCTUnwrap(values.first)
        XCTAssertEqual(GitCommitSnippet.load(defaults:defaults).first?.id,first.id)
        values[0].favorite = false
        GitCommitSnippet.save(values,defaults:defaults)
        XCTAssertEqual(GitCommitSnippet.load(defaults:defaults).first?.text,"Subject\n\nBody 中文")
        XCTAssertFalse(try XCTUnwrap(GitCommitSnippet.load(defaults:defaults).first).favorite)
    }
}
