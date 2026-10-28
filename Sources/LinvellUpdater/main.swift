import Foundation
import LinvellCore
import Darwin

if CommandLine.arguments.count == 3,CommandLine.arguments[1] == "--archive-rollback" {
    do {
        _ = try RollbackArchive.retain(previous:URL(fileURLWithPath:CommandLine.arguments[2]))
        print("One compressed rollback version retained."); exit(0)
    } catch { fputs("Rollback archive could not be completed. Original copy was preserved.\n",stderr); exit(1) }
}

guard CommandLine.arguments.count == 2 else { exit(2) }
let jobURL = URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
do {
    let job = try JSONDecoder().decode(InstallJob.self,from:Data(contentsOf:jobURL))
    guard job.parentPID > 1,job.application != job.replacement else { throw UpdateFailure.invalidResponse }
    // Wait for the host to finish its normal unsaved-document and terminal close flow.
    let deadline = Date().addingTimeInterval(120)
    while kill(job.parentPID,0) == 0 {
        if Date() > deadline { throw CocoaError(.userCancelled) }
        Thread.sleep(forTimeInterval:0.2)
    }
    let previous = try SignedUpdate.install(current:job.application,candidate:job.replacement)
    if job.relaunch {
        let launch = Process(); launch.executableURL = URL(fileURLWithPath:"/usr/bin/open"); launch.arguments = ["-n",job.application.path]
        try launch.run(); launch.waitUntilExit()
        if launch.terminationStatus != 0 {
            if renameatx_np(AT_FDCWD,previous.path,AT_FDCWD,job.application.path,UInt32(RENAME_SWAP)) == 0 {
                RollbackArchive.unregister(previous); try? FileManager.default.removeItem(at:previous)
            }
            throw CocoaError(.executableLoad)
        }
    }
    var result = ["status":"installed"]
    do {
        let archive = try RollbackArchive.retain(previous:previous)
        RollbackArchive.removeLegacyCopies(beside:job.application)
        result["previousVersion"] = archive.path
    } catch {
        // The new app has already launched. Never report the installation as failed
        // or delete its recoverable predecessor just because archiving failed.
        RollbackArchive.unregister(previous)
        result["previousVersion"] = previous.path; result["rollbackArchiveError"] = error.localizedDescription
    }
    try JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:jobURL.deletingLastPathComponent().appendingPathComponent("result.json"),options:.atomic)
} catch {
    let result = ["status":"failed","message":error.localizedDescription]
    try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:jobURL.deletingLastPathComponent().appendingPathComponent("result.json"),options:.atomic)
    exit(1)
}
