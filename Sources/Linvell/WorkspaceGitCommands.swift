import AppKit
import LinvellCore

extension WorkspaceController {
    func worktreeDidRelocate(host: String?,from old: String,to new: String?) {
        let matches = host == nil ? remoteConnection == nil && root?.url.path == old : remoteConnection?.host == host && remoteDirectory == old
        guard matches,window?.isVisible != true,!agentsRunning,!documents.contains(where:{ $0.buffer.isModified }) else { return }
        resetLanguageServices(); stopPlugins(); gitWorkspaceView?.shutdown(); gitWorkspaceView = nil
        runWorkspaceView = nil; fileIndex = []
        if let new {
            if host == nil { root = FileNode(URL(fileURLWithPath:new)) } else { remoteDirectory = new }
            for doc in documents {
                if let remote = doc.remote,remote.path.hasPrefix(old+"/") { remote.path = new+String(remote.path.dropFirst(old.count)) }
                else if let image = doc.previewURL,image.path.hasPrefix(old+"/") { doc.previewURL = URL(fileURLWithPath:new+String(image.path.dropFirst(old.count))) }
                else { doc.buffer.relocate(from:URL(fileURLWithPath:old),to:URL(fileURLWithPath:new)) }
            }
            projectTitle.stringValue = URL(fileURLWithPath:new).lastPathComponent
        } else {
            documents.removeAll(); current = nil; root = nil; remoteDirectory = "~"
            editors.arrangedSubviews.forEach { $0.removeFromSuperview() }
        }
        outline.reloadData(); renderTabs()
    }
    var worktreeIntegrationEnabled: Bool {
        let location: WorkspaceSession?
        if let remoteConnection { location = .ssh(host:remoteConnection.host,path:remoteDirectory) }
        else { location = root.map { .local(path:$0.url.path) } }
        return location.map { GitRepositoryOrganization.showsWorktrees($0) } ?? false
    }
    private func activeGit(_ action: (GitWorkspace) -> Void) {
        guard let git = gitWorkspaceView,editors.arrangedSubviews.first === git,!git.running,window?.attachedSheet == nil else { return }
        action(git)
    }
    @objc func showGitChanges() { activeGit { $0.showChangesFromMenu() } }
    @objc func refreshGitRepository() { activeGit { $0.reload() } }
    @objc func openGitTerminal() { activeGit { $0.openTerminalFromMenu() } }
    @objc func showGitInFinder() { activeGit { $0.showInFinderFromMenu() } }
    @objc func expandGitDirectories() { activeGit { $0.expandDirectoriesFromMenu(true) } }
    @objc func collapseGitDirectories() { activeGit { $0.expandDirectoriesFromMenu(false) } }
    @objc func createGitBranch() { activeGit { $0.newBranchFromMenu() } }
    @objc func createGitTag() { activeGit { $0.newTagFromMenu() } }
    @objc func stashGitChanges() { activeGit { $0.stashFromMenu() } }
    @objc func browseGitStashes() { activeGit { $0.stashesFromMenu() } }
    @objc func renameGitBranch() { activeGit { $0.renameBranchFromMenu() } }
    @objc func mergeGitBranch() { activeGit { $0.mergeBranchFromMenu() } }
    @objc func amendGitCommit() { activeGit { $0.amendFromMenu() } }
    @objc func checkoutGitCommit() { activeGit { $0.checkoutCommitFromMenu() } }
    @objc func revertGitCommit() { activeGit { $0.revertCommitFromMenu() } }
    @objc func copyGitCommit() { activeGit { $0.copyCommitFromMenu() } }
    @objc func compareGitCommits() { activeGit { $0.compareSelectedCommits() } }
    @objc func createGitWorktree() { activeGit { $0.newWorktreeFromMenu() } }
    @objc func finishGitWorktree() { activeGit { $0.finishWorktreeFromMenu() } }
    @objc func showGitShortcuts() { activeGit { $0.shortcutsFromMenu() } }
    @objc func commitGitChanges() { activeGit { $0.commitFromMenu() } }
    @objc func stageGitChanges() { activeGit { $0.stageAllFromMenu() } }
    @objc func unstageGitChanges() { activeGit { $0.unstageAllFromMenu() } }
    @objc func stageGitFile() { activeGit { $0.stageFromMenu() } }
    @objc func unstageGitFile() { activeGit { $0.unstageFromMenu() } }
    @objc func pullGitChanges() { activeGit { $0.pullFromMenu() } }
    @objc func pushGitChanges() { activeGit { $0.pushFromMenu() } }
}
