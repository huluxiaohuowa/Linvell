import AppKit
import LinvellCore

struct PreparedCodeRename {
    let edits: CodeDocumentEdits
    let original: String
    let updated: String
    let openID: UUID?
    let openVersion: Int?
    let buffer: DocumentBuffer?
    let remote: RemoteDocument?
}
struct CodeRenameUndo {
    let document: OpenDocument
    let before: String
    let after: String
}

extension WorkspaceController {
    @objc func renameSymbol() {
        guard let document = current,let editor = activePane?.textView,let snapshot = codeSnapshot(document),let window else { return }
        let at = editor.selectedRange().location,word = EditorTextView.codeWord(in:editor.string,at:at)
        guard word.length > 0 else { return }
        let oldName = (editor.string as NSString).substring(with:word)
        let alert = NSAlert(); alert.messageText = L.text("Rename Symbol")
        alert.informativeText = L.text("The language service updates this symbol's definition and references across the workspace.")
        let name = NSTextField(frame:NSRect(x:0,y:0,width:350,height:28)); name.stringValue = oldName
        alert.accessoryView = name; alert.window.initialFirstResponder = name
        alert.addButton(withTitle:L.text("Preview Rename")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self,response == .alertFirstButtonReturn,self.current?.buffer.id == snapshot.id,self.current?.buffer.revision == snapshot.version else { return }
            let value = name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !value.isEmpty,value != oldName,!value.contains("\0") else { return }
            self.languageRequest("textDocument/rename",at:at,extra:["newName":value]) { [weak self] edit,context in self?.prepareCodeRename(edit,context:context,oldName:oldName,newName:value) }
        }
    }
    func prepareCodeRename(_ value: Any,context: EditorCodeSnapshot,oldName: String,newName: String) {
        do {
            let plans = try CodeWorkspaceEdit.parse(value)
            guard !plans.isEmpty else { status.stringValue = L.text("No rename changes returned."); return }
            let existing = documents.compactMap { document -> EditorCodeSnapshot? in
                guard let snapshot = codeSnapshot(document),snapshot.remote?.host == context.remote?.host else { return nil }; return snapshot
            }
            let services = languageServices
            services.queue.async { [weak self] in
                let result = Result { () throws -> [PreparedCodeRename] in
                    var totalBytes = 0
                    func budget(_ text: String) throws {
                        let size = text.utf8.count
                        totalBytes += size
                        guard size <= 2*1024*1024,totalBytes <= 32*1024*1024 else { throw LanguageServiceError.message("The refactor exceeds the safe analysis size. No changes were applied.") }
                    }
                    return try plans.map { plan in
                        guard let url = URL(string:plan.uri),url.isFileURL else { throw DocumentError.invalidRange }
                        let path = url.standardizedFileURL.path,root = URL(fileURLWithPath:context.root).standardizedFileURL.path
                        guard path.hasPrefix(root+"/") else { throw LanguageServiceError.message("The refactor includes files outside this workspace. No changes were applied.") }
                        if let open = existing.first(where:{ $0.uri == plan.uri }) {
                            try budget(open.text)
                            if let version = plan.version,version != open.version { throw DocumentError.invalidRange }
                            let updated = try Self.checkedRename(plan,source:open.text,oldName:oldName)
                            return PreparedCodeRename(edits:plan,original:open.text,updated:updated,openID:open.id,openVersion:open.version,buffer:nil,remote:nil)
                        }
                        guard plan.version == nil else { throw DocumentError.invalidRange }
                        let buffer: DocumentBuffer,remoteDocument: RemoteDocument?
                        if let remote = context.remote {
                            let reply = try remote.request("read",path:path)
                            guard let encoded = reply.content,let data = Data(base64Encoded:encoded),let digest = reply.digest else { throw LanguageServiceError.message("Incomplete remote refactor response.") }
                            guard data.count <= 2*1024*1024 else { throw LanguageServiceError.message("The refactor exceeds the safe analysis size. No changes were applied.") }
                            let document = try RemoteDocument(connection:remote,path:reply.path ?? path,digest:digest,data:data)
                            remoteDocument = document; buffer = try DocumentBuffer(url:document.localURL)
                        } else {
                            guard url.resolvingSymlinksInPath().path.hasPrefix(root+"/"),
                                  (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 2*1024*1024 else { throw LanguageServiceError.message("The refactor exceeds the safe analysis size. No changes were applied.") }
                            buffer = try DocumentBuffer(url:url); remoteDocument = nil
                        }
                        try budget(buffer.text)
                        return PreparedCodeRename(edits:plan,original:buffer.text,updated:try Self.checkedRename(plan,source:buffer.text,oldName:oldName),openID:nil,openVersion:nil,buffer:buffer,remote:remoteDocument)
                    }
                }
                DispatchQueue.main.async {
                    guard let self,self.current?.buffer.id == context.id,self.current?.buffer.revision == context.version else { return }
                    switch result {
                    case .success(let prepared): self.previewCodeRename(prepared,newName:newName)
                    case .failure(let error): self.show(error)
                    }
                }
            }
        } catch { show(error) }
    }
    private static func checkedRename(_ plan: CodeDocumentEdits,source: String,oldName: String) throws -> String {
        // Closed files have no client version. Validate every old token as well as UTF-16 ranges.
        let index = LineIndex(source)
        for edit in plan.edits {
            let range = try edit.range.range(in:source,index:index)
            guard (source as NSString).substring(with:range) == oldName else { throw LanguageServiceError.message("A rename target changed or needs a compound rename. No changes were applied.") }
        }
        return try CodeTextEdit.applying(plan.edits,to:source)
    }
    private func previewCodeRename(_ prepared: [PreparedCodeRename],newName: String) {
        guard let window else { return }
        let alert = NSAlert(); alert.messageText = L.format("Rename to “%@”",newName)
        let count = prepared.reduce(0) { $0+$1.edits.edits.count }
        let paths = prepared.prefix(12).compactMap { URL(string:$0.edits.uri)?.lastPathComponent }.joined(separator:"\n")
        alert.informativeText = L.format("%d changes in %d files. Changes remain unsaved and can be undone together.",count,prepared.count)+"\n\n"+paths
        alert.addButton(withTitle:L.text("Apply Rename")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.applyCodeRename(prepared) }
        }
    }
    func applyCodeRename(_ prepared: [PreparedCodeRename]) {
        // Validate the entire plan before changing even one buffer.
        guard prepared.allSatisfy({ item in
            guard let id = item.openID else {
                return item.buffer != nil && !documents.contains { document in
                    let path = document.remote?.path ?? document.fileURL?.path
                    return path.map { URL(fileURLWithPath:$0).absoluteString } == item.edits.uri && document.remote?.connection.host == item.remote?.connection.host
                }
            }
            return documents.contains { $0.buffer.id == id && $0.buffer.revision == item.openVersion && $0.buffer.text == item.original && !autoSaving.contains(id) }
        }) else { status.stringValue = L.text("The project changed after the preview. Run Rename again."); return }
        completionPanel?.dismiss(); hoverPopover?.close()
        var undo: [CodeRenameUndo] = []
        for item in prepared {
            let document: OpenDocument
            if let id = item.openID,let existing = documents.first(where:{ $0.buffer.id == id }) { document = existing }
            else if let buffer = item.buffer { document = OpenDocument(buffer); document.remote = item.remote; documents.append(document) }
            else { continue }
            undo.append(CodeRenameUndo(document:document,before:item.original,after:item.updated))
        }
        for entry in undo { replaceCodeBuffer(entry.document,text:entry.after) }
        registerRenameUndo(undo); renderCodeRename()
        status.stringValue = L.format("Renamed in %d files. Save changes to write them to disk.",undo.count)
    }
    private func replaceCodeBuffer(_ document: OpenDocument,text: String) {
        autoSaveWork.removeValue(forKey:document.buffer.id)?.cancel()
        document.storage.replaceCharacters(in:NSRange(location:0,length:(document.storage.string as NSString).length),with:text)
        document.buffer.update(text); document.vim.sync(text:text,cursor:min(document.vim.cursor,(text as NSString).length))
        document.codeDiagnostics = []
        for pane in panes where pane.document === document {
            pane.textView.setSelectedRange(NSRange(location:min(pane.textView.selectedRange().location,(text as NSString).length),length:0))
            pane.refreshCodePresentation()
        }
        synchronizeLanguage(document); scheduleAutoSave(document)
    }
    private func renderCodeRename() { renderTabs(); markdownView?.render(current?.buffer.text ?? ""); updateStatus() }
    private func registerRenameUndo(_ entries: [CodeRenameUndo]) {
        guard let manager = window?.undoManager else { return }
        let group = manager.groupingLevel == 0 && !manager.isUndoing && !manager.isRedoing
        if group { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget:self) { workspace in
            guard entries.allSatisfy({ $0.document.buffer.text == $0.after && !workspace.autoSaving.contains($0.document.buffer.id) }) else { workspace.show(DocumentError.invalidRange); return }
            for entry in entries {
                if !workspace.documents.contains(where:{ $0 === entry.document }) { workspace.documents.append(entry.document) }
                workspace.replaceCodeBuffer(entry.document,text:entry.before)
            }
            workspace.registerRenameUndo(entries.map { CodeRenameUndo(document:$0.document,before:$0.after,after:$0.before) })
            workspace.renderCodeRename()
        }
        manager.setActionName(L.text("Rename Symbol"))
        if group { manager.endUndoGrouping() }
    }
    @objc func saveAll() { for document in documents where document.buffer.isModified { if !saveDocument(document) { break } } }
}
