import AppKit

enum FileDrop {
    static func urls(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
    }
    static func perform(_ sender: NSDraggingInfo,in window: NSWindow?) -> Bool {
        let urls = urls(sender.draggingPasteboard)
        guard !urls.isEmpty,let workspace = window?.windowController as? WorkspaceController else { return false }
        urls.forEach { workspace.open($0) }; window?.makeKeyAndOrderFront(nil); return true
    }
}

final class WorkspaceRootView: NSView {
    override init(frame: NSRect) {
        super.init(frame:frame); wantsLayer = true; clipsToBounds = true
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { FileDrop.urls(sender.draggingPasteboard).isEmpty ? [] : .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !FileDrop.urls(sender.draggingPasteboard).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { FileDrop.perform(sender,in:window) }
}
