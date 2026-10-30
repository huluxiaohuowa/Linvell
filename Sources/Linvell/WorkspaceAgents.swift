import AppKit

extension WorkspaceController {
    func shutdownAgent() {
        agentFileMonitor?.stop(); agentFileMonitor = nil
        agentWorkspace?.shutdown()
    }
    @objc func showAgents() {
        if let existing = agentWorkspace,existing.running { presentAgent(existing); return }
        let directory = remoteConnection == nil ? (root?.url.path ?? current?.fileURL?.deletingLastPathComponent().path) : remoteDirectory
        guard let directory else { openFolder(); return }
        if let existing = agentWorkspace,existing.project != directory || existing.remote?.host != remoteConnection?.host {
            guard existing.mayClose() else { return }; existing.shutdown(); agentWorkspace = nil
        }
        if agentWorkspace == nil { agentWorkspace = AgentWorkspace(project:directory,remote:remoteConnection) }
        else { agentWorkspace?.reload() }
        guard let agentWorkspace else { return }
        agentWorkspace.onOpenFile = { [weak self] path,remote,line in
            self?.openCodeFile(path,remote:remote) { [weak self] in if let line { self?.goToLine(line) } }
        }
        agentWorkspace.onStart = { [weak self,weak agentWorkspace] in if let agentWorkspace { self?.presentAgent(agentWorkspace) } }
        if agentFileMonitor == nil { agentFileMonitor = AgentFileMonitor(workspace:self) }
        presentAgent(agentWorkspace)
    }
    private func presentAgent(_ agent: AgentWorkspace) {
        preserveEditorPosition(); current = nil; activePane = nil; panes = []; markdownView = nil
        editors.arrangedSubviews.forEach { $0.removeFromSuperview() }
        editors.addArrangedSubview(agent); editors.adjustSubviews(); renderTabs()
        previewButton.isHidden = true; breadcrumb.stringValue = L.text("Agents"); modeLabel.stringValue = "AGENT"
        languageStatus.stringValue = ""
        status.stringValue = agent.running ? L.text("Running")+" · "+(agent.activeRuntime?.context.kind.title ?? agent.kind.title) : L.text("Agents")
        window?.title = L.text("Agents")+" — Linvell"
        showSidebar("agents"); window?.makeFirstResponder(agent.terminal)
    }
}
