import Foundation
import CryptoKit

public enum DocumentError: LocalizedError {
    case unsupportedEncoding, externalChange, mixedLineEndings, invalidRange, encodingFailure
    public var errorDescription: String? {
        switch self {
        case .unsupportedEncoding: return "This file is not supported text. It has not been modified."
        case .externalChange: return "The file changed on disk. Save a copy or reopen it before saving."
        case .mixedLineEndings: return "This file has mixed line endings. Saving is blocked to avoid silently changing them. Save a copy after choosing a line ending."
        case .invalidRange: return "The edit range does not belong to this document version."
        case .encodingFailure: return "The text cannot be represented in the original encoding."
        }
    }
}

public final class DocumentBuffer {
    public let id: UUID
    public private(set) var url: URL?
    public private(set) var text: String
    public private(set) var revision = 0
    public private(set) var savedText: String
    public private(set) var encoding: String.Encoding = .utf8
    public private(set) var hasBOM = false
    public private(set) var lineEnding = "\n"
    public private(set) var hasMixedLineEndings = false
    private var diskDigest: Data?
    public var isModified: Bool { text != savedText || url == nil && !text.isEmpty }
    public var displayName: String { url?.lastPathComponent ?? "Untitled" }
    public var formatLabel: String {
        let name = encoding == .utf8 ? "UTF-8" : encoding == .utf16LittleEndian ? "UTF-16 LE" : "UTF-16 BE"
        return name + (hasBOM ? " BOM" : "") + " · " + (hasMixedLineEndings ? "Mixed EOL" : lineEnding == "\r\n" ? "CRLF" : lineEnding == "\r" ? "CR" : "LF")
    }

    public init(text: String = "", id: UUID = UUID()) {
        self.id = id; self.text = text; self.savedText = text
    }

    public convenience init(url: URL) throws {
        self.init()
        let resolved = url.resolvingSymlinksInPath()
        let data = try Data(contentsOf: resolved)
        var content = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { hasBOM = true; content = data.dropFirst(3) }
        else if data.starts(with: [0xFF, 0xFE]) { hasBOM = true; encoding = .utf16LittleEndian; content = data.dropFirst(2) }
        else if data.starts(with: [0xFE, 0xFF]) { hasBOM = true; encoding = .utf16BigEndian; content = data.dropFirst(2) }
        guard let decoded = String(data: content, encoding: encoding), !decoded.contains("\0") else { throw DocumentError.unsupportedEncoding }
        let crlf = decoded.components(separatedBy: "\r\n").count - 1
        let rest = decoded.replacingOccurrences(of: "\r\n", with: "")
        let lf = rest.contains("\n"), cr = rest.contains("\r")
        hasMixedLineEndings = [crlf > 0, lf, cr].filter { $0 }.count > 1
        lineEnding = crlf > 0 ? "\r\n" : cr ? "\r" : "\n"
        text = decoded.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        savedText = text; self.url = resolved; diskDigest = Self.digest(data)
    }

    public func replace(_ range: NSRange, with replacement: String) throws {
        guard let swiftRange = Range(range, in: text),
              swiftRange.lowerBound.samePosition(in:text.unicodeScalars) != nil,
              swiftRange.upperBound.samePosition(in:text.unicodeScalars) != nil else { throw DocumentError.invalidRange }
        text.replaceSubrange(swiftRange, with: replacement); revision += 1
    }

    public func update(_ value: String) {
        guard value != text else { return }
        text = value; revision += 1
    }

    public func save(to destination: URL? = nil) throws {
        guard let target = (destination ?? url)?.resolvingSymlinksInPath() else { throw CocoaError(.fileNoSuchFile) }
        let sameFile = target == url
        if sameFile, let digest = diskDigest {
            guard let current = try? Data(contentsOf: target), Self.digest(current) == digest else { throw DocumentError.externalChange }
        }
        if hasMixedLineEndings { throw DocumentError.mixedLineEndings }
        let diskText = text.replacingOccurrences(of: "\n", with: lineEnding)
        guard var data = diskText.data(using: encoding, allowLossyConversion: false) else { throw DocumentError.encodingFailure }
        if hasBOM {
            let prefix: [UInt8] = encoding == .utf8 ? [0xEF, 0xBB, 0xBF] : encoding == .utf16LittleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]
            data.insert(contentsOf: prefix, at: 0)
        }
        let fm = FileManager.default
        let attributes = try? fm.attributesOfItem(atPath: target.path)
        try data.write(to: target, options: .atomic)
        if let mode = attributes?[.posixPermissions] { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path) }
        guard try Data(contentsOf: target) == data else { throw CocoaError(.fileWriteUnknown) }
        url = target; diskDigest = Self.digest(data); savedText = text
    }

    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}

public struct RecoveryEntry: Codable {
    public let id: UUID
    public let path: String?
    public let text: String
    public let date: Date
    public init(buffer: DocumentBuffer) {
        id = buffer.id; path = buffer.url?.path; text = buffer.text; date = Date()
    }
}

public final class RecoveryStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func write(_ buffer: DocumentBuffer) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(buffer.id.uuidString + ".json")
        try JSONEncoder().encode(RecoveryEntry(buffer: buffer)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func entries() throws -> [RecoveryEntry] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(RecoveryEntry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date < $1.date }
    }
    public func remove(_ id: UUID) throws {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
