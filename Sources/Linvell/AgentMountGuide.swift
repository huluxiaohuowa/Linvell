import AppKit
import LinvellCore

final class AgentMountGuide: NSView {
    let availability = Theme.label("",size:12,color:Theme.secondary)
    let copy = NSButton(),instructions = NSButton(),recheck = NSButton(),connect = NSButton()
    var onRecheck: (() -> Void)?
    var onConnect: (() -> Void)?
    init() {
        super.init(frame:.zero)
        availability.maximumNumberOfLines = 0; availability.lineBreakMode = .byWordWrapping
        let explanation = Theme.label(L.text("Local agents need SSHFS and compatible macOS filesystem support to access this SSH project. Running an agent on the SSH host does not require them."),size:13,color:Theme.secondary)
        explanation.maximumNumberOfLines = 0; explanation.lineBreakMode = .byWordWrapping
        let steps = Theme.label(L.text("Install the prerequisites, follow any system authorization or restart prompts, then recheck and connect the project mount."),size:13,color:Theme.secondary)
        steps.maximumNumberOfLines = 0; steps.lineBreakMode = .byWordWrapping
        for (button,title,action) in [(copy,"Copy Homebrew Install Command",#selector(copyCommand)),(instructions,"Open macFUSE Installation Guide",#selector(openGuide)),(recheck,"Recheck Installation",#selector(recheckInstallation)),(connect,"Connect Project",#selector(connectProject))] {
            button.title = L.text(title); button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        let command = Theme.label(AgentMountSupport.installCommand,size:12,color:Theme.foreground)
        command.font = .monospacedSystemFont(ofSize:12,weight:.regular); command.isSelectable = true
        command.maximumNumberOfLines = 0; command.lineBreakMode = .byCharWrapping
        let content = Theme.stack([explanation,availability,command,copy,instructions,steps,recheck,connect],orientation:.vertical,spacing:10)
        Theme.pin(content,in:self)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    func update() {
        let support = AgentMountSupport.detect()
        let sshfs = L.text(support.sshfs == nil ? "SSHFS: not found" : "SSHFS: installed")
        let filesystem = L.text(support.macFUSEInstalled ? "macFUSE: installation detected" : "macFUSE: installation not detected")
        availability.stringValue = sshfs+" · "+filesystem
    }
    @objc func copyCommand() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(AgentMountSupport.installCommand,forType:.string)
    }
    @objc private func openGuide() { NSWorkspace.shared.open(AgentMountSupport.installationGuide) }
    @objc private func connectProject() { onConnect?() }
    @objc private func recheckInstallation() { update(); onRecheck?() }
}
