import AppKit
import SwiftTerm

/// The terminal parser, cursor, accessibility and pixels commit together at the
/// window's display cadence; no fixed 60 Hz throttle is used by the application.
final class DisplayPacedTerminalView: LocalProcessTerminalView {
    override init(frame: NSRect) {
        super.init(frame:frame)
        displayUpdateScheduler = { [weak self] work in
            let schedule = { [weak self] in
                guard let self,let window = self.window else { work(); return }
                Rendering.enqueue(in:window,key:ObjectIdentifier(self),work:work)
            }
            if Thread.isMainThread { schedule() } else { DispatchQueue.main.async(execute:schedule) }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}
