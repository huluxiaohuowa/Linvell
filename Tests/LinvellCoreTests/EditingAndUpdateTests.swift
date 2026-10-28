import XCTest
@testable import LinvellCore

final class EditingAndUpdateTests: XCTestCase {
    func testIncrementalLineIndexAcrossBoundaryChanges() {
        var text = "a\n😀\nc\n",index = LineIndex(text)
        let edits: [(NSRange,String)] = [(NSRange(location:1,length:1),"\n\n"),(NSRange(location:0,length:2),"中"),(NSRange(location:2,length:2),"x\ny"),(NSRange(location:0,length:0),"\n")]
        for (range,replacement) in edits {
            text = (text as NSString).replacingCharacters(in:range,with:replacement)
            index.apply(range:range,replacement:replacement)
            XCTAssertEqual(index.starts,LineIndex(text).starts)
            for p in 0...text.utf16.count { XCTAssertEqual(index.line(at:p),LineIndex(text).line(at:p)) }
        }
    }
    func testLineIndexManyEdits() {
        var text = "",index = LineIndex("")
        for n in 0..<400 {
            let location = text.utf16.count/2,range = NSRange(location:location,length:n%3 == 0 && !text.isEmpty ? 1 : 0)
            let inserted = n%2 == 0 ? "x\ny" : "z"
            text = (text as NSString).replacingCharacters(in:range,with:inserted); index.apply(range:range,replacement:inserted)
            XCTAssertEqual(index.starts,LineIndex(text).starts)
        }
    }
    func testMultiEditUnicodeAndOffsets() throws {
        let r = try MultiEdit.apply([NSRange(location:0,length:2),NSRange(location:3,length:2)],replacement:"中",to:"😀 😀")
        XCTAssertEqual(r.text,"中 中"); XCTAssertEqual(r.selections,[NSRange(location:1,length:0),NSRange(location:3,length:0)])
    }
    func testMultiEditMergesOverlapsButKeepsAdjacentCarets() throws {
        let r = try MultiEdit.apply([NSRange(location:0,length:3),NSRange(location:2,length:2)],replacement:"X",to:"abcde")
        XCTAssertEqual(r.text,"Xe")
        let adjacent = try MultiEdit.apply([NSRange(location:0,length:0),NSRange(location:1,length:0)],replacement:"!",to:"ab")
        XCTAssertEqual(adjacent.text,"!a!b")
    }
    func testMultiEditRejectsHalfSurrogate() { XCTAssertThrowsError(try MultiEdit.apply([NSRange(location:1,length:1)],replacement:"x",to:"😀")) }
    func testSemanticVersionOrdering() {
        let sequence = ["0.1.0-preview.1","0.1.0-preview.2","0.1.0-preview.10","0.1.0","0.1.1","1.0.0","1.1.0","2.0.0"]
        for pair in zip(sequence,sequence.dropFirst()) { XCTAssertLessThan(ReleaseVersion(pair.0)!,ReleaseVersion(pair.1)!) }
        for invalid in ["../evil","v1.0","1.0.0-","01.0.0","1.0.0-preview.01","999999999999999999999.0.0"] { XCTAssertNil(ReleaseVersion(invalid)) }
    }
    func testReleaseSelectionRejectsDraftAndUnsafeAssets() throws {
        func release(_ tag: String,draft: Bool = false,preview: Bool = false,host: String = "github.com") -> [String:Any] {
            let version = String(tag.dropFirst())
            return ["tag_name":tag,"draft":draft,"prerelease":preview,"assets":[["name":"Linvell-\(version)-universal.zip","size":123,"browser_download_url":"https://\(host)/huluxiaohuowa/Linvell/releases/download/\(tag)/Linvell-\(version)-universal.zip"],["name":"SHA256SUMS.txt","size":100,"browser_download_url":"https://\(host)/huluxiaohuowa/Linvell/releases/download/\(tag)/SHA256SUMS.txt"]]]
        }
        let json = [release("v2.0.0",draft:true),release("v1.5.0",host:"evil.example"),release("v1.2.0-preview.2",preview:true),release("v1.1.0")]
        let data = try JSONSerialization.data(withJSONObject:json),releases = try JSONDecoder().decode([GitHubRelease].self,from:data)
        XCTAssertEqual(UpdateOffer.select(releases,installed:"1.0.0",previews:false)?.tag,"v1.1.0")
        XCTAssertEqual(UpdateOffer.select(releases,installed:"1.0.0",previews:true)?.tag,"v1.2.0-preview.2")
        XCTAssertNil(UpdateOffer.select(releases,installed:"3.0.0",previews:true))
    }
    func testChecksumsRequireExactFilenameAndUniqueEntry() {
        let hash = String(repeating:"a",count:64)
        XCTAssertEqual(UpdateOffer.checksum(hash+"  Linvell.zip\n",filename:"Linvell.zip"),hash)
        XCTAssertNil(UpdateOffer.checksum(hash+"  other.zip\n",filename:"Linvell.zip"))
        XCTAssertNil(UpdateOffer.checksum(hash+"  Linvell.zip\n"+hash+"  Linvell.zip",filename:"Linvell.zip"))
    }
    func testArchivePreflightAcceptsOwnZipAndRejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Linvell.app/Contents/MacOS"),withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        try Data("plist".utf8).write(to:root.appendingPathComponent("Linvell.app/Contents/Info.plist"))
        try Data("binary".utf8).write(to:root.appendingPathComponent("Linvell.app/Contents/MacOS/Linvell"))
        func zip(_ name: String) throws -> Data {
            let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/bin/ditto"); p.arguments = ["-c","-k","--keepParent",root.appendingPathComponent("Linvell.app").path,root.appendingPathComponent(name).path]
            try p.run(); p.waitUntilExit(); XCTAssertEqual(p.terminationStatus,0)
            return try Data(contentsOf:root.appendingPathComponent(name))
        }
        XCTAssertNoThrow(try UpdateArchive.validate(zip("valid.zip")))
        try FileManager.default.createSymbolicLink(atPath:root.appendingPathComponent("Linvell.app/link").path,withDestinationPath:"/tmp")
        XCTAssertThrowsError(try UpdateArchive.validate(zip("link.zip")))
        XCTAssertThrowsError(try UpdateArchive.validate(Data(repeating:0,count:100)))
    }
    func testUnsignedAppCannotBeUpdateTrustAnchor() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".app")
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:url) }
        XCTAssertThrowsError(try SignedUpdate.validate(current:url,candidate:url))
    }
}
