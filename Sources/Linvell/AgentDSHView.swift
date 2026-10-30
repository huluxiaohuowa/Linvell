import AppKit
import WebKit
import LinvellCore

/// DSH ships a Web application, not an interactive terminal profile. Keep its
/// own UI and credential service together; Linvell never reads login secrets.
final class AgentDSHView: NSView, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private weak var runtime: AgentRuntime?
    private let message = NSTextField(wrappingLabelWithString:L.text("Starting DeepSeek Harness…"))
    private var timer: Timer?
    private var deadline = Date.distantFuture
    private var loaded = false
    private var prepared = false
    private(set) var ready = false
    private(set) var failed = false
    private(set) var failureStage = ""
    init(runtime: AgentRuntime) {
        self.runtime = runtime
        let configuration = WKWebViewConfiguration()
        // Each open conversation retains its own selection and authenticated cookies.
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame:.zero,configuration:configuration)
        super.init(frame:.zero)
        webView.navigationDelegate = self; webView.uiDelegate = self
        Theme.pin(webView,in:self); Theme.pin(message,in:self,inset:20)
        webView.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    func start() {
        deadline = Date().addingTimeInterval(60)
        timer = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in self?.poll() }
    }
    private func poll() {
        guard let runtime else { timer?.invalidate(); return }
        if loaded {
            if !runtime.terminal.process.running { timer?.invalidate() }
            return
        }
        let output = String(decoding:runtime.terminal.getTerminal().getBufferAsData(),as:UTF8.self)
        if let url = Self.launchURL(in:output) {
            loaded = true
            timer?.invalidate(); timer = nil
            webView.load(URLRequest(url:url))
        } else if !runtime.terminal.process.running || Date() > deadline {
            fail(); timer?.invalidate()
        }
    }
    static func launchURL(in output: String) -> URL? {
        // PTY wrapping may split the launch token over terminal rows.
        let compact = output.replacingOccurrences(of:"\r",with:"").replacingOccurrences(of:"\n",with:"")
        guard let match = compact.range(of:#"dsh web: (http://127\.0\.0\.1:[0-9]+/\?token=[A-Za-z0-9_-]+)"#,options:.regularExpression),
              let start = compact[match].range(of:"http://") else { return nil }
        return URL(string:String(compact[start.lowerBound..<match.upperBound]))
    }
    private func fail() {
        failed = true; webView.isHidden = true; message.isHidden = false
        message.stringValue = L.text("DeepSeek Harness could not open the conversation. Check the selected CLI and agent home, then try again.")
    }
    func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) {
        guard !prepared,let runtime else {
            if prepared { ready = true; message.isHidden = true; webView.isHidden = false; window?.makeFirstResponder(webView) }
            return
        }
        prepared = true
        webView.callAsyncJavaScript(Self.prepareScript,arguments:["sessionID":runtime.sessionID ?? "","directory":runtime.directory],in:nil,in:.page) { [weak self,weak runtime] result in
            guard let self,let runtime else { return }
            switch result {
            case .success(let value):
                if let value = value as? [String:String],let stage = value["error"] { self.failureStage = stage; self.fail(); return }
                guard let id = value as? String,!id.isEmpty else { self.failureStage = "session identity"; self.fail(); return }
                runtime.sessionID = id
                self.webView.reload()
            case .failure(let error): self.failureStage = "WebKit \((error as NSError).code)"; self.fail()
            }
        }
    }
    // Public Web RPC creates the blank Session without a prompt. The browser's
    // persisted selection restores the exact id, including duplicate titles.
    static let prepareScript = """
    let stage = 'initialization';
    try {
    async function rpc(method, args) {
        stage = method;
        const rpcId = crypto.randomUUID();
        const response = await fetch('/api/' + method, {
            method: 'POST', credentials: 'include',
            headers: {'content-type': 'application/json'},
            body: JSON.stringify({type:'client-request', rpcId, method, payload:{args}})
        });
        const envelope = await response.json();
        if (!response.ok || envelope.type !== 'server-response' || envelope.rpcId !== rpcId || !envelope.result?.ok)
            throw new Error('DSH conversation request failed');
        return envelope.result.value;
    }
    let id = sessionID;
    if (!id) {
        const account = await rpc('account/getState', {});
        if (account.status === 'credential-stored') await rpc('session/initializeDefaultModel', {});
        id = (await rpc('session/create', {request:{cwd:directory}})).sessionId;
    }
    localStorage.setItem('dsh.sessions.current', JSON.stringify({sessionId:id}));
    return id;
    } catch (_) { return {error:stage}; }
    """
    func webView(_ webView: WKWebView,didFail navigation: WKNavigation!,withError error: Error) { fail() }
    func webView(_ webView: WKWebView,didFailProvisionalNavigation navigation: WKNavigation!,withError error: Error) { fail() }
    func webView(_ webView: WKWebView,decidePolicyFor action: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.navigationType == .linkActivated,url.host != webView.url?.host || url.port != webView.url?.port {
            if ["https","http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView,createWebViewWith configuration: WKWebViewConfiguration,for action: WKNavigationAction,windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url,["https","http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        return nil
    }
}
