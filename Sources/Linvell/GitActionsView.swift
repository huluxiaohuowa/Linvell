import AppKit
import SwiftTerm
import LinvellCore
import Darwin

/// Native forms share Git's argv interface locally and over SSH. Interactive
/// operations use a PTY rather than pretending that every Git workflow is batchable.
final class GitActionsView: NSView, NSTextFieldDelegate, LocalProcessTerminalViewDelegate {
    let repository: GitRepository
    let operations = Theme.choiceButton(),parameters = NSStackView(),argv = NSTextField()
    let output = NSTextView(),status = Theme.label("",size:12,color:Theme.secondary)
    let resultHost = NSView()
    var fields: [(String,NSTextField)] = []
    var pathHint: String?
    var terminal: DisplayPacedTerminalView?
    var onChange: (() -> Void)?
    var onBusyChange: ((Bool) -> Void)?
    private(set) var busy = false
    private var runButton: NSButton!
    var running: Bool { busy || terminal?.process.running == true }
    init(repository: GitRepository) {
        self.repository = repository; super.init(frame:.zero)
        operations.addItems(withTitles:GitOperation.all.map { L.text($0.title) }+[L.text("Custom Git Arguments")])
        operations.target = self; operations.action = #selector(operationChanged)
        parameters.orientation = .vertical; parameters.alignment = .leading; parameters.spacing = 8
        argv.font = .monospacedSystemFont(ofSize:12,weight:.regular); argv.placeholderString = "[\"status\", \"--short\"]"
        argv.usesSingleLineMode = true; argv.cell?.isScrollable = true
        argv.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        argv.setAccessibilityLabel(L.text("Git argument array"))
        runButton = Theme.actionButton("Execute",target:self,action:#selector(execute))
        let console = Theme.actionButton("Interactive Git Console",target:self,action:#selector(startConsole))
        let stop = Theme.actionButton("Stop Console",target:self,action:#selector(stopConsole))
        output.isEditable = false; output.isRichText = false; output.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        output.backgroundColor = Theme.canvas; output.textColor = Theme.foreground; output.textContainerInset = NSSize(width:12,height:12)
        output.isVerticallyResizable = true; output.autoresizingMask = .width; output.usesFindBar = true
        let scroll = ResponsiveScrollView(); scroll.documentView = output; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        Theme.pin(scroll,in:resultHost)
        let help = NSTextField(wrappingLabelWithString:L.text("Choose an operation and fill its fields. Advanced arguments are a JSON array, without shell expansion. Interactive rebase, patch selection and every other Git command are available in the console on this repository’s host."))
        help.font = .systemFont(ofSize:12); help.textColor = Theme.secondary
        Theme.pin(Theme.stack([operations,parameters,Theme.label("Git argument array",size:12),argv,Theme.stack([runButton,console,stop,NSView()]),help,status,resultHost],orientation:.vertical,spacing:10),in:self)
        operationChanged()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { terminate() }
    func refreshTheme() {
        output.backgroundColor = Theme.canvas; output.textColor = Theme.foreground
        terminal?.nativeBackgroundColor = Theme.canvas; terminal?.nativeForegroundColor = Theme.foreground
    }
    func selectOperation(_ title: String,path: String? = nil) {
        pathHint = path
        if let index = GitOperation.all.firstIndex(where:{ $0.title == title }) { operations.selectItem(at:index); operationChanged() }
        if let path,let field = fields.first(where:{ $0.0 == "Path" })?.1 { field.stringValue = path; updateArguments() }
    }
    @objc func operationChanged() {
        parameters.arrangedSubviews.forEach { $0.removeFromSuperview() }; fields.removeAll()
        guard GitOperation.all.indices.contains(operations.indexOfSelectedItem) else { argv.stringValue = "[\"status\", \"--short\"]"; return }
        for (name,value) in GitOperation.all[operations.indexOfSelectedItem].fields {
            let field = NSTextField(); field.stringValue = name == "Path" ? pathHint ?? value : value; field.delegate = self
            field.usesSingleLineMode = true; field.cell?.isScrollable = true
            field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
            field.setAccessibilityLabel(L.text(name)); fields.append((name,field))
            let row = Theme.stack([Theme.label(name,size:12),field],spacing:10)
            parameters.addArrangedSubview(row); row.widthAnchor.constraint(equalTo:parameters.widthAnchor).isActive = true
        }
        updateArguments()
    }
    func controlTextDidChange(_ notification: Notification) { updateArguments() }
    private func updateArguments() {
        guard GitOperation.all.indices.contains(operations.indexOfSelectedItem) else { return }
        let values = Dictionary(uniqueKeysWithValues:fields.map { ($0.0,$0.1.stringValue) })
        let arguments = try? GitOperation.all[operations.indexOfSelectedItem].arguments(values)
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        argv.stringValue = arguments.flatMap { try? encoder.encode($0) }.flatMap { String(data:$0,encoding:.utf8) } ?? ""
    }
    @objc func execute() {
        guard !busy,terminal?.process.running != true else { status.stringValue = L.text("Finish the current Git operation first."); return }
        do {
            let arguments = try GitOperation.customArguments(argv.stringValue)
            let selected = operations.indexOfSelectedItem
            let operation = GitOperation.all.indices.contains(selected) ? GitOperation.all[selected] : nil
            let expected = try? operation?.arguments(Dictionary(uniqueKeysWithValues:fields.map { ($0.0,$0.1.stringValue) }))
            if operation?.writes != false || expected != arguments {
                guard let window else { return }
                let alert = NSAlert(); alert.messageText = L.text("Execute Git operation?")
                alert.informativeText = repository.directory+"\n\ngit "+arguments.map(SSHRemote.quote).joined(separator:" ")+"\n\n"+L.text("This can change files, repository history or remotes. Review the exact arguments before continuing.")
                alert.addButton(withTitle:L.text("Execute")); alert.addButton(withTitle:L.text("Cancel"))
                alert.beginSheetModal(for:window) { [weak self] response in if response == .alertFirstButtonReturn { self?.perform(arguments) } }
            } else { perform(arguments) }
        } catch { status.stringValue = error.localizedDescription }
    }
    func perform(_ arguments: [String]) {
        guard !running else { return }
        terminal?.removeFromSuperview(); terminal = nil
        busy = true; onBusyChange?(true); runButton.isEnabled = false; status.stringValue = L.text("Running Git…")
        let repo = repository
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { String(try repo.run(arguments,timeout:600).suffix(512*1024)) }
            DispatchQueue.main.async {
                guard let self else { return }; self.busy = false; self.onBusyChange?(false); self.runButton.isEnabled = true
                switch result {
                case .success(let text): self.output.string = text; self.status.stringValue = L.text("Git operation completed."); self.onChange?()
                case .failure(let error): self.output.string = String(error.localizedDescription.suffix(512*1024)); self.status.stringValue = L.text("Git operation failed. Review the output.")
                }
            }
        }
    }
    @objc func startConsole() {
        guard !busy else { return }
        if terminal?.process.running == true { window?.makeFirstResponder(terminal); return }
        let term = DisplayPacedTerminalView(frame:resultHost.bounds); terminal?.removeFromSuperview(); terminal = term
        term.processDelegate = self; term.font = Theme.editorFont; term.nativeBackgroundColor = Theme.canvas; term.nativeForegroundColor = Theme.foreground; term.caretColor = Theme.accent
        Theme.pin(term,in:resultHost)
        var environment = ProcessInfo.processInfo.environment; environment["TERM"] = "xterm-256color"; environment["COLORTERM"] = "truecolor"
        let executable: String,args: [String]
        if let remote = repository.remote {
            executable = "/usr/bin/ssh"
            args = ["-tt","--",remote.host,RunTasks.remoteCommand(directory:repository.directory,command:"exec \"${SHELL:-/bin/sh}\" -il")]
        } else { executable = environment["SHELL"] ?? "/bin/zsh"; args = ["-il"] }
        term.startProcess(executable:executable,args:args,environment:environment.map { "\($0.key)=\($0.value)" },currentDirectory:repository.remote == nil ? repository.directory : NSHomeDirectory())
        onBusyChange?(true)
        status.stringValue = L.text("Interactive Git Console")+" · "+repository.directory
        window?.makeFirstResponder(term)
    }
    @objc func stopConsole() { terminate(); onBusyChange?(false); onChange?() }
    func terminate() {
        guard let terminal,terminal.process.running else { return }
        let pid = terminal.process.shellPid
        if pid > 0,getpgid(pid) == pid,pid != getpgrp() { kill(-pid,SIGHUP) }
        terminal.terminate()
    }
    func sizeChanged(source: LocalProcessTerminalView,newCols: Int,newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView,title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView,directory: String?) {}
    func processTerminated(source: TerminalView,exitCode: Int32?) { status.stringValue = L.format("Exited with status %d",Int(exitCode ?? -1)); onBusyChange?(false); onChange?() }
}
