import AppKit

/// Display the same patch in two aligned, selectable columns.
final class GitSplitDiff: NSView {
    private let oldText = NSTextView(),newText = NSTextView()
    private let oldScroll = ResponsiveScrollView(),newScroll = ResponsiveScrollView()
    private var synchronizing = false
    private var oldLines: [(display: NSRange,source: NSRange)] = []
    private var newLines: [(display: NSRange,source: NSRange)] = []

    override init(frame: NSRect) {
        super.init(frame:frame)
        let panes = ResizablePanes()
        panes.firstMinimum = 120; panes.secondMinimum = 120
        for (text,scroll,title) in [(oldText,oldScroll,"Before"),(newText,newScroll,"After")] {
            text.isEditable = false; text.isRichText = false
            text.isVerticallyResizable = true; text.isHorizontallyResizable = true
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.containerSize = NSSize(width:100_000,height:CGFloat.greatestFiniteMagnitude)
            text.textContainerInset = NSSize(width:8,height:8)
            text.setAccessibilityLabel(L.text(title))
            scroll.documentView = text; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.drawsBackground = false
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self,selector:#selector(syncScroll(_:)),name:NSView.boundsDidChangeNotification,object:scroll.contentView)
            let heading = Theme.label(title,size:11,color:Theme.secondary,weight:.semibold)
            let column = NSView()
            Theme.pin(Theme.stack([heading,scroll],orientation:.vertical,spacing:3),in:column,inset:4)
            panes.addArrangedSubview(column)
        }
        Theme.pin(panes,in:self)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setWrap(_ wrap: Bool) {
        for (text,scroll) in [(oldText,oldScroll),(newText,newScroll)] {
            text.isHorizontallyResizable = !wrap
            text.autoresizingMask = wrap ? .width : []
            text.textContainer?.widthTracksTextView = wrap
            text.textContainer?.containerSize = NSSize(width:wrap ? max(1,scroll.contentSize.width-16) : 100000,height:CGFloat.greatestFiniteMagnitude)
            if wrap { text.setFrameSize(NSSize(width:scroll.contentSize.width,height:text.frame.height)) }
            scroll.hasHorizontalScroller = !wrap
        }
    }

    func render(_ patch: NSAttributedString) {
        let left = NSMutableAttributedString(),right = NSMutableAttributedString()
        var removed: [NSRange] = [],added: [NSRange] = []
        oldLines = []; newLines = []
        let source = patch.string as NSString
        func append(_ range: NSRange?,to column: NSMutableAttributedString,lines: inout [(display:NSRange,source:NSRange)]) {
            if let range {
                lines.append((NSRange(location:column.length,length:range.length),range))
                column.append(patch.attributedSubstring(from:range))
            }
            column.append(NSAttributedString(string:"\n",attributes:[.font:Theme.editorFont]))
        }
        func flush() {
            for index in 0..<max(removed.count,added.count) {
                append(removed.indices.contains(index) ? removed[index] : nil,to:left,lines:&self.oldLines)
                append(added.indices.contains(index) ? added[index] : nil,to:right,lines:&self.newLines)
            }
            removed.removeAll(); added.removeAll()
        }
        var inHunk = false
        source.enumerateSubstrings(in:NSRange(location:0,length:source.length),options:.byLines) { value,range,_,_ in
            guard let value else { return }
            if value.hasPrefix("diff --git ") { inHunk = false }
            if value.hasPrefix("@@ ") || (range.location == 0 && value.hasPrefix("+++ ")) {
                flush()
                inHunk = true
                append(range,to:left,lines:&self.oldLines)
                append(range,to:right,lines:&self.newLines)
            } else if inHunk && value.hasPrefix("-") {
                removed.append(range)
            } else if inHunk && value.hasPrefix("+") {
                added.append(range)
            } else {
                flush()
                append(range,to:left,lines:&self.oldLines)
                append(range,to:right,lines:&self.newLines)
            }
        }
        flush()
        for (text,scroll,value) in [(oldText,oldScroll,left),(newText,newScroll,right)] {
            text.backgroundColor = Theme.canvas
            text.textStorage?.setAttributedString(value)
            text.minSize = scroll.contentSize
            text.sizeToFit()
            text.scrollRangeToVisible(NSRange(location:0,length:0))
        }
    }

    func sourceSelection() -> NSRange? {
        let left = oldText.selectedRange(),right = newText.selectedRange()
        let useOld = window?.firstResponder === oldText || (window?.firstResponder !== newText && left.length > 0)
        let selection = useOld ? left : right
        guard selection.length > 0 else { return nil }
        let selected = (useOld ? oldLines : newLines).filter { NSIntersectionRange(selection,$0.display).length > 0 }
        guard let first = selected.first,let last = selected.last else { return nil }
        for (a,b) in zip(selected,selected.dropFirst()) where NSMaxRange(a.source)+1 != b.source.location { return nil }
        let start = first.source.location+max(0,selection.location-first.display.location)
        let end = last.source.location+min(last.display.length,NSMaxRange(selection)-last.display.location)
        return NSRange(location:start,length:end-start)
    }

    @objc private func syncScroll(_ notification: Notification) {
        guard !synchronizing,let source = notification.object as? NSClipView else { return }
        let other = source === oldScroll.contentView ? newScroll : oldScroll
        synchronizing = true
        let point = NSPoint(x:other.contentView.bounds.minX,y:source.bounds.minY)
        other.contentView.scroll(to:point)
        other.reflectScrolledClipView(other.contentView)
        synchronizing = false
    }
}
