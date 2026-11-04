import AppKit

final class GitDiffLineRuler: NSRulerView {
    private weak var editor: NSTextView?
    private let side: Int?
    init(scroll: NSScrollView,editor: NSTextView,side: Int? = nil) {
        self.editor = editor; self.side = side
        super.init(scrollView:scroll,orientation:.verticalRuler)
        clientView = editor; ruleThickness = side == nil ? 84 : 48
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self,selector:#selector(invalidate),name:NSView.boundsDidChangeNotification,object:scroll.contentView)
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func invalidate() { needsDisplay = true }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        Theme.panel.setFill(); bounds.fill()
        guard let editor,let manager = editor.layoutManager,let container = editor.textContainer else { return }
        let source = editor.string as NSString
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.regular),.foregroundColor:Theme.secondary]
        let glyphs = manager.glyphRange(forBoundingRect:editor.visibleRect,in:container)
        let visible = manager.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
        var old = 0,new = 0,inHunk = false
        source.enumerateSubstrings(in:NSRange(location:0,length:source.length),options:.byLines) { value,range,_,stop in
            if range.location > NSMaxRange(visible) { stop.pointee = true; return }
            guard let line = value,!line.isEmpty else { return }
            if line.hasPrefix("@@ ") {
                let parts = line.split(separator:" ")
                old = parts.count > 1 ? Int(parts[1].dropFirst().split(separator:",")[0]) ?? 0 : 0
                new = parts.count > 2 ? Int(parts[2].dropFirst().split(separator:",")[0]) ?? 0 : 0
                inHunk = true; return
            }
            if line.hasPrefix("diff ") { inHunk = false }
            guard inHunk,let prefix = line.first,[" ","+","-"].contains(prefix) else { return }
            let left = prefix == "+" ? "" : String(old),right = prefix == "-" ? "" : String(new)
            if prefix != "+" { old += 1 }; if prefix != "-" { new += 1 }
            guard NSMaxRange(range) >= visible.location else { return }
            let glyph = manager.glyphIndexForCharacter(at:range.location)
            let fragment = manager.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
            let y = fragment.minY+editor.textContainerInset.height-editor.visibleRect.minY
            guard y > -20,y < self.bounds.height else { return }
            let labels = self.side.map { [($0 == 0 ? left : right,CGFloat(42))] } ?? [(left,CGFloat(38)),(right,CGFloat(78))]
            for (value,x) in labels {
                let label = value as NSString
                label.draw(at:NSPoint(x:x-label.size(withAttributes:attributes).width,y:y),withAttributes:attributes)
            }
        }
    }
}
