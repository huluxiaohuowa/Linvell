// Adapted from Silica (MIT), Copyright (c) 2026 Dinh Quang Hieu.
// See Resources/ThirdPartyNotices.txt.
import Foundation

struct SyntaxPattern: Sendable {
    let kind: SourceTokenKind
    let pattern: String
    /// Capture group to color; 0 colors the whole match.
    let group: Int

    init(_ kind: SourceTokenKind, _ pattern: String, group: Int = 0) {
        self.kind = kind
        self.pattern = pattern
        self.group = group
    }
}

/// A small regex-based grammar.
///
/// Tokenizing runs in two phases:
/// 1. `rules` are matched independently, in order; later rules win where they overlap.
/// 2. `spans` (comments and strings) are matched as one combined, left-to-right scan,
///    so whichever starts first wins (`"//"` inside a string stays a string), and they
///    override everything from phase 1.
///
/// Span patterns must only use non-capturing groups `(?:…)`.
struct SilicaGrammar: @unchecked Sendable {
    private struct Rule {
        let kind: SourceTokenKind
        let regex: NSRegularExpression
        let group: Int
    }

    private let rules: [Rule]
    private let spanRegex: NSRegularExpression?
    private let spanKinds: [SourceTokenKind]

    init(rules: [SyntaxPattern] = [], spans: [SyntaxPattern] = []) {
        let options: NSRegularExpression.Options = [.anchorsMatchLines]
        self.rules = rules.map { pattern in
            Rule(
                kind: pattern.kind,
                // Grammars are static and covered by tests; a bad pattern is a programmer error.
                regex: try! NSRegularExpression(pattern: pattern.pattern, options: options),
                group: pattern.group
            )
        }
        if spans.isEmpty {
            spanRegex = nil
        } else {
            let combined = spans.map { "(\($0.pattern))" }.joined(separator: "|")
            spanRegex = try! NSRegularExpression(pattern: combined, options: options)
        }
        spanKinds = spans.map(\.kind)
    }

    /// Thread-safe; call with an immutable snapshot of the text.
    func tokenize(_ text: NSString, cancelled: () -> Bool) -> [SourceToken] {
        let string = text as String
        let fullRange = NSRange(location: 0, length: text.length)
        var tokens: [SourceToken] = []

        for rule in rules {
            guard !cancelled(), tokens.count < 500_000 else { return [] }
            rule.regex.enumerateMatches(in: string, range: fullRange) { match, _, stop in
                if cancelled() || tokens.count >= 500_000 { stop.pointee = true; return }
                guard let range = match?.range(at: rule.group), range.location != NSNotFound, range.length > 0 else { return }
                tokens.append(SourceToken(range: range, kind: rule.kind))
            }
        }

        if let spanRegex {
            spanRegex.enumerateMatches(in: string, range: fullRange) { match, _, stop in
                if cancelled() || tokens.count >= 500_000 { stop.pointee = true; return }
                guard let match else { return }
                for (index, kind) in spanKinds.enumerated() {
                    let range = match.range(at: index + 1)
                    if range.location != NSNotFound {
                        if range.length > 0 {
                            tokens.append(SourceToken(range: range, kind: kind))
                        }
                        break
                    }
                }
            }
        }

        return tokens
    }
}
