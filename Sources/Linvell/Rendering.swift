import AppKit
import QuartzCore

/// AppKit/Core Animation owns scrolling. Use its responsive path and pace pending
/// window drawing with the display only while the user is interacting.
final class ResponsiveScrollView: NSScrollView {
    override class var isCompatibleWithResponsiveScrolling: Bool { true }
    override init(frame: NSRect) {
        super.init(frame:frame)
        wantsLayer = true; contentView = ResponsiveClipView()
        contentView.wantsLayer = true; scrollerStyle = .overlay
    }
    required init?(coder: NSCoder) { fatalError() }
}
final class ResponsiveClipView: NSClipView {
    override class var isCompatibleWithResponsiveScrolling: Bool { true }
}
class ResponsiveTableView: NSTableView {
    override class var isCompatibleWithResponsiveScrolling: Bool { true }
    override init(frame: NSRect) { super.init(frame:frame); wantsLayer = true; usesAutomaticRowHeights = false }
    required init?(coder: NSCoder) { fatalError() }
}
class ResponsiveOutlineView: NSOutlineView {
    override class var isCompatibleWithResponsiveScrolling: Bool { true }
    override init(frame: NSRect) { super.init(frame:frame); wantsLayer = true; usesAutomaticRowHeights = false }
    required init?(coder: NSCoder) { fatalError() }
}

enum Rendering {
    private static var monitor: Any?
    private static let windows = NSMapTable<NSWindow,WindowFrameScheduler>(keyOptions:.weakMemory,valueOptions:.strongMemory)
    static func frameRange(maximum: Int) -> CAFrameRateRange {
        let rate = Float(max(1,maximum))
        return CAFrameRateRange(minimum:min(80,rate),maximum:rate,preferred:rate)
    }
    private static func scheduler(for window: NSWindow) -> WindowFrameScheduler {
        if let existing = windows.object(forKey:window) { return existing }
        let scheduler = WindowFrameScheduler(window:window); windows.setObject(scheduler,forKey:window); return scheduler
    }
    static func enqueue(in window: NSWindow,key: ObjectIdentifier,work: @escaping () -> Void) {
        guard window.isVisible,window.occlusionState.contains(.visible) else { work(); return }
        scheduler(for:window).enqueue(key:key,work:work)
    }
    static func pulse(_ window: NSWindow) {
        scheduler(for:window).pulse()
    }
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching:[.scrollWheel,.leftMouseDragged,.rightMouseDragged,.magnify,.rotate,.keyDown,.leftMouseDown]) { event in
            if let window = event.window,window.isVisible {
                pulse(window)
            }
            return event
        }
    }
}

final class WindowFrameScheduler: NSObject {
    private weak var window: NSWindow?
    private var link: CADisplayLink?
    private var until: CFTimeInterval = 0
    private var screen: NSScreen?
    private var actions: [ObjectIdentifier:() -> Void] = [:]
    private var observer: NSObjectProtocol?
    var onFrame: ((CFTimeInterval) -> Void)?
    private final class Target: NSObject {
        weak var owner: WindowFrameScheduler?
        @objc func frame(_ link: CADisplayLink) { owner?.frame(link) }
    }
    private let target = Target()
    init(window: NSWindow) {
        self.window = window; super.init(); target.owner = self
        observer = NotificationCenter.default.addObserver(forName:NSWindow.didChangeOcclusionStateNotification,object:window,queue:.main) { [weak self] _ in
            if self?.window?.occlusionState.contains(.visible) != true { self?.flush(); self?.stop() }
        }
    }
    deinit { link?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    func enqueue(key: ObjectIdentifier,work: @escaping () -> Void) { actions[key] = work; pulse() }
    private func flush() { let pending = actions; actions.removeAll(); pending.values.forEach { $0() } }
    func pulse(duration: TimeInterval = 0.3) {
        guard let window else { return }
        until = CACurrentMediaTime()+duration
        if link != nil,screen !== window.screen { stop() }
        guard link == nil else { return }
        screen = window.screen
        let link = window.displayLink(target:target,selector:#selector(Target.frame(_:)))
        link.preferredFrameRateRange = Rendering.frameRange(maximum:window.screen?.maximumFramesPerSecond ?? 60)
        link.add(to:.main,forMode:.common); self.link = link
    }
    private func frame(_ link: CADisplayLink) {
        guard let window,CACurrentMediaTime() <= until else { stop(); return }
        onFrame?(link.timestamp); flush()
        window.displayIfNeeded()
    }
    func stop() { link?.invalidate(); link = nil; screen = nil }
}
