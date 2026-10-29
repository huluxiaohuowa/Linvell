import Foundation

/// A bounded TAR reader validates paths and entry types before writing. Only the
/// selected Node binary and license is extracted from its official runtime distribution.
enum ManagedToolArchive {
    static func extract(_ archive: URL,to destination: URL,member: String? = nil) throws {
        let temporary = archive.deletingLastPathComponent().appendingPathComponent(UUID().uuidString+".tar")
        defer { try? FileManager.default.removeItem(at:temporary) }
        let unpack = try ToolCommand.run(URL(fileURLWithPath:"/usr/bin/gzip"),arguments:["-dc",archive.path],directory:nil,timeout:90,outputFile:temporary,maximumOutputBytes:512*1024*1024)
        guard unpack.succeeded else { throw UpdateFailure.invalidArchive }
        let input = try FileHandle(forReadingFrom:temporary); defer { try? input.close() }
        var seen = Set<String>(),total = 0,found = false,nextName: String?
        while let header = try input.read(upToCount:512),header.count == 512,!header.allSatisfy({ $0 == 0 }) {
            func string(_ range: Range<Int>) -> String { String(decoding:header[range].prefix(while:{ $0 != 0 }),as:UTF8.self) }
            func octal(_ range: Range<Int>) -> Int? { Int(string(range).trimmingCharacters(in:.whitespacesAndNewlines),radix:8) }
            guard let size = octal(124..<136),size >= 0,size <= 384*1024*1024,let checksum = octal(148..<156) else { throw UpdateFailure.invalidArchive }
            let actual = header.enumerated().reduce(0) { $0+((148..<156).contains($1.offset) ? 32 : Int($1.element)) }
            guard actual == checksum else { throw UpdateFailure.invalidArchive }
            let start = try input.offset(),blocks = UInt64((size+511)/512*512)
            var name = nextName ?? string(0..<100); nextName = nil
            let prefix = string(345..<500)
            if !prefix.isEmpty,name == string(0..<100) { name = prefix+"/"+name }
            let type = header[156]
            if type == 120 || type == 76 {
                guard size <= 1024*1024 else { throw UpdateFailure.invalidArchive }
                let bytes = try input.read(upToCount:size) ?? Data()
                if type == 76 { nextName = String(decoding:bytes.prefix(while:{ $0 != 0 }),as:UTF8.self) }
                else {
                    var offset = 0
                    while offset < bytes.count {
                        guard let space = bytes[offset...].firstIndex(of:32),let count = Int(String(decoding:bytes[offset..<space],as:UTF8.self)),count > 0,offset+count <= bytes.count else { throw UpdateFailure.invalidArchive }
                        let record = String(decoding:bytes[(space+1)..<(offset+count-1)],as:UTF8.self)
                        if record.hasPrefix("path=") { nextName = String(record.dropFirst(5)) }; offset += count
                    }
                }
                try input.seek(toOffset:start+blocks); continue
            }
            let license = member.map { String($0.dropLast("bin/node".count))+"LICENSE" }
            if let member,name != member && name != license { try input.seek(toOffset:start+blocks); continue }
            if type == 103 { try input.seek(toOffset:start+blocks); continue }
            let path: String
            if member != nil { path = name == license ? "LICENSE" : "bin/node" }
            else {
                guard name.hasPrefix("package/") else { throw UpdateFailure.invalidArchive }; path = String(name.dropFirst(8))
            }
            if path.isEmpty { try input.seek(toOffset:start+blocks); continue }
            guard !path.hasPrefix("/"),!path.contains("\\"),!path.contains("\0"),!path.split(separator:"/").contains(".."),[0,48,53].contains(type),seen.insert(path).inserted else { throw UpdateFailure.invalidArchive }
            total += size; guard total <= 384*1024*1024 else { throw UpdateFailure.invalidArchive }
            let target = destination.appendingPathComponent(path)
            if type == 53 { try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true) }
            else {
                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                guard FileManager.default.createFile(atPath:target.path,contents:nil,attributes:[.posixPermissions:path == "bin/node" ? 0o755 : 0o644]) else { throw CocoaError(.fileWriteUnknown) }
                let output = try FileHandle(forWritingTo:target)
                do {
                    var remaining = size
                    while remaining > 0 {
                        let data = try input.read(upToCount:min(1024*1024,remaining)) ?? Data()
                        guard !data.isEmpty else { throw UpdateFailure.invalidArchive }; try output.write(contentsOf:data); remaining -= data.count
                    }
                    try output.close()
                } catch { try? output.close(); throw error }
                found = true
            }
            try input.seek(toOffset:start+blocks)
        }
        guard found else { throw UpdateFailure.invalidArchive }
    }
}
