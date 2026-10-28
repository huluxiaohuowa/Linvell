import XCTest
import AppKit
import LinvellCore
@testable import Linvell

final class PreviewTests: XCTestCase {
    func testFontCatalogIncludesInstalledMonospaceAndPreservesOtherSelections() {
        let options = EditorFonts.installedMonospace(selected:"Menlo")
        XCTAssertTrue(options.contains(where:{ $0.title == "Menlo" }))
        XCTAssertTrue(options.contains(where:{ $0.title == "Monaco" }))
        XCTAssertNotNil(EditorFonts.resolve("Menlo",size:16))
        let proportional = NSFont.systemFont(ofSize:16).fontName
        XCTAssertTrue(EditorFonts.installedMonospace(selected:proportional).contains(where:{ $0.value == proportional }))
        let missing = "LinvellMissingTestFont"
        XCTAssertTrue(EditorFonts.installedMonospace(selected:missing).contains(where:{ $0.value == missing }))
        XCTAssertNil(EditorFonts.resolve(missing,size:16))
    }
    func testHTMLPreviewPreservesDocumentAndLocalStyles() {
        let document = "<!doctype html><html><head><link rel=\"stylesheet\" href=\"style.css\"></head><body><h1>Hello</h1></body></html>"
        let output = MarkdownPreview.documentHTML(document)
        XCTAssertTrue(output.contains("style.css")); XCTAssertTrue(output.contains("<h1>Hello</h1>"))
        XCTAssertTrue(output.contains("Content-Security-Policy")); XCTAssertTrue(output.contains("style-src linvell-preview:"))
        XCTAssertTrue(OpenDocument(DocumentBuffer()).imageURL == nil)
    }
    func testMarkdownRendersCommonDocumentStructures() {
        let source = """
        # A document

        **Bold** and *italic* with [a link](https://example.com).

        - First
        - Second

        ```swift
        let html = "<tag>"
        ```

        | Name | Value |
        | --- | --- |
        | A | 1 |

        ![Local](images/example.png)
        """
        let html = MarkdownRendering.html(source,colors:Theme.Profile.light.colors)
        for fragment in ["<h1","<strong>Bold</strong>","<em>italic</em>","<ul>","<pre>","&lt;tag&gt;","<table>","images/example.png"] { XCTAssertTrue(html.contains(fragment),fragment) }
        XCTAssertTrue(html.contains("default-src 'none'"))
    }
    func testMarkdownResourcesCannotEscapeDocumentFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        XCTAssertEqual(MarkdownRendering.localURL(URL(string:"linvell-preview://document/images/a%20b.png")!,root:root),root.appendingPathComponent("images/a b.png"))
        XCTAssertNil(MarkdownRendering.localURL(URL(string:"linvell-preview://document/../outside.png")!,root:root))
        XCTAssertNil(MarkdownRendering.localURL(URL(string:"https://example.com/tracker.png")!,root:root))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("escape"),withDestinationURL:root.deletingLastPathComponent())
        XCTAssertNil(MarkdownRendering.localURL(URL(string:"linvell-preview://document/escape/outside.png")!,root:root))
    }
    func testImageDocumentDoesNotBecomeAnEditableTextBuffer() {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Brand/Linvell.png")
        XCTAssertTrue(ImagePreview.supports(url)); XCTAssertNotNil(NSImage(contentsOf:url))
        XCTAssertFalse(ImagePreview.supports(URL(fileURLWithPath:"/tmp/source.swift")))
        let document = OpenDocument(imageURL:url)
        XCTAssertEqual(document.fileURL,url); XCTAssertEqual(document.displayName,"Linvell.png")
        XCTAssertFalse(document.buffer.isModified); XCTAssertFalse(document.isMarkdown)
        _ = ImagePreview(url:url)
    }
}
