import AppKit
import LinvellCore

final class GitGraphView: NSView {
    let row: GitGraphRow
    init(_ row: GitGraphRow) {
        self.row = row; super.init(frame:.zero); translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant:CGFloat(max(2,row.width))*14+12).isActive = true
        heightAnchor.constraint(equalToConstant:58).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let center = bounds.midY
        func x(_ lane: Int) -> CGFloat { 10+CGFloat(lane)*14 }
        func color(_ hash: String) -> NSColor {
            let palette: [NSColor] = [Theme.accent,.systemBlue,.systemPurple,.systemOrange,.systemPink,.systemTeal]
            return palette[hash.utf8.reduce(0) { ($0+Int($1))%palette.count }]
        }
        func edge(_ edge: GitGraphRow.Edge,top: CGFloat,bottom: CGFloat) {
            color(edge.hash).setStroke(); let line = NSBezierPath(); line.lineWidth = 2
            line.move(to:NSPoint(x:x(edge.from),y:top))
            let mid = (top+bottom)/2
            line.curve(to:NSPoint(x:x(edge.to),y:bottom),controlPoint1:NSPoint(x:x(edge.from),y:mid),controlPoint2:NSPoint(x:x(edge.to),y:mid)); line.stroke()
        }
        row.upper.forEach { edge($0,top:0,bottom:center) }
        row.lower.forEach { edge($0,top:center,bottom:bounds.height) }
        Theme.canvas.setFill(); NSBezierPath(ovalIn:NSRect(x:x(row.lane)-5,y:center-5,width:10,height:10)).fill()
        Theme.accent.setStroke(); let circle = NSBezierPath(ovalIn:NSRect(x:x(row.lane)-4,y:center-4,width:8,height:8)); circle.lineWidth = 2; circle.stroke()
    }
}
