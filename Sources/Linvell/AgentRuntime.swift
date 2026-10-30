import AppKit
import SwiftTerm
import LinvellCore

/// A session owns its PTY and terminal buffer independently of the visible selection.
final class AgentRuntime {
    struct Context: Equatable {
        let kind: AgentKind
        let host: String?
        let executable: String
        let home: String
    }
    let context: Context
    var sessionID: String?
    var dshView: AgentDSHView?
    var contentView: NSView { dshView ?? terminal }
    let remote: SSHRemote?
    let mapping: AgentSyncMapping?
    let terminal: LocalProcessTerminalView
    let links: AgentTerminalDelegate
    var directory: String
    var title: String
    var exitCode: Int32?
    init(context: Context,session: AgentSession?,directory: String,remote: SSHRemote?,mapping: AgentSyncMapping?,terminal: LocalProcessTerminalView) {
        self.context = context; sessionID = session?.id; self.directory = directory; self.remote = remote; self.mapping = mapping
        title = session?.title ?? L.text("New Session"); self.terminal = terminal
        links = AgentTerminalDelegate(terminal); terminal.terminalDelegate = links
    }
}

/// Forward the existing SwiftTerm delegate contract, replacing only link routing.
/// A subclass method cannot replace SwiftTerm's protocol-extension witness.
final class AgentTerminalDelegate: TerminalViewDelegate {
    weak var terminal: LocalProcessTerminalView?
    var onOpen: ((String) -> Void)?
    init(_ terminal: LocalProcessTerminalView) { self.terminal = terminal }
    func sizeChanged(source: TerminalView,newCols: Int,newRows: Int) { terminal?.sizeChanged(source:source,newCols:newCols,newRows:newRows) }
    func setTerminalTitle(source: TerminalView,title: String) { terminal?.setTerminalTitle(source:source,title:title) }
    func hostCurrentDirectoryUpdate(source: TerminalView,directory: String?) { terminal?.hostCurrentDirectoryUpdate(source:source,directory:directory) }
    func send(source: TerminalView,data: ArraySlice<UInt8>) { terminal?.send(source:source,data:data) }
    func scrolled(source: TerminalView,position: Double) { terminal?.scrolled(source:source,position:position) }
    func clipboardCopy(source: TerminalView,content: Data) { terminal?.clipboardCopy(source:source,content:content) }
    func rangeChanged(source: TerminalView,startY: Int,endY: Int) { terminal?.rangeChanged(source:source,startY:startY,endY:endY) }
    func requestOpenLink(source: TerminalView,link: String,params: [String:String]) { onOpen?(link) }
}

struct AgentFileLink {
    let path: String
    let line: Int?
    static func resolve(_ value: String,directory: String) -> AgentFileLink? {
        var text = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty,!text.contains("\0"),!text.contains("\n") else { return nil }
        var line: Int?
        if text.hasPrefix("file://") {
            guard let url = URL(string:text),url.isFileURL else { return nil }
            if let fragment = url.fragment { line = Int(fragment.hasPrefix("L") ? String(fragment.dropFirst()) : fragment) }
            text = url.path
        } else if text.contains("://") { return nil }
        if let match = text.range(of:#":([0-9]+)(?::[0-9]+)?$"#,options:.regularExpression) {
            line = Int(text[match].dropFirst().split(separator:":")[0]); text.removeSubrange(match)
        }
        guard !text.isEmpty else { return nil }
        let path = text.hasPrefix("/") ? text : (directory as NSString).appendingPathComponent(text)
        return AgentFileLink(path:(path as NSString).standardizingPath,line:line)
    }
}
