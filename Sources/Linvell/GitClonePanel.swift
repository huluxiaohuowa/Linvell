import AppKit
import LinvellCore

/// Progress and cancellation adapted from FoldGit's clone sheet (dufu, MIT).
final class GitClonePanel: GitNativeSheet, NSTextFieldDelegate {
    let address = NSTextField(),folder = NSTextField(),parent = NSTextField(string:NSHomeDirectory()),progress = NSProgressIndicator()
    let onCloned: (URL) -> Void
    private var process: Process?,cancelled = false,previousSuggestion = "",diagnostic = ""
    init(owner: NSWindow,onCloned: @escaping (URL) -> Void) {
        self.onCloned = onCloned; super.init(title:"Clone Remote Repository",owner:owner)
        address.placeholderString = L.text("HTTPS or SSH repository address"); address.delegate = self
        row("Repository Address",address); row("Parent Folder",parent); body.addArrangedSubview(button("Choose Parent Folder…",#selector(chooseParent))); row("Folder Name",folder)
        progress.style = .bar; progress.isIndeterminate = true; progress.widthAnchor.constraint(equalToConstant:590).isActive = true; body.addArrangedSubview(progress)
        footer.addArrangedSubview(button("Clone",#selector(clone)))
        footer.addArrangedSubview(button("Cancel Clone",#selector(cancelClone))); fit()
    }
    required init?(coder: NSCoder) { fatalError() }
    func controlTextDidChange(_ notification: Notification) {
        guard !working else { return }
        let value = address.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        let component = value.split(separator:"/").last.map(String.init) ?? "repository"
        let suggested = component.hasSuffix(".git") ? String(component.dropLast(4)) : component
        if folder.stringValue.isEmpty || folder.stringValue == previousSuggestion { folder.stringValue = suggested }; previousSuggestion = suggested
    }
    @objc func chooseParent() { guard !working,let window else { return }; let panel = NSOpenPanel(); panel.appearance = window.effectiveAppearance; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.beginSheetModal(for:window) { [self] response in if response == .OK,let url = panel.url { parent.stringValue = url.path } } }
    @objc func clone() {
        guard !working else { return }; let name = folder.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),remote = address.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !remote.isEmpty,!name.isEmpty,name != ".",name != "..",!name.contains("/"),!name.contains("\0"),parent.stringValue.hasPrefix("/") else { message.stringValue = L.text("Enter a repository address and a valid destination folder."); return }
        let destination = URL(fileURLWithPath:parent.stringValue).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath:destination.path) else { message.stringValue = L.text("Choose a new folder for the clone."); return }
        let task = Process(),pipe = Pipe(); process = task; cancelled = false; diagnostic = ""; working = true
        // Cancellation remains available while the clone owns its destination.
        footer.arrangedSubviews.compactMap { $0 as? NSButton }.last?.isEnabled = true
        address.isEnabled = false; folder.isEnabled = false; parent.isEnabled = false; progress.isIndeterminate = true; progress.startAnimation(nil); message.stringValue = L.text("Cloning repository…")
        task.executableURL = URL(fileURLWithPath:"/usr/bin/git"); task.arguments = ["clone","--progress","--",remote,destination.path]
        var environment = ProcessInfo.processInfo.environment; environment["GIT_TERMINAL_PROMPT"] = "0"; task.environment = environment; task.standardOutput = pipe; task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData; guard !data.isEmpty else { return }; let value = String(decoding:data,as:UTF8.self)
            DispatchQueue.main.async { guard let self else { return }; self.diagnostic = String((self.diagnostic+value).suffix(16_000)); let line = self.diagnostic.split(whereSeparator:{ $0 == "\r" || $0 == "\n" }).last.map(String.init) ?? ""
                self.message.stringValue = Self.safe(line)
                if let range = line.range(of:#"\d+(?=%)"#,options:.regularExpression),let percent = Double(line[range]) { self.progress.isIndeterminate = false; self.progress.maxValue = 100; self.progress.doubleValue = min(100,max(0,percent)) } }
        }
        task.terminationHandler = { [weak self] task in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { guard let self else { return }; self.working = false; self.process = nil; self.progress.stopAnimation(nil); self.address.isEnabled = true; self.folder.isEnabled = true; self.parent.isEnabled = true
                if task.terminationStatus == 0,!self.cancelled { self.closeSheet(); self.onCloned(destination) }
                else { self.message.stringValue = self.cancelled ? L.text("Clone canceled. Choose a new destination or retry.") : Self.safe(self.diagnostic) }
            }
        }
        do { try task.run() } catch { pipe.fileHandleForReading.readabilityHandler = nil; process = nil; working = false; progress.stopAnimation(nil); address.isEnabled = true; folder.isEnabled = true; parent.isEnabled = true; message.stringValue = L.text(error.localizedDescription) }
    }
    @objc func cancelClone() { guard let process,process.isRunning else { return }; cancelled = true; message.stringValue = L.text("Canceling clone…"); process.terminate() }
    static func safe(_ text: String) -> String { text.replacingOccurrences(of:#"(https?://)[^\s/@]+(?::[^\s/@]*)?@"#,with:"$1[redacted]@",options:.regularExpression).replacingOccurrences(of:#"(?i)((?:[?&]|\b)(?:access[_-]?token|password|token|private[_-]?token)=)[^\s&#]+"#,with:"$1[redacted]",options:.regularExpression) }
}
