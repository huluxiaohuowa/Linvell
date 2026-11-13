import AppKit
import LinvellCore

/// File and hunk actions live alongside the selectable patch in both review modes.
final class GitPatchTextView: NSTextView {
    var apply: ((GitHunk?) -> Void)?
    var unstaging = false
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for:event) ?? NSMenu()
        guard apply != nil else { return menu }
        menu.addItem(.separator())
        for (title,selector) in [(unstaging ? "Unstage Selected Lines" : "Stage Selected Lines",#selector(applyLines)),
                                 (unstaging ? "Unstage Hunk" : "Stage Hunk",#selector(applyHunk)),
                                 (unstaging ? "Unstage File" : "Stage File",#selector(applyFile))] {
            let item = NSMenuItem(title:L.text(title),action:selector,keyEquivalent:"")
            item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc func applyLines() {
        do { apply?(try GitHunk.selection(in:string,range:selectedRange(),unstage:unstaging)) }
        catch { if let window { Theme.errorAlert(error).beginSheetModal(for:window) } }
    }
    @objc func applyHunk() {
        let source = string as NSString
        let position = selectedRange().location
        var location = 0
        for hunk in GitHunk.parse(string) {
            let range = source.range(of:hunk.header,options:[],range:NSRange(location:location,length:source.length-location))
            guard range.location != NSNotFound else { continue }
            location = NSMaxRange(range)
            let next = source.range(of:"\n@@ ",options:[],range:NSRange(location:location,length:source.length-location))
            if position >= range.location && (next.location == NSNotFound || position <= next.location) {
                // The callback accepts an index-directed patch, so reverse selected hunk lines here too.
                do { apply?(try GitHunk.selection(in:string,range:NSRange(location:range.location,length:(next.location == NSNotFound ? source.length : next.location)-range.location),unstage:unstaging)) }
                catch { if let window { Theme.errorAlert(error).beginSheetModal(for:window) } }
                return
            }
        }
    }
    @objc func applyFile() { apply?(nil) }
}
