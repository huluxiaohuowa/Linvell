import XCTest
import AppKit
import PDFKit
import QuickLookUI
import LinvellCore
@testable import Linvell

final class PreviewTests: XCTestCase {
    func testNativePreviewRoutingKeepsSourceFilesEditable() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        for ext in ["pdf","DOCX","xlsx","pptx","pages","numbers","key","mp4","mp3","rtf"] {
            XCTAssertNotNil(FilePreview.kind(for:root.appendingPathComponent("sample."+ext)),ext)
        }
        let source = root.appendingPathComponent("sample.swift")
        try "let value = 1".write(to:source,atomically:true,encoding:.utf8)
        let text = try OpenDocument.load(source)
        XCTAssertNil(text.previewURL)
        XCTAssertEqual(text.buffer.text,"let value = 1")
        let binary = root.appendingPathComponent("sample.unknown-linvell")
        try Data([0,0xFF,0,0x80]).write(to:binary)
        let document = try OpenDocument.load(binary)
        XCTAssertEqual(document.fileURL,binary)
        XCTAssertFalse(document.buffer.isModified)
        let workspace = WorkspaceController()
        defer { workspace.window?.close() }
        workspace.activate(document)
        XCTAssertTrue(workspace.editors.arrangedSubviews.first is FilePreview)
        XCTAssertNil(workspace.activePane)
        XCTAssertNil(workspace.window?.attachedSheet)
        workspace.toggleSplit()
        XCTAssertEqual(workspace.editors.arrangedSubviews.count,1)
        XCTAssertTrue(workspace.saveDocument(document))
        XCTAssertTrue(workspace.saveDocument(document,asCopy:true))
        XCTAssertEqual(try Data(contentsOf:binary),Data([0,0xFF,0,0x80]))
    }

    func testPDFUsesNativePDFView() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".pdf")
        defer { try? FileManager.default.removeItem(at:url) }
        let image = NSImage(size:NSSize(width:100,height:100))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x:0,y:0,width:100,height:100).fill()
        image.unlockFocus()
        let pdf = PDFDocument()
        pdf.insert(try XCTUnwrap(PDFPage(image:image)),at:0)
        XCTAssertTrue(pdf.write(to:url))
        let document = try OpenDocument.load(url)
        XCTAssertEqual(document.previewURL,url)
        let view = FilePreview(url:url)
        let native = try XCTUnwrap(view.subviews.first as? PDFView)
        XCTAssertEqual(native.document?.pageCount,1)
        XCTAssertTrue(native.autoScales)
        XCTAssertFalse(document.buffer.isModified)
    }

    func testRichTextUsesEmbeddedQuickLook() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".rtf")
        defer { try? FileManager.default.removeItem(at:url) }
        let text = NSAttributedString(string:"Native document preview")
        try text.data(from:NSRange(location:0,length:text.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf]).write(to:url)
        let document = try OpenDocument.load(url)
        XCTAssertEqual(document.previewURL,url)
        let view = FilePreview(url:url)
        let native = try XCTUnwrap(view.subviews.first as? QLPreviewView)
        XCTAssertEqual(native.previewItem.previewItemURL,url)
        XCTAssertFalse(native.autostarts)
    }

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
        XCTAssertTrue(OpenDocument(DocumentBuffer()).previewURL == nil)
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
        for fragment in ["<h1","<strong>Bold</strong>","<em>italic</em>","<ul data-source-line=", "<pre data-source-line=","&lt;tag&gt;","<span class=\"syntax-keyword\">let</span>","<span class=\"syntax-string\">","<table data-source-line=","images/example.png"] { XCTAssertTrue(html.contains(fragment),fragment) }
        XCTAssertTrue(html.contains("default-src 'none'"))
    }
    func testMarkdownCodeUsesTheSelectedThemeAndPreservesEscaping() {
        let profile = Theme.Profile.ember
        let source = "```swift\nlet value = \"&lt; <tag>\"\n```"
        let html = MarkdownRendering.html(source,colors:profile.colors,profile:profile)
        let stringColor = Theme.syntaxHex(.string,palette:profile.colors,profile:profile)
        XCTAssertTrue(html.contains(String(format:".syntax-string{color:#%06X}",stringColor)))
        XCTAssertTrue(html.contains("&amp;lt; &lt;tag&gt;"))
        XCTAssertFalse(html.contains("<tag>"))
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
        let document = OpenDocument(previewURL:url)
        XCTAssertEqual(document.fileURL,url); XCTAssertEqual(document.displayName,"Linvell.png")
        XCTAssertFalse(document.buffer.isModified); XCTAssertFalse(document.isMarkdown)
        _ = ImagePreview(url:url)
    }
}
