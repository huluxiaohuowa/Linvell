import AppKit

final class GitReviewLineRuler: NSRulerView {
    private weak var editor: NSTextView?

    init(scroll: NSScrollView,editor: NSTextView) {
        self.editor = editor
        super.init(scrollView:scroll,orientation:.verticalRuler)
        ruleThickness = 48
        clientView = editor
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self,selector:#selector(invalidate),name:NSView.boundsDidChangeNotification,object:scroll.contentView)
        NotificationCenter.default.addObserver(self,selector:#selector(invalidate),name:NSText.didChangeNotification,object:editor)
    }

    required init(coder: NSCoder) { fatalError() }
    @objc private func invalidate() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor,let manager = editor.layoutManager,let container = editor.textContainer else { return }
        Theme.panel.setFill()
        bounds.fill()
        let source = editor.string as NSString
        guard source.length > 0 else { return }
        let visible = editor.visibleRect.offsetBy(dx:0,dy:-editor.textContainerInset.height)
        let glyphs = manager.glyphRange(forBoundingRect:visible,in:container)
        guard glyphs.length > 0 else { return }
        var glyph = glyphs.location
        let character = manager.characterIndexForGlyph(at:glyph)
        var line = source.substring(to:character).filter { $0 == "\n" }.count+1
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.regular),.foregroundColor:Theme.secondary]
        while glyph < NSMaxRange(glyphs) {
            var range = NSRange()
            let fragment = manager.lineFragmentRect(forGlyphAt:glyph,effectiveRange:&range)
            let index = manager.characterIndexForGlyph(at:glyph)
            if index == 0 || source.character(at:index-1) == 10 {
                let label = String(line) as NSString
                let y = fragment.minY+editor.textContainerInset.height-editor.visibleRect.minY
                label.draw(at:NSPoint(x:ruleThickness-label.size(withAttributes:attributes).width-7,y:y),withAttributes:attributes)
                line += 1
            }
            glyph = NSMaxRange(range)
        }
    }
}
