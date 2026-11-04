import Foundation
import Darwin

/// Descriptor-relative traversal never follows a replacement file or parent-directory symlink.
enum GitSourceReader {
    static func read(root: URL,path: String,limit: Int,allowSymbolicLink: Bool = false) throws -> Data {
        var parent = open(root.resolvingSymlinksInPath().path,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw posix() }
        defer { close(parent) }
        let parts = path.split(separator:"/").filter { $0 != "." }
        guard !parts.isEmpty,!parts.contains("..") else { throw GitError.invalidPath }
        for component in parts.dropLast() {
            let next = openat(parent,String(component),O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard next >= 0 else { throw posix() }
            close(parent); parent = next
        }
        if allowSymbolicLink {
            var info = stat()
            guard fstatat(parent,String(parts.last!),&info,AT_SYMLINK_NOFOLLOW) == 0 else { throw posix() }
            // Git diffs a symlink's target text, never the target file's contents.
            if info.st_mode & S_IFMT == S_IFLNK { return Data() }
        }
        let descriptor = openat(parent,String(parts.last!),O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw posix() }
        let handle = FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor,&before) == 0 else { throw posix() }
        guard before.st_mode & S_IFMT == S_IFREG else { throw GitError.invalidPath }
        guard before.st_size <= limit else { throw GitError.command("File too large for a preview.") }
        var data = Data()
        while data.count <= limit {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount:min(65536,limit+1-data.count)) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw GitError.command("File too large for a preview.") }
        var after = stat(),current = stat()
        guard fstat(descriptor,&after) == 0,
              fstatat(parent,String(parts.last!),&current,AT_SYMLINK_NOFOLLOW) == 0 else { throw posix() }
        func same(_ a: stat,_ b: stat) -> Bool {
            a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mode == b.st_mode && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
        }
        guard same(before,after),same(after,current) else { throw GitError.command("The file changed while loading. Refresh and try again.") }
        return data
    }
    private static func posix() -> NSError { NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
}
