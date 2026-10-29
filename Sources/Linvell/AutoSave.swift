import AppKit
import LinvellCore

final class TabCloseButton: NSButton {
    var modified = false { didSet { if oldValue != modified { needsDisplay = true } } }
    override init(frame: NSRect) {
        super.init(frame:frame); title = ""; isBordered = false
        widthAnchor.constraint(equalToConstant:22).isActive = true
        heightAnchor.constraint(equalToConstant:22).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x:bounds.midX-5,y:bounds.midY-5,width:10,height:10)
        (modified ? Theme.accent : Theme.secondary).set()
        if modified { NSBezierPath(ovalIn:rect).fill() }
        else {
            let path = NSBezierPath(); path.lineWidth = 1.4; path.lineCapStyle = .round
            path.move(to:NSPoint(x:rect.minX,y:rect.minY)); path.line(to:NSPoint(x:rect.maxX,y:rect.maxY))
            path.move(to:NSPoint(x:rect.minX,y:rect.maxY)); path.line(to:NSPoint(x:rect.maxX,y:rect.minY)); path.stroke()
        }
    }
}

extension WorkspaceController {
    func scheduleAutoSave(_ document: OpenDocument) {
        let id = document.buffer.id
        autoSaveWork.removeValue(forKey:id)?.cancel()
        guard PreferencesSync.value("autoSave") == "true",document.imageURL == nil,document.buffer.url != nil,document.buffer.isModified,!autoSaving.contains(id) else { return }
        let work = DispatchWorkItem { [weak self,weak document] in
            guard let self,let document,self.documents.contains(where:{ $0 === document }),PreferencesSync.value("autoSave") == "true" else { return }
            self.autoSaveWork.removeValue(forKey:id)
            guard !self.panes.contains(where:{ $0.document === document && $0.textView.hasMarkedText() }) else { return }
            guard let snapshot = try? document.buffer.saveSnapshot() else { return }
            self.autoSaving.insert(id)
            let remote = document.remote,expected = remote?.digest
            self.saveQueue.async { [weak self] in
                var digest: String?
                let result = Result { () throws -> Data in
                    if let remote {
                        let reply = try remote.connection.request("write",path:remote.path,content:snapshot.data(),digest:expected)
                        guard let value = reply.digest else { throw GitError.command("The remote save was not acknowledged.") }
                        digest = value
                    }
                    return try snapshot.write()
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.autoSaving.remove(id)
                    if let digest { remote?.digest = digest }
                    switch result {
                    case .success(let saved):
                        document.buffer.completeSave(snapshot,digest:saved)
                        self.codeDocumentSaved(document,savedVersion:snapshot.revision)
                        try? self.recovery.remove(id)
                        if document.buffer.isModified { self.scheduleAutoSave(document) }
                    case .failure(let error): self.status.stringValue = L.text("Automatic save stopped: ")+error.localizedDescription
                    }
                    self.updateTabTitles()
                }
            }
        }
        autoSaveWork[id] = work
        DispatchQueue.main.asyncAfter(deadline:.now()+1,execute:work)
    }
}
