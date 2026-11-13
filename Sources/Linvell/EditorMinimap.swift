import AppKit

/// Draws only the lines that fit in the minimap, sampling long documents.
final class EditorMinimap: NSView {
    weak var pane: EditorPane?
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let pane, bounds.height >= 4 else { return }
        let document = pane.document
        let starts = document.lines.starts
        let text = document.storage.string as NSString
        let slots = min(starts.count,max(1,Int((bounds.height-2)/2)))
        let rowHeight: CGFloat = 2
        let mapHeight = CGFloat(slots)*rowHeight
        let tokens = document.syntax.version == document.buffer.revision ? document.syntax.analysis.tokens : []
        Theme.secondary.withAlphaComponent(0.13).setFill()
        NSRect(x:0,y:0,width:1,height:bounds.height).fill()
        for slot in 0..<slots {
            let line = slot*starts.count/slots
            let start = starts[line]
            let end = min(start+80,line+1 < starts.count ? starts[line+1] : text.length)
            let y = CGFloat(slot)*rowHeight+1
            var tokenIndex = 0, high = tokens.count
            while tokenIndex < high {
                let mid = (tokenIndex+high)/2
                if NSMaxRange(tokens[mid].range) <= start { tokenIndex = mid+1 } else { high = mid }
            }
            var column: CGFloat = 0
            for offset in start..<end {
                let unit = text.character(at:offset)
                if column >= bounds.width-8 || unit == 10 || unit == 13 { break }
                if unit == 9 { column += 4; continue }
                defer { column += 1 }
                if unit == 32 { continue }
                while tokenIndex < tokens.count, NSMaxRange(tokens[tokenIndex].range) <= offset { tokenIndex += 1 }
                let color = tokenIndex < tokens.count && tokens[tokenIndex].range.location <= offset
                    ? Theme.syntaxColor(tokens[tokenIndex].kind) : Theme.secondary
                color.withAlphaComponent(0.7).setFill()
                NSRect(x:4+column,y:y,width:1,height:1).fill()
            }
        }
        let top = pane.scrollAnchor.line-1
        let last = CGFloat(starts.count)
        let bottom = CGFloat(pane.lastVisibleSourceLine+1)
        let height = min(mapHeight,max(5,(bottom-top)*mapHeight/last))
        let y = min(mapHeight-height,max(0,top*mapHeight/last))
        let viewport = NSBezierPath(roundedRect:NSRect(x:2,y:y,width:bounds.width-4,height:height),xRadius:3,yRadius:3)
        Theme.foreground.withAlphaComponent(0.13).setFill()
        viewport.fill()
        Theme.foreground.withAlphaComponent(0.27).setStroke()
        viewport.stroke()
    }

    override func mouseDown(with event: NSEvent) { navigate(event) }
    override func mouseDragged(with event: NSEvent) { navigate(event) }

    private func navigate(_ event: NSEvent) {
        guard let pane else { return }
        let lines = pane.document.lines.starts.count
        let slots = min(lines,max(1,Int((bounds.height-2)/2)))
        let height = CGFloat(slots)*2
        let progress = max(0,min(1,convert(event.locationInWindow,from:nil).y/height))
        let line = min(lines,Int(progress*CGFloat(lines))+1)
        pane.scrollFromPreview(DocumentScrollAnchor(line:Double(line),progress:Double(progress)))
    }
}
