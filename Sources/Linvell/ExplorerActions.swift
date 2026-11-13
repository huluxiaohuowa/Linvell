import AppKit
import LinvellCore

enum ExplorerActions {
    static func item(_ title: String,perform: @escaping () -> Void) -> NSMenuItem {
        let item = ExplorerActionItem(title:L.text(title),action:#selector(ExplorerActionItem.invoke),keyEquivalent:"")
        item.perform = perform
        item.target = item
        return item
    }

    static func pathItems(_ path: String,relative: String? = nil,reveal: URL? = nil) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let reveal {
            items.append(item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([reveal]) })
        }
        items.append(item("Copy Path") { copy(path) })
        if let relative { items.append(item("Copy Relative Path") { copy(relative) }) }
        return items
    }

    static func relative(_ path: String,under root: String?) -> String? {
        guard let root else { return nil }
        let prefix = root.hasSuffix("/") ? root : root+"/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    static func duplicate(_ url: URL,directory: Bool) throws -> URL {
        let ext = directory ? "" : url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent()
        for number in 1...1000 {
            let suffix = number == 1 ? " copy" : " copy \(number)"
            let target = parent.appendingPathComponent(base+suffix+(ext.isEmpty ? "" : "."+ext),isDirectory:directory)
            do { try FileManager.default.copyItem(at:url,to:target); return target }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { continue }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private static func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value,forType:.string)
    }
}

private final class ExplorerActionItem: NSMenuItem {
    var perform: (() -> Void)?
    @objc func invoke() { perform?() }
}
