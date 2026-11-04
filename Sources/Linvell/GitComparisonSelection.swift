import AppKit

final class GitComparisonSelection: NSView {
    let from = NSComboBox(),to = NSComboBox()
    init(refs: [String]) {
        super.init(frame:NSRect(x:0,y:0,width:420,height:100))
        for picker in [from,to] { picker.addItems(withObjectValues:refs); picker.usesDataSource = false; picker.completes = true }
        from.stringValue = refs.first ?? "HEAD"; to.stringValue = refs.dropFirst().first ?? "HEAD"
        let swap = NSButton(title:L.text("Swap Commits"),target:self,action:#selector(swapRevisions))
        Theme.pin(Theme.stack([Theme.stack([Theme.label("Base"),from]),
                               Theme.stack([Theme.label("Target"),to]),swap],orientation:.vertical,spacing:6),in:self)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func swapRevisions() {
        let value = from.stringValue; from.stringValue = to.stringValue; to.stringValue = value
    }
}
