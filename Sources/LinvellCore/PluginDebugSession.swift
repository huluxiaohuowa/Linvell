import Foundation
import LinvellPluginKit

/// DAP over framed stdio, sharing process ownership with the plugin runtime.
public final class PluginDebugSession {
    public let rpc: LanguageRPC
    public let logs: PluginLogBuffer
    public var event: ((String,[String:Any]) -> Void)?
    private let lock = NSLock()
    private var initialized = false
    private let ready = DispatchSemaphore(value:0)
    public init(runtime: PluginRuntime,debugger: PluginDebugger,logs: PluginLogBuffer) throws {
        self.logs = logs; rpc = try runtime.launch(debugger.program,log:logs.append,dap:true)
        rpc.notification = { [weak self] method,params in
            guard let self else { return }
            if method == "initialized" { self.lock.lock(); self.initialized = true; self.lock.unlock(); self.ready.signal() }
            if method == "output",let output = params["output"] as? String { self.logs.append(output) }
            self.event?(method,params)
        }
    }
    /// The launch response may be deferred until configurationDone, so send it concurrently.
    public func start(_ debugger: PluginDebugger,root: String,breakpoints: [String:[Int]] = [:]) throws {
        _ = try rpc.request("initialize",params:["clientID":"linvell","adapterID":debugger.id,"linesStartAt1":true,"columnsStartAt1":true,"pathFormat":"path","supportsRunInTerminalRequest":false],timeout:10)
        let object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(debugger.launch))
        let params = PluginTools.expand(object,root:root) as? [String:Any] ?? [:]
        let completed = DispatchSemaphore(value:0),resultLock = NSLock()
        var outcome: Result<Any,Error>?
        DispatchQueue.global(qos:.userInitiated).async { [rpc] in
            let value = Result { try rpc.request("launch",params:params,timeout:20) }
            resultLock.lock(); outcome = value; resultLock.unlock(); completed.signal()
        }
        lock.lock(); let isReady = initialized; lock.unlock()
        if !isReady,ready.wait(timeout:.now()+10) == .timedOut { rpc.stop(); throw LanguageServiceError.timeout }
        for (path,lines) in breakpoints { _ = try rpc.request("setBreakpoints",params:["source":["path":path],"breakpoints":lines.map { ["line":$0] }]) }
        _ = try rpc.request("configurationDone",params:[:],timeout:10)
        guard completed.wait(timeout:.now()+20) == .success else { rpc.stop(); throw LanguageServiceError.timeout }
        resultLock.lock(); let result = outcome; resultLock.unlock(); _ = try result?.get()
    }
    public func request(_ command: String,arguments: [String:Any] = [:]) throws -> Any { try rpc.request(command,params:arguments,timeout:10) }
    public func stop() { rpc.closePluginChannel() }
    public func disconnect() { _ = try? rpc.request("disconnect",params:["terminateDebuggee":true],timeout:2); rpc.stop() }
    deinit { stop() }
}
