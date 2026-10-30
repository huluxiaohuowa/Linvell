import AppKit

extension WorkspaceController {
    var allAgentWorkspaces: [AgentWorkspace] {
        var result = agentWorkspaces
        if let agentWorkspace,!result.contains(where:{ $0 === agentWorkspace }) { result.append(agentWorkspace) }
        return result
    }
    var agentsRunning: Bool { allAgentWorkspaces.contains { $0.running } }
    func mayCloseAgents() -> Bool { allAgentWorkspaces.first(where:{ $0.running })?.mayClose() ?? true }
    func shutdownAgent() {
        agentFileMonitor?.stop(); agentFileMonitor = nil
        allAgentWorkspaces.forEach { $0.shutdown() }
    }
    /// Bind discovery and launch controls to the current project, while retaining
    /// other projects' PTYs until they are explicitly stopped or the window exits.
    @discardableResult func synchronizeAgentWorkspace(autoLoad: Bool = true) -> AgentWorkspace? {
        let directory = remoteConnection == nil ? (root?.url.path ?? current?.fileURL?.deletingLastPathComponent().path) : remoteDirectory
        guard let directory else { return nil }
        if let existing = agentWorkspace,existing.project == directory,existing.remote?.host == remoteConnection?.host { return existing }
        if let existing = agentWorkspace,!agentWorkspaces.contains(where:{ $0 === existing }) { agentWorkspaces.append(existing) }
        let selected = agentWorkspaces.first { $0.project == directory && $0.remote?.host == remoteConnection?.host }
            ?? AgentWorkspace(project:directory,remote:remoteConnection,autoLoad:autoLoad)
        if !agentWorkspaces.contains(where:{ $0 === selected }) { agentWorkspaces.append(selected) }
        agentWorkspace = selected
        return selected
    }
    func agentProjectDidChange() {
        guard let previous = agentWorkspace else { return }
        let visible = editors.arrangedSubviews.contains { $0 is AgentWorkspace }
        guard let selected = synchronizeAgentWorkspace(),selected !== previous else { return }
        configureAgent(selected)
        if visible { presentAgent(selected,showConfiguration:sidebarKind == "agents") }
        else if sidebarKind == "agents" { showSidebar("agents") }
    }
    @objc func showAgents() {
        guard let selected = synchronizeAgentWorkspace() else { openFolder(); return }
        configureAgent(selected); selected.reload()
        if agentFileMonitor == nil { agentFileMonitor = AgentFileMonitor(workspace:self) }
        presentAgent(selected)
    }
    private func configureAgent(_ agentWorkspace: AgentWorkspace) {
        agentWorkspace.onOpenFile = { [weak self] path,remote,line in
            self?.openCodeFile(path,remote:remote) { [weak self] in if let line { self?.goToLine(line) } }
        }
        agentWorkspace.onStart = { [weak self,weak agentWorkspace] in if let agentWorkspace { self?.presentAgent(agentWorkspace) } }
    }
    private func presentAgent(_ agent: AgentWorkspace,showConfiguration: Bool = true) {
        preserveEditorPosition(); current = nil; activePane = nil; panes = []; markdownView = nil
        editors.arrangedSubviews.forEach { $0.removeFromSuperview() }
        editors.addArrangedSubview(agent); editors.adjustSubviews(); renderTabs()
        previewButton.isHidden = true; breadcrumb.stringValue = L.text("Agents"); modeLabel.stringValue = "AGENT"
        languageStatus.stringValue = ""
        status.stringValue = agent.terminal?.process.running == true ? L.text("Running")+" · "+(agent.activeRuntime?.context.kind.title ?? agent.kind.title) : L.text("Agents")
        window?.title = L.text("Agents")+" — Linvell"
        if showConfiguration { showSidebar("agents") }; window?.makeFirstResponder(agent.terminal)
    }
}
