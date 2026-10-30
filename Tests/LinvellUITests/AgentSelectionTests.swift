import XCTest
import AppKit
import SwiftTerm
@testable import Linvell
@testable import LinvellCore

final class AgentSelectionTests: XCTestCase {
    private func pump(_ seconds: TimeInterval) { RunLoop.current.run(until:Date().addingTimeInterval(seconds)) }
    func testProviderSelectionChangesTheDisplayedTerminalAndExplainsMissingTask() throws {
        _ = NSApplication.shared
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/agent-test-fixtures/selection-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let view = AgentWorkspace(project:root.path,remote:nil,autoLoad:false)
        let keys = AgentKind.allCases.flatMap { ["agentCLI.local."+$0.rawValue+".path","agentCLI.local."+$0.rawValue+".home"] }
        let previous = keys.map { UserDefaults.standard.object(forKey:$0) }
        defer { view.shutdown(); for (key,value) in zip(keys,previous) { UserDefaults.standard.set(value,forKey:key) }; try? FileManager.default.removeItem(at:root) }
        view.path.stringValue = "/bin/cat"; view.agentHome.stringValue = root.path; view.startNew()
        let codex = try XCTUnwrap(view.terminal),codexPID = codex.process.shellPid
        view.kindPicker.selectItem(at:AgentKind.allCases.firstIndex(of:.pi)!); view.selectionChanged()
        XCTAssertNil(view.terminal); XCTAssertNil(codex.superview); XCTAssertTrue(codex.process.running); XCTAssertFalse(view.stop.isEnabled)
        view.path.stringValue = "/bin/cat"; view.agentHome.stringValue = root.path; view.startNew()
        let pi = try XCTUnwrap(view.terminal)
        XCTAssertFalse(pi === codex)
        view.kindPicker.selectItem(at:AgentKind.allCases.firstIndex(of:.dsh)!); view.selectionChanged()
        XCTAssertNil(view.terminal); XCTAssertNil(pi.superview); XCTAssertTrue(pi.process.running)
        XCTAssertTrue(view.newSession.isEnabled); let count = view.runtimes.count
        view.startNew()
        XCTAssertEqual(view.runtimes.count,count)
        XCTAssertEqual(view.status.stringValue,L.text("Enter a DSH task, then create or resume a session."))
        view.openSessions.selectItem(at:0); view.selectOpenSession()
        XCTAssertEqual(view.kind,.codex); XCTAssertTrue(view.terminal === codex)
        XCTAssertTrue(codex.superview === view.terminalHost); XCTAssertEqual(codex.process.shellPid,codexPID)
        view.openSessions.selectItem(at:1); view.selectOpenSession()
        XCTAssertEqual(view.kind,.pi); XCTAssertTrue(view.terminal === pi); XCTAssertNil(codex.superview)
    }
    func testLiveProviderAndLocationMatrixChecksRenderedTerminalNotJustSelectorValues() throws {
        guard let file = ProcessInfo.processInfo.environment["LINVELL_SSH_FIXTURE"] else { throw XCTSkip("Disposable SSH selection fixture required") }
        _ = NSApplication.shared
        let fixture = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:file))) as! [String:String]
        let host = try XCTUnwrap(fixture["host"]),remoteRoot = try XCTUnwrap(fixture["root"]),remote = try SSHRemote(host:host)
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("dev/build/linvell/agent-test-fixtures/matrix-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let view = AgentWorkspace(project:remoteRoot,remote:remote,autoLoad:false)
        let kinds: [AgentKind] = [.codex,.pi,.dsh]
        var keys: [String] = []
        for kind in kinds { for source in ["local",host] {
            keys.append("agentCLI.\(source).\(kind.rawValue).path")
            keys.append("agentCLI.\(source).\(kind.rawValue).home")
        } }
        let previous = keys.map { UserDefaults.standard.object(forKey:$0) }
        defer { view.shutdown(); for (key,value) in zip(keys,previous) { UserDefaults.standard.set(value,forKey:key) }; try? FileManager.default.removeItem(at:root) }
        // Existing local runtimes can be reattached even when their old sync connection is
        // absent. New local creation still follows the real synchronization prerequisite.
        for kind in kinds {
            for ssh in [false,true] {
                let cli = ssh ? remoteRoot+"/fixture-running-agent" : "/bin/cat"
                let home = ssh ? remoteRoot+"/isolated-agent-home" : root.path
                let term = DisplayPacedTerminalView(frame:NSRect(x:0,y:0,width:800,height:500))
                let runtime = AgentRuntime(context:.init(kind:kind,host:ssh ? host : nil,executable:cli,home:home),session:nil,directory:ssh ? remoteRoot : root.path,remote:ssh ? remote : nil,mapping:nil,terminal:term)
                view.register(runtime)
                if ssh {
                    term.startProcess(executable:"/usr/bin/ssh",args:["-tt","--",host,RunTasks.remoteCommand(directory:remoteRoot,command:"exec "+SSHRemote.quote(cli))])
                } else { term.startProcess(executable:cli,currentDirectory:root.path) }
            }
        }
        pump(1)
        let pids = view.runtimes.map { $0.terminal.process.shellPid }
        XCTAssertEqual(Set(pids).count,6); XCTAssertTrue(view.runtimes.allSatisfy { $0.terminal.process.running })
        for kind in kinds {
            for ssh in [false,true,false,true] {
                view.kindPicker.selectItem(at:AgentKind.allCases.firstIndex(of:kind)!); view.location.selectedSegment = ssh ? 1 : 0; view.selectionChanged()
                let expected = try XCTUnwrap(view.runtimes.first { $0.context.kind == kind && ($0.context.host != nil) == ssh })
                XCTAssertTrue(view.activeRuntime === expected); XCTAssertTrue(view.terminal === expected.terminal)
                XCTAssertTrue(expected.terminal.superview === view.terminalHost)
                XCTAssertEqual(view.terminalHost.subviews.filter { $0 is LocalProcessTerminalView }.count,1)
                XCTAssertTrue(view.scope.stringValue.hasPrefix(ssh ? host : L.text("This Mac")))
                XCTAssertTrue(view.openSessions.titleOfSelectedItem?.contains(kind.title) == true)
                XCTAssertTrue(view.openSessions.titleOfSelectedItem?.contains(ssh ? host : L.text("This Mac")) == true)
                XCTAssertTrue(view.stop.isEnabled); XCTAssertTrue(view.kindPicker.isEnabled); XCTAssertTrue(view.location.isEnabled)
                XCTAssertEqual(view.runtimes.map { $0.terminal.process.shellPid },pids)
                XCTAssertTrue(view.runtimes.allSatisfy { $0.terminal.process.running })
            }
        }
        view.openSessions.selectItem(at:0); view.selectOpenSession()
        XCTAssertEqual(view.kind,.codex); XCTAssertFalse(view.usesSSH)
        let stopped = try XCTUnwrap(view.terminal); view.stopAgent()
        view.openSessions.selectItem(at:3); view.selectOpenSession()
        XCTAssertEqual(view.kind,.pi); XCTAssertTrue(view.usesSSH); XCTAssertTrue(view.terminal === view.runtimes[3].terminal)
        pump(1.3)
        XCTAssertFalse(stopped.process.running)
        XCTAssertTrue(view.runtimes.dropFirst().allSatisfy { $0.terminal.process.running })
        view.shutdown(); pump(0.2); XCTAssertFalse(view.running)
    }
}

