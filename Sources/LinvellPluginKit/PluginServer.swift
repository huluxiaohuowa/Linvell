import Foundation

/// Protocol 1: one active command request at a time, framed JSON-RPC over stdin/stdout.
public struct PluginCommandContext: Codable {
    public let command: String
    public let document: PluginDocument?
    public init(command: String, document: PluginDocument? = nil) { self.command = command; self.document = document }
}

public struct PluginDocument: Codable {
    public let text: String
    public let revision: Int
    public init(text: String, revision: Int) { self.text = text; self.revision = revision }
}

public struct PluginCommandResult: Codable {
    public var message: String?
    public var replacementText: String?
    public init(message: String? = nil, replacementText: String? = nil) { self.message = message; self.replacementText = replacementText }
}

public enum PluginServer {
    /// Reserve stdout for the protocol. Use stderr for development diagnostics.
    public static func run(handler: (PluginCommandContext) throws -> PluginCommandResult) throws {
        let input = FileHandle.standardInput, output = FileHandle.standardOutput
        while let body = try readFrame(input) {
            guard let request = try JSONSerialization.jsonObject(with:body) as? [String:Any],
                  request["jsonrpc"] as? String == "2.0",let id = request["id"] as? Int else { throw ProtocolError.invalidFrame }
            var response: [String:Any] = ["jsonrpc":"2.0","id":id]
            do {
                switch request["method"] as? String {
                case "initialize":
                    guard (request["params"] as? [String:Any])?["protocolVersion"] as? Int == 1 else { throw ProtocolError.invalidFrame }
                    response["result"] = ["protocolVersion":1]
                case "commands/execute":
                    let params = try JSONSerialization.data(withJSONObject:request["params"] ?? [:])
                    let result = try handler(JSONDecoder().decode(PluginCommandContext.self,from:params))
                    response["result"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(result))
                default: throw ProtocolError.unknownMethod
                }
            } catch {
                response["error"] = ["code":-32603,"message":error.localizedDescription]
            }
            let data = try JSONSerialization.data(withJSONObject:response)
            guard data.count <= 32*1024*1024 else { throw ProtocolError.invalidFrame }
            try output.write(contentsOf:Data("Content-Length: \(data.count)\r\n\r\n".utf8)+data)
        }
    }
    private static func readFrame(_ input: FileHandle) throws -> Data? {
        var header = Data()
        while !header.suffix(4).elementsEqual([13,10,13,10]) {
            guard let byte = try input.read(upToCount:1),!byte.isEmpty else {
                if header.isEmpty { return nil }; throw ProtocolError.invalidFrame
            }
            header.append(byte)
            guard header.count <= 8192 else { throw ProtocolError.invalidFrame }
        }
        guard let line = String(data:header,encoding:.utf8)?.components(separatedBy:"\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
              let size = Int(line.dropFirst("content-length:".count).trimmingCharacters(in:.whitespaces)),size > 0,size <= 32*1024*1024 else { throw ProtocolError.invalidFrame }
        var body = Data()
        while body.count < size {
            guard let bytes = try input.read(upToCount:size-body.count),!bytes.isEmpty else { throw ProtocolError.invalidFrame }
            body.append(bytes)
        }
        return body
    }
    private enum ProtocolError: LocalizedError {
        case invalidFrame, unknownMethod
        var errorDescription: String? { self == .invalidFrame ? "Invalid Linvell plugin protocol frame." : "Unknown Linvell plugin method." }
    }
}
