import Foundation

/// Cancels both a queued native action and its outstanding JSON-RPC request.
public final class LanguageRequestCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID:() -> Void] = [:]
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() {
        lock.lock(); cancelled = true; let callbacks = Array(handlers.values); handlers.removeAll(); lock.unlock()
        callbacks.forEach { $0() }
    }
    func register(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID(); lock.lock(); let invoke = cancelled
        if !invoke { handlers[id] = handler }; lock.unlock()
        if invoke { handler() }; return id
    }
    func unregister(_ id: UUID) { lock.lock(); handlers.removeValue(forKey:id); lock.unlock() }
}

public enum LanguageDocumentChange {
    /// One minimal UTF-16 replacement, matching negotiated LSP incremental sync.
    public static func between(_ old: String,_ new: String) -> [String:Any]? {
        guard old != new else { return nil }
        let a = old as NSString,b = new as NSString
        var prefix = 0,endA = a.length,endB = b.length
        while prefix < min(endA,endB),a.character(at:prefix) == b.character(at:prefix) { prefix += 1 }
        if prefix > 0,prefix < a.length,(0xDC00...0xDFFF).contains(a.character(at:prefix)) { prefix -= 1 }
        while endA > prefix,endB > prefix,a.character(at:endA-1) == b.character(at:endB-1) { endA -= 1; endB -= 1 }
        if endA < a.length,(0xDC00...0xDFFF).contains(a.character(at:endA)) { endA += 1; endB += 1 }
        return ["range":["start":CodePosition(offset:prefix,in:old).json,"end":CodePosition(offset:endA,in:old).json],"text":b.substring(with:NSRange(location:prefix,length:endB-prefix))]
    }
}
