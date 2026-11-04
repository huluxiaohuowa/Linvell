import AppKit
import UniformTypeIdentifiers

/// Launch Services discovery and favorites adapted from FoldGit OpenInStore (dufu, MIT).
struct GitExternalApplication {
    let id: String,path: String,name: String
    static func read(_ url: URL) -> Self? {
        guard url.pathExtension.lowercased() == "app",let bundle = Bundle(url:url),bundle.infoDictionary?["CFBundleExecutable"] is String,bundle.infoDictionary?["LSBackgroundOnly"] as? Bool != true,bundle.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return Self(id:bundle.bundleIdentifier ?? url.standardizedFileURL.path,path:url.standardizedFileURL.path,name:bundle.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey:"CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent)
    }
    static func discover(directory: URL,defaults: UserDefaults = .standard) -> [Self] {
        let workspace = NSWorkspace.shared
        let custom = (defaults.stringArray(forKey:"git.openApplications") ?? []).map { URL(fileURLWithPath:$0) }
        let urls = workspace.urlsForApplications(toOpen:directory)+workspace.urlsForApplications(toOpen:UTType.folder)+workspace.urlsForApplications(toOpen:UTType.directory)+custom
        var seen: Set<String> = []
        return urls.compactMap { url -> Self? in
            guard let app = read(url),seen.insert(app.id).inserted else { return nil }
            return workspace.urlForApplication(withBundleIdentifier:app.id).flatMap(read) ?? app
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private enum GitApplicationOpening { static var opening = false }

extension GitWorkspace {
    func browseExternalApplications() {
        guard let window else { return }
        guard repository.remote == nil else { let alert = GitNativeSheet.alert(owner:window); alert.messageText = L.text("External applications require a local checkout."); alert.beginSheetModal(for:window); return }
        let defaults = UserDefaults.standard,saved = defaults.stringArray(forKey:"git.openApplications") ?? [],pinned = defaults.stringArray(forKey:"git.openApplicationPins") ?? [],recent = defaults.stringArray(forKey:"git.openApplicationRecents") ?? []
        let applications = GitExternalApplication.discover(directory:repository.root)
        let ordered = (pinned+recent).compactMap { id in applications.first { $0.id == id } }
        var seen: Set<String> = []
        let all = (ordered+applications).filter { seen.insert($0.id).inserted }
        let add = PickerOption(title:L.text("Add Application…"),detail:"") { [weak self] in
            let panel = NSOpenPanel(); panel.appearance = window.effectiveAppearance; panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath:"/Applications"); panel.allowsMultipleSelection = true
            panel.beginSheetModal(for:window) { response in
                guard response == .OK else { return }; var updated = saved
                for url in panel.urls where GitExternalApplication.read(url) != nil && !updated.contains(url.path) { updated.append(url.path) }
                defaults.set(updated,forKey:"git.openApplications"); self?.browseExternalApplications()
            }
        }
        let options = all.map { app in
            PickerOption(title:(pinned.contains(app.id) ? "★ " : "")+app.name,detail:app.path) { [weak self] in
                guard let self,!GitApplicationOpening.opening else { return }; GitApplicationOpening.opening = true
                NSWorkspace.shared.open([self.repository.root],withApplicationAt:URL(fileURLWithPath:app.path),configuration:NSWorkspace.OpenConfiguration()) { _,error in
                    DispatchQueue.main.async {
                        GitApplicationOpening.opening = false
                        if let error { let alert = NSAlert(error:error); alert.window.appearance = window.effectiveAppearance; alert.beginSheetModal(for:window) }
                        else { var recents = defaults.stringArray(forKey:"git.openApplicationRecents") ?? []; recents.removeAll { $0 == app.id }; recents.insert(app.id,at:0); defaults.set(Array(recents.prefix(6)),forKey:"git.openApplicationRecents") }
                    }
                }
            }
        }
        gitPicker = QuickPicker(title:L.text("Open in…"),options:[add]+options+[
            PickerOption(title:L.text("Refresh Applications"),detail:"") { [weak self] in self?.browseExternalApplications() },
            PickerOption(title:L.text("Manage Applications…"),detail:"") { [weak self] in
                guard let self else { return }
                self.gitPicker = QuickPicker(title:L.text("Manage Applications…"),options:applications.map { app in
                    PickerOption(title:(pinned.contains(app.id) ? L.text("Unpin") : L.text("Pin"))+" · "+app.name,detail:app.path) {
                        var pins = defaults.stringArray(forKey:"git.openApplicationPins") ?? []; pins.removeAll { $0 == app.id }; if !pinned.contains(app.id) { pins.append(app.id) }; defaults.set(pins,forKey:"git.openApplicationPins")
                    }
                }+saved.map { path in PickerOption(title:L.text("Remove")+" · "+URL(fileURLWithPath:path).lastPathComponent,detail:path) { defaults.set(saved.filter { $0 != path },forKey:"git.openApplications") } },owner:window)
            }
        ],owner:window)
    }
}
