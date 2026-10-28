import Foundation
import LinvellCore
import Darwin

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
    let result = ["status":"installed","previousVersion":previous.path]
    try JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:jobURL.deletingLastPathComponent().appendingPathComponent("result.json"),options:.atomic)
    if job.relaunch {
        let launch = Process(); launch.executableURL = URL(fileURLWithPath:"/usr/bin/open"); launch.arguments = ["-n",job.application.path]
        try launch.run(); launch.waitUntilExit()
        if launch.terminationStatus != 0 {
            _ = renameatx_np(AT_FDCWD,previous.path,AT_FDCWD,job.application.path,UInt32(RENAME_SWAP))
            throw CocoaError(.executableLoad)
        }
    }
} catch {
    let result = ["status":"failed","message":error.localizedDescription]
    try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys).write(to:jobURL.deletingLastPathComponent().appendingPathComponent("result.json"),options:.atomic)
    exit(1)
}
