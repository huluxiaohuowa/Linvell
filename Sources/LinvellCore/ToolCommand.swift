import Foundation
import Darwin

public struct ToolResult {
    public let output: String
    public let exitCode: Int32
    public let timedOut: Bool
    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

/// Executes an argument vector without a shell. Call off the main thread.
public enum ToolCommand {
    public static func executable(_ name: String) -> URL? {
        let folders = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").split(separator:":").map(String.init)+["/opt/homebrew/bin","/usr/local/bin","/usr/bin","/bin"]
        return folders.map { URL(fileURLWithPath:$0).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath:$0.path) }
    }
    public static func run(_ executable: URL,arguments: [String],directory: URL?,timeout: TimeInterval = 12,environment overrides: [String:String] = [:],input: Data? = nil,inputFile: URL? = nil,outputFile: URL? = nil,trimOutput: Bool = true,maximumOutputBytes: Int = 1024*1024,started: ((Process) -> Void)? = nil) throws -> ToolResult {
        let output = outputFile ?? FileManager.default.temporaryDirectory.appendingPathComponent("linvell-tool-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath:output.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forUpdating:output)
        defer { try? handle.close(); if outputFile == nil { try? FileManager.default.removeItem(at:output) } }
        let process = Process(),finished = DispatchSemaphore(value:0)
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
        process.standardOutput = handle; process.standardError = handle; process.standardInput = FileHandle.nullDevice
        let inputURL = output.appendingPathExtension("input")
        var inputHandle: FileHandle?
        defer { try? inputHandle?.close(); try? FileManager.default.removeItem(at:inputURL) }
        if let input {
            guard FileManager.default.createFile(atPath:inputURL.path,contents:input,attributes:[.posixPermissions:0o600]) else { throw CocoaError(.fileWriteUnknown) }
            inputHandle = try FileHandle(forReadingFrom:inputURL); process.standardInput = inputHandle
        } else if let inputFile {
            inputHandle = try FileHandle(forReadingFrom:inputFile); process.standardInput = inputHandle
        }
        process.terminationHandler = { _ in finished.signal() }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"; environment["DOTNET_SKIP_FIRST_TIME_EXPERIENCE"] = "1"
        environment.merge(overrides,uniquingKeysWith:{ _,new in new })
        process.environment = environment
        try process.run()
        started?(process)
        var timedOut = false,tooLarge = false
        if outputFile != nil {
            let deadline = Date().addingTimeInterval(timeout)
            while finished.wait(timeout:.now()+0.1) == .timedOut {
                tooLarge = ((try? output.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) > maximumOutputBytes
                timedOut = Date() >= deadline
                if tooLarge || timedOut { break }
            }
        } else { timedOut = finished.wait(timeout:.now()+timeout) == .timedOut }
        if timedOut || tooLarge {
            process.terminate()
            if finished.wait(timeout:.now()+1) == .timedOut { kill(process.processIdentifier,SIGKILL); process.waitUntilExit() }
        }
        if tooLarge { throw CocoaError(.fileReadTooLarge) }
        if outputFile != nil,((try? output.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) > maximumOutputBytes { throw CocoaError(.fileReadTooLarge) }
        if outputFile != nil { return ToolResult(output:"",exitCode:process.terminationStatus,timedOut:timedOut) }
        try handle.seek(toOffset:0)
        let bytes = try handle.read(upToCount:maximumOutputBytes+1) ?? Data()
        guard bytes.count <= maximumOutputBytes else { throw CocoaError(.fileReadTooLarge) }
        let raw = String(decoding:bytes,as:UTF8.self)
        let text = trimOutput ? raw.trimmingCharacters(in:.whitespacesAndNewlines) : raw
        return ToolResult(output:text,exitCode:process.terminationStatus,timedOut:timedOut)
    }
}
