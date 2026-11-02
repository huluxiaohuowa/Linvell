import AppKit
import LinvellCore

extension WorkspaceController {
    @objc func newAgentTask() {
        guard remoteConnection == nil,let root else { show(GitError.command("Task workspaces currently require a local repository.")); return }
        let repository = GitRepository(root:root.url)
        let alert = NSAlert(); alert.messageText = L.text("New Task Workspace…")
        alert.informativeText = L.text("Create an isolated branch and worktree from HEAD. Your current uncommitted changes stay in this window.")
        let name = NSTextField(frame:NSRect(x:0,y:0,width:380,height:26)); name.placeholderString = L.text("Task name")
        alert.accessoryView = name; alert.addButton(withTitle:L.text("Create")); alert.addButton(withTitle:L.text("Cancel"))
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for:window!) { [weak self] response in
            guard response == .alertFirstButtonReturn,let self else { return }
            let title = name.stringValue
            self.taskOperation { try AgentTaskStore().create(title:title,in:repository) } completion: { [weak self] task in self?.openTaskWorkspace(task.directory,title:task.title) }
        }
    }
    @objc func showAgentTasks() {
        guard remoteConnection == nil,let root else { show(GitError.command("Task workspaces currently require a local repository.")); return }
        let repository = GitRepository(root:root.url),store = AgentTaskStore()
        taskOperation { (try store.worktrees(in:repository),try store.tasks(in:repository)) } completion: { [weak self] paths,tasks in
            guard let self,let window = self.window else { return }
            var options = [PickerOption(title:L.text("New Task Workspace…"),detail:L.text("Isolate a task in its own branch and directory"),invoke:{ [weak self] in self?.newAgentTask() })]
            options += paths.map { path in
                let task = tasks.first { $0.directory == path }
                return PickerOption(title:task?.title ?? URL(fileURLWithPath:path).lastPathComponent,detail:(task?.branch ?? L.text("Existing worktree"))+" · "+path,invoke:{ [weak self] in self?.openTaskWorkspace(path,title:task?.title) })
            }
            options += tasks.map { task in
                PickerOption(title:L.text("Remove Clean Task Workspace…")+" · "+task.title,detail:task.directory,invoke:{ [weak self] in self?.removeAgentTask(task,repository:repository) })
            }
            self.picker = QuickPicker(title:L.text("Task Workspaces…"),options:options,owner:window)
        }
    }
    func openTaskWorkspace(_ path: String,title: String? = nil) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        if let existing = app.workspaces.first(where:{ $0.remoteConnection == nil && $0.root?.url.path == path && $0.window?.isVisible == true }) {
            existing.window?.makeKeyAndOrderFront(nil); return
        }
        let target = app.newWorkspace()
        target.setProject(URL(fileURLWithPath:path,isDirectory:true))
        target.synchronizeAgentWorkspace(autoLoad:false)?.isolatesProject = true
        target.projectTitle.stringValue = title ?? URL(fileURLWithPath:path).lastPathComponent
        target.showAgents()
    }
    private func removeAgentTask(_ task: AgentTask,repository: GitRepository) {
        let open = (NSApp.delegate as? AppDelegate)?.workspaces.contains { $0.root?.url.path == task.directory && ($0.window?.isVisible == true || $0.agentsRunning) } ?? false
        guard !open else { show(GitError.command("Close the task window and stop its agents before removing its worktree.")); return }
        let alert = NSAlert(); alert.messageText = L.text("Remove Clean Task Workspace…")
        alert.informativeText = task.title+"\n"+L.text("Only a clean, unlocked worktree can be removed. The branch and its commits are kept.")
        alert.addButton(withTitle:L.text("Remove")); alert.addButton(withTitle:L.text("Cancel"))
        alert.beginSheetModal(for:window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let open = (NSApp.delegate as? AppDelegate)?.workspaces.contains { $0.root?.url.path == task.directory && ($0.window?.isVisible == true || $0.agentsRunning) } ?? false
            guard !open else { self?.show(GitError.command("Close the task window and stop its agents before removing its worktree.")); return }
            self?.taskOperation { try AgentTaskStore().remove(task,in:repository) } completion: { [weak self] in self?.status.stringValue = L.text("Task worktree removed; branch kept.") }
        }
    }
    private func taskOperation<T>(_ work: @escaping () throws -> T,completion: @escaping (T) -> Void) {
        status.stringValue = L.text("Reading task workspaces…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result(catching:work)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result { case .success(let value): self.status.stringValue = L.text("Ready"); completion(value)
                case .failure(let error): self.show(error); self.status.stringValue = error.localizedDescription }
            }
        }
    }
}
