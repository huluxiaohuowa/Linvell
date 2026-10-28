import Foundation
import WebKit

struct DocumentScrollAnchor {
    let line: Double
    let progress: Double
}

final class PreviewScrollBridge: NSObject, WKScriptMessageHandler {
    weak var preview: MarkdownPreview?
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) { preview?.receivedScroll(message.body) }
}

enum PreviewScrollScript {
    static let source = #"""
    (() => {
      let ignoreUntil = 0, scheduled = false;
      const main = document.querySelector('main[data-source-lines]');
      if (!main) return;
      const total = Math.max(1, Number(main.dataset.sourceLines));
      const points = () => Array.from(main.children)
        .filter(e => e.hasAttribute('data-source-line'))
        .map(e => ({line:Number(e.dataset.sourceLine), y:e.getBoundingClientRect().top+window.scrollY}))
        .filter(p => Number.isFinite(p.line) && Number.isFinite(p.y));
      const maximum = () => Math.max(0,document.documentElement.scrollHeight-window.innerHeight);
      window.__linvellSourceScroll = (line,progress) => {
        let y = 0, all = points();
        if (progress >= .999) y = maximum();
        else if (progress > .001 && all.length) {
          let i = 0; while(i+1 < all.length && all[i+1].line <= line) i++;
          const a = all[i], b = all[i+1] || {line:total+1,y:document.documentElement.scrollHeight};
          y = a.y+(b.y-a.y)*Math.max(0,Math.min(1,(line-a.line)/Math.max(1,b.line-a.line)));
        }
        ignoreUntil = performance.now()+80;
        window.scrollTo(0,Math.max(0,Math.min(maximum(),y)));
      };
      window.addEventListener('scroll',() => {
        if (performance.now() < ignoreUntil || scheduled) return;
        scheduled = true;
        queueMicrotask(() => {
          scheduled = false; if (performance.now() < ignoreUntil) return;
          const all = points(),y = window.scrollY,max = maximum();
          let line = 1;
          if (all.length) {
            let i=0; while(i+1 < all.length && all[i+1].y <= y) i++;
            const a=all[i],b=all[i+1] || {line:total+1,y:document.documentElement.scrollHeight};
            line=a.line+(b.line-a.line)*Math.max(0,Math.min(1,(y-a.y)/Math.max(1,b.y-a.y)));
          }
          window.webkit.messageHandlers.linvellScroll.postMessage({line,progress:max > 0 ? y/max : 0});
        });
      },{passive:true});
    })();
    """#
}
