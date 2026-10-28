import AppKit
import LinvellCore

final class ProjectTools: NSView {
    private let project: URL
    private let tabs: NSSegmentedControl
    private let content = NSStackView()
    private let spinner = NSProgressIndicator()
    private var generation = UUID()
    private let sampler = SystemSampler()
    private var timer: Timer?
    private var refreshing = false
    init(project: URL) {
        self.project = project
        tabs = NSSegmentedControl(labels:["Overview","Runtime & Packages","Git Details","System"].map(L.text),trackingMode:.selectOne,target:nil,action:nil)
        super.init(frame:.zero)
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(refresh)
        let title = Theme.label("Project Tools",size:28,weight:.semibold)
        let name = Theme.label(project.lastPathComponent,size:14,color:Theme.secondary)
        let refreshButton = Theme.actionButton("Refresh",target:self,action:#selector(refresh))
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let header = Theme.stack([Theme.stack([title,name],orientation:.vertical,spacing:5),NSView(),spinner,refreshButton])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 16
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        let page = ToolsPage(); page.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = page
        Theme.pin(content,in:page,inset:2); page.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor).isActive = true
        content.setHuggingPriority(.defaultLow,for:.vertical)
        Theme.pin(Theme.stack([header,tabs,scroll],orientation:.vertical,spacing:22),in:self,inset:30)
        refresh()
        NotificationCenter.default.addObserver(self,selector:#selector(languageApplied),name:L.changed,object:nil)
        timer = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
            guard let self,self.tabs.selectedSegment == 3,self.window?.isVisible == true,!self.refreshing else { return }; self.refresh()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
    @objc private func languageApplied() { L.apply(to:self); refresh() }
    @objc private func refresh() {
        refreshing = true
        let token = UUID(); generation = token; spinner.startAnimation(nil)
        let section = tabs.selectedSegment,project = self.project,sampler = self.sampler
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let snapshot: Result<SystemSnapshot,Error>? = section == 3 ? Result { try sampler.sample() } : nil
            let reports = Self.reports(section:section,project:project,snapshot:snapshot)
            DispatchQueue.main.async { [weak self] in
                guard let self,self.generation == token else { return }
                self.refreshing = false; self.spinner.stopAnimation(nil)
                self.content.arrangedSubviews.forEach { $0.removeFromSuperview() }
                if section == 3,case .success(let sample) = snapshot {
                    let map = CoreHeatmap(loads:sample.cpuLoads)
                    map.widthAnchor.constraint(equalTo:self.content.widthAnchor).isActive = true; self.content.addArrangedSubview(map)
                }
                for report in reports {
                    let card = ToolCard(title:L.text(report.0),body:report.1)
                    card.widthAnchor.constraint(equalTo:self.content.widthAnchor).isActive = true
                    self.content.addArrangedSubview(card)
                }
            }
        }
    }
    private static func run(_ name: String,_ arguments: [String],project: URL) -> String {
        guard let executable = ToolCommand.executable(name) else { return L.format("%@ is not installed or is not on PATH.",name) }
        do {
            let result = try ToolCommand.run(executable,arguments:arguments,directory:project)
            if result.timedOut { return L.text("The command timed out.") }
            if !result.succeeded { return L.format("Command failed (exit %d).\n%@",Int(result.exitCode),result.output) }
            return result.output.isEmpty ? L.text("No results.") : result.output
        } catch { return error.localizedDescription }
    }
    private static func git(_ args: [String],project: URL) -> String { run("git",["--no-optional-locks","-c","core.fsmonitor=false"]+args,project:project) }
    private static func reports(section: Int,project: URL,snapshot: Result<SystemSnapshot,Error>?) -> [(String,String)] {
        switch section {
        case 0:
            let versions = [("Node","node",["--version"]),("npm","npm",["--version"]),("Python","python3",["--version"]),(".NET","dotnet",["--version"]),("Swift","swift",["--version"])].map { title,tool,args in title+"\n"+run(tool,args,project:project) }.joined(separator:"\n\n")
            return [("Installed runtimes",versions),("Git status",git(["status","--short","--branch"],project:project)),("Package health",L.text("Vulnerability and outdated-package scans have not been run. No clean result is assumed."))]
        case 1:
            var reports: [(String,String)] = []
            let node = project.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf:node),let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
                for group in ["dependencies","devDependencies"] {
                    if let packages = value[group] as? [String:String] { reports.append((group,packages.sorted { $0.key < $1.key }.map { $0.key+"  "+$0.value }.joined(separator:"\n"))) }
                }
            }
            let requirements = project.appendingPathComponent("requirements.txt")
            if let text = try? String(contentsOf:requirements,encoding:.utf8) { reports.append(("Python requirements",text)) }
            for filename in [".nvmrc",".node-version",".python-version",".tool-versions","global.json"] {
                if let value = try? String(contentsOf:project.appendingPathComponent(filename),encoding:.utf8) { reports.append((filename,value)) }
            }
            if reports.isEmpty { reports.append(("Project manifests",L.text("No supported manifest was found at this project's root. Package modifications are not implemented yet."))) }
            return reports
        case 2:
            return [("Recent commits",git(["log","-n","15","--date=short","--format=%h  %ad  %s"],project:project)),("Collaborators",git(["shortlog","-sn","HEAD"],project:project)),("Most changed files",mostChanged(project))]
        default:
            let info = ProcessInfo.processInfo
            let memory = ByteCountFormatter.string(fromByteCount:Int64(info.physicalMemory),countStyle:.memory)
            let disk = (try? FileManager.default.attributesOfFileSystem(forPath:project.path)) ?? [:]
            let capacity = (disk[.systemSize] as? NSNumber)?.int64Value ?? 0,free = (disk[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            var result = [("System",info.operatingSystemVersionString+"\n"+L.format("%d logical cores",info.activeProcessorCount)+"\n"+L.format("Physical memory: %@",memory)),("Project volume",L.format("Available: %@\nCapacity: %@",ByteCountFormatter.string(fromByteCount:free,countStyle:.file),ByteCountFormatter.string(fromByteCount:capacity,countStyle:.file)))]
            if case .success(let sample) = snapshot {
                let bytes = { (value: UInt64) in ByteCountFormatter.string(fromByteCount:Int64(value),countStyle:.memory) }
                result.append(("Memory",L.format("Active: %@\nWired: %@\nCompressed: %@\nFree: %@",bytes(sample.activeMemory),bytes(sample.wiredMemory),bytes(sample.compressedMemory),bytes(sample.freeMemory))))
                let rate = { (value: Double?) in value.map { ByteCountFormatter.string(fromByteCount:Int64($0),countStyle:.file)+"/s" } ?? L.text("Collecting samples or counters unavailable.") }
                result.append(("Physical network",L.format("Receive: %@\nSend: %@",rate(sample.networkIn),rate(sample.networkOut))))
                result.append(("Disk activity",L.format("Read: %@\nWrite: %@",rate(sample.diskRead),rate(sample.diskWrite))))
            } else if case .failure(let error) = snapshot { result.append(("Live diagnostics",error.localizedDescription)) }
            return result
        }
    }
    private static func mostChanged(_ project: URL) -> String {
        let value = git(["log","-n","100","--format=","--name-only"],project:project)
        guard !value.contains("fatal:") else { return value }
        let counts = value.split(separator:"\n").reduce(into:[String:Int]()) { $0[String($1),default:0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(20).map { "\($0.value)  \($0.key)" }.joined(separator:"\n")
    }
}

private final class CoreHeatmap: NSView {
    let loads: [Double]?
    private var columns = 1
    init(loads: [Double]?) { self.loads = loads; super.init(frame:.zero); heightAnchor.constraint(greaterThanOrEqualToConstant:72).isActive = true }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        let count = loads?.count ?? ProcessInfo.processInfo.activeProcessorCount
        return NSSize(width:NSView.noIntrinsicMetric,height:CGFloat((count+columns-1)/columns)*58+30)
    }
    override func layout() {
        super.layout(); let next = max(1,Int(bounds.width/76))
        if next != columns { columns = next; invalidateIntrinsicContentSize() }
    }
    override func draw(_ dirtyRect: NSRect) {
        (L.text("CPU · per-core utilization") as NSString).draw(at:NSPoint(x:0,y:0),withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.semibold),.foregroundColor:Theme.accent])
        guard let loads else {
            (L.text("Collecting the first CPU sample…") as NSString).draw(at:NSPoint(x:0,y:28),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:Theme.secondary]); return
        }
        for (index,load) in loads.enumerated() {
            let rect = NSRect(x:CGFloat(index%columns)*76,y:CGFloat(index/columns)*58+28,width:68,height:50)
            Theme.accent.withAlphaComponent(0.12+load*0.8).setFill(); NSBezierPath(roundedRect:rect,xRadius:7,yRadius:7).fill()
            let color = !Theme.profile.isDark && load > 0.6 ? NSColor.white : Theme.foreground
            ("CPU \(index+1)" as NSString).draw(at:NSPoint(x:rect.minX+8,y:rect.minY+6),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:9,weight:.medium),.foregroundColor:color])
            (String(format:"%.0f%%",load*100) as NSString).draw(at:NSPoint(x:rect.minX+8,y:rect.minY+23),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:13,weight:.semibold),.foregroundColor:color])
        }
    }
}

private final class ToolsPage: NSView { override var isFlipped: Bool { true } }

private final class ToolCard: NSView {
    init(title: String,body: String) {
        super.init(frame:.zero); wantsLayer = true; layer?.backgroundColor = Theme.panel.cgColor
        layer?.borderColor = Theme.secondary.withAlphaComponent(0.2).cgColor; layer?.borderWidth = 1; layer?.cornerRadius = 10
        let heading = Theme.label(title,size:14,color:Theme.accent,weight:.semibold)
        let value = NSTextField(wrappingLabelWithString:body); value.isSelectable = true; value.font = .monospacedSystemFont(ofSize:12,weight:.regular); value.textColor = Theme.foreground
        Theme.pin(Theme.stack([heading,value],orientation:.vertical,spacing:12),in:self,inset:20)
    }
    required init?(coder: NSCoder) { fatalError() }
}
