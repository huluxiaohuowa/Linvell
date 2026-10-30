import AppKit
import LinvellCore

final class AgentSyncGuide: NSView {
    let availability = NSTextField(labelWithString:"")
    let command = Theme.label(AgentSyncSupport.installCommand,size:12,color:Theme.foreground)
    let copy = NSButton(),instructions = NSButton(),recheck = NSButton(),connect = NSButton()
    var onRecheck: (() -> Void)?
    var onConnect: (() -> Void)?
    init() {
        super.init(frame:.zero)
        availability.maximumNumberOfLines = 0; availability.lineBreakMode = .byWordWrapping
        let explanation = Theme.label(L.text("Mutagen is optional. Install it only to let a local agent edit this SSH project through a synchronized local copy. Agents running on the SSH host do not need it."),size:13,color:Theme.secondary)
        explanation.maximumNumberOfLines = 0; explanation.lineBreakMode = .byWordWrapping
        let steps = Theme.label(L.text("No filesystem driver or startup security change is required. Linvell manages its own synchronization process without registering a login item. Changes synchronize both ways; conflicts require review. Build and test commands need SSH to run remotely."),size:13,color:Theme.secondary)
        steps.maximumNumberOfLines = 0; steps.lineBreakMode = .byWordWrapping
        for (button,title,action) in [(copy,"Copy Homebrew Install Command",#selector(copyCommand)),(instructions,"Mutagen Documentation",#selector(openGuide)),(recheck,"Recheck Installation",#selector(recheckInstallation)),(connect,"Connect with Mutagen",#selector(connectProject))] {
            button.title = L.text(title); button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        command.font = .monospacedSystemFont(ofSize:12,weight:.regular); command.isSelectable = true
        command.maximumNumberOfLines = 0; command.lineBreakMode = .byCharWrapping
        let content = Theme.stack([explanation,availability,command,copy,instructions,steps,recheck,connect],orientation:.vertical,spacing:10)
        Theme.pin(content,in:self)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(support: AgentSyncSupport = .detect()) {
        let available = support.executable != nil
        availability.stringValue = L.text(available ? "✓ Mutagen installed — local agents can edit remote code" : "Mutagen not installed — optional for local agents on SSH projects")
        availability.textColor = available ? .systemGreen : .secondaryLabelColor
        command.isHidden = available; copy.isHidden = available
    }
    @objc func copyCommand() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(AgentSyncSupport.installCommand,forType:.string)
    }
    @objc private func openGuide() { NSWorkspace.shared.open(AgentSyncSupport.installationGuide) }
    @objc private func connectProject() { onConnect?() }
    @objc private func recheckInstallation() { update(); onRecheck?() }
}
