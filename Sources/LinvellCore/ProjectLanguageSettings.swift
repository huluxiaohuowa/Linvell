import Foundation
import CryptoKit
import Darwin

public enum ProjectSettingsError: LocalizedError {
    case invalidJSONC
    public var errorDescription: String? { "Invalid .linvell/settings.json. Fix its JSON syntax before applying language tools." }
}

/// A small JSONC editor keeps comments and unrelated workspace settings byte-for-byte.
public struct JSONCSettings {
    private let data: Data
    public let values: [String:Any]
    public init(_ data: Data) throws {
        guard data.count <= 1024*1024 else { throw ProjectSettingsError.invalidJSONC }
        let input = data.isEmpty ? Data("{}\n".utf8) : data
        var parser = JSONCParser(input)
        let node = try parser.document()
        guard let object = node.value as? [String:Any] else { throw LanguageServiceError.message("Workspace settings must be a JSON object.") }
        self.data = input; values = object
    }
    public func setting(_ language: String) -> LanguageToolchain {
        let object = values["["+language+"]"] as? [String:Any] ?? [:]
        var profile = LanguageToolchain()
        profile.runtime = object["linvell.interpreterPath"] as? String ?? (language == "python" ? values["python.defaultInterpreterPath"] as? String : nil) ?? ""
        profile.server = object["linvell.languageServerPath"] as? String ?? ""
        profile.arguments = object["linvell.languageServerArguments"] as? [String] ?? []
        profile.enabled = object["linvell.languageServiceEnabled"] as? Bool ?? true
        profile.storage = (object["linvell.languageServiceStorage"] as? String).flatMap(LanguageToolStorage.init(rawValue:)) ?? .project
        profile.addGitIgnore = object["linvell.languageServiceAddGitIgnore"] as? Bool ?? true
        var configuration: [String:Any] = [:]
        let aliases = language == "python" ? ["python","pylsp","pyright","basedpyright"] : ["javascript","typescript"].contains(language) ? ["javascript","typescript"] : ["c","cpp","objective-c"].contains(language) ? ["clangd"] : [language]
        for (key,value) in values.sorted(by:{ $0.key < $1.key }) where aliases.contains(key.components(separatedBy:".").first ?? "") {
            LanguageConfiguration.insert(value,path:ArraySlice(key.components(separatedBy:".")),into:&configuration)
        }
        configuration = LanguageConfiguration.merge(configuration,object["linvell.languageServerSettings"] as? [String:Any] ?? [:])
        profile.configurationJSON = String(decoding:(try? JSONSerialization.data(withJSONObject:configuration,options:.sortedKeys)) ?? Data("{}".utf8),as:UTF8.self)
        return profile
    }
    public func updating(_ language: String,profile: LanguageToolchain) throws -> Data {
        var result = data
        for (key,value) in [("linvell.interpreterPath",profile.runtime as Any),("linvell.languageServerPath",profile.server as Any),("linvell.languageServerArguments",profile.arguments as Any),("linvell.languageServiceEnabled",profile.enabled as Any),("linvell.languageServiceStorage",profile.storage.rawValue as Any),("linvell.languageServiceAddGitIgnore",profile.addGitIgnore as Any)] {
            result = try Self.set(result,path:["["+language+"]"],key:key,value:value)
        }
        if profile.configurationJSON != setting(language).configurationJSON {
            guard let object = try JSONSerialization.jsonObject(with:Data(profile.configurationJSON.utf8)) as? [String:Any] else { throw ProjectSettingsError.invalidJSONC }
            result = try Self.set(result,path:["["+language+"]"],key:"linvell.languageServerSettings",value:object)
        }
        return result
    }
    public func updatingPlugin(_ id: String,configuration: [String:Any]) throws -> Data {
        try Self.set(data,path:["plugins"],key:id,value:configuration)
    }
    private static func set(_ data: Data,path: [String],key: String,value: Any) throws -> Data {
        guard data.count <= 1024*1024 else { throw ProjectSettingsError.invalidJSONC }
        var parser = JSONCParser(data); var node = try parser.document()
        for (index,component) in path.enumerated() {
            guard let child = node.properties[component] else {
                let inserted = try insert(data,node:node,key:component,value:[:],depth:index)
                return try set(inserted,path:path,key:key,value:value)
            }
            guard child.value is [String:Any] else { throw LanguageServiceError.message("The language settings section must be an object. No configuration was replaced.") }
            node = child
        }
        if let old = node.properties[key] {
            var result = data; result.replaceSubrange(old.range,with:try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.sortedKeys,.withoutEscapingSlashes])); return result
        }
        return try insert(data,node:node,key:key,value:value,depth:path.count)
    }
    private static func insert(_ data: Data,node: JSONCNode,key: String,value: Any,depth: Int) throws -> Data {
        let name = try JSONSerialization.data(withJSONObject:key,options:.fragmentsAllowed)
        let raw = try JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed,.sortedKeys,.withoutEscapingSlashes])
        let indent = String(repeating:"  ",count:depth+1),endIndent = String(repeating:"  ",count:depth)
        var addition = Data((!node.properties.isEmpty && !node.trailingComma ? "," : "").utf8)
        addition.append(Data(("\n"+indent).utf8)); addition.append(name); addition.append(Data(": ".utf8)); addition.append(raw); addition.append(Data(("\n"+endIndent).utf8))
        var result = data; result.insert(contentsOf:addition,at:node.range.upperBound-1); return result
    }
}
private struct JSONCNode { let value: Any; let range: Range<Int>; var properties: [String:JSONCNode] = [:]; var trailingComma = false }
private struct JSONCParser {
    let bytes: [UInt8]
    var offset = 0
    init(_ data: Data) { bytes = Array(data); if bytes.starts(with:[239,187,191]) { offset = 3 } }
    mutating func document() throws -> JSONCNode { guard bytes.count <= 1024*1024 else { throw ProjectSettingsError.invalidJSONC }; let node = try value(); try trivia(); guard offset == bytes.count else { throw ProjectSettingsError.invalidJSONC }; return node }
    mutating func trivia() throws {
        while offset < bytes.count {
            if [9,10,13,32].contains(bytes[offset]) { offset += 1; continue }
            if bytes[offset] == 47,offset+1 < bytes.count {
                if bytes[offset+1] == 47 { offset += 2; while offset < bytes.count,bytes[offset] != 10 { offset += 1 }; continue }
                if bytes[offset+1] == 42 {
                    offset += 2
                    while offset+1 < bytes.count,!(bytes[offset] == 42 && bytes[offset+1] == 47) { offset += 1 }
                    guard offset+1 < bytes.count else { throw ProjectSettingsError.invalidJSONC }; offset += 2; continue
                }
            }
            break
        }
    }
    mutating func value() throws -> JSONCNode {
        try trivia(); let start = offset
        guard offset < bytes.count else { throw ProjectSettingsError.invalidJSONC }
        if bytes[offset] == 123 || bytes[offset] == 91 {
            let object = bytes[offset] == 123,close: UInt8 = object ? 125 : 93
            offset += 1; var dictionary: [String:Any] = [:],properties: [String:JSONCNode] = [:],array: [Any] = [],trailing = false
            try trivia()
            while offset < bytes.count,bytes[offset] != close {
                if object {
                    guard bytes[offset] == 34,let key = try string().value as? String else { throw ProjectSettingsError.invalidJSONC }
                    try trivia(); guard offset < bytes.count,bytes[offset] == 58,dictionary[key] == nil else { throw ProjectSettingsError.invalidJSONC }; offset += 1
                    let child = try value(); dictionary[key] = child.value; properties[key] = child
                } else { array.append(try value().value) }
                try trivia(); guard offset < bytes.count else { throw ProjectSettingsError.invalidJSONC }
                if bytes[offset] == 44 { offset += 1; try trivia(); trailing = offset < bytes.count && bytes[offset] == close }
                else if bytes[offset] != close { throw ProjectSettingsError.invalidJSONC }
            }
            guard offset < bytes.count,bytes[offset] == close else { throw ProjectSettingsError.invalidJSONC }; offset += 1
            return JSONCNode(value:object ? dictionary : array,range:start..<offset,properties:properties,trailingComma:trailing)
        }
        if bytes[offset] == 34 { return try string() }
        while offset < bytes.count,![9,10,13,32,44,93,125,47].contains(bytes[offset]) { offset += 1 }
        guard offset > start else { throw ProjectSettingsError.invalidJSONC }
        let result = try JSONSerialization.jsonObject(with:Data(bytes[start..<offset]),options:.fragmentsAllowed)
        return JSONCNode(value:result,range:start..<offset)
    }
    mutating func string() throws -> JSONCNode {
        let start = offset; offset += 1
        while offset < bytes.count {
            if bytes[offset] == 92 { offset += 2; continue }
            if bytes[offset] == 34 { offset += 1; return JSONCNode(value:try JSONSerialization.jsonObject(with:Data(bytes[start..<offset]),options:.fragmentsAllowed),range:start..<offset) }
            offset += 1
        }
        throw ProjectSettingsError.invalidJSONC
    }
}

