import Foundation

// Adapted from FoldGit FileContentReader, copyright (c) 2026 dufu, MIT.
enum GitPreviewText {
    static func decode(_ data: Data,plain: Bool) throws -> String {
        let source: String?
        if data.starts(with:[0xFF,0xFE]) { source = try strictUTF16(data.dropFirst(2),littleEndian:true) }
        else if data.starts(with:[0xFE,0xFF]) { source = try strictUTF16(data.dropFirst(2),littleEndian:false) }
        else { source = String(data:data.starts(with:[0xEF,0xBB,0xBF]) ? data.dropFirst(3) : data[...],encoding:.utf8) }
        guard let source else { throw GitError.command("Unsupported or invalid text encoding.") }
        var lines = 1,length = 0
        for unit in source.utf16 {
            guard unit != 0,unit >= 32 || [9,10,13,12].contains(unit) else { throw GitError.command("Binary file") }
            if [10,13,0x2028,0x2029].contains(unit) { lines += 1; length = 0 } else { length += 1 }
            if !plain && (lines > 100_000 || length > 20_000) {
                throw GitError.command("This file needs a plain-text preview. Choose Load Large Plain Text.")
            }
        }
        return source
    }

    private static func strictUTF16(_ data: Data.SubSequence,littleEndian: Bool) throws -> String? {
        guard data.count.isMultiple(of:2) else { return nil }
        var units: [UInt16] = []
        units.reserveCapacity(data.count/2)
        var highSurrogate = false,offset = data.startIndex
        while offset < data.endIndex {
            if (offset-data.startIndex) % 8192 == 0 { try Task.checkCancellation() }
            let first = UInt16(data[offset]),second = UInt16(data[offset+1])
            let unit = littleEndian ? first | second << 8 : first << 8 | second
            if highSurrogate {
                guard (0xDC00...0xDFFF).contains(unit) else { return nil }
                highSurrogate = false
            } else if (0xD800...0xDBFF).contains(unit) { highSurrogate = true }
            else if (0xDC00...0xDFFF).contains(unit) { return nil }
            units.append(unit); offset += 2
        }
        guard !highSurrogate else { return nil }
        return String(decoding:units,as:UTF16.self)
    }
}
