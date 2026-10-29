import Foundation
import CoreServices

/// Filesystem events carry paths only; source text is indexed by the language server.
public final class LanguageWorkspaceWatch {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label:"top.fuluwa.linvell.language-file-events",qos:.utility)
    public init(root: String,changed: @escaping ([String],[Int]) -> Void) {
        let callbacks = LanguageWatchCallbacks(changed)
        var context = FSEventStreamContext(version:0,info:Unmanaged.passUnretained(callbacks).toOpaque(),retain:{ pointer in
            guard let pointer else { return nil }; _ = Unmanaged<LanguageWatchCallbacks>.fromOpaque(pointer).retain(); return UnsafeRawPointer(pointer)
        },release:{ pointer in
            if let pointer { Unmanaged<LanguageWatchCallbacks>.fromOpaque(pointer).release() }
        },copyDescription:nil)
        stream = FSEventStreamCreate(nil,{ _,info,count,paths,flags,_ in
            guard let info else { return }
            let callbacks = Unmanaged<LanguageWatchCallbacks>.fromOpaque(info).takeUnretainedValue()
            let values = unsafeBitCast(paths,to:NSArray.self) as? [String] ?? []
            let paths = Array(values.prefix(count))
            let types = paths.enumerated().map { index,path -> Int in
                if !FileManager.default.fileExists(atPath:path) { return 3 }
                return flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 ? 1 : 2
            }
            callbacks.changed(paths,types)
        },&context,[root] as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),0.3,FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream { FSEventStreamSetDispatchQueue(stream,queue); if !FSEventStreamStart(stream) { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil } }
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}

private final class LanguageWatchCallbacks {
    let changed: ([String],[Int]) -> Void
    init(_ changed: @escaping ([String],[Int]) -> Void) { self.changed = changed }
}
