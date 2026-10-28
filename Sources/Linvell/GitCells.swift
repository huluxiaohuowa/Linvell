import AppKit
import LinvellCore

final class GitFileCell: NSTableCellView {
    let name = Theme.label("",size:13,weight:.medium)
    let path = Theme.label("",size:11,color:Theme.secondary)
    let badge = NSTextField(labelWithString:"")
    init(change: GitChange) {
        super.init(frame:.zero); clipsToBounds = true
        let icon = FileIcon.view(for:URL(fileURLWithPath:change.path))
        name.stringValue = URL(fileURLWithPath:change.path).lastPathComponent; path.stringValue = change.path
        let status: String,color: NSColor
        if change.conflicted { status = "Conflict"; color = .systemRed }
        else if change.index == "?" { status = "Untracked"; color = .systemTeal }
        else if change.index == "R" || change.worktree == "R" { status = "Renamed"; color = .systemBlue }
        else if change.index == "D" || change.worktree == "D" { status = "Deleted"; color = .systemRed }
        else if change.index == "A" { status = "Added"; color = .systemGreen }
        else { status = "Modified"; color = .systemOrange }
        badge.stringValue = L.text(status); badge.font = .systemFont(ofSize:10,weight:.semibold); badge.textColor = color
        badge.wantsLayer = true; badge.layer?.backgroundColor = color.withAlphaComponent(0.13).cgColor; badge.layer?.cornerRadius = 4
        badge.alignment = .center; badge.identifier = NSUserInterfaceItemIdentifier("Git.status")
        for field in [name,path,badge] {
            field.maximumNumberOfLines = 1; field.usesSingleLineMode = true
            field.lineBreakMode = field === path ? .byTruncatingMiddle : .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        }
        for view in [icon,name,path,badge] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo:leadingAnchor,constant:12),icon.centerYAnchor.constraint(equalTo:centerYAnchor),
            name.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:10),name.topAnchor.constraint(equalTo:topAnchor,constant:10),name.heightAnchor.constraint(equalToConstant:18),
            name.trailingAnchor.constraint(lessThanOrEqualTo:badge.leadingAnchor,constant:-8),
            badge.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-10),badge.centerYAnchor.constraint(equalTo:name.centerYAnchor),badge.heightAnchor.constraint(equalToConstant:20),
            badge.widthAnchor.constraint(equalToConstant:max(48,badge.intrinsicContentSize.width+12)),
            path.leadingAnchor.constraint(equalTo:name.leadingAnchor),path.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-10),path.topAnchor.constraint(equalTo:name.bottomAnchor,constant:3),path.heightAnchor.constraint(equalToConstant:16)
        ])
        setAccessibilityLabel(L.text(status)+" · "+change.path)
        toolTip = change.path
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class GitHistoryCell: NSTableCellView {
    init(commit: GitCommit,row: GitGraphRow,lanes: Int) {
        super.init(frame:.zero); clipsToBounds = true
        let graph = GitGraphView(row)
        let title = Theme.label(commit.subject,size:13,weight:.medium)
        let detail = Theme.label(String(commit.hash.prefix(8))+" · "+commit.author+" · "+String(commit.date.prefix(10))+(commit.refs.isEmpty ? "" : " · "+commit.refs),size:11,color:Theme.secondary)
        for label in [title,detail] { label.maximumNumberOfLines = 1; label.usesSingleLineMode = true; label.lineBreakMode = .byTruncatingTail }
        for view in [graph,title,detail] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            graph.leadingAnchor.constraint(equalTo:leadingAnchor,constant:8),graph.centerYAnchor.constraint(equalTo:centerYAnchor),
            title.leadingAnchor.constraint(equalTo:leadingAnchor,constant:CGFloat(max(2,lanes))*14+30),title.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-12),title.topAnchor.constraint(equalTo:topAnchor,constant:10),title.heightAnchor.constraint(equalToConstant:18),
            detail.leadingAnchor.constraint(equalTo:title.leadingAnchor),detail.trailingAnchor.constraint(equalTo:title.trailingAnchor),detail.topAnchor.constraint(equalTo:title.bottomAnchor,constant:3),detail.heightAnchor.constraint(equalToConstant:16)
        ])
        toolTip = commit.refs+"\n"+commit.subject; setAccessibilityLabel(commit.subject+" · "+commit.author)
    }
    required init?(coder: NSCoder) { fatalError() }
}
