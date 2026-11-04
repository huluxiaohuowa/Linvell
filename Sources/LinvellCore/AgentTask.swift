import Foundation
import CryptoKit

/// A task owns only the worktree it creates. Existing worktrees remain user-owned.
public struct AgentTask: Codable, Equatable {
    public let id: UUID
    public let title: String
    public let directory: String
    public let branch: String
    public let commonDirectory: String
    /// Canonical original owned directory; set only when an owned task worktree moves.
    public var originalDirectory: String? = nil
}

public struct AgentTaskStore {
    public let directory: URL
    public init(directory: URL = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Linvell/Tasks",isDirectory:true)) { self.directory = directory }
    private func common(_ repository: GitRepository) throws -> String {
        guard repository.remote == nil else { throw GitError.command("Task workspaces currently require a local repository.") }
        return try repository.run(["rev-parse","--path-format=absolute","--git-common-dir"]).trimmingCharacters(in:.newlines)
    }
    private func bucket(_ common: String) -> URL {
        directory.appendingPathComponent(SHA256.hash(data:Data(common.utf8)).map { String(format:"%02x",$0) }.joined(),isDirectory:true)
    }
    private func validated(_ url: URL) -> AgentTask? {
        guard let values = try? url.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey]),values.isSymbolicLink != true,values.isRegularFile == true,
              let data = try? Data(contentsOf:url),let task = try? JSONDecoder().decode(AgentTask.self,from:data),
              url.standardizedFileURL == bucket(task.commonDirectory).appendingPathComponent(task.id.uuidString+".json").standardizedFileURL,
              (task.originalDirectory ?? task.directory) == bucket(task.commonDirectory).appendingPathComponent(task.id.uuidString).path else { return nil }
        return task
    }
    private func records() -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey])) ?? []
        return folders.flatMap { folder -> [URL] in
            guard let values = try? folder.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]),values.isDirectory == true,values.isSymbolicLink != true else { return [] }
            return ((try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []).filter { $0.pathExtension == "json" }
        }
    }
    public func task(at path: String) -> AgentTask? {
        let canonical = URL(fileURLWithPath:path).standardizedFileURL.path
        guard let task = records().compactMap(validated).first(where:{ $0.directory == canonical }) else { return nil }
        let repo = GitRepository(root:URL(fileURLWithPath:canonical))
        guard (try? common(repo)) == task.commonDirectory,
              (try? repo.worktrees().contains(where:{ $0.path == canonical && $0.branch == task.branch && !$0.prunable })) == true else { return nil }
        return task
    }
    public func relocateWorktree(from old: String,to path: String) throws {
        for record in records() {
            guard let task = validated(record),task.directory == old else { continue }
            let repo = GitRepository(root:URL(fileURLWithPath:path))
            guard try common(repo) == task.commonDirectory,
                  try repo.worktrees().contains(where:{ $0.path == path && $0.branch == task.branch && !$0.prunable }) else { throw GitError.command("The moved task no longer matches its registered worktree.") }
            var moved = AgentTask(id:task.id,title:task.title,directory:path,branch:task.branch,commonDirectory:task.commonDirectory)
            moved.originalDirectory = task.originalDirectory ?? task.directory
            try JSONEncoder().encode(moved).write(to:record,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:record.path)
        }
    }
    public func tasks(in repository: GitRepository) throws -> [AgentTask] {
        let common = try common(repository),worktrees = try worktrees(in:repository)
        let records = (try? FileManager.default.contentsOfDirectory(at:bucket(common),includingPropertiesForKeys:nil)) ?? []
        return records.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let task = validated(url) else { return nil }
            return task.commonDirectory == common && worktrees.contains(task.directory) ? task : nil
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    public func worktrees(in repository: GitRepository) throws -> [String] {
        _ = try common(repository)
        return try repository.run(["worktree","list","--porcelain","-z"]).split(separator:"\0").compactMap {
            $0.hasPrefix("worktree ") ? String($0.dropFirst(9)) : nil
        }
    }
    public func create(title: String,in repository: GitRepository) throws -> AgentTask {
        let title = title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !title.isEmpty,title.count <= 120,!title.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }) else { throw GitError.command("Enter a task name (1–120 characters).") }
        let common = try common(repository),id = UUID(),folder = bucket(common)
        let path = folder.appendingPathComponent(id.uuidString,isDirectory:true)
        let slug = title.lowercased().split(whereSeparator:{ !$0.isASCII || !$0.isLetter && !$0.isNumber }).prefix(8).joined(separator:"-")
        let branch = "codex/"+(slug.isEmpty ? "task" : String(slug.prefix(45)))+"-"+id.uuidString.prefix(8).lowercased()
        let task = AgentTask(id:id,title:title,directory:path.path,branch:branch,commonDirectory:common)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let record = folder.appendingPathComponent(id.uuidString+".json")
        try JSONEncoder().encode(task).write(to:record,options:.atomic)
        do { _ = try repository.run(["worktree","add","-b",branch,"--",path.path,"HEAD"],timeout:60) }
        catch { try? FileManager.default.removeItem(at:record); throw error }
        return task
    }
    /// Git refuses dirty/locked trees. Never force removal or delete the branch.
    public func remove(_ task: AgentTask,in repository: GitRepository) throws {
        let common = try common(repository),folder = bucket(common)
        let expected = folder.appendingPathComponent(task.id.uuidString).path
        let record = folder.appendingPathComponent(task.id.uuidString+".json")
        guard task.commonDirectory == common,(task.originalDirectory ?? task.directory) == expected,
              try repository.worktrees().contains(where:{ $0.path == task.directory && $0.branch == task.branch && !$0.prunable }),
              try JSONDecoder().decode(AgentTask.self,from:Data(contentsOf:record)) == task else { throw GitError.command("Only Linvell-created task workspaces can be removed here.") }
        _ = try repository.run(["worktree","remove","--",task.directory],timeout:60)
        // Retain the record as task history; tasks(in:) lists only registered live worktrees.
    }
}
