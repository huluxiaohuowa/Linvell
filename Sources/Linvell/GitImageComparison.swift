import AppKit
import ImageIO

final class GitImageComparison: NSView {
    private let panes = ResizablePanes()
    private let zoom = Theme.choiceButton()
    private var columns: [(NSImageView,NSScrollView,NSBitmapImageRep)] = []
    private let layoutMode = NSSegmentedControl(labels:[L.text("Auto"),L.text("Unified"),L.text("Side by Side")],trackingMode:.selectOne,target:nil,action:nil)

    init(before: Data?,after: Data?) {
        super.init(frame:NSRect(x:0,y:0,width:700,height:500))
        zoom.addItems(withTitles:[L.text("Fit"),"12.5%","25%","50%",L.text("Actual Size"),"200%","400%","800%"])
        zoom.target = self; zoom.action = #selector(updateZoom)
        layoutMode.selectedSegment = UserDefaults.standard.integer(forKey:"git.diffMode")
        layoutMode.target = self; layoutMode.action = #selector(updateLayout)
        let bar = Theme.stack([Theme.label("Image Comparison"),layoutMode,NSView(),zoom],spacing:6)
        bar.heightAnchor.constraint(equalToConstant:30).isActive = true
        for (title,data) in [("Before",before),("After",after)] {
            let image = GitCheckerboardImageView()
            image.imageScaling = .scaleAxesIndependently
            let bitmap: NSBitmapImageRep? = data.flatMap { data in
                guard let source = CGImageSourceCreateWithData(data as CFData,nil),
                      let info = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                      let width = info[kCGImagePropertyPixelWidth] as? Int,let height = info[kCGImagePropertyPixelHeight] as? Int,
                      Double(width)*Double(height) <= 40_000_000 else { return nil }
                let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,
                    kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:max(width,height)]
                return CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary).map(NSBitmapImageRep.init(cgImage:))
            }
            image.image = bitmap.flatMap { bitmap in
                bitmap.cgImage.map { NSImage(cgImage:$0,size:NSSize(width:bitmap.pixelsWide,height:bitmap.pixelsHigh)) }
            }
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            scroll.documentView = image
            if let bitmap { columns.append((image,scroll,bitmap)) }
            let metadata = bitmap.map { "\($0.pixelsWide) × \($0.pixelsHigh) px · "+ByteCountFormatter.string(fromByteCount:Int64(data?.count ?? 0),countStyle:.file) } ?? L.text(data == nil ? "No Image in This Version" : "Image Preview Unavailable")
            let column = Theme.stack([Theme.label(title),Theme.label(metadata,size:11,color:Theme.secondary),scroll],orientation:.vertical,spacing:6)
            column.frame = NSRect(x:0,y:0,width:350,height:450)
            panes.addArrangedSubview(column)
        }
        Theme.pin(Theme.stack([bar,panes],orientation:.vertical,spacing:6),in:self)
        updateLayout()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); updateLayout() }
    @objc private func updateLayout() {
        let vertical = layoutMode.selectedSegment == 1 || (layoutMode.selectedSegment == 0 && bounds.width < 700)
        if panes.isVertical == vertical { panes.isVertical = !vertical }
        updateZoom()
    }
    @objc private func updateZoom() {
        for (image,scroll,bitmap) in columns {
            let width = CGFloat(bitmap.pixelsWide),height = CGFloat(bitmap.pixelsHigh)
            let scale: CGFloat
            if zoom.indexOfSelectedItem == 0 {
                scale = max(0.01,min(max(1,scroll.contentSize.width-16)/width,max(1,scroll.contentSize.height-16)/height))
            } else {
                scale = [0,0.125,0.25,0.5,1,2,4,8][zoom.indexOfSelectedItem]/(window?.backingScaleFactor ?? 2)
            }
            image.setFrameSize(NSSize(width:max(1,width*scale),height:max(1,height*scale)))
        }
    }
}

private final class GitCheckerboardImageView: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.canvas.setFill(); dirtyRect.fill()
        Theme.secondary.withAlphaComponent(0.12).setFill()
        let tile: CGFloat = 12
        for y in Int(floor(dirtyRect.minY/tile))...Int(ceil(dirtyRect.maxY/tile)) {
            for x in Int(floor(dirtyRect.minX/tile))...Int(ceil(dirtyRect.maxX/tile)) where (x+y).isMultiple(of:2) {
                NSRect(x:CGFloat(x)*tile,y:CGFloat(y)*tile,width:tile,height:tile).fill()
            }
        }
        super.draw(dirtyRect)
    }
}
