import AppKit

extension GitWorkspace {
    func browseExternalApplications() {
        guard let window else { return }
        let defaults = UserDefaults.standard,key = "git.openApplications"
        let saved = defaults.stringArray(forKey:key) ?? []
        let suggested = ["Terminal","iTerm","Xcode","Visual Studio Code","Nova","Sublime Text","Finder"]
            .compactMap { name -> String? in
                let path = "/Applications/"+name+".app"
                if FileManager.default.fileExists(atPath:path) { return path }
                let system = "/System/Applications/"+name+".app"
                if FileManager.default.fileExists(atPath:system) { return system }
                let utility = "/System/Applications/Utilities/"+name+".app"
                return FileManager.default.fileExists(atPath:utility) ? utility : nil
            }
        let applications = saved+suggested.filter { !saved.contains($0) }
        let add = PickerOption(title:L.text("Add Application…"),detail:"") { [weak self] in
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath:"/Applications"); panel.allowsMultipleSelection = true
            panel.beginSheetModal(for:window) { response in
                guard response == .OK else { return }
                var updated = saved
                for url in panel.urls where !updated.contains(url.path) { updated.append(url.path) }
                defaults.set(updated,forKey:key); self?.browseExternalApplications()
            }
        }
        let options = applications.map { path in
            PickerOption(title:URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent,detail:path) { [weak self] in
                guard let self,self.repository.remote == nil else { return }
                NSWorkspace.shared.open([self.repository.root],withApplicationAt:URL(fileURLWithPath:path),configuration:NSWorkspace.OpenConfiguration()) { _,error in
                    if let error { DispatchQueue.main.async { NSAlert(error:error).beginSheetModal(for:window) } }
                }
            }
        }
        gitPicker = QuickPicker(title:L.text("Open in…"),options:[add]+options+[
            PickerOption(title:L.text("Manage Applications…"),detail:"") { [weak self] in
                self?.gitPicker = QuickPicker(title:L.text("Remove Application"),options:saved.map { path in
                    PickerOption(title:URL(fileURLWithPath:path).lastPathComponent,detail:path) {
                        defaults.set(saved.filter { $0 != path },forKey:key)
                    }
                },owner:window)
            }
        ],owner:window)
    }
}
