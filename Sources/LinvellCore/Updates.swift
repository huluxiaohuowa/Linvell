import Foundation

public struct ReleaseVersion: Comparable, Equatable {
    public let numbers: [Int]
    public let prerelease: [String]
    public init?(_ source: String) {
        let value = source.hasPrefix("v") ? String(source.dropFirst()) : source
        let main = value.split(separator:"+",maxSplits:1).first.map(String.init) ?? ""
        let parts = main.split(separator:"-",maxSplits:1,omittingEmptySubsequences:false)
        let numeric = parts[0].split(separator:".",omittingEmptySubsequences:false)
        guard numeric.count == 3,numeric.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && ($0 == "0" || !$0.hasPrefix("0")) }),numeric.allSatisfy({ Int($0) != nil }) else { return nil }
        numbers = numeric.map { Int($0)! }
        prerelease = parts.count > 1 ? parts[1].split(separator:".",omittingEmptySubsequences:false).map(String.init) : []
        guard prerelease.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 } && (!$0.allSatisfy(\.isNumber) || $0 == "0" || !$0.hasPrefix("0")) }) else { return nil }
    }
    public static func < (a: Self,b: Self) -> Bool {
        if a.numbers != b.numbers { return a.numbers.lexicographicallyPrecedes(b.numbers) }
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (left,right) in zip(a.prerelease,b.prerelease) where left != right {
            let l = left.allSatisfy(\.isNumber),r = right.allSatisfy(\.isNumber)
            if l && r { return left.count == right.count ? left < right : left.count < right.count }
            if l != r { return l }
            return left < right
        }
        return a.prerelease.count < b.prerelease.count
    }
}

public struct GitHubRelease: Decodable {
    public struct Asset: Decodable {
        public let name: String
        public let browser_download_url: URL
        public let size: Int64
        public let digest: String?
    }
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
}

public struct UpdateOffer {
    public let tag: String
    public let archive: GitHubRelease.Asset
    public let checksum: GitHubRelease.Asset
    public static func select(_ releases: [GitHubRelease],installed: String,previews: Bool) -> UpdateOffer? {
        guard let current = ReleaseVersion(installed) else { return nil }
        return releases.compactMap { release -> (ReleaseVersion,UpdateOffer)? in
            guard !release.draft,let version = ReleaseVersion(release.tag_name),version > current,
                  previews || (!release.prerelease && version.prerelease.isEmpty) else { return nil }
            let name = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            guard let archive = release.assets.first(where: { $0.name == "Linvell-\(name)-universal.zip" }),archive.size > 0,archive.size <= 256*1024*1024,
                  let checksum = release.assets.first(where: { $0.name == "SHA256SUMS.txt" }),checksum.size > 0,checksum.size < 64*1024,
                  trustedAssetURL(archive.browser_download_url,tag:release.tag_name),trustedAssetURL(checksum.browser_download_url,tag:release.tag_name) else { return nil }
            return (version,UpdateOffer(tag:release.tag_name,archive:archive,checksum:checksum))
        }.max(by: { $0.0 < $1.0 })?.1
    }
    public static func trustedAssetURL(_ url: URL,tag: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil && url.path.hasPrefix("/huluxiaohuowa/Linvell/releases/download/\(tag)/")
    }
    public static func checksum(_ text: String,filename: String) -> String? {
        let lines = text.components(separatedBy:.newlines).compactMap { line -> (String,String)? in
            let fields = line.split(maxSplits:1,whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2 else { return nil }
            let hash = String(fields[0]).lowercased(),name = fields[1].trimmingCharacters(in:.whitespaces).trimmingCharacters(in:CharacterSet(charactersIn:"*"))
            guard hash.count == 64,hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            return (hash,name)
        }.filter { $0.1 == filename }
        return lines.count == 1 ? lines[0].0 : nil
    }
}

public enum UpdateFailure: LocalizedError {
    case invalidArchive, untrustedPackage, invalidResponse, notWritable
    public var errorDescription: String? {
        switch self {
        case .invalidArchive: return "The update archive is invalid or contains unsafe entries."
        case .untrustedPackage: return "The update could not be verified as an authentic, newer Linvell release."
        case .invalidResponse: return "The update server returned an invalid response."
        case .notWritable: return "Move Linvell to a writable Applications folder before installing updates."
        }
    }
}

/// ZIP preflight before extraction: no links, path traversal, ZIP64 or unbounded expansion.
public enum UpdateArchive {
    public static func validate(_ data: Data) throws {
        func fail() throws -> Never { throw UpdateFailure.invalidArchive }
        func u16(_ p: Int) -> Int { Int(data[p]) | Int(data[p+1])<<8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p+2)<<16 }
        guard data.count >= 22,data.count <= 256*1024*1024 else { try fail() }
        var end: Int?
        for p in stride(from:data.count-22,through:max(0,data.count-65557),by:-1) {
            if u32(p) == 0x06054b50 && p+22+u16(p+20) == data.count { end = p; break }
        }
        guard let e = end,u16(e+4) == 0,u16(e+6) == 0,u16(e+8) == u16(e+10) else { try fail() }
        let count = u16(e+10),directory = u32(e+16),length = u32(e+12)
        guard count > 0,count < 20_000,directory <= e,length <= e-directory,directory+length == e else { try fail() }
        var p = directory,total = 0,paths = Set<String>()
        for _ in 0..<count {
            guard p+46 <= e,u32(p) == 0x02014b50 else { try fail() }
            let flags = u16(p+8),method = u16(p+10),compressed = u32(p+20),size = u32(p+24)
            let n = u16(p+28),extra = u16(p+30),comment = u16(p+32),local = u32(p+42)
            guard flags&1 == 0,[0,8].contains(method),u16(p+34) == 0,p+46+n+extra+comment <= e,
                  let name = String(data:data[(p+46)..<(p+46+n)],encoding:.utf8),!name.isEmpty,!name.contains("\0"),!name.contains("\\"),!name.hasPrefix("/"),
                  !name.split(separator:"/",omittingEmptySubsequences:false).contains(".."),
                  name == "Linvell.app/" || name.hasPrefix("Linvell.app/") || name.hasPrefix("__MACOSX/"),
                  (u32(p+38)>>16)&0xf000 != 0xa000,paths.insert(name).inserted else { try fail() }
            total += size; guard total <= 768*1024*1024,local+30 <= directory,u32(local) == 0x04034b50 else { try fail() }
            let ln = u16(local+26),le = u16(local+28)
            guard local+30+ln+le <= directory,compressed <= directory-local-30-ln-le,
                  data[(local+30)..<(local+30+ln)] == data[(p+46)..<(p+46+n)] else { try fail() }
            p += 46+n+extra+comment
        }
        guard p == directory+length,paths.contains("Linvell.app/Contents/Info.plist"),paths.contains("Linvell.app/Contents/MacOS/Linvell") else { try fail() }
    }
}
