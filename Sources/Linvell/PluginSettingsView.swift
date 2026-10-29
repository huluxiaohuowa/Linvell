import AppKit
import LinvellCore
import LinvellPluginKit

final class PluginSettingsWindow: PluginOwnedWindow {
    let session: PluginSession
    let scope = NSSegmentedControl(labels:[L.text("User"),L.text("Workspace")],trackingMode:.selectOne,target:nil,action:nil)
    let form = NSStackView(),feedback = NSTextField(wrappingLabelWithString:"")
    private var controls: [String:NSControl] = [:]
    private var snapshot: PluginPersistence.ConfigurationSnapshot?
    private var project: ProjectLanguageSettings?
    private var workspace: PluginWorkspace?
    private var generation = UUID()
    init(owner: WorkspaceController,session: PluginSession) {
        self.session = session; super.init(owner:owner,title:session.package.manifest.name+" — "+L.text("Plugin Settings"))
        scope.selectedSegment = 0; scope.target = self; scope.action = #selector(reloadSettings)
        scope.setEnabled(owner.pluginWorkspace != nil,forSegment:1)
        let save = Theme.actionButton("Save Plugin Settings",target:self,action:#selector(saveSettings))
        let reload = Theme.actionButton("Reload",target:self,action:#selector(reloadSettings))
        let header = Theme.stack([scope,NSView(),reload,save]); header.heightAnchor.constraint(equalToConstant:36).isActive = true
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 16
        let scroll = ResponsiveScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = form
        form.translatesAutoresizingMaskIntoConstraints = false; form.widthAnchor.constraint(equalTo:scroll.widthAnchor,constant:-20).isActive = true
        feedback.font = .systemFont(ofSize:12); feedback.textColor = Theme.secondary
        Theme.pin(Theme.stack([header,scroll,feedback],orientation:.vertical,spacing:16),in:window!.contentView!,inset:20)
        reloadSettings()
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func reloadSettings() {
        let hasWorkspace = workspaceOwner?.pluginWorkspace != nil
        scope.setEnabled(hasWorkspace,forSegment:1); if !hasWorkspace { scope.selectedSegment = 0 }
        let token = UUID(); generation = token; snapshot = nil; project = nil; controls.removeAll(); form.arrangedSubviews.forEach { $0.removeFromSuperview() }
        workspace = workspaceOwner?.pluginWorkspace; let workspace = workspace,isProject = scope.selectedSegment == 1
        feedback.stringValue = L.text("Loading plugin settings…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let environment = try self.session.persistence.environment(package:self.session.package,workspace:isProject ? workspace : nil)
                for field in self.session.package.manifest.settings ?? [] { if let value = environment.configuration[field.key] { try PluginContributions.validateSetting(value,field:field) } }
                let user = try self.session.persistence.configurationSnapshot(package:self.session.package)
                let project = try isProject ? workspace.map { try ProjectLanguageSettings.read(root:$0.root,remote:$0.remote) } : nil
                DispatchQueue.main.async {
                    guard self.generation == token,self.workspaceOwner?.pluginSessions[self.session.package.manifest.id] === self.session else { return }
                    self.snapshot = user; self.project = project; self.render(environment.configuration); self.feedback.stringValue = L.text("Saved files determine the effective configuration.")
                }
            } catch { DispatchQueue.main.async { if self.generation == token { self.feedback.stringValue = L.existing(error.localizedDescription) } } }
        }
    }
    private func render(_ values: [String:PluginValue]) {
        for field in session.package.manifest.settings ?? [] {
            let label = NSTextField(labelWithString:field.title); label.font = .systemFont(ofSize:14,weight:.medium); label.textColor = Theme.foreground
            let control: NSControl
            switch field.kind {
            case .boolean:
                let button = NSButton(checkboxWithTitle:field.title,target:nil,action:nil)
                button.state = values[field.key] == .bool(true) ? .on : .off; control = button
            case .choice:
                let choice = NSPopUpButton(); choice.addItems(withTitles:field.choices ?? []); choice.selectItem(withTitle:values[field.key]?.string ?? ""); control = choice
            case .string,.number:
                let value = values[field.key]
                let text = NSTextField(string:field.kind == .number ? value?.number.map(String.init(describing:)) ?? "0" : value?.string ?? "")
                text.widthAnchor.constraint(greaterThanOrEqualToConstant:260).isActive = true; control = text
            }
            control.setAccessibilityLabel(field.title); controls[field.key] = control
            let description = NSTextField(wrappingLabelWithString:field.description ?? ""); description.font = .systemFont(ofSize:12); description.textColor = Theme.secondary
            let row = Theme.stack([label,control,description],orientation:.vertical,spacing:5); form.addArrangedSubview(row); row.widthAnchor.constraint(equalTo:form.widthAnchor).isActive = true
        }
    }
    @objc func saveSettings() {
        guard let snapshot,workspaceOwner?.pluginSessions[session.package.manifest.id] === session else { return }
        do {
            var values: [String:PluginValue] = [:]
            for field in session.package.manifest.settings ?? [] {
                guard let control = controls[field.key] else { throw PluginError.invalidState }
                let value: PluginValue
                switch field.kind {
                case .boolean: value = .bool((control as! NSButton).state == .on)
                case .choice: value = .string((control as! NSPopUpButton).titleOfSelectedItem ?? "")
                case .string: value = .string((control as! NSTextField).stringValue)
                case .number:
                    guard let number = Double((control as! NSTextField).stringValue),number.isFinite else { throw PluginError.invalidState }; value = .number(number)
                }
                try PluginContributions.validateSetting(value,field:field); values[field.key] = value
            }
            let workspace = workspace,project = project,token = generation,session = session
            guard workspace?.identityKey == workspaceOwner?.pluginWorkspace?.identityKey else { throw PluginError.staleDocument }
            feedback.stringValue = L.text("Saving plugin settings…")
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                do {
                    if let project {
                        var existing = (try JSONCSettings(project.data).values["plugins"] as? [String:Any])?[session.package.manifest.id] as? [String:Any] ?? [:]
                        let object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(values)) as! [String:Any]
                        existing.merge(object,uniquingKeysWith:{ _,new in new }); _ = try project.writePlugin(session.package.manifest.id,configuration:existing)
                    } else { try session.persistence.saveConfiguration(values,package:session.package,expected:snapshot) }
                    DispatchQueue.main.async { if self?.generation == token { self?.reloadSettings() } }
                } catch { DispatchQueue.main.async { if self?.generation == token { self?.feedback.stringValue = L.existing(error.localizedDescription) } } }
            }
        } catch { feedback.stringValue = L.existing(error.localizedDescription) }
    }
}
