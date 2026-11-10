import AppKit
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers

/// Native, read-only previews share the same document lifecycle as image tabs.
final class FilePreview: NSView {
    enum Kind { case image, pdf, quickLook }

    static func kind(for url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if ImagePreview.supports(url) { return .image }
        // Include package formats and legacy Office types even when their UTI is dynamic.
        if ["doc","docx","docm","dot","dotx","xls","xlsx","xlsm","xlsb","xlt","xltx",
            "ppt","pptx","pptm","pps","ppsx","pot","potx","pages","numbers","key",
            "odt","ods","odp","rtf","rtfd","epub","usdz"].contains(ext) { return .quickLook }
        if let type = UTType(filenameExtension:ext),!type.conforms(to:.text),
           type.conforms(to:.content) || type.conforms(to:.archive) { return .quickLook }
        return nil
    }

    private var quickLook: QLPreviewView?

    init(url: URL) {
        super.init(frame:.zero)
        setAccessibilityLabel(url.lastPathComponent)
        switch Self.kind(for:url) {
        case .image:
            Theme.pin(ImagePreview(url:url),in:self)
        case .pdf:
            guard let document = PDFDocument(url:url) else { showUnavailable(); return }
            let pdf = PDFView()
            pdf.document = document; pdf.autoScales = true
            pdf.displayMode = .singlePageContinuous
            Theme.pin(pdf,in:self)
        case .quickLook:
            guard let preview = QLPreviewView(frame:.zero,style:.normal) else { showUnavailable(); return }
            quickLook = preview; preview.shouldCloseWithWindow = false
            preview.autostarts = false
            preview.previewItem = url as NSURL
            Theme.pin(preview,in:self)
        case nil:
            showUnavailable()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { quickLook?.close() }

    private func showUnavailable() {
        let message = Theme.label("This file cannot be previewed.",size:14,color:Theme.secondary)
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo:centerXAnchor),
            message.centerYAnchor.constraint(equalTo:centerYAnchor),
            message.leadingAnchor.constraint(greaterThanOrEqualTo:leadingAnchor,constant:20)
        ])
    }
}
