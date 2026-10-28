# Dependency audit

## SwiftTerm

- Upstream: https://github.com/migueldeicaza/SwiftTerm
- Version: v1.10.1
- Commit: `5c83a9d214e7354697624c11deb4e488bdcfabad`
- License: MIT; bundled notice in `Resources/ThirdPartyNotices.txt`.
- Terminal engine and macOS implementation are Swift, using native AppKit/POSIX interfaces. This revision contains no C/C++/Objective-C/Metal implementation files under `Sources/SwiftTerm`.
- Chosen over newer revisions containing Metal shader sources to keep the implementation-language boundary specified by the development plan.
- Swift Argument Parser is resolved for upstream's unused `termcast` executable; it is not linked into Linvell.
- `Package.resolved` pins transitive resolution. Reference Vim is never embedded.

## Product references

Nova 14.1 was downloaded from Panic as the original plan's reference, then exited and moved to Trash after the visual-direction correction. Nova is not the visual acceptance baseline.

The current layout uses the familiar VS Code workspace structure, implemented independently with AppKit. Linvell uses its own gourd mark and four native color profiles; proprietary program code and assets are not used.

The broader Vim target remains Vim 9.2; full upstream behavior coverage and its exact acceptance build are still open. Basic native command tests are not a full compatibility result.
