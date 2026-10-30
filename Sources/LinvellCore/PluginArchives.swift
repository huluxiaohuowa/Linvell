import Foundation
import CZlib

/// Bounded ZIP extraction validates local/central paths, CRC and exact decompressed sizes before committing files.
public enum PluginArchives {
    private struct Entry { let name: String,start: Int,size: Int,expanded: Int,method: Int,crc: Int,mode: Int }
    public static func validate(_ data: Data) throws { _ = try entries(data) }
    private static func entries(_ data: Data) throws -> [Entry] {
        guard data.count >= 22,data.count <= 128*1024*1024 else { throw PluginError.invalidPackage }
        func u16(_ n: Int) throws -> Int { guard n >= 0,n+2 <= data.count else { throw PluginError.invalidPackage }; return Int(data[n]) | Int(data[n+1])<<8 }
        func u32(_ n: Int) throws -> Int { try u16(n) | u16(n+2)<<16 }
        var end: Int?
        for n in stride(from:data.count-22,through:max(0,data.count-65557),by:-1) {
            if try u32(n) == 0x06054b50,try n+22+u16(n+20) == data.count { end = n; break }
        }
        guard let end,try u16(end+4) == 0,try u16(end+6) == 0,try u16(end+8) == u16(end+10) else { throw PluginError.invalidPackage }
        let count = try u16(end+10),size = try u32(end+12),start = try u32(end+16)
        guard count > 0,count <= 4000,size <= 4*1024*1024,start+size == end else { throw PluginError.invalidPackage }
        var at = start,total = 0,names = Set<String>(),spans: [(Int,Int)] = [],entries: [Entry] = []
        for _ in 0..<count {
            guard try u32(at) == 0x02014b50 else { throw PluginError.invalidPackage }
            let flags = try u16(at+8),method = try u16(at+10),compressed = try u32(at+20),expanded = try u32(at+24)
            let length = try u16(at+28),extra = try u16(at+30),comment = try u16(at+32),local = try u32(at+42),mode = try u32(at+38)>>16
            guard length > 0,at+46+length+extra+comment <= end,flags & 1 == 0,[0,8].contains(method),expanded <= 64*1024*1024,mode & 0xf000 != 0xa000,try u16(at+34) == 0 else { throw PluginError.invalidPackage }
            let raw = data.subdata(in:at+46..<at+46+length)
            guard let name = String(data:raw,encoding:.utf8),!name.hasPrefix("/"),!name.contains("\\"),!name.utf8.contains(0),!name.split(separator:"/").contains(".."),!name.split(separator:"/").contains("."),names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw PluginError.invalidPackage }
            guard try u32(local) == 0x04034b50,try u16(local+6) == flags,try u16(local+8) == method,try u16(local+26) == length else { throw PluginError.invalidPackage }
            let payload = try local+30+length+u16(local+28)
            guard local+30+length <= start,payload+compressed <= start,data.subdata(in:local+30..<local+30+length) == raw else { throw PluginError.invalidPackage }
            if flags & 8 == 0 { guard try u32(local+14) == u32(at+16),try u32(local+18) == compressed,try u32(local+22) == expanded else { throw PluginError.invalidPackage } }
            guard method != 0 || compressed == expanded else { throw PluginError.invalidPackage }
            guard !name.hasSuffix("/") || expanded == 0 else { throw PluginError.invalidPackage }
            entries.append(Entry(name:name,start:payload,size:compressed,expanded:expanded,method:method,crc:try u32(at+16),mode:mode))
            spans.append((local,payload+compressed));total += expanded
            guard total <= 256*1024*1024 else { throw PluginError.invalidPackage }
            at += 46+length+extra+comment
        }
        guard at == end else { throw PluginError.invalidPackage }
        let ordered = spans.sorted { $0.0 < $1.0 }
        for index in 1..<ordered.count { guard ordered[index].0 >= ordered[index-1].1 else { throw PluginError.invalidPackage } }
        return entries
    }
    public static func extract(_ archive: URL,to directory: URL) throws -> URL {
        let data = try Data(contentsOf:archive),entries = try entries(data)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for entry in entries {
            let file = directory.appendingPathComponent(entry.name)
            guard file.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path+"/") else { throw PluginError.invalidPackage }
            if entry.name.hasSuffix("/") { try FileManager.default.createDirectory(at:file,withIntermediateDirectories:true);continue }
            try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
            let input = data.subdata(in:entry.start..<entry.start+entry.size)
            var output: Data
            if entry.method == 0 { output = input }
            else {
                output = Data(count:entry.expanded+1)
                var stream = z_stream()
                guard inflateInit2_(&stream,-MAX_WBITS,zlibVersion(),Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw PluginError.invalidPackage }
                defer { inflateEnd(&stream) }
                let code = input.withUnsafeBytes { source in output.withUnsafeMutableBytes { target -> Int32 in
                    stream.next_in = UnsafeMutablePointer(mutating:source.bindMemory(to:UInt8.self).baseAddress);stream.avail_in = UInt32(input.count)
                    stream.next_out = target.bindMemory(to:UInt8.self).baseAddress;stream.avail_out = UInt32(entry.expanded+1)
                    return inflate(&stream,Z_FINISH)
                } }
                guard code == Z_STREAM_END,stream.total_out == entry.expanded,stream.total_in == input.count else { throw PluginError.invalidPackage }
                output.count = entry.expanded
            }
            let checksum = output.withUnsafeBytes { crc32(0,$0.bindMemory(to:UInt8.self).baseAddress,uInt(output.count)) }
            guard checksum == entry.crc else { throw PluginError.invalidPackage }
            try output.write(to:file,options:.withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions:entry.mode & 0o111 != 0 ? 0o755 : 0o644],ofItemAtPath:file.path)
        }
        let enumerator = FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.isSymbolicLinkKey,.isRegularFileKey],options:[])
        var manifests: [URL] = []
        while let file = enumerator?.nextObject() as? URL {
            let values = try file.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey])
            guard values.isSymbolicLink != true else { throw PluginError.invalidPackage }
            if file.lastPathComponent == "plugin.json",values.isRegularFile == true { manifests.append(file) }
        }
        guard manifests.count == 1 else { throw PluginError.invalidPackage }
        return manifests[0].deletingLastPathComponent()
    }
}
