import AppKit
import WebKit
import UniformTypeIdentifiers
import Ink
import LinvellCore

enum MarkdownRendering {
    static func html(_ text: String,colors: [UInt32]) -> String {
        let color = { (index: Int) in String(format:"#%06X",colors[index]) }
        let lines = LineIndex(text)
        var parser = MarkdownParser()
        for target: Modifier.Target in [.headings,.paragraphs,.codeBlocks,.lists,.tables,.blockquotes,.horizontalLines] {
            parser.addModifier(Modifier(target:target) { input in
                guard input.markdown.base == text,let tagEnd = input.html.firstIndex(of:">") else { return input.html }
                let range = NSRange(input.markdown.startIndex..<input.markdown.endIndex,in:text)
                var html = input.html
                html.insert(contentsOf:" data-source-line=\"\(lines.line(at:range.location)+1)\"",at:tagEnd)
                return html
            })
        }
        let content = text.utf8.count <= 2*1024*1024 ? parser.html(from:text) : "<p>Markdown preview is limited to 2 MiB. The source remains available in the editor.</p>"
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src linvell-preview: data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>
        :root{color-scheme:light dark}*{box-sizing:border-box}body{margin:0;padding:32px clamp(24px,5vw,64px);background:\(color(0));color:\(color(2));font:16px/1.7 -apple-system,BlinkMacSystemFont,sans-serif;overflow-wrap:anywhere}
        main{max-width:900px;margin:auto}h1,h2,h3,h4,h5,h6{line-height:1.3;margin:1.7em 0 .65em;font-weight:650}h1{font-size:2em}h2{font-size:1.5em;border-bottom:1px solid \(color(7));padding-bottom:.3em}main>:first-child{margin-top:0}a{color:\(color(4));text-underline-offset:3px}p,ul,ol,pre,blockquote,table{margin:0 0 1.1em}li+li{margin-top:.25em}code{font: .88em/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;background:\(color(1));padding:.15em .35em;border-radius:4px}pre{padding:18px 20px;background:\(color(1));border:1px solid \(color(7));border-radius:8px;overflow:auto;overflow-wrap:normal}pre code{padding:0;background:none;white-space:pre}blockquote{margin-left:0;padding:6px 20px;border-left:4px solid \(color(4));color:\(color(3))}blockquote p:last-child{margin-bottom:0}img{max-width:100%;height:auto;border-radius:6px}table{border-collapse:collapse;display:block;overflow:auto}th,td{padding:9px 14px;border:1px solid \(color(7));text-align:left}th{background:\(color(1))}hr{border:0;border-top:1px solid \(color(7));margin:2em 0}
        </style></head><body><main data-source-lines="\(lines.starts.count)">\(content)</main></body></html>
        """
    }
    static func localURL(_ url: URL,root: URL) -> URL? {
        guard url.scheme == "linvell-preview",url.host == "document" else { return nil }
        let root = root.resolvingSymlinksInPath()
        let components = url.path.split(separator:"/").map(String.init)
        guard !components.contains("..") else { return nil }
        var candidate = root
        for component in components {
            candidate = candidate.appendingPathComponent(component).resolvingSymlinksInPath().standardizedFileURL
            guard candidate == root || candidate.path.hasPrefix(root.path+"/") else { return nil }
        }
        return candidate != root ? candidate : nil
    }
}

final class MarkdownPreview: NSView, WKNavigationDelegate {
    let webView: WKWebView
    private let resources: MarkdownResources
    private var work: DispatchWorkItem?
    private var generation = UUID()
    private let isHTML: Bool
    private let scrollBridge = PreviewScrollBridge()
    private var lastScrollAnchor = DocumentScrollAnchor(line:1,progress:0)
    private var sourceLines = 1
    var onScroll: ((DocumentScrollAnchor) -> Void)?
    var openFile: ((URL) -> Void)?
    init(root: URL,html: Bool = false) {
        isHTML = html
        resources = MarkdownResources(root:root)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = html
        if !html {
            configuration.userContentController.add(scrollBridge,contentWorld:.defaultClient,name:"linvellScroll")
            configuration.userContentController.addUserScript(WKUserScript(source:PreviewScrollScript.source,injectionTime:.atDocumentEnd,forMainFrameOnly:true,in:.defaultClient))
        }
        configuration.setURLSchemeHandler(resources,forURLScheme:"linvell-preview")
        webView = WKWebView(frame:.zero,configuration:configuration)
        super.init(frame:.zero); webView.navigationDelegate = self
        scrollBridge.preview = self
        webView.setAccessibilityLabel(L.text(html ? "HTML rendered preview" : "Markdown rendered preview"))
        Theme.pin(webView,in:self)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { work?.cancel() }
    func render(_ text: String) {
        sourceLines = LineIndex(text).starts.count
        work?.cancel(); let token = UUID(); generation = token
        let colors = Theme.profile.colors
        let rawHTML = isHTML
        let item = DispatchWorkItem { [weak self] in
            let html = rawHTML ? Self.documentHTML(text) : MarkdownRendering.html(text,colors:colors)
            DispatchQueue.main.async { [weak self] in
                guard let self,self.generation == token else { return }
                self.webView.loadHTMLString(html,baseURL:URL(string:"linvell-preview://document/")!)
            }
        }
        work = item; DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+0.2,execute:item)
    }
    func scrollFromSource(_ anchor: DocumentScrollAnchor) {
        guard !isHTML else { return }; lastScrollAnchor = anchor
        guard webView.url != nil,!webView.isLoading,anchor.line.isFinite,anchor.progress.isFinite else { return }
        webView.evaluateJavaScript("window.__linvellSourceScroll && window.__linvellSourceScroll(\(anchor.line),\(anchor.progress))",in:nil,in:.defaultClient,completionHandler:{ _ in })
    }
    func receivedScroll(_ body: Any) {
        guard !isHTML,let value = body as? [String:Any],let line = value["line"] as? Double,let progress = value["progress"] as? Double,
              line.isFinite,progress.isFinite,progress >= 0,progress <= 1 else { return }
        let anchor = DocumentScrollAnchor(line:min(Double(sourceLines+1),max(1,line)),progress:progress)
        lastScrollAnchor = anchor; onScroll?(anchor)
    }
    func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) { scrollFromSource(lastScrollAnchor) }
    static func documentHTML(_ source: String) -> String {
        let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src linvell-preview: https: data:; style-src linvell-preview: https: 'unsafe-inline'; script-src linvell-preview: https: 'unsafe-inline'; font-src linvell-preview: https: data:; connect-src https: wss:; base-uri 'none'; form-action 'none'\">"
        if let head = source.range(of:"<head(?:\\s[^>]*)?>",options:[.regularExpression,.caseInsensitive]) {
            var html = source; html.insert(contentsOf:policy,at:head.upperBound); return html
        }
        return policy+source
    }
    func webView(_ webView: WKWebView,decidePolicyFor navigationAction: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .linkActivated {
            if let file = MarkdownRendering.localURL(url,root:resources.root) { openFile?(file) }
            else if ["http","https","mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            else if url.fragment != nil,url.path == "/" { decisionHandler(.allow); return }
            decisionHandler(.cancel); return
        }
        decisionHandler(url.scheme == "about" || url.scheme == "linvell-preview" ? .allow : .cancel)
    }
}

private final class MarkdownResources: NSObject, WKURLSchemeHandler {
    let root: URL
    init(root: URL) { self.root = root }
    func webView(_ webView: WKWebView,start urlSchemeTask: WKURLSchemeTask) {
        guard let requested = urlSchemeTask.request.url,let url = MarkdownRendering.localURL(requested,root:root),
              let type = UTType(filenameExtension:url.pathExtension),type.conforms(to:.image) || ["css","js","mjs","woff","woff2","ttf","otf"].contains(url.pathExtension.lowercased()),
              let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize,size <= 20*1024*1024,
              let data = try? Data(contentsOf:url) else { urlSchemeTask.didFailWithError(CocoaError(.fileReadNoSuchFile)); return }
        urlSchemeTask.didReceive(URLResponse(url:requested,mimeType:type.preferredMIMEType ?? "application/octet-stream",expectedContentLength:data.count,textEncodingName:nil))
        urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView,stop urlSchemeTask: WKURLSchemeTask) {}
}
