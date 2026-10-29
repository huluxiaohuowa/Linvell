import Foundation
import Darwin

public struct CodePosition: Codable, Equatable {
    public let line: Int
    public let character: Int
    public init(line: Int,character: Int) { self.line = line; self.character = character }
    public init(offset: Int,in text: String) {
        let index = LineIndex(text),row = index.line(at:offset)
        line = row; character = offset-index.starts[row]
    }
    public func offset(in text: String,index: LineIndex? = nil) throws -> Int {
        let ns = text as NSString,index = index ?? LineIndex(text)
        guard line >= 0,line < index.starts.count,character >= 0 else { throw DocumentError.invalidRange }
        let start = index.starts[line],end = line+1 < index.starts.count ? index.starts[line+1]-1 : ns.length
        guard character <= end-start else { throw DocumentError.invalidRange }
        let result = start+character
        if result > 0,result < ns.length {
            let unit = ns.character(at:result),previous = ns.character(at:result-1)
            if (0xDC00...0xDFFF).contains(unit),(0xD800...0xDBFF).contains(previous) { throw DocumentError.invalidRange }
        }
        return result
    }
    public var json: [String:Any] { ["line":line,"character":character] }
}
public struct CodeRange: Codable, Equatable {
    public let start: CodePosition
    public let end: CodePosition
    public func range(in text: String,index: LineIndex? = nil) throws -> NSRange {
        let index = index ?? LineIndex(text)
        let lower = try start.offset(in:text,index:index),upper = try end.offset(in:text,index:index)
        guard upper >= lower else { throw DocumentError.invalidRange }
        return NSRange(location:lower,length:upper-lower)
    }
}
public struct CodeTextEdit: Decodable {
    public let range: CodeRange
    public let newText: String
    public static func applying(_ edits: [CodeTextEdit],to text: String) throws -> String {
        let index = LineIndex(text)
        let ordered = try edits.map { (try $0.range.range(in:text,index:index),$0.newText) }.sorted { $0.0.location < $1.0.location }
        for pair in zip(ordered,ordered.dropFirst()) where NSMaxRange(pair.0.0) > pair.1.0.location || pair.0.0.location == pair.1.0.location { throw DocumentError.invalidRange }
        let result = NSMutableString(string:text)
        for (range,value) in ordered.reversed() { result.replaceCharacters(in:range,with:value) }
        return result as String
    }
}
public struct CodeDiagnostic: Decodable {
    public let range: CodeRange
    public let message: String
    public let severity: Int?
}
public struct CodeLocation: Decodable {
    public let uri: String
    public let range: CodeRange
    public static func locations(_ value: Any) throws -> [CodeLocation] {
        guard !(value is NSNull) else { return [] }
        let values = (value as? [[String:Any]]) ?? (value as? [String:Any]).map { [$0] } ?? []
        return try values.map { raw in
            if let uri = raw["targetUri"],let range = raw["targetSelectionRange"] ?? raw["targetRange"] {
                return try JSONDecoder().decode(Self.self,from:JSONSerialization.data(withJSONObject:["uri":uri,"range":range]))
            }
            return try JSONDecoder().decode(Self.self,from:JSONSerialization.data(withJSONObject:raw))
        }
    }
}
public enum LanguageToolStorage: String, Codable { case project,user }
public struct LanguageToolchain: Codable, Equatable {
    public var runtime = ""
    public var server = ""
    public var arguments: [String] = []
    public var enabled = true
    public var storage: LanguageToolStorage = .project
    public var addGitIgnore = true
    public init() {}
    private enum CodingKeys: String,CodingKey { case runtime,server,arguments,enabled,storage,addGitIgnore }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        runtime = try c.decodeIfPresent(String.self,forKey:.runtime) ?? ""; server = try c.decodeIfPresent(String.self,forKey:.server) ?? ""
        arguments = try c.decodeIfPresent([String].self,forKey:.arguments) ?? []; enabled = try c.decodeIfPresent(Bool.self,forKey:.enabled) ?? true
        storage = try c.decodeIfPresent(LanguageToolStorage.self,forKey:.storage) ?? .project; addGitIgnore = try c.decodeIfPresent(Bool.self,forKey:.addGitIgnore) ?? true
    }
}
public struct CodeLanguage: Equatable {
    public let id: String,title: String,extensions: [String],runtimes: [String],servers: [String],arguments: [String]
    public static let supported: [CodeLanguage] = [
        .init(id:"swift",title:"Swift",extensions:["swift"],runtimes:["swift"],servers:["sourcekit-lsp"],arguments:[]),
        .init(id:"python",title:"Python",extensions:["py","pyi","pyw"],runtimes:["python3","python"],servers:["pyright-langserver","basedpyright-langserver","pylsp"],arguments:["--stdio"]),
        .init(id:"javascript",title:"JavaScript",extensions:["js","jsx","mjs","cjs"],runtimes:["node"],servers:["typescript-language-server"],arguments:["--stdio"]),
        .init(id:"typescript",title:"TypeScript",extensions:["ts","tsx"],runtimes:["node"],servers:["typescript-language-server"],arguments:["--stdio"]),
        .init(id:"cpp",title:"C++",extensions:["cc","cpp","cxx","hpp","hh","hxx"],runtimes:["clang++","g++"],servers:["clangd"],arguments:[]),
        .init(id:"objective-c",title:"Objective-C",extensions:["m","mm"],runtimes:["clang"],servers:["clangd"],arguments:[]),
        .init(id:"c",title:"C",extensions:["c","h"],runtimes:["clang","gcc"],servers:["clangd"],arguments:[]),
        .init(id:"go",title:"Go",extensions:["go"],runtimes:["go"],servers:["gopls"],arguments:[]),
        .init(id:"rust",title:"Rust",extensions:["rs"],runtimes:["rustc"],servers:["rust-analyzer"],arguments:[]),
        .init(id:"java",title:"Java",extensions:["java"],runtimes:["java"],servers:["jdtls"],arguments:[]),
        .init(id:"csharp",title:"C#",extensions:["cs"],runtimes:["dotnet"],servers:["csharp-ls"],arguments:[]),
        .init(id:"ruby",title:"Ruby",extensions:["rb","rake"],runtimes:["ruby"],servers:["ruby-lsp"],arguments:[]),
        .init(id:"php",title:"PHP",extensions:["php"],runtimes:["php"],servers:["phpactor"],arguments:["language-server"]),
        .init(id:"shellscript",title:"Shell",extensions:["sh","bash","zsh"],runtimes:["bash","zsh"],servers:["bash-language-server"],arguments:["start"]),
        .init(id:"lua",title:"Lua",extensions:["lua"],runtimes:["lua","luajit"],servers:["lua-language-server"],arguments:[]),
        .init(id:"r",title:"R",extensions:["r","R"],runtimes:["R"],servers:["R"],arguments:["--slave","-e","languageserver::run()"]),
        .init(id:"verilog",title:"Verilog / SystemVerilog",extensions:["v","vh","sv","svh"],runtimes:["iverilog","verilator"],servers:["verible-verilog-ls"],arguments:[]),
        .init(id:"vhdl",title:"VHDL",extensions:["vhd","vhdl"],runtimes:["ghdl"],servers:["vhdl_ls"],arguments:[]),
        .init(id:"dart",title:"Dart",extensions:["dart"],runtimes:["dart"],servers:["dart"],arguments:["language-server","--protocol=lsp"]),
        .init(id:"html",title:"HTML",extensions:["html","htm"],runtimes:["node"],servers:["vscode-html-language-server"],arguments:["--stdio"]),
        .init(id:"css",title:"CSS / SCSS / Less",extensions:["css","scss","less"],runtimes:["node"],servers:["vscode-css-language-server"],arguments:["--stdio"]),
        .init(id:"json",title:"JSON",extensions:["json","jsonc"],runtimes:["node"],servers:["vscode-json-language-server"],arguments:["--stdio"])
    ]
    public static func custom(id: String) -> CodeLanguage { .init(id:id,title:id,extensions:[],runtimes:[],servers:[],arguments:[]) }
    public static func forPath(_ path: String) -> CodeLanguage? { supported.first { $0.extensions.contains(URL(fileURLWithPath:path).pathExtension.lowercased()) } }
    public func documentID(path: String) -> String {
        let ext = URL(fileURLWithPath:path).pathExtension
        if id == "typescript" { return ext == "tsx" ? "typescriptreact" : id }
        if id == "javascript" { return ext == "jsx" ? "javascriptreact" : id }
        if id == "objective-c" { return ext == "mm" ? "objective-cpp" : id }
        if id == "verilog" { return ["sv","svh"].contains(ext) ? "systemverilog" : id }
        if id == "c" { return ["m":"objective-c","mm":"objective-cpp","cpp":"cpp","cc":"cpp","cxx":"cpp","hpp":"cpp"][ext] ?? id }
        return ["scss","less","jsonc"].contains(ext) ? ext : id
    }
}