public struct ProjectLanguageSettings {
    public let data: Data
    public let digest: String
    public let root: String
    public let remote: SSHRemote?
    public static func read(root: String,remote: SSHRemote?) throws -> ProjectLanguageSettings {
        if let remote {
            let reply = try remote.request("settings-read",path:root)
            guard let encoded = reply.content,let bytes = Data(base64Encoded:encoded),let digest = reply.digest else { throw ProjectSettingsError.invalidJSONC }
            _ = try JSONCSettings(bytes)
            return Self(data:bytes,digest:digest,root:root,remote:remote)
        }
        let folder = URL(fileURLWithPath:root).appendingPathComponent(".linvell"),path = folder.appendingPathComponent("settings.json")
        try checkSymlink(folder); try checkSymlink(path)
        let exists = FileManager.default.fileExists(atPath:path.path)
        if exists,let size = try path.resourceValues(forKeys:[.fileSizeKey]).fileSize,size > 1024*1024 { throw ProjectSettingsError.invalidJSONC }
        let bytes = exists ? try Data(contentsOf:path) : Data("{}\n".utf8)
        _ = try JSONCSettings(bytes)
        return Self(data:bytes,digest:exists ? hash(bytes) : "missing",root:root,remote:nil)
    }
    public func write(language: String,profile: LanguageToolchain) throws -> ProjectLanguageSettings {
        try write(try JSONCSettings(data).updating(language,profile:profile))
    }
    public func writePlugin(_ id: String,configuration: [String:Any]) throws -> ProjectLanguageSettings {
        try write(try JSONCSettings(data).updatingPlugin(id,configuration:configuration))
    }
    private func write(_ bytes: Data) throws -> ProjectLanguageSettings {
        if let remote { _ = try remote.request("settings-write",path:root,content:bytes,digest:digest); return try Self.read(root:root,remote:remote) }
        let folder = URL(fileURLWithPath:root).appendingPathComponent(".linvell"),path = folder.appendingPathComponent("settings.json")
        try Self.checkSymlink(folder); try Self.checkSymlink(path)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let fd = open(folder.appendingPathComponent(".settings.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd >= 0,flock(fd,LOCK_EX) == 0 else { if fd >= 0 { close(fd) }; throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd,LOCK_UN); close(fd) }
        let current = try Self.read(root:root,remote:nil)
        guard current.digest == digest else { throw DocumentError.externalChange }
        try bytes.write(to:path,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:path.path)
        return Self(data:bytes,digest:Self.hash(bytes),root:root,remote:nil)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private static func checkSymlink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true { throw LanguageServiceError.message("Project settings cannot use a symlink outside their configuration directory.") }
    }
}
