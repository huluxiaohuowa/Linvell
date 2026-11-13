import AppKit
import LinvellCore

extension WorkspaceController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard root != nil, remoteConnection == nil else { return }
        let node = outline.item(atRow:outline.clickedRow) as? FileNode
        for (title,action) in [("New File Here…",#selector(createExplorerFile(_:))),
                               ("New Folder Here…",#selector(createExplorerFolder(_:)))] {
            addExplorerItem(title,action:action,node:node,to:menu)
        }
        if let node {
            menu.addItem(.separator())
            addExplorerItem("Rename…",action:#selector(renameExplorerItem(_:)),node:node,to:menu)
            addExplorerItem("Move to Trash…",action:#selector(trashExplorerItem(_:)),node:node,to:menu)
        }
    }

    private func addExplorerItem(_ title: String,action: Selector,node: FileNode?,to menu: NSMenu) {
        let item = NSMenuItem(title:L.text(title),action:action,keyEquivalent:"")
        item.target = self
        item.representedObject = node
        menu.addItem(item)
    }

    @objc private func createExplorerFile(_ sender: NSMenuItem) { createExplorerItem(sender,directory:false) }
    @objc private func createExplorerFolder(_ sender: NSMenuItem) { createExplorerItem(sender,directory:true) }

    private func createExplorerItem(_ sender: NSMenuItem,directory: Bool) {
        let node = sender.representedObject as? FileNode
        guard let folder = node.map({ $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() }) ?? root?.url else { return }
        promptExplorerName(directory ? "New Folder Here…" : "New File Here…",initial:"",button:"Create") { [weak self] name in
            guard let self else { return }
            let target = folder.appendingPathComponent(name,isDirectory:directory)
            do {
                if directory { try FileManager.default.createDirectory(at:target,withIntermediateDirectories:false) }
                else { try Data().write(to:target,options:.withoutOverwriting) }
                self.refreshExplorerDirectory(folder)
                if !directory { self.open(target) }
            } catch { self.show(error) }
        }
    }

    @objc private func renameExplorerItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode else { return }
        let original = node.url, folder = original.deletingLastPathComponent()
        promptExplorerName("Rename…",initial:original.lastPathComponent,button:"Rename") { [weak self] name in
            guard let self,name != original.lastPathComponent else { return }
            let target = folder.appendingPathComponent(name,isDirectory:node.isDirectory)
            let affected = self.openDocuments(under:original)
            guard !affected.contains(where:{ self.autoSaving.contains($0.buffer.id) }),
                  !self.loading.keys.contains(where:{ $0.path == original.path || $0.path.hasPrefix(original.path+"/") }) else {
                self.status.stringValue = L.text("Finish opening or saving the file and try again.")
                return
            }
            do {
                let oldCode = affected.compactMap { self.codeSnapshot($0,forClosing:true) }
                try FileManager.default.moveItem(at:original,to:target)
                oldCode.forEach { self.languageServices.close($0) }
                for document in affected {
                    if let preview = document.previewURL {
                        document.previewURL = URL(fileURLWithPath:target.path+String(preview.path.dropFirst(original.path.count)))
                    } else { document.buffer.relocate(from:original,to:target) }
                    document.syntax.invalidate()
                }
                if let current = self.current,affected.contains(where:{ $0 === current }) { self.activate(current) }
                else { self.renderTabs() }
                self.refreshExplorerDirectory(folder)
            } catch { self.show(error) }
        }
    }

    @objc private func trashExplorerItem(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileNode, let window else { return }
        let affected = openDocuments(under:node.url)
        guard !affected.contains(where:{ $0.buffer.isModified || autoSaving.contains($0.buffer.id) }),
              !loading.keys.contains(where:{ $0.path == node.url.path || $0.path.hasPrefix(node.url.path+"/") }) else {
            status.stringValue = L.text("Save or close affected tabs before moving this item to the Trash.")
            return
        }
        let alert = ThemedAlert()
        alert.messageText = L.format("Move “%@” to the Trash?",node.url.lastPathComponent)
        alert.addButton(withTitle:L.text("Move to Trash"))
        alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] result in
            guard let self,result == .alertFirstButtonReturn,
                  !affected.contains(where:{ $0.buffer.isModified || self.autoSaving.contains($0.buffer.id) }) else { return }
            do {
                try FileManager.default.trashItem(at:node.url,resultingItemURL:nil)
                affected.forEach { self.closeDocument($0) }
                self.refreshExplorerDirectory(node.url.deletingLastPathComponent())
            } catch { self.show(error) }
        }
    }

    private func openDocuments(under url: URL) -> [OpenDocument] {
        documents.filter { document in
            guard document.remote == nil, let path = document.fileURL?.path else { return false }
            return path == url.path || path.hasPrefix(url.path+"/")
        }
    }

    private func promptExplorerName(_ title: String,initial: String,button: String,apply: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = ThemedAlert()
        alert.messageText = L.text(title)
        let field = NSTextField(string:initial)
        field.frame.size = NSSize(width:310,height:26)
        field.placeholderString = L.text("Name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle:L.text(button))
        alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] result in
            guard result == .alertFirstButtonReturn else { return }
            let name = field.stringValue
            guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, name != ".", name != "..",
                  !name.contains("/"), !name.utf8.contains(0) else {
                self?.show(CocoaError(.fileWriteInvalidFileName)); return
            }
            apply(name)
        }
    }

    private func refreshExplorerDirectory(_ folder: URL) {
        if let root, root.url == folder {
            updateExternalDirectory(root,children:FileNode(folder).children)
        } else if let node = (0..<outline.numberOfRows).compactMap({ outline.item(atRow:$0) as? FileNode }).first(where:{ $0.url == folder }) {
            updateExternalDirectory(node,children:FileNode(folder).children)
        } else { refreshFiles() }
    }

    func updateIgnoredFiles(for project: FileNode) {
        let directory = project.url
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let repository = GitRepository(root:directory)
            let ignored = (try? repository.run(["ls-files","--others","--ignored","--exclude-standard","--directory","-z","--"])) ?? ""
            let paths = Set(ignored.split(separator:"\0").map { String($0.hasSuffix("/") ? $0.dropLast() : $0[...]) })
            DispatchQueue.main.async {
                guard let self,self.root === project else { return }
                self.ignoredFiles = paths
                self.outline.reloadData(forRowIndexes:IndexSet(integersIn:0..<self.outline.numberOfRows),columnIndexes:IndexSet(integer:0))
            }
        }
    }

    func isIgnored(_ node: FileNode) -> Bool {
        guard let root,!ignoredFiles.isEmpty else { return false }
        var path = ProjectFiles.relative(node.url,root:root.url)
        while !path.isEmpty {
            if ignoredFiles.contains(path) { return true }
            path = (path as NSString).deletingLastPathComponent
        }
        return false
    }
}
