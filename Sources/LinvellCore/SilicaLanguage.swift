// Adapted from Silica (MIT), Copyright (c) 2026 Dinh Quang Hieu.
// See Resources/ThirdPartyNotices.txt.
import Foundation

/// Languages the editor can highlight, detected from the file name.
enum SilicaLanguage: String, Sendable, CaseIterable {
    case swift, javascript, typescript, json, python, ruby, go, rust
    case c, cpp, objectiveC, java, kotlin, csharp, php
    case shell, yaml, toml, html, xml, css, markdown, sql, dockerfile, makefile

    init?(url: URL) {
        let name = url.lastPathComponent.lowercased()
        switch name {
        case "dockerfile", "containerfile": self = .dockerfile; return
        case "makefile", "gnumakefile": self = .makefile; return
        case "gemfile", "rakefile", "podfile", "fastfile", "brewfile": self = .ruby; return
        case ".zshrc", ".bashrc", ".bash_profile", ".zprofile", ".profile", ".envrc": self = .shell; return
        case ".gitignore", ".gitattributes", ".editorconfig", ".npmrc", ".env": self = .toml; return
        default: break
        }
        if name.hasPrefix("dockerfile.") { self = .dockerfile; return }

        switch url.pathExtension.lowercased() {
        case "swift", "swiftinterface": self = .swift
        case "js", "mjs", "cjs", "jsx": self = .javascript
        case "ts", "mts", "cts", "tsx": self = .typescript
        case "json", "jsonc", "json5", "xcproj", "babelrc", "eslintrc", "webmanifest": self = .json
        case "py", "pyi", "pyw": self = .python
        case "rb", "rake", "gemspec", "podspec": self = .ruby
        case "go": self = .go
        case "rs": self = .rust
        case "c", "h": self = .c
        case "cc", "cpp", "cxx", "hpp", "hh", "hxx", "ipp": self = .cpp
        case "m", "mm": self = .objectiveC
        case "java": self = .java
        case "kt", "kts": self = .kotlin
        case "cs": self = .csharp
        case "php": self = .php
        case "sh", "bash", "zsh", "fish", "command": self = .shell
        case "yml", "yaml": self = .yaml
        case "toml", "ini", "cfg", "conf", "properties", "xcconfig", "env": self = .toml
        case "html", "htm", "xhtml", "vue", "svelte": self = .html
        case "xml", "plist", "svg", "xib", "storyboard", "entitlements", "xcscheme", "xsd", "rss", "atom":
            self = .xml
        case "css", "scss", "sass", "less": self = .css
        case "md", "markdown", "mdx", "mdown": self = .markdown
        case "sql": self = .sql
        case "mk": self = .makefile
        default: return nil
        }
    }

    /// The language named on a Markdown code fence, e.g. ```swift or ```js.
    init?(fenceName: String) {
        let name = fenceName.lowercased().trimmingCharacters(in: .whitespaces)
        let aliases: [String: String] = [
            "javascript": "js", "typescript": "ts", "python": "py", "ruby": "rb", "rust": "rs",
            "objc": "m", "objective-c": "m", "objectivec": "m", "c++": "cpp", "csharp": "cs",
            "c#": "cs", "kotlin": "kt", "shell": "sh", "console": "sh", "yaml": "yml",
            "markdown": "md", "golang": "go",
        ]
        switch name {
        case "dockerfile", "docker": self = .dockerfile
        case "makefile", "make": self = .makefile
        default:
            guard !name.isEmpty, let language = SilicaLanguage(url: URL(filePath: "x." + (aliases[name] ?? name))) else {
                return nil
            }
            self = language
        }
    }