extension AgentSelectionTests {
    func testConflictReviewOpensBothVersionsInCurrentWorkspaceAndRejectsEscapes() throws {
        _ = NSApplication.shared
        let view = AgentWorkspace(project:"/remote/project",remote:try SSHRemote(host:"fixture-review"),autoLoad:false)
        defer { view.shutdown() }
        view.mapping = AgentSyncMapping(host:"fixture-review",remoteRoot:"/remote/project",localRoot:"/private/local-replica")
        var opened: [(String,String?)] = []
        view.onOpenFile = { path,remote,_ in opened.append((path,remote?.host)) }
        view.reviewConflict("src/file.swift")
        XCTAssertEqual(opened.map(\.0),["/private/local-replica/src/file.swift","/remote/project/src/file.swift"])
        XCTAssertNil(opened[0].1); XCTAssertEqual(opened[1].1,"fixture-review")
        view.reviewConflict("../../outside"); view.reviewConflict("/absolute"); view.reviewConflict("")
        XCTAssertEqual(opened.count,2)
    }
    func testLocalSSHSetupHasVisibleInstallInstructionsAndActionableNewSession() throws {
        _ = NSApplication.shared
        let view = AgentWorkspace(project:"/remote/setup-project",remote:try SSHRemote(host:"fixture-setup-host"),autoLoad:false)
        defer { view.shutdown() }
        view.location.selectedSegment = 0; view.selectionChanged()
        view.path.stringValue = "/bin/cat"
        XCTAssertTrue(view.newSession.isEnabled)
        XCTAssertFalse(view.syncGuide.isHidden)
        XCTAssertTrue(view.syncGuide.isDescendant(of:view.terminalHost))
        XCTAssertFalse(view.connectSync.isHidden)
        let preview = NSView(frame:NSRect(x:0,y:0,width:1280,height:860))
        view.frame = NSRect(x:320,y:0,width:960,height:860)
        view.configurationView.frame = NSRect(x:0,y:0,width:320,height:860)
        preview.addSubview(view); preview.addSubview(view.configurationView)
        let window = NSWindow(contentRect:preview.frame,styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named:Theme.isDark ? .darkAqua : .aqua)
        window.contentView = preview; window.setFrameOrigin(NSPoint(x:-10000,y:-10000)); window.orderFrontRegardless()
        defer { window.close() }
        preview.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        XCTAssertTrue(view.bounds.contains(view.syncGuide.convert(view.syncGuide.bounds,to:view)))
        let bitmap = try XCTUnwrap(preview.bitmapImageRepForCachingDisplay(in:preview.bounds))
        preview.cacheDisplay(in:preview.bounds,to:bitmap)
        let artifactRoot = URL(fileURLWithPath:ProcessInfo.processInfo.environment["LINVELL_UI_ARTIFACT_DIR"] ?? (NSHomeDirectory()+"/dev/build/linvell/agent-ui"))
        try FileManager.default.createDirectory(at:artifactRoot,withIntermediateDirectories:true)
        let png = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        try png.write(to:artifactRoot.appendingPathComponent("agent-install-guide.png"))
        let supportRoot = artifactRoot.appendingPathComponent("mutagen-support-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:supportRoot,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:supportRoot) }
        let cli = supportRoot.appendingPathComponent("mutagen")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to:cli)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:cli.path)
        view.syncGuide.update(support:AgentSyncSupport.detect(environment:["PATH":supportRoot.path]))
        XCTAssertEqual(view.syncGuide.availability.textColor,NSColor.systemGreen)
        XCTAssertTrue(view.syncGuide.availability.stringValue.contains("local agents can edit remote code"))
        XCTAssertTrue(view.syncGuide.command.isHidden); XCTAssertTrue(view.syncGuide.copy.isHidden)
        view.syncGuide.update(support:AgentSyncSupport.detect(environment:["PATH":""]))
        XCTAssertFalse(view.syncGuide.command.isHidden); XCTAssertFalse(view.syncGuide.copy.isHidden)
        XCTAssertNotEqual(view.syncGuide.availability.textColor,NSColor.systemGreen)
        XCTAssertEqual(AgentSyncSupport.installCommand,"brew install mutagen-io/mutagen/mutagen")
        XCTAssertEqual(AgentSyncSupport.installationGuide.host,"mutagen.io")
        XCTAssertTrue(view.syncGuide.instructions.isEnabled); XCTAssertTrue(view.syncGuide.copy.isEnabled)
        view.syncGuide.recheck.performClick(nil)
        XCTAssertTrue(view.syncGuide.availability.stringValue.contains("Mutagen"))
        if AgentSyncSupport.detect().executable == nil {
            view.newSession.performClick(nil)
            let deadline = Date().addingTimeInterval(3)
            while !view.newSession.isEnabled,Date() < deadline { pump(0.02) }
            XCTAssertTrue(view.newSession.isEnabled)
            XCTAssertNil(view.terminal); XCTAssertTrue(view.runtimes.isEmpty)
            XCTAssertTrue(view.status.stringValue.contains("Mutagen"),"Missing installation must be explained instead of a silent disabled button.")
        }
    }
}
