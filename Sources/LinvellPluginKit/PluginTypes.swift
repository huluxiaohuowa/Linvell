import Foundation

/// JSON values for non-secret configuration and persistent state.
public indirect enum PluginValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), array([PluginValue]), object([String:PluginValue]), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let v = try? value.decode(Bool.self) { self = .bool(v) }
        else if let v = try? value.decode(Double.self) { self = .number(v) }
        else if let v = try? value.decode(String.self) { self = .string(v) }
        else if let v = try? value.decode([PluginValue].self) { self = .array(v) }
        else { self = .object(try value.decode([String:PluginValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
}

public struct PluginEnvironment: Codable {
    public let configuration: [String:PluginValue]
    public let globalState: [String:PluginValue]
    public let workspaceState: [String:PluginValue]
    public init(configuration: [String:PluginValue] = [:],globalState: [String:PluginValue] = [:],workspaceState: [String:PluginValue] = [:]) {
        self.configuration = configuration; self.globalState = globalState; self.workspaceState = workspaceState
    }
}

public struct PluginStateUpdate: Codable {
    public enum Scope: String, Codable { case global, workspace }
    public let scope: Scope
    public let key: String
    /// nil removes the key; .null stores a JSON null.
    public let value: PluginValue?
    public init(scope: Scope,key: String,value: PluginValue?) { self.scope = scope; self.key = key; self.value = value }
    private enum CodingKeys: String, CodingKey { case scope, key, value }
    public init(from decoder: Decoder) throws {
        let object = try decoder.container(keyedBy:CodingKeys.self)
        scope = try object.decode(Scope.self,forKey:.scope); key = try object.decode(String.self,forKey:.key)
        value = object.contains(.value) ? try object.decode(PluginValue.self,forKey:.value) : nil
    }
    public func encode(to encoder: Encoder) throws {
        var object = encoder.container(keyedBy:CodingKeys.self)
        try object.encode(scope,forKey:.scope); try object.encode(key,forKey:.key)
        if let value { try object.encode(value,forKey:.value) }
    }
}

/// Zero-based UTF-16 offsets into the exact request snapshot, not byte offsets.
public struct PluginTextEdit: Codable {
    public let location: Int
    public let length: Int
    public let text: String
    public init(location: Int,length: Int,text: String) { self.location = location; self.length = length; self.text = text }
}

public struct PluginDocumentEvent: Codable {
    public enum Kind: String, Codable { case open, change, save, close }
    public let kind: Kind
    public let documentID: String
    public let revision: Int
    /// Close, oversized documents and saves of an older revision carry metadata only.
    public let document: PluginDocument?
    public let environment: PluginEnvironment?
    public init(kind: Kind,documentID: String,revision: Int,document: PluginDocument? = nil,environment: PluginEnvironment? = nil) {
        self.kind = kind; self.documentID = documentID; self.revision = revision; self.document = document; self.environment = environment
    }
}
