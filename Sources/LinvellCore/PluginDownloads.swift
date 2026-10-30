import Foundation

/// HTTPS only in production, with bounded bodies and no credential-bearing URLs.
public final class PluginDownloads: NSObject, URLSessionDataDelegate {
    private let maximum: Int,allowLoopback: Bool
    private var bytes = Data(),failure: Error?,status = 0
    private let done = DispatchSemaphore(value:0)
    private init(maximum: Int,allowLoopback: Bool) { self.maximum = maximum; self.allowLoopback = allowLoopback }
    public static func valid(_ url: URL,allowLoopback: Bool = false) -> Bool {
        url.host != nil && url.user == nil && url.password == nil && url.fragment == nil && (url.scheme == "https" || allowLoopback && url.scheme == "http" && ["127.0.0.1","localhost","::1"].contains(url.host ?? ""))
    }
    public static func fetch(_ url: URL,maximum: Int,allowLoopback: Bool = false) throws -> Data {
        guard valid(url,allowLoopback:allowLoopback) else { throw LanguageServiceError.message("Enter an HTTPS URL without credentials.") }
        let delegate = PluginDownloads(maximum:maximum,allowLoopback:allowLoopback),config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30;config.timeoutIntervalForResource = 90;config.httpCookieStorage = nil;config.urlCredentialStorage = nil
        let session = URLSession(configuration:config,delegate:delegate,delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with:url).resume()
        guard delegate.done.wait(timeout:.now()+95) == .success else { throw LanguageServiceError.timeout }
        if let error = delegate.failure { throw error }
        guard (200..<300).contains(delegate.status),!delegate.bytes.isEmpty else { throw LanguageServiceError.message("Plugin download failed. Check the URL and try again.") }
        return delegate.bytes
    }
    public func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,Self.valid(url,allowLoopback:allowLoopback) else { failure = PluginError.invalidPackage;completionHandler(nil);return };completionHandler(request)
    }
    public func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive response: URLResponse,completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard response.expectedContentLength <= maximum else { failure = PluginError.invalidPackage;completionHandler(.cancel);return };completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive data: Data) {
        if bytes.count+data.count > maximum { failure = PluginError.invalidPackage;dataTask.cancel() } else { bytes.append(data) }
    }
    public func urlSession(_ session: URLSession,task: URLSessionTask,didCompleteWithError error: Error?) { if failure == nil { failure = error };done.signal() }
}
