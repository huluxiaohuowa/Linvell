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
    private var modificationCheck: (Int,Bool)?
    public var isModified: Bool {
        if let (checked,result) = modificationCheck,checked == revision { return result }
        let result = text != savedText || url == nil && !text.isEmpty
        modificationCheck = (revision,result); return result
    }
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
        guard let decoded = String(data: content, encoding: encoding) else { throw DocumentError.unsupportedEncoding }
        // Scan once without allocating an array containing every line of a large file.
        var crlf = false,lf = false,cr = false,pendingCR = false
        for byte in decoded.utf8 {
            if byte == 0 { throw DocumentError.unsupportedEncoding }
            if pendingCR {
                if byte == 10 { crlf = true; pendingCR = false; continue }
                cr = true
            }
            pendingCR = byte == 13
            if byte == 10 { lf = true }
        }
        cr = cr || pendingCR
        hasMixedLineEndings = [crlf,lf,cr].filter { $0 }.count > 1
        lineEnding = crlf ? "\r\n" : cr ? "\r" : "\n"
        text = crlf || cr ? decoded.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n") : decoded
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

    /// Immutable capture for background I/O. Completing an older save never clears newer edits.
    public struct SaveSnapshot {
        public let target: URL
        public let text: String
        public let revision: Int
        private let baseline: Data?
        private let encoding: String.Encoding
        private let bom: Bool
        private let ending: String
        private let mixed: Bool
        fileprivate init(_ buffer: DocumentBuffer,target: URL) {
            self.target = target; text = buffer.text; revision = buffer.revision
            baseline = target == buffer.url ? buffer.diskDigest : nil
            encoding = buffer.encoding; bom = buffer.hasBOM; ending = buffer.lineEnding; mixed = buffer.hasMixedLineEndings
        }
        public func data() throws -> Data {
            guard !mixed else { throw DocumentError.mixedLineEndings }
            guard var result = text.replacingOccurrences(of:"\n",with:ending).data(using:encoding,allowLossyConversion:false) else { throw DocumentError.encodingFailure }
            if bom { result.insert(contentsOf:encoding == .utf8 ? [0xEF,0xBB,0xBF] : encoding == .utf16LittleEndian ? [0xFF,0xFE] : [0xFE,0xFF],at:0) }
            return result
        }
        public func write() throws -> Data {
            if let baseline {
                guard let current = try? Data(contentsOf:target),DocumentBuffer.digest(current) == baseline else { throw DocumentError.externalChange }
            }
            let bytes = try data(),fm = FileManager.default
            let attributes = try? fm.attributesOfItem(atPath:target.path)
            try bytes.write(to:target,options:.atomic)
            if let mode = attributes?[.posixPermissions] { try fm.setAttributes([.posixPermissions:mode],ofItemAtPath:target.path) }
            guard try Data(contentsOf:target) == bytes else { throw CocoaError(.fileWriteUnknown) }
            return DocumentBuffer.digest(bytes)
        }
    }
    public func saveSnapshot(to destination: URL? = nil) throws -> SaveSnapshot {
        guard let target = (destination ?? url)?.resolvingSymlinksInPath() else { throw CocoaError(.fileNoSuchFile) }
        return SaveSnapshot(self,target:target)
    }
    public func completeSave(_ snapshot: SaveSnapshot,digest: Data) {
        url = snapshot.target; savedText = snapshot.text; diskDigest = digest; modificationCheck = nil
    }
    public func save(to destination: URL? = nil) throws {
        let snapshot = try saveSnapshot(to:destination)
        completeSave(snapshot,digest:try snapshot.write())
    }

    public func dataForSaving() throws -> Data {
        if hasMixedLineEndings { throw DocumentError.mixedLineEndings }
        let diskText = text.replacingOccurrences(of: "\n", with: lineEnding)
        guard var data = diskText.data(using: encoding, allowLossyConversion: false) else { throw DocumentError.encodingFailure }
        if hasBOM {
            let prefix: [UInt8] = encoding == .utf8 ? [0xEF, 0xBB, 0xBF] : encoding == .utf16LittleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]
            data.insert(contentsOf: prefix, at: 0)
        }
        return data
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
