import XCTest
@testable import LinvellCore

final class UpdateTransportTests: XCTestCase {
    func testOfflineAndInvalidProxyResponsesFallThroughInOrder() async throws {
        let origin = URL(string:"https://api.github.com/repos/huluxiaohuowa/Linvell/releases")!
        var attempts: [String] = []
        let value: String = try await UpdateTransport.firstValid(origin,load:{ url in
            attempts.append(url.host!)
            if url.host == "api.github.com" { throw URLError(.notConnectedToInternet) }
            return Data((url.host == "ghfast.top" ? "invalid response" : "verified fixture").utf8)
        },validate:{ bytes in
            guard String(decoding:bytes,as:UTF8.self) == "verified fixture" else { throw UpdateFailure.invalidResponse }; return "accepted"
        })
        XCTAssertEqual(value,"accepted"); XCTAssertEqual(attempts,["api.github.com","ghfast.top","gh-proxy.com"])
    }
    func testPrivateOrUnrelatedURLsNeverReachPublicProxies() {
        for raw in ["https://user:secret@github.com/huluxiaohuowa/Linvell/releases/download/v1/a.zip","https://github.com/private/repo/releases/download/v1/a.zip","https://example.invalid/file"] {
            let url = URL(string:raw)!; XCTAssertEqual(UpdateTransport.candidates(url),[url])
        }
        XCTAssertEqual(UpdateTransport.candidates(URL(string:"https://github.com/huluxiaohuowa/Linvell/releases/download/v0.1.7/Linvell-0.1.7-universal.zip")!).count,4)
    }
}
