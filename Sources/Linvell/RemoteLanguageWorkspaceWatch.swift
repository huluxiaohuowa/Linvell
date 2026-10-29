import Foundation
import LinvellCore

/// Only metadata crosses SSH. Scans run outside the UI and language-request queues.
final class RemoteLanguageWorkspaceWatch {
    private let timer: DispatchSourceTimer
    private var states: [String:String]?
    private var digest: String?
    init(remote: SSHRemote,root: String,changed: @escaping ([String],[Int]) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue:DispatchQueue(label:"top.fuluwa.linvell.remote-source-watch",qos:.utility))
        self.timer = timer
        timer.schedule(deadline:.now(),repeating:15,leeway:.seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                let reply = try remote.request("language-file-states",path:root,digest:self.digest)
                guard let current = reply.fileStates else { return }
                if let previous = self.states {
                    let events = Self.changes(previous:previous,current:current)
                    if !events.0.isEmpty { changed(events.0,events.1) }
                }
                self.states = current; self.digest = reply.digest
            } catch { /* Keep the prior snapshot across transient network failures. */ }
        }
        timer.resume()
    }
    static func changes(previous: [String:String],current: [String:String]) -> ([String],[Int]) {
        var paths: [String] = [],types: [Int] = []
        for path in current.keys.sorted() where previous[path] != current[path] { paths.append(path); types.append(previous[path] == nil ? 1 : 2) }
        for path in previous.keys.sorted() where current[path] == nil { paths.append(path); types.append(3) }
        return (paths,types)
    }
    deinit { timer.cancel() }
}