public enum LanguageServiceError: LocalizedError {
    case message(String), timeout, stopped, invalidFrame
    public var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .timeout: return "The language service did not respond in time."
        case .stopped: return "The language service stopped. Check the selected toolchain."
        case .invalidFrame: return "The language service sent an invalid response."
        }
    }
}

/// Incremental byte framing: headers and JSON can arrive in separate reads or multiple messages per read.
public struct LSPFrames {
    private var bytes = Data()
    public init() {}
    public static func encode(_ object: [String:Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject:object)
        var result = Data("Content-Length: \(body.count)\r\n\r\n".utf8); result.append(body); return result
    }
    public mutating func append(_ data: Data) throws -> [[String:Any]] {
        bytes.append(data); var result: [[String:Any]] = []
        while true {
            guard let end = bytes.range(of:Data("\r\n\r\n".utf8)) else { if bytes.count > 8192 { throw LanguageServiceError.invalidFrame }; break }
            guard let header = String(data:bytes[..<end.lowerBound],encoding:.utf8),
                  let lengthLine = header.components(separatedBy:"\r\n").first(where:{ $0.lowercased().hasPrefix("content-length:") }),
                  let length = Int(lengthLine.split(separator:":",maxSplits:1,omittingEmptySubsequences:false)[1].trimmingCharacters(in:.whitespaces)),length > 0,length <= 32*1024*1024 else { throw LanguageServiceError.invalidFrame }
            let start = end.upperBound
            guard bytes.count-start >= length else { break }
            guard let value = try JSONSerialization.jsonObject(with:bytes[start..<start+length]) as? [String:Any] else { throw LanguageServiceError.invalidFrame }
            result.append(value); bytes = Data(bytes.dropFirst(start+length))
        }
        return result
    }
}

