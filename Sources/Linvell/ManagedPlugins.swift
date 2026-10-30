import AppKit
import LinvellCore

extension WorkspaceController {
    @objc func showPluginManager() {
        let manager = (pluginWindows["manager"] as? PluginManagerWindow) ?? PluginManagerWindow(owner:self)
        pluginWindows["manager"] = manager;manager.refresh();manager.showWindow(nil);manager.window?.makeKeyAndOrderFront(nil)
    }
    @objc func managedPluginsChanged(_ notification: Notification) { syncManagedPlugins(reloadID:notification.object as? String) }
    @objc func pauseManagedPlugin(_ notification: Notification) { if let id = notification.object as? String { stopPlugin(id) } }
    func syncManagedPlugins(reloadID: String? = nil) {
        guard managedPluginAutoload,window?.isVisible == true else { return }
        if remoteConnection != nil && !remoteDirectory.hasPrefix("/") { return }
        let request = UUID(),store = installedPluginStore;managedPluginLoad = request
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { () -> (PluginRegistry,[String:PluginPackage],[String]) in
                let registry = try store.registry()
                var packages: [String:PluginPackage] = [:]
                var errors: [String] = []
                for record in registry.installed where record.enabled { do { packages[record.id] = try store.package(record) } catch { errors.append(record.name+": "+error.localizedDescription) } }
                return (registry,packages,errors)
            }
            DispatchQueue.main.async {
                guard let self,self.managedPluginLoad == request else { return }
                do {
                    let (registry,packages,errors) = try result.get(),enabled = Set(registry.installed.filter(\.enabled).map(\.id))
                    for id in self.managedPluginIDs where !enabled.contains(id) || reloadID == id { self.stopPlugin(id) }
                    for record in registry.installed where record.enabled {
                        guard let package = packages[record.id] else { continue }
                        if let session = self.pluginSessions[record.id] {
                            if session.package.directory == package.directory { continue }
                            if !self.managedPluginIDs.contains(record.id) && reloadID != record.id { continue }
                        }
                        do { try self.installPlugin(package) } catch { self.status.stringValue = L.existing(error.localizedDescription) }
                    }
                    self.managedPluginIDs = Set(registry.installed.map(\.id))
                    self.applyManagedResources(registry)
                    if !errors.isEmpty { self.status.stringValue = errors.joined(separator:"; ") }
                    NotificationCenter.default.post(name:PluginMenus.changed,object:self)
                } catch { self.status.stringValue = L.existing(error.localizedDescription) }
            }
        }
    }
    func stopPlugin(_ id: String) {
        guard let session = pluginSessions.removeValue(forKey:id) else { return };session.stop();clearPluginUI(session);PluginMenus.refresh()
    }
    func applyManagedResources(_ registry: PluginRegistry) {
        if let id = registry.themePlugin,let theme = registry.themeID,let session = pluginSessions[id],!session.isStopped,let value = session.package.manifest.themes?.first(where:{ $0.id == theme }),Theme.pluginTheme?.0 != session.sessionID {
            Theme.pluginTheme = (session.sessionID,value);NotificationCenter.default.post(name:PreferencesSync.didApply,object:nil)
        }
        if let id = registry.iconPlugin,let session = pluginSessions[id],!session.isStopped,FileIcon.pluginIcons?.0 != session.sessionID { selectPluginIcons(session,persist:false) }
    }
    func saveManagedTheme(_ id: String?,session: PluginSession) {
        guard managedPluginIDs.contains(session.package.manifest.id) else { return }
        let store = installedPluginStore
        DispatchQueue.global(qos:.utility).async { try? store.selectTheme(plugin:session.package.manifest.id,id:id) }
    }
}
