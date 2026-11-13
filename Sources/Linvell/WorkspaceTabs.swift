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
        if let path = document.remote?.path ?? document.fileURL?.path {
            menu.addItem(.separator())
            let project = document.remote == nil ? root?.url.path : remoteDirectory
            for item in ExplorerActions.pathItems(path,relative:ExplorerActions.relative(path,under:project),reveal:document.remote == nil ? document.fileURL : nil) { menu.addItem(item) }
        }
        return menu
    }

    @objc func selectNextTab() { selectTab(offset:1) }
    @objc func selectPreviousTab() { selectTab(offset:-1) }

    private func selectTab(offset: Int) {
        guard !documents.isEmpty else { return }
        guard let index = documents.firstIndex(where:{ $0 === current }) else {
            activate(offset > 0 ? documents[0] : documents[documents.count-1]); return
        }
        let next = (index+offset+documents.count)%documents.count
        if next != index { activate(documents[next]) }
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
