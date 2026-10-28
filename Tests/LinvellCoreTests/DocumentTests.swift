import XCTest
@testable import LinvellCore

final class DocumentTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:directory) }
    func file(_ bytes: Data) throws -> URL { let url = directory.appendingPathComponent("中文 😀.txt"); try bytes.write(to:url); return url }
    func testUTF8BOMCRLFRoundTrip() throws {
        let bytes = Data([0xEF,0xBB,0xBF]) + "你好 👩🏽‍💻\r\nlast line".data(using:.utf8)!
        let url = try file(bytes), doc = try DocumentBuffer(url:url)
        XCTAssertEqual(doc.text,"你好 👩🏽‍💻\nlast line"); XCTAssertEqual(doc.lineEnding,"\r\n"); XCTAssertTrue(doc.hasBOM)
        try doc.save(); XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
    func testUTF16BOMPreserved() throws {
        let bytes = Data([0xFF,0xFE]) + "text 中文\n".data(using:.utf16LittleEndian)!
        let url = try file(bytes), doc = try DocumentBuffer(url:url); try doc.save(); XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
    func testExternalChangeCannotBeOverwritten() throws {
        let url = try file(Data("first".utf8)), doc = try DocumentBuffer(url:url)
        doc.update("mine"); try Data("external".utf8).write(to:url)
        XCTAssertThrowsError(try doc.save()) { XCTAssertTrue($0 is DocumentError) }
        XCTAssertEqual(try String(contentsOf:url,encoding:.utf8),"external")
        let copy = directory.appendingPathComponent("copy.txt"); try doc.save(to:copy)
        XCTAssertEqual(try String(contentsOf:copy,encoding:.utf8),"mine")
    }
    func testDeletedFileIsConflict() throws {
        let url = try file(Data("first".utf8)), doc = try DocumentBuffer(url:url)
        try FileManager.default.removeItem(at:url); doc.update("mine"); XCTAssertThrowsError(try doc.save())
    }
    func testMixedEOLBlockedWithoutChangingOriginal() throws {
        let bytes = Data("a\r\nb\nc".utf8), url = try file(bytes), doc = try DocumentBuffer(url:url)
        XCTAssertTrue(doc.hasMixedLineEndings); doc.update("changed"); XCTAssertThrowsError(try doc.save()); XCTAssertEqual(try Data(contentsOf:url),bytes)
    }
    func testSinglePassLineEndingDetection() throws {
        for (source,ending,mixed) in [("a\nb\n","\n",false),("a\r\nb\r\n","\r\n",false),("a\rb\r","\r",false),("a\r\nb\r","\r\n",true),("a\r\r\nb\n","\r\n",true),("中文 😀","\n",false)] {
            let doc = try DocumentBuffer(url:file(Data(source.utf8)))
            XCTAssertEqual(doc.lineEnding,ending); XCTAssertEqual(doc.hasMixedLineEndings,mixed)
            XCTAssertEqual(doc.text,source.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n"))
        }
    }
    func testSymlinkAndPermissionsPreserved() throws {
        let url = try file(Data("hello".utf8)); try FileManager.default.setAttributes([.posixPermissions:0o640],ofItemAtPath:url.path)
        let link = directory.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at:link,withDestinationURL:url)
        let doc = try DocumentBuffer(url:link); doc.update("world"); try doc.save()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath:link.path),url.path)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue,0o640)
    }
    func testInvalidUTF16RangeRejected() throws {
        let doc = DocumentBuffer(text:"a😀b"); XCTAssertThrowsError(try doc.replace(NSRange(location:2,length:1),with:"x"))
        try doc.replace(NSRange(location:1,length:2),with:"中"); XCTAssertEqual(doc.text,"a中b")
    }
    func testBinaryRejected() throws { let url = try file(Data([0,1,2,3])); XCTAssertThrowsError(try DocumentBuffer(url:url)) }
    func testRecoverySurvivesNewStoreAndRemovesOnSave() throws {
        let store = RecoveryStore(directory:directory.appendingPathComponent("recovery")), doc = DocumentBuffer(text:"unsaved 中文")
        try store.write(doc); let entries = try RecoveryStore(directory:store.directory).entries()
        XCTAssertEqual(entries.first?.text,doc.text); XCTAssertEqual(entries.first?.id,doc.id)
        try store.remove(doc.id); XCTAssertTrue(try store.entries().isEmpty)
    }
    func testSaveFailureRetainsDirtyContent() throws {
        let doc = DocumentBuffer(); doc.update("keep me")
        XCTAssertThrowsError(try doc.save(to:directory.appendingPathComponent("absent/a.txt")))
        XCTAssertEqual(doc.text,"keep me"); XCTAssertTrue(doc.isModified)
    }
}
