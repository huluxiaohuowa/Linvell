import AppKit
import LinvellCore

/// Coalesces native file events and remote polling. Repositories are read only while their view is active.
final class GitWorkspaceRefresh {
    private var repository: GitRepository
    private var watchers: [LanguageWorkspaceWatch] = []
    private var timer: Timer?
    private var dirty = true
    private var checking = false
    private var fingerprint: String?
    private var lastPoll = Date.distantPast
    private var invalidated = false
    var isVisible: () -> Bool
    var changed: () -> Void

    init(repository: GitRepository,isVisible: @escaping () -> Bool,changed: @escaping () -> Void) {
        self.repository = repository; self.isVisible = isVisible; self.changed = changed
        if repository.remote == nil {
            watchers = [LanguageWorkspaceWatch(root:repository.directory) { [weak self] paths,_ in
                guard paths.contains(where:{ !$0.hasSuffix(".lock") }) else { return }
                DispatchQueue.main.async { self?.dirty = true }
            }]
            DispatchQueue.global(qos:.utility).async { [weak self] in
                let folders = (try? repository.metadataDirectories()) ?? []
                DispatchQueue.main.async {
                    guard let self,!self.invalidated else { return }
                    for folder in Set(folders) where !folder.hasPrefix(repository.directory+"/") {
                        self.watchers.append(LanguageWorkspaceWatch(root:folder) { [weak self] paths,_ in
                            guard paths.contains(where:{ !$0.hasSuffix(".lock") }) else { return }
                            DispatchQueue.main.async { self?.dirty = true }
                        })
                    }
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.check() }
        NotificationCenter.default.addObserver(self,selector:#selector(activated),name:NSApplication.didBecomeActiveNotification,object:nil)
    }
    @objc private func activated() { dirty = true; check() }
    func invalidate() { invalidated = true; timer?.invalidate(); timer = nil; watchers = []; NotificationCenter.default.removeObserver(self) }
    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
    func check(force: Bool = false) {
        guard !invalidated,!checking,force || isVisible() else { return }
        let remote = repository.remote != nil
        guard force || dirty || (remote && Date().timeIntervalSince(lastPoll) >= 2) else { return }
        dirty = false; checking = true; lastPoll = Date()
        let repository = self.repository
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let value = try? repository.refreshFingerprint()
            DispatchQueue.main.async {
                guard let self,!self.invalidated else { return }
                self.checking = false
                if value != self.fingerprint || force {
                    self.fingerprint = value; self.changed()
                }
            }
        }
    }
}