    var grammar: SilicaGrammar {
        switch self {
        case .swift: Grammars.swift
        case .javascript, .typescript: Grammars.javaScript
        case .json: Grammars.json
        case .python: Grammars.python
        case .ruby: Grammars.ruby
        case .go: Grammars.go
        case .rust: Grammars.rust
        case .c, .cpp, .objectiveC: Grammars.cFamily
        case .java: Grammars.java
        case .kotlin: Grammars.kotlin
        case .csharp: Grammars.csharp
        case .php: Grammars.php
        case .shell: Grammars.shell
        case .yaml: Grammars.yaml
        case .toml: Grammars.toml
        case .html, .xml: Grammars.markup
        case .css: Grammars.css
        case .markdown: Grammars.markdown
        case .sql: Grammars.sql
        case .dockerfile: Grammars.dockerfile
        case .makefile: Grammars.makefile
        }
    }
}

// MARK: - Shared patterns

private enum P {
    static let lineComment = ##"//.*"##
    static let blockComment = ##"/\*[\s\S]*?(?:\*/|\z)"##
    /// `#` comment that starts a line or follows whitespace (so `$#` / `a#b` aren't comments).
    static let hashComment = ##"(?:^|(?<=\s))#.*"##
    static let doubleString = ##""(?:\\.|[^"\\\n])*""##
    static let singleString = ##"'(?:\\.|[^'\\\n])*'"##
    static let tripleDouble = ##""""[\s\S]*?(?:"""|\z)"##
    static let tripleSingle = ##"'''[\s\S]*?(?:'''|\z)"##
    static let backtick = ##"`(?:\\.|[^`\\])*`"##
    static let number = ##"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)[a-zA-Z]*\b"##
    static let capitalized = ##"\b[A-Z][A-Za-z0-9_]*\b"##
    static let call = ##"\b([A-Za-z_]\w*)\s*(?=\()"##

    static func words(_ list: String) -> String {
        "\\b(?:" + list.split(separator: " ").joined(separator: "|") + ")\\b"
    }

    static func declared(after keyword: String) -> String {
        "\\b(?:\(keyword))\\s+([A-Za-z_]\\w*)"
    }
}

// MARK: - Grammars