public final class LanguageRPC {
    private let process = Process(),input = Pipe(),output = Pipe()
    private let reader = DispatchQueue(label:"top.fuluwa.linvell.lsp.read",qos:.userInitiated)
    private let writer = DispatchQueue(label:"top.fuluwa.linvell.lsp.write",qos:.userInitiated)
    private let lock = NSLock()
    private var nextID = 0,pending: [Int:(Result<Any,Error>) -> Void] = [:]
    private var stopped = false,frames = LSPFrames()
    private var onNotification: ((String,[String:Any]) -> Void)?
    private var settings: [String:Any] = [:]
    public var notification: ((String,[String:Any]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return onNotification }
        set { lock.lock(); onNotification = newValue; lock.unlock() }
    }
    public var configuration: [String:Any] {
        get { lock.lock(); defer { lock.unlock() }; return settings }
        set { lock.lock(); settings = newValue; lock.unlock() }
    }
    public init(executable: URL,arguments: [String],directory: URL?,environment: [String:String]? = nil) throws {
        _ = fcntl(input.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1)
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
        process.environment = environment; process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard let self else { return }
            self.reader.async { [weak self] in
                guard let self else { return }
                if bytes.isEmpty { self.finish(); return }
                do { for value in try self.frames.append(bytes) { self.receive(value) } } catch { self.finish() }
            }
        }
        process.terminationHandler = { [weak self] _ in self?.finish() }
        do { try process.run() } catch { output.fileHandleForReading.readabilityHandler = nil; throw error }
    }
    deinit { stop() }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !stopped && process.isRunning }
    private func send(_ object: [String:Any]) {
        writer.async { [weak self] in
            guard let self,self.isRunning else { return }
            do { try self.input.fileHandleForWriting.write(contentsOf:LSPFrames.encode(object)) } catch { self.finish() }
        }
    }
    public func notify(_ method: String,params: [String:Any]) { send(["jsonrpc":"2.0","method":method,"params":params]) }
    public func request(_ method: String,params: [String:Any],timeout: TimeInterval = 12) throws -> Any {
        let signal = DispatchSemaphore(value:0),resultLock = NSLock()
        var outcome: Result<Any,Error>?
        lock.lock()
        guard !stopped else { lock.unlock(); throw LanguageServiceError.stopped }
        nextID += 1; let id = nextID
        pending[id] = { result in resultLock.lock(); outcome = result; resultLock.unlock(); signal.signal() }
        lock.unlock(); send(["jsonrpc":"2.0","id":id,"method":method,"params":params])
        if signal.wait(timeout:.now()+timeout) == .timedOut {
            lock.lock(); pending.removeValue(forKey:id); lock.unlock()
            notify("$/cancelRequest",params:["id":id]); throw LanguageServiceError.timeout
        }
        resultLock.lock(); defer { resultLock.unlock() }
        return try (outcome ?? .failure(LanguageServiceError.stopped)).get()
    }
    private func receive(_ object: [String:Any]) {
        if let method = object["method"] as? String {
            let params = object["params"] as? [String:Any] ?? [:]
            if let id = object["id"] {
                let result: Any
                switch method {
                case "workspace/configuration": result = (params["items"] as? [[String:Any]] ?? []).map { item -> Any in
                    guard let section = item["section"] as? String else { return configuration }
                    return section.split(separator:".").reduce(configuration as Any) { ($0 as? [String:Any])?[String($1)] ?? NSNull() }
                }
                case "workspace/applyEdit": result = ["applied":false,"failureReason":"Use an explicit editor refactor command."]
                case "client/registerCapability","window/workDoneProgress/create": result = NSNull()
                default: result = NSNull()
                }
                send(["jsonrpc":"2.0","id":id,"result":result])
            } else { notification?(method,params) }
            return
        }
        guard let id = object["id"] as? Int else { return }
        lock.lock(); let callback = pending.removeValue(forKey:id); lock.unlock()
        if let error = object["error"] as? [String:Any] { callback?(.failure(LanguageServiceError.message(error["message"] as? String ?? "Language request failed."))) }
        else { callback?(.success(object["result"] ?? NSNull())) }
    }
    private func finish() {
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true
        let callbacks = Array(pending.values); pending.removeAll(); lock.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        callbacks.forEach { $0(.failure(LanguageServiceError.stopped)) }
    }
    public func stop() {
        finish()
        let handle = input.fileHandleForWriting,process = process
        writer.async {
            if let exit = try? LSPFrames.encode(["jsonrpc":"2.0","method":"exit","params":[:]]) { try? handle.write(contentsOf:exit) }
            try? handle.close()
            if process.isRunning { process.terminate() }
        }
    }
}

