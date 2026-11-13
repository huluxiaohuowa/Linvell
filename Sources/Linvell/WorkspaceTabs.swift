import AppKit

extension WorkspaceController {
    func tabMenu(for document: OpenDocument) -> NSMenu {
        let menu = NSMenu()
        for (title,action) in [
            ("Move Tab Left",#selector(moveTabLeft(_:))),
            ("Move Tab Right",#selector(moveTabRight(_:))),
            ("Close Other Tabs",#selector(closeOtherTabs(_:))),
            ("Close Tab",#selector(closeSelectedTab(_:)))
        ] {
            let item = NSMenuItem(title:L.text(title),action:action,keyEquivalent:"")
            item.target = self
            item.representedObject = document.buffer.id
            menu.addItem(item)
        }
        return menu
    }

    func moveTab(_ id: UUID,by offset: Int) {
        guard let index = documents.firstIndex(where:{ $0.buffer.id == id }),
              documents.indices.contains(index+offset) else { return }
        _ = moveTab(id,toInsertion:index+offset+(offset > 0 ? 1 : 0))
    }

    @discardableResult
    func moveTab(_ id: UUID,toInsertion boundary: Int) -> Bool {
        guard let source = documents.firstIndex(where:{ $0.buffer.id == id }),
              (0...documents.count).contains(boundary) else { return false }
        let destination = boundary > source ? boundary-1 : boundary
        guard source != destination else { return true }
        let document = documents.remove(at:source)
        documents.insert(document,at:destination)
        renderTabs()
        persistWorkspaceTabs()
        return true
    }
    @objc private func moveTabLeft(_ item: NSMenuItem) {
        if let id = item.representedObject as? UUID { moveTab(id,by:-1) }
    }
    @objc private func moveTabRight(_ item: NSMenuItem) {
        if let id = item.representedObject as? UUID { moveTab(id,by:1) }
    }
    @objc private func closeOtherTabs(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID else { return }
        for document in documents.reversed() where document.buffer.id != id {
            closeDocument(document)
            if documents.contains(where:{ $0 === document }) { break }
        }
    }
    @objc private func closeSelectedTab(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID,
              let document = documents.first(where:{ $0.buffer.id == id }) else { return }
        closeDocument(document)
    }
}
