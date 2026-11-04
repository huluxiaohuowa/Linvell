import XCTest
@testable import Linvell

final class GitAutoFetchTests: XCTestCase {
    func testSavedRepositoryFetchesWithoutAnOpenGitViewAndHonorsOverrides() throws {
        let suite = "Linvell.AutoFetchTest."+UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let a = WorkspaceSession.local(path:"/fixture/a"),b = WorkspaceSession.ssh(host:"fixture",path:"/fixture/b")
        defaults.set(try JSONEncoder().encode([a,b]),forKey:"git.savedRepositories")
        defaults.set(true,forKey:"git.defaultAutoFetch")
        defaults.set(1,forKey:"git.defaultFetchMinutes")
        defaults.set(false,forKey:GitAutoFetchScheduler.key(b))
        let completed = expectation(description:"Saved repository fetched")
        let scheduler = GitAutoFetchScheduler(defaults:defaults) { location in
            XCTAssertEqual(location,a); completed.fulfill()
        }
        defer { scheduler.stop() }
        let start = Date()
        scheduler.tick(now:start); scheduler.tick(now:start.addingTimeInterval(61))
        wait(for:[completed],timeout:3)
        let disabled = expectation(description:"Archived repository never fetches"); disabled.isInverted = true
        defaults.set([a.repositoryID],forKey:"git.archivedRepositories")
        let other = GitAutoFetchScheduler(defaults:defaults) { _ in disabled.fulfill() }
        other.tick(now:start); other.tick(now:start.addingTimeInterval(121))
        wait(for:[disabled],timeout:0.15); other.stop()
    }
}