public final class LanguageSession {
    public let rpc: LanguageRPC
    public private(set) var capabilities: [String:Any] = [:]
    private var versions: [String:Int] = [:]
    public var openDocumentCount: Int { versions.count }
    public init(rpc: LanguageRPC,root: String,runtime: String) throws {
        self.rpc = rpc
        rpc.configuration = ["python":["pythonPath":runtime,"analysis":["autoSearchPaths":true,"useLibraryCodeForTypes":true]],"pylsp":["plugins":["jedi":["environment":runtime.isEmpty ? NSNull() : runtime as Any]]]]
        let result = try rpc.request("initialize",params:["processId":NSNull(),"rootUri":URL(fileURLWithPath:root).absoluteString,"workspaceFolders":[["uri":URL(fileURLWithPath:root).absoluteString,"name":URL(fileURLWithPath:root).lastPathComponent]],"clientInfo":["name":"Linvell"],"capabilities":["general":["positionEncodings":["utf-16"]],"workspace":["configuration":true,"workspaceFolders":true,"workspaceEdit":["documentChanges":true,"resourceOperations":[]]],"textDocument":["hover":["contentFormat":["plaintext","markdown"]],"completion":["completionItem":["snippetSupport":false]],"rename":["prepareSupport":true],"publishDiagnostics":["versionSupport":true]]],"initializationOptions":["pythonPath":runtime]],timeout:30) as? [String:Any] ?? [:]
        capabilities = result["capabilities"] as? [String:Any] ?? [:]
        if let encoding = capabilities["positionEncoding"] as? String,encoding != "utf-16" { rpc.stop(); throw LanguageServiceError.message("The language server must support UTF-16 positions.") }
        rpc.notify("initialized",params:[:]); rpc.notify("workspace/didChangeConfiguration",params:["settings":rpc.configuration])
    }
    public func synchronize(uri: String,language: String,text: String,version: Int) {
        guard versions[uri] != version else { return }
        if versions[uri] == nil { rpc.notify("textDocument/didOpen",params:["textDocument":["uri":uri,"languageId":language,"version":version,"text":text]]) }
        else { rpc.notify("textDocument/didChange",params:["textDocument":["uri":uri,"version":version],"contentChanges":[["text":text]]]) }
        versions[uri] = version
    }
    public func close(uri: String) {
        if versions.removeValue(forKey:uri) != nil { rpc.notify("textDocument/didClose",params:["textDocument":["uri":uri]]) }
    }
    public func saved(uri: String,text: String) {
        guard versions[uri] != nil else { return }
        rpc.notify("textDocument/didSave",params:["textDocument":["uri":uri],"text":text])
    }
    public func request(_ method: String,uri: String,position: CodePosition,extra: [String:Any] = [:]) throws -> Any {
        var params: [String:Any] = ["textDocument":["uri":uri],"position":position.json]
        extra.forEach { params[$0] = $1 }; return try rpc.request(method,params:params)
    }
}