private enum Grammars {
    static let swift = SilicaGrammar(
        rules: [
            SyntaxPattern(.function, P.call, group: 1),
            SyntaxPattern(.function, P.declared(after: "func"), group: 1),
            SyntaxPattern(.type, P.capitalized),
            SyntaxPattern(.number, P.number),
            SyntaxPattern(.attribute, ##"@\w+"##),
            SyntaxPattern(.keyword, P.words("""
                associatedtype class deinit enum extension fileprivate func import init inout internal let \
                open operator private precedencegroup protocol public rethrows static struct subscript typealias \
                var break case catch continue default defer do else fallthrough for guard if in repeat return \
                throw switch where while as Any await async false is nil self Self super throws true try actor \
                some any isolated consuming borrowing mutating nonmutating override final lazy weak \
                unowned required convenience dynamic indirect optional get set willSet didSet macro package \
                sending each
                """)),
            SyntaxPattern(.preprocessor, ##"#\w+"##),
        ],
        spans: [
            SyntaxPattern(.comment, P.blockComment),
            SyntaxPattern(.comment, P.lineComment),
            SyntaxPattern(.string, P.tripleDouble),
            SyntaxPattern(.string, P.doubleString),
        ]
    )

    static let javaScript = SilicaGrammar(
        rules: [
            SyntaxPattern(.function, P.call, group: 1),
            SyntaxPattern(.type, P.capitalized),
            SyntaxPattern(.number, P.number),
            SyntaxPattern(.attribute, ##"@\w+"##),
            SyntaxPattern(.keyword, P.words("""
                break case catch class const continue debugger default delete do else export extends finally \
                for function if import in instanceof let new return super switch this throw try typeof var void \
                while with yield async await of static get set from as true false null undefined NaN Infinity \
                interface type enum implements private protected public readonly abstract declare namespace \
                module keyof infer is satisfies override any unknown never string number boolean bigint symbol \
                object asserts accessor
                """)),
        ],
        spans: [
            SyntaxPattern(.comment, P.blockComment),
            SyntaxPattern(.comment, P.lineComment),
            SyntaxPattern(.string, P.backtick),
            SyntaxPattern(.string, P.doubleString),
            SyntaxPattern(.string, P.singleString),
        ]
    )

    static let json = SilicaGrammar(
        rules: [
            SyntaxPattern(.number, ##"-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"##),
            SyntaxPattern(.keyword, P.words("true false null")),
        ],
        spans: [
            SyntaxPattern(.comment, P.blockComment),
            SyntaxPattern(.comment, P.lineComment),
            SyntaxPattern(.property, ##""(?:\\.|[^"\\\n])*"(?=\s*:)"##),
            SyntaxPattern(.string, P.doubleString),
        ]
    )

    static let python = SilicaGrammar(
        rules: [
            SyntaxPattern(.function, P.call, group: 1),
            SyntaxPattern(.type, P.capitalized),
            SyntaxPattern(.type, P.words("int str float bool bytes list dict set tuple object type complex frozenset bytearray")),
            SyntaxPattern(.function, P.declared(after: "def"), group: 1),
            SyntaxPattern(.type, P.declared(after: "class"), group: 1),
            SyntaxPattern(.number, P.number),
            SyntaxPattern(.attribute, ##"^[ \t]*@[\w.]+"##),
            SyntaxPattern(.keyword, P.words("""
                False None True and as assert async await break class continue def del elif else except \
                finally for from global if import in is lambda nonlocal not or pass raise return try while \
                with yield match case self cls
                """)),
        ],
        spans: [
            SyntaxPattern(.comment, ##"#.*"##),
            SyntaxPattern(.string, ##"(?:[rRbBuUfF]{1,2})?"""[\s\S]*?(?:"""|\z)"##),
            SyntaxPattern(.string, ##"(?:[rRbBuUfF]{1,2})?'''[\s\S]*?(?:'''|\z)"##),
            SyntaxPattern(.string, ##"(?:[rRbBuUfF]{1,2})?"(?:\\.|[^"\\\n])*""##),
            SyntaxPattern(.string, ##"(?:[rRbBuUfF]{1,2})?'(?:\\.|[^'\\\n])*'"##),
        ]
    )

    static let ruby = SilicaGrammar(
        rules: [
            SyntaxPattern(.type, P.capitalized),
            SyntaxPattern(.function, P.declared(after: "def"), group: 1),
            SyntaxPattern(.number, P.number),
            SyntaxPattern(.attribute, ##"(?<![:\w]):[A-Za-z_]\w*[?!]?"##),
            SyntaxPattern(.variable, ##"@{1,2}\w+|\$\w+"##),
            SyntaxPattern(.keyword, P.words("""
                alias and begin break case class def do else elsif end ensure false for if in module next nil \
                not or redo rescue retry return self super then true undef unless until when while yield \
                require require_relative attr_accessor attr_reader attr_writer private protected public lambda \
                proc puts raise
                """)),
        ],
        spans: [
            SyntaxPattern(.comment, ##"^=begin[\s\S]*?(?:^=end|\z)"##),
            SyntaxPattern(.comment, P.hashComment),
            SyntaxPattern(.string, P.doubleString),
            SyntaxPattern(.string, P.singleString),
        ]
    )

    static let go = SilicaGrammar(
        rules: [
            SyntaxPattern(.type, P.capitalized),
            SyntaxPattern(.type, P.words("""
                bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string \
                uint uint8 uint16 uint32 uint64 uintptr any comparable
                """)),
            SyntaxPattern(.function, P.call, group: 1),
            SyntaxPattern(.number, P.number),
            SyntaxPattern(.keyword, P.words("""
                break case chan const continue default defer else fallthrough for func go goto if import \
                interface map package range return select struct switch type var true false nil iota
                """)),
        ],
        spans: [
            SyntaxPattern(.comment, P.blockComment),
            SyntaxPattern(.comment, P.lineComment),
            SyntaxPattern(.string, P.backtick),
            SyntaxPattern(.string, P.doubleString),
            SyntaxPattern(.string, ##"'(?:\\.|[^'\\\n])+'"##),
        ]
    )

    static let rust = SilicaGrammar(
        rules: [
            SyntaxPattern(.function, P.call, group: 1),
            SyntaxPattern(.type, P.capitalized),
            SyntaxPattern(.type, P.words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str")),
            SyntaxPattern(.number, P.number),
            SyntaxPattern(.preprocessor, ##"\b[a-z_]\w*!(?=\s*[(\[{])"##),
            SyntaxPattern(.attribute, ##"#!?\[[^\]\n]*\]"##),
            SyntaxPattern(.attribute, ##"'[a-zA-Z_]\w*\b(?!')"##),
            SyntaxPattern(.keyword, P.words("""
                as async await break const continue crate dyn else enum extern false fn for if impl in let \
                loop match mod move mut pub ref return self Self static struct super trait true type unsafe \
                use where while union
                """)),
        ],
        spans: [
            SyntaxPattern(.comment, P.blockComment),
            SyntaxPattern(.comment, P.lineComment),
            SyntaxPattern(.string, ##"b?"(?:\\.|[^"\\])*""##),
            SyntaxPattern(.string, ##"b?'(?:\\.|[^'\\\n])'"##),
        ]
    )

    static let cFamily = SilicaGrammar(
        rules: [
            SyntaxPattern(.function, P.call, group: 1),
            SyntaxPattern(.type, P.capitalized),
            SyntaxPattern(.number, P.number),
            SyntaxPattern(.keyword, ##"@\w+"##),
            SyntaxPattern(.keyword, P.words("""
                auto break case char const continue default do double else enum extern float for goto if \
                inline int long register restrict return short signed sizeof static struct switch typedef \
                union unsigned void volatile while bool true false NULL nullptr class namespace template \
                typename public private protected virtual override final friend operator new delete this \
                throw try catch using constexpr consteval constinit noexcept static_cast dynamic_cast \
                reinterpret_cast const_cast decltype explicit mutable concept requires co_await co_return \
                co_yield thread_local alignas alignof wchar_t size_t self super id nil YES NO instancetype \
                BOOL SEL IMP nonatomic atomic strong weak copy assign readonly readwrite nullable nonnull
                """)),
            SyntaxPattern(.preprocessor, ##"^[ \t]*#[ \t]*\w+"##),
            SyntaxPattern(.string, ##"^[ \t]*#[ \t]*(?:include|import)[ \t]*(<[^>\n]*>)"##, group: 1),
        ],
        spans: [
            SyntaxPattern(.comment, P.blockComment),
            SyntaxPattern(.comment, P.lineComment),
            SyntaxPattern(.string, ##"@?"(?:\\.|[^"\\\n])*""##),
            SyntaxPattern(.string, ##"'(?:\\.|[^'\\\n])+'"##),
        ]
    )

    static let java = SilicaGrammar(
        rules: [
            SyntaxPattern(.function, P.call, group: 1),
            SyntaxPattern(.type, P.capitalized),
            SyntaxPattern(.number, P.number),
            SyntaxPattern(.attribute, ##"@\w+"##),
            SyntaxPattern(.keyword, P.words("""
                abstract assert boolean break byte case catch char class const continue default do double \
                else enum extends final finally float for goto if implements import instanceof int interface \
                long native new package private protected public return short static strictfp super switch \
                synchronized this throw throws transient try void volatile while true false null var record \
                sealed permits yield
                """)),
        ],
        spans: [
            SyntaxPattern(.comment, P.blockComment),
            SyntaxPattern(.comment, P.lineComment),
            SyntaxPattern(.string, P.tripleDouble),
            SyntaxPattern(.string, P.doubleString),
            SyntaxPattern(.string, ##"'(?:\\.|[^'\\\n])+'"##),
        ]
    )

    static let kotlin = SilicaGrammar(
        rules: [
            SyntaxPattern(.function, P.call, group: 1),
            SyntaxPattern(.function, P.declared(after: "fun"), group: 1),
            SyntaxPattern(.type, P.capitalized),
            SyntaxPattern(.number, P.number),
            SyntaxPattern(.attribute, ##"@\w+"##),
            SyntaxPattern(.keyword, P.words("""
                as break class continue do else false for fun if in interface is null object package return \
                super this throw true try typealias typeof val var when while by catch constructor finally get \
                import init set where actual abstract annotation companion const crossinline data enum expect \
                external final infix inline inner internal lateinit noinline open operator out override \
                private protected public reified sealed suspend tailrec vararg it
                """)),
        ],
        spans: [
            SyntaxPattern(.comment, P.blockComment),
            SyntaxPattern(.comment, P.lineComment),
            SyntaxPattern(.string, P.tripleDouble),
            SyntaxPattern(.string, P.doubleString),
            SyntaxPattern(.string, ##"'(?:\\.|[^'\\\n])+'"##),
        ]
    )

    static let csharp = SilicaGrammar(
        rules: [
            SyntaxPattern(.function, P.call, group: 1),
            SyntaxPattern(.type, P.capitalized),
            SyntaxPattern(.number, P.number),
            SyntaxPattern(.attribute, ##"^[ \t]*\[[A-Z][^\]\n]*\]"##),
            SyntaxPattern(.keyword, P.words("""
                abstract as base bool break byte case catch char checked class const continue decimal default \
                delegate do double else enum event explicit extern false finally fixed float for foreach goto \
                if implicit in int interface internal is lock long namespace new null object operator out \
                override params private protected public readonly ref return sbyte sealed short sizeof \
                stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe \
                ushort using virtual void volatile while var async await dynamic get set value yield record \
                init required global nameof when with not and or
                """)),
            SyntaxPattern(.preprocessor, ##"^[ \t]*#[ \t]*\w+"##),
        ],
        spans: [
            SyntaxPattern(.comment, P.blockComment),
            SyntaxPattern(.comment, P.lineComment),
            SyntaxPattern(.string, ##"@"(?:""|[^"])*""##),
            SyntaxPattern(.string, ##"\$?"(?:\\.|[^"\\\n])*""##),
            SyntaxPattern(.string, ##"'(?:\\.|[^'\\\n])+'"##),
        ]
    )

    static let php = SilicaGrammar(
        rules: [
            SyntaxPattern(.function, P.call, group: 1),
            SyntaxPattern(.type, P.capitalized),
            SyntaxPattern(.number, P.number),
            SyntaxPattern(.variable, ##"\$\w+"##),
            SyntaxPattern(.preprocessor, ##"<\?(?:php|=)?|\?>"##),
            SyntaxPattern(.keyword, P.words("""
                abstract and array as break callable case catch class clone const continue declare default do \
                echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final \
                finally fn for foreach function global goto if implements include include_once instanceof \
                insteadof interface isset list match namespace new or print private protected public readonly \
                require require_once return static switch throw trait try unset use var while xor yield true \
                false null self parent enum
                """)),
        ],
        spans: [
            SyntaxPattern(.comment, P.blockComment),
            SyntaxPattern(.comment, P.lineComment),
            SyntaxPattern(.comment, P.hashComment),
            SyntaxPattern(.string, P.doubleString),
            SyntaxPattern(.string, P.singleString),
        ]
    )

    static let shell = SilicaGrammar(
        rules: [
            SyntaxPattern(.function, ##"^[ \t]*(?:function[ \t]+)?([A-Za-z_][\w-]*)[ \t]*\(\)"##, group: 1),
            SyntaxPattern(.number, ##"\b\d+\b"##),
            SyntaxPattern(.variable, ##"\$\{[^}\n]*\}|\$[A-Za-z_]\w*|\$[0-9@#?*$!-]"##),
            SyntaxPattern(.keyword, P.words("""
                if then else elif fi for while until do done case esac in function return local export source \
                alias unset declare readonly select time break continue exit eval exec shift trap set test \
                echo printf cd read
                """)),
        ],
        spans: [
            SyntaxPattern(.comment, P.hashComment),
            SyntaxPattern(.string, ##""(?:\\.|[^"\\])*""##),
            SyntaxPattern(.string, ##"'[^']*'"##),
        ]
    )

    static let yaml = SilicaGrammar(
        rules: [
            SyntaxPattern(.number, ##"(?<![\w.-])-?\d+(?:\.\d+)?(?![\w.-])"##),
            SyntaxPattern(.keyword, ##"(?i)(?<![\w-])(?:true|false|yes|no|on|off|null)(?![\w-])"##),
            SyntaxPattern(.attribute, ##"[&*][\w-]+"##),
            SyntaxPattern(.preprocessor, ##"^(?:---|\.\.\.)[ \t]*$"##),
            SyntaxPattern(.property, ##"^[ \t]*(?:-[ \t]+)?([\w$.\-/]+(?:[ \t]+[\w$.\-/]+)*)[ \t]*:(?=[ \t]|$)"##, group: 1),
        ],
        spans: [
            SyntaxPattern(.comment, P.hashComment),
            SyntaxPattern(.string, P.doubleString),
            SyntaxPattern(.string, ##"'(?:''|[^'\n])*'"##),
        ]
    )

    static let toml = SilicaGrammar(
        rules: [
            SyntaxPattern(.number, ##"(?<![\w.-])[+-]?\d[\d_]*(?:\.\d+)?(?![\w.-])"##),
            SyntaxPattern(.keyword, P.words("true false")),
            SyntaxPattern(.property, ##"^[ \t]*([\w.\-]+)[ \t]*="##, group: 1),
            SyntaxPattern(.type, ##"^[ \t]*\[\[?[^\]\n]*\]\]?"##),
        ],
        spans: [
            SyntaxPattern(.comment, ##"(?:(?:^|(?<=\s))#.*|^[ \t]*;.*)"##),
            SyntaxPattern(.string, P.tripleDouble),
            SyntaxPattern(.string, P.tripleSingle),
            SyntaxPattern(.string, P.doubleString),
            SyntaxPattern(.string, ##"'[^'\n]*'"##),
        ]
    )

    static let markup = SilicaGrammar(
        rules: [
            SyntaxPattern(.tag, ##"</?([A-Za-z][\w:.\-]*)"##, group: 1),
            SyntaxPattern(.attribute, ##"(?<=\s)([A-Za-z_:@][\w:.\-]*)(?=\s*=)"##, group: 1),
            SyntaxPattern(.string, ##"=\s*("[^"]*"|'[^']*')"##, group: 1),
            SyntaxPattern(.number, ##"&(?:\w+|#\d+|#x[0-9a-fA-F]+);"##),
            SyntaxPattern(.preprocessor, ##"<![A-Za-z][^>]*>|<\?[\s\S]*?\?>"##),
        ],
        spans: [
            SyntaxPattern(.comment, ##"<!--[\s\S]*?(?:-->|\z)"##),
            SyntaxPattern(.string, ##"<!\[CDATA\[[\s\S]*?(?:\]\]>|\z)"##),
        ]
    )

    static let css = SilicaGrammar(
        rules: [
            SyntaxPattern(.type, ##"(?<![\w-])\.[A-Za-z_-][\w-]*"##),
            SyntaxPattern(.function, ##"\b([\w-]+)\("##, group: 1),
            SyntaxPattern(.property, ##"^[ \t]*([A-Za-z-]+)[ \t]*:(?![^;\n]*\{)"##, group: 1),
            SyntaxPattern(.property, ##"[{;][ \t]*([A-Za-z-]+)[ \t]*:"##, group: 1),
            SyntaxPattern(.number, ##"(?<![\w#.-])-?\d*\.?\d+(?:px|em|rem|vh|vw|vmin|vmax|ch|ex|pt|pc|cm|mm|in|ms|s|deg|rad|turn|fr|dpi|dppx|%)?"##),
            SyntaxPattern(.number, ##"#[0-9a-fA-F]{3,8}\b"##),
            SyntaxPattern(.variable, ##"--[\w-]+|\$[\w-]+"##),
            SyntaxPattern(.keyword, ##"@[\w-]+|!important"##),
        ],
        spans: [
            SyntaxPattern(.comment, P.blockComment),
            SyntaxPattern(.string, P.doubleString),
            SyntaxPattern(.string, P.singleString),
        ]
    )

    static let markdown = SilicaGrammar(
        rules: [
            SyntaxPattern(.heading, ##"^#{1,6}[ \t].*$"##),
            SyntaxPattern(.comment, ##"^[ \t]*>.*$"##),
            SyntaxPattern(.comment, ##"^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$"##),
            SyntaxPattern(.keyword, ##"^[ \t]*(?:[-*+]|\d+[.)])(?=[ \t])"##),
            SyntaxPattern(.attribute, ##"(\*\*|__)(?=\S)[^\n]*?\S\1"##),
            SyntaxPattern(.link, ##"!?\[[^\]\n]*\]\([^)\n]*\)|<https?://[^>\s]+>"##),
        ],
        spans: [
            SyntaxPattern(.string, ##"^[ \t]*```[\s\S]*?(?:^[ \t]*```|\z)"##),
            SyntaxPattern(.string, ##"^[ \t]*~~~[\s\S]*?(?:^[ \t]*~~~|\z)"##),
            SyntaxPattern(.comment, ##"<!--[\s\S]*?(?:-->|\z)"##),
            SyntaxPattern(.string, ##"`[^`\n]+`"##),
        ]
    )

    static let sql = SilicaGrammar(
        rules: [
            SyntaxPattern(.function, P.call, group: 1),
            SyntaxPattern(.number, P.number),
            SyntaxPattern(.keyword, "(?i)" + P.words("""
                select from where insert into values update set delete create table alter drop index view \
                join inner left right outer full cross on as and or not null is in exists between like ilike \
                group by order having limit offset union all distinct primary key foreign references default \
                unique check constraint case when then else end begin commit rollback transaction returning \
                with if replace asc desc true false integer int bigint smallint text varchar char boolean \
                date timestamp numeric real serial cascade trigger function procedure return returns
                """)),
        ],
        spans: [
            SyntaxPattern(.comment, ##"--.*"##),
            SyntaxPattern(.comment, P.blockComment),
            SyntaxPattern(.string, ##"'(?:''|[^'])*'"##),
            SyntaxPattern(.property, ##""[^"\n]*"|`[^`\n]*`"##),
        ]
    )

    static let dockerfile = SilicaGrammar(
        rules: [
            SyntaxPattern(.variable, ##"\$\{[^}\n]*\}|\$[A-Za-z_]\w*"##),
            SyntaxPattern(.keyword, ##"(?i)^[ \t]*(?:FROM|RUN|CMD|LABEL|MAINTAINER|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)\b|\bAS\b"##),
        ],
        spans: [
            SyntaxPattern(.comment, ##"^[ \t]*#.*"##),
            SyntaxPattern(.string, P.doubleString),
            SyntaxPattern(.string, P.singleString),
        ]
    )

    static let makefile = SilicaGrammar(
        rules: [
            SyntaxPattern(.function, ##"^([^\s:#=][^:#=\n]*?)[ \t]*:(?!=)"##, group: 1),
            SyntaxPattern(.property, ##"^[ \t]*([\w.]+)[ \t]*(?:[:+?!]?=)"##, group: 1),
            SyntaxPattern(.variable, ##"\$\([^)\n]*\)|\$\{[^}\n]*\}|\$[@<^?*%+]"##),
            SyntaxPattern(.keyword, ##"^[ \t]*-?(?:include|ifeq|ifneq|ifdef|ifndef|else|endif|define|endef|export|override)\b"##),
        ],
        spans: [
            SyntaxPattern(.comment, P.hashComment),
            SyntaxPattern(.string, P.doubleString),
            SyntaxPattern(.string, P.singleString),
        ]
    )
}
