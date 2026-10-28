import Foundation

public struct RunTask: Codable {
    public let label: String
    public let command: String
    public init(label: String,command: String) { self.label = label; self.command = command }
}
public enum RunTasks {
    public static func discover(at root: URL) -> [RunTask] {
        var tasks: [RunTask] = []
        if let data = try? Data(contentsOf:root.appendingPathComponent("package.json")),let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any],let scripts = object["scripts"] as? [String:String] {
            tasks += scripts.keys.sorted().map { RunTask(label:"npm: "+$0,command:"npm run "+SSHRemote.quote($0)) }
        }
        if let data = try? Data(contentsOf:root.appendingPathComponent(".vscode/tasks.json")),let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any],let entries = object["tasks"] as? [[String:Any]] {
            for entry in entries {
                guard let command = entry["command"] as? String,let label = entry["label"] as? String else { continue }
                guard entry["dependsOn"] == nil,entry["options"] == nil,
                      entry["args"] == nil || entry["args"] is [String] else { continue }
                let arguments = entry["args"] as? [String] ?? []
                guard !command.contains("${"),!arguments.contains(where:{ $0.contains("${") }) else { continue }
                let args = arguments.map(SSHRemote.quote).joined(separator:" ")
                let executable = (entry["type"] as? String) == "process" ? SSHRemote.quote(command) : command
                tasks.append(RunTask(label:label,command:executable+(args.isEmpty ? "" : " "+args)))
            }
        }
        if FileManager.default.fileExists(atPath:root.appendingPathComponent("Package.swift").path) { tasks += [RunTask(label:"Swift: run",command:"swift run"),RunTask(label:"Swift: test",command:"swift test")] }
        if FileManager.default.fileExists(atPath:root.appendingPathComponent("Makefile").path) { tasks.append(RunTask(label:"Make",command:"make")) }
        return tasks
    }
    public static func directoryExpression(_ path: String) -> String {
        if path == "~" { return "\"$HOME\"" }
        if path.hasPrefix("~/") { return "\"$HOME\"/"+SSHRemote.quote(String(path.dropFirst(2))) }
        return SSHRemote.quote(path)
    }
    public static func remoteCommand(directory: String,command: String) -> String {
        "/bin/sh -lc "+SSHRemote.quote("cd -- "+directoryExpression(directory)+" && exec \"${SHELL:-/bin/sh}\" -lc "+SSHRemote.quote(command))
    }
    public static func remoteShell(directory: String) -> String {
        "/bin/sh -lc "+SSHRemote.quote("cd -- "+directoryExpression(directory)+" && exec \"${SHELL:-/bin/sh}\" -l")
    }
}
