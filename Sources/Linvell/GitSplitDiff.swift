// Similarity pairing and matched wrapped-row spacing adapted from FoldGit (MIT), copyright (c) 2026 dufu.
import AppKit

/// The columns share logical rows and row heights; source offsets still address the original patch.
final class GitSplitDiff: NSView {
    let oldText = NSTextView(),newText = NSTextView()
    private let oldScroll = GitReviewCodeScroll(),newScroll = GitReviewCodeScroll()
    private let panes = ResizablePanes()
    private var synchronizing = false
    private var wrapping = false
    private var patch = NSAttributedString(string:"")
    private var renderedWidth: CGFloat = -1
    private(set) var oldLines: [(display:NSRange,source:NSRange)] = []
    private(set) var newLines: [(display:NSRange,source:NSRange)] = []
    private(set) var rowHeights: [CGFloat] = []
    private(set) var measuredHeight: CGFloat = 60
    var continuous = false { didSet { oldScroll.continuous = continuous; newScroll.continuous = continuous; oldScroll.hasVerticalScroller = !continuous; newScroll.hasVerticalScroller = !continuous } }
    var onHeightChange: (() -> Void)?
    var visibleEditor: NSTextView { window?.firstResponder === oldText ? oldText : newText }

    override init(frame: NSRect) {
        super.init(frame:frame)
        panes.firstMinimum = 120; panes.secondMinimum = 120
        for (text,scroll,title) in [(oldText,oldScroll,"Before"),(newText,newScroll,"After")] {
            text.isEditable = false; text.isRichText = false
            text.isVerticallyResizable = true; text.isHorizontallyResizable = true
            text.usesFindBar = true; text.isIncrementalSearchingEnabled = true
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.containerSize = NSSize(width:100_000,height:CGFloat.greatestFiniteMagnitude)
            text.textContainerInset = NSSize(width:8,height:8)
            text.setAccessibilityLabel(L.text(title))
            scroll.documentView = text
            scroll.verticalRulerView = GitDiffLineRuler(scroll:scroll,editor:text,side:text === oldText ? 0 : 1)
            scroll.hasVerticalRuler = true; scroll.rulersVisible = true
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.drawsBackground = false
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
    override func layout() {
        super.layout()
        panes.layoutSubtreeIfNeeded()
        let width = max(32,oldScroll.contentSize.width-16)+max(32,newScroll.contentSize.width-16)*0.371
        if wrapping,abs(width-renderedWidth) > 0.5 { rebuild(width:width) }
    }
    func setWrap(_ wrap: Bool) {
        guard wrapping != wrap else { return }
        wrapping = wrap
        rebuild(width:max(32,min(oldScroll.contentSize.width,newScroll.contentSize.width)-16))
    }
    func render(_ patch: NSAttributedString) {
        self.patch = patch.copy() as! NSAttributedString
        rebuild(width:max(32,min(oldScroll.contentSize.width,newScroll.contentSize.width)-16))
    }
    private func rebuild(width: CGFloat) {
        let oldWidth = max(32,oldScroll.contentSize.width-16),newWidth = max(32,newScroll.contentSize.width-16)
        renderedWidth = oldWidth+newWidth*0.371
        var oldAnnotation: NSRange?,newAnnotation: NSRange?
        var rows: [(NSRange?,NSRange?)] = []
        var removed: [NSRange] = [],added: [NSRange] = []
        let source = patch.string as NSString
        var budget = InlineDiff.Budget()
        func flush() {
            let old = removed.map { String(source.substring(with:$0).dropFirst()) }
            let new = added.map { String(source.substring(with:$0).dropFirst()) }
            for (a,b) in InlineDiff.pair(old,new,budget:&budget) { rows.append((a.map { removed[$0] },b.map { added[$0] })) }
            if oldAnnotation != nil || newAnnotation != nil { rows.append((oldAnnotation,newAnnotation)) }
            removed = []; added = []; oldAnnotation = nil; newAnnotation = nil
        }
        var inHunk = false
        source.enumerateSubstrings(in:NSRange(location:0,length:source.length),options:.byLines) { line,range,_,_ in
            guard let line else { return }
            if line.hasPrefix("diff --git ") { flush(); inHunk = false }
            if line.hasPrefix("@@ ") { flush(); inHunk = true; rows.append((range,range)) }
            else if inHunk && line.hasPrefix("-") { removed.append(range) }
            else if inHunk && line.hasPrefix("+") { added.append(range) }
            else if inHunk && line.hasPrefix("\\") {
                // Keep the EOF annotation on the side whose last line it describes.
                if !added.isEmpty { newAnnotation = range }
                else if !removed.isEmpty { oldAnnotation = range }
                else { rows.append((range,range)) }
            } else { flush(); rows.append((range,range)) }
        }
        flush()
        let font = Theme.editorFont
        let lineHeight = ceil(font.ascender-font.descender+font.leading)+4
        func lines(_ range: NSRange?,width: CGFloat) -> Int {
            guard wrapping,let range,range.length > 0 else { return 1 }
            let storage = NSTextStorage(attributedString:patch.attributedSubstring(from:range))
            let paragraph = NSMutableParagraphStyle(); paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight
            paragraph.lineBreakMode = .byCharWrapping
            paragraph.defaultTabInterval = (" " as NSString).size(withAttributes:[.font:font]).width*4; paragraph.tabStops = []
            paragraph.baseWritingDirection = .leftToRight
            storage.addAttributes([.font:font,.paragraphStyle:paragraph],range:NSRange(location:0,length:storage.length))
            let manager = NSLayoutManager(),container = NSTextContainer(size:NSSize(width:width,height:CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 5
            storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for:container)
            var count = 0
            manager.enumerateLineFragments(forGlyphRange:NSRange(location:0,length:manager.numberOfGlyphs)) { _,_,_,_,_ in count += 1 }
            return max(1,count)
        }
        let oldCounts = rows.map { lines($0.0,width:oldWidth) },newCounts = rows.map { lines($0.1,width:newWidth) }
        rowHeights = zip(oldCounts,newCounts).map { CGFloat(max($0,$1))*lineHeight }
        func column(old: Bool) -> (NSMutableAttributedString,[(NSRange,NSRange)]) {
            let value = NSMutableAttributedString(),counts = old ? oldCounts : newCounts
            var mapping: [(NSRange,NSRange)] = []
            for (index,row) in rows.enumerated() {
                let range = old ? row.0 : row.1,start = value.length
                if let range { value.append(patch.attributedSubstring(from:range)); mapping.append((NSRange(location:start,length:range.length),range)) }
                value.append(NSAttributedString(string:"\n",attributes:[.font:font]))
                let paragraph = NSMutableParagraphStyle()
                paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight
                paragraph.lineBreakMode = .byCharWrapping; paragraph.baseWritingDirection = .leftToRight
                paragraph.defaultTabInterval = (" " as NSString).size(withAttributes:[.font:font]).width*4; paragraph.tabStops = []
                paragraph.paragraphSpacing = max(0,rowHeights[index]-CGFloat(counts[index])*lineHeight)
                value.addAttribute(.paragraphStyle,value:paragraph,range:NSRange(location:start,length:value.length-start))
            }
            return (value,mapping)
        }
        let left = column(old:true),right = column(old:false)
        oldLines = left.1; newLines = right.1
        for (text,scroll,value,columnWidth) in [(oldText,oldScroll,left.0,oldWidth),(newText,newScroll,right.0,newWidth)] {
            let selection = text.selectedRange()
            text.backgroundColor = Theme.liveCanvas
            text.isHorizontallyResizable = !wrapping; text.autoresizingMask = wrapping ? .width : []
            text.textContainer?.widthTracksTextView = false
            text.textContainer?.containerSize = NSSize(width:wrapping ? columnWidth : 100_000,height:CGFloat.greatestFiniteMagnitude)
            scroll.hasHorizontalScroller = !wrapping
            text.textStorage?.setAttributedString(value)
            text.minSize = .zero
            text.setFrameSize(NSSize(width:max(1,scroll.contentSize.width),height:rowHeights.reduce(0,+)+20))
            if !wrapping { text.sizeToFit() }
            text.setSelectedRange(NSRange(location:min(selection.location,value.length),length:min(selection.length,max(0,value.length-selection.location))))
            scroll.verticalRulerView?.needsDisplay = true
        }
        let height = max(60,rowHeights.reduce(0,+)+58+(wrapping ? 0 : 16))
        if abs(measuredHeight-height) > 1 { measuredHeight = height; onHeightChange?() }
    }
    func sourceSelection(allowCaret: Bool = false) -> NSRange? {
        let left = oldText.selectedRange(),right = newText.selectedRange()
        let useOld = window?.firstResponder === oldText || (window?.firstResponder !== newText && left.length > 0)
        let selection = useOld ? left : right
        let mapping = useOld ? oldLines : newLines
        if selection.length == 0 {
            guard allowCaret,let line = mapping.first(where:{ NSLocationInRange(selection.location,$0.display) }) else { return nil }
            return NSRange(location:line.source.location+selection.location-line.display.location,length:0)
        }
        let selected = mapping.filter { NSIntersectionRange(selection,$0.display).length > 0 }
        guard let first = selected.first,let last = selected.last else { return nil }
        for (a,b) in zip(selected,selected.dropFirst()) where NSMaxRange(a.source)+1 != b.source.location { return nil }
        let start = first.source.location+max(0,selection.location-first.display.location)
        let end = last.source.location+min(last.display.length,NSMaxRange(selection)-last.display.location)
        return NSRange(location:start,length:end-start)
    }
    @objc private func syncScroll(_ notification: Notification) {
        guard !synchronizing,!continuous,let source = notification.object as? NSClipView else { return }
        let other = source === oldScroll.contentView ? newScroll : oldScroll
        synchronizing = true
        other.contentView.scroll(to:NSPoint(x:other.contentView.bounds.minX,y:source.bounds.minY)); other.reflectScrolledClipView(other.contentView)
        synchronizing = false
    }
}
