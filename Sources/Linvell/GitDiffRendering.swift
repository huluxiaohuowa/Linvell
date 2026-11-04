import AppKit
import LinvellCore

/// Color only presentation text; selections always refer to the untouched Git patch.
enum GitDiffRendering {
    static func summary(_ patch: String) -> String {
        var files = 0,added = 0,removed = 0,inHunk = false
        for line in patch.components(separatedBy:"\n") {
            if line.hasPrefix("diff --git ") { files += 1; inHunk = false }
            else if line.hasPrefix("@@ ") { inHunk = true }
            else if inHunk && line.hasPrefix("+") { added += 1 }
            else if inHunk && line.hasPrefix("-") { removed += 1 }
        }
        return L.format("%d files · +%d · −%d",files,added,removed)
    }
    static func color(_ kind: SourceTokenKind) -> NSColor {
        switch kind {
        case .keyword,.type,.directive: return Theme.keyword
        case .string: return Theme.accent
        case .number: return Theme.number
        case .comment: return Theme.secondary
        }
    }

    static func styled(_ value: String,path: String? = nil) -> NSMutableAttributedString {
        let patch = NSMutableAttributedString(string:value,attributes:[.font:Theme.editorFont,.foregroundColor:Theme.foreground])
        let source = value as NSString
        var currentPath = path ?? "",inHunk = false
        var oldSource = "",newSource = ""
        var oldMap: [(NSRange,NSRange)] = [],newMap: [(NSRange,NSRange)] = []
        func flush() {
            for (text,mapping) in [(oldSource,oldMap),(newSource,newMap)] {
                for token in SourceSyntax.analyze(text,path:currentPath).tokens {
                    var low = 0,high = mapping.count
                    while low < high {
                        let middle = (low+high)/2
                        if NSMaxRange(mapping[middle].0) <= token.range.location { low = middle+1 } else { high = middle }
                    }
                    while low < mapping.count,mapping[low].0.location < NSMaxRange(token.range) {
                        let (input,output) = mapping[low],overlap = NSIntersectionRange(token.range,input)
                        if overlap.length > 0 { patch.addAttribute(.foregroundColor,value:color(token.kind),range:NSRange(location:output.location+overlap.location-input.location,length:overlap.length)) }
                        low += 1
                    }
                }
            }
            oldSource = ""; newSource = ""; oldMap = []; newMap = []
        }
        source.enumerateSubstrings(in:NSRange(location:0,length:source.length),options:.byLines) { line,range,_,_ in
            guard let line else { return }
            if line.hasPrefix("diff --git ") { flush(); inHunk = false }
            if line.hasPrefix("+++ b/"),path == nil { currentPath = String(line.dropFirst(6)) }
            if line.hasPrefix("@@ ") { flush(); inHunk = true; patch.addAttribute(.foregroundColor,value:Theme.accent,range:range); return }
            guard inHunk,let prefix = line.first,[" ","+","-"].contains(prefix) else { return }
            let content = String(line.dropFirst()),length = max(0,range.length-1)
            let output = NSRange(location:range.location+1,length:length)
            if prefix != "+" { oldMap.append((NSRange(location:oldSource.utf16.count,length:length),output)); oldSource += content+"\n" }
            if prefix != "-" { newMap.append((NSRange(location:newSource.utf16.count,length:length),output)); newSource += content+"\n" }
            if prefix != " " {
                let color: NSColor = prefix == "+" ? .systemGreen : .systemRed
                patch.addAttribute(.backgroundColor,value:color.withAlphaComponent(0.13),range:range)
            }
        }
        flush()
        InlineDiff.highlight(patch,removed:.systemRed,added:.systemGreen)
        return patch
    }
}

/// Embedded patches let their outer review own vertical scrolling.
final class GitReviewCodeScroll: NSScrollView {
    var continuous = false
    override func scrollWheel(with event: NSEvent) {
        if continuous,abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            var ancestor = superview
            while let view = ancestor {
                if let outer = view as? NSScrollView { outer.scrollWheel(with:event); return }
                ancestor = view.superview
            }
        }
        super.scrollWheel(with:event)
    }
}
