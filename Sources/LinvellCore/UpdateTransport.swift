import Foundation

public enum UpdateTransport {
    /// Only public Linvell metadata/assets are sent to acceleration endpoints.
    public static func candidates(_ origin: URL) -> [URL] {
        guard origin.scheme == "https",origin.user == nil,origin.password == nil,origin.port == nil,
              (origin.host == "api.github.com" && origin.path.hasPrefix("/repos/huluxiaohuowa/Linvell/releases")) ||
              (origin.host == "github.com" && origin.path.hasPrefix("/huluxiaohuowa/Linvell/releases/download/")) else { return [origin] }
        return [origin]+["https://ghfast.top/","https://gh-proxy.com/","https://hk.gh-proxy.com/"].compactMap { URL(string:$0+origin.absoluteString) }
    }
    public static func firstValid<T>(_ origin: URL,load: (URL) async throws -> Data,validate: (Data) throws -> T) async throws -> T {
        var last: Error = UpdateFailure.invalidResponse
        for url in candidates(origin) {
            do { return try validate(await load(url)) }
            catch { if Task.isCancelled { throw CancellationError() }; last = error }
        }
        throw last
    }
}
