import AppKit
import UniformTypeIdentifiers

final class ImagePreview: NSView {
    static func supports(_ url: URL) -> Bool {
        UTType(filenameExtension:url.pathExtension)?.conforms(to:.image) == true
    }
    private let scroll = ResponsiveScrollView()
    private let canvas: ImageCanvas
    private let information = Theme.label("",size:12,color:Theme.secondary)
    private var fitting = true
    private var scale: CGFloat = 1
    init(url: URL) {
        canvas = ImageCanvas(image:NSImage(contentsOf:url))
        super.init(frame:.zero)
        let fit = Theme.actionButton("Fit",target:self,action:#selector(fitImage))
        let actual = Theme.actionButton("100%",target:self,action:#selector(actualSize))
        let minus = Theme.actionButton("−",target:self,action:#selector(zoomOut))
        let plus = Theme.actionButton("+",target:self,action:#selector(zoomIn))
        let bar = Theme.stack([information,NSView(),minus,plus,actual,fit],spacing:8)
        bar.edgeInsets = NSEdgeInsets(top:10,left:16,bottom:10,right:16)
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = true; scroll.backgroundColor = Theme.panel; scroll.documentView = canvas
        Theme.pin(Theme.stack([bar,scroll],orientation:.vertical,spacing:0),in:self)
        setAccessibilityLabel("Image preview: \(url.lastPathComponent)")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); updateImage() }
    @objc private func fitImage() { fitting = true; updateImage() }
    @objc private func actualSize() { fitting = false; scale = 1; updateImage() }
    @objc private func zoomIn() { fitting = false; scale = min(8,scale*1.25); updateImage() }
    @objc private func zoomOut() { fitting = false; scale = max(0.01,scale/1.25); updateImage() }
    private func updateImage() {
        guard let image = canvas.image,image.size.width > 0,image.size.height > 0 else {
            information.stringValue = "This image format could not be decoded."; return
        }
        let area = scroll.contentSize
        if fitting { scale = max(0.01,min(1,min(area.width/image.size.width,area.height/image.size.height))) }
        canvas.scale = scale
        canvas.setFrameSize(NSSize(width:max(area.width,image.size.width*scale),height:max(area.height,image.size.height*scale)))
        let representation = image.representations.first
        information.stringValue = "\(representation?.pixelsWide ?? Int(image.size.width)) × \(representation?.pixelsHigh ?? Int(image.size.height))   ·   \(Int((scale*100).rounded()))%"
        canvas.needsDisplay = true
    }
}

private final class ImageCanvas: NSView {
    override class var isCompatibleWithResponsiveScrolling: Bool { true }
    let image: NSImage?
    var scale: CGFloat = 1
    init(image: NSImage?) { self.image = image; super.init(frame:.zero); wantsLayer = true; clipsToBounds = true }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        Theme.panel.setFill(); dirtyRect.fill()
        guard let image else { return }
        let size = NSSize(width:image.size.width*scale,height:image.size.height*scale)
        let rect = NSRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
    }
}
