# Plugin P4/P5 acceptance — 0.2.0

2026-10-29. Protocol 1 remains backward compatible with P1/P2/P3. Linvell is still a macOS application; Linux artifacts are plugin programs.

## Delivered interfaces

- Optional manifest `languageServers`, `tasks`, `debuggers`, `execution` and `executables`. Programs use validated package-relative executable paths, target maps and argv arrays, with workspaceFolder expansion. No implicit tool downloads, project scanning or task execution on load.
- Language providers reuse the native LSP client for completion, diagnostics, navigation, rename, formatting, version validation and cancellation. Explicitly loaded providers take precedence for their language IDs; overlapping plugin ownership is rejected. Custom file extensions map to the provider's first language. Stop/reload removes providers and restores built-in services.
- Explicit task execution in owned native terminal windows, including output/input, Stop and close cleanup. Programs run on the selected execution host in the project directory.
- DAP framed stdio launch interface with the current source line as an initial breakpoint, continue/pause/step controls, stack/scopes/variables and evaluation. Adapter output/stderr and command/event log records use a bounded, memory-only 256 KiB buffer.
- Default local execution keeps UI plugins on the Mac. Workspace execution follows the SSH project host, with local AppKit rendering. Supported target keys are macos-arm64, macos-x86_64, linux-x86_64 and linux-aarch64. Remote hosts require Python 3 and the selected executable's runtime dependencies.
- Remote executable files are explicitly selected from the manifest, bounded to 64 MiB each / 128 MiB total, SHA-256 checked and staged under the remote build directory. A supervisor forwards framed stdio and reaps the child process group on EOF/HUP/TERM. Stop cancels pending RPCs and transfer processes. Failures keep logs/reconnect entries; explicit reconnect creates a fresh session. Tasks are never automatically replayed. Workspace changes stop contributed programs.
- `Sources/LinvellPluginKit/Package.swift` is an independent, Foundation-only SDK package. HelloPlugin no longer depends on the editor/AppKit package. `Examples/ToolPlugin` is a runnable C/clangd/lldb-dap example.

## Evidence

- Focused plugin/service selection: 35 tests, one environment-gated skip, zero failures. Includes seven P4/P5 Core tests and a native ownership/routing test, plus all existing plugin P1/P2/P3 checks.
- Real clangd launched through a plugin runtime: definition, hover, rename, formatting and cancellation accepted. Real lldb-dap launched a compiled C program, stopped, returned stack/scopes/evaluation and disconnected.
- Real SSH Linux x86_64 execution: verified transfer, repeated command replies, stopped transport rejection, stopped session rejection and a fresh reconnected session succeeded. A Linux Swift SDK example was separately compiled on the Linux machine with Swift 6.0.3, statically linked Swift runtime and stripped, then transferred by the actual runtime and exercised for handshake, storage-backed greeting and Unicode document transformation. The executable still links system libc/libm/libstdc++/libgcc. The build machine needed its installed GCC 11 library search path because an incomplete GCC 12 directory was selected by default.
- Visible local QA: loaded C Tools Example; native task compiled and ran main.c, printed `Linvell plugin task: 7` and exited 0. Command-W closed only the task window. Debug main stopped at the source breakpoint, showed `count = 7`, and evaluating `count + 1` returned 8; stopping/closing returned to the unchanged editor.
- Website source has bilingual language/tool, debugging/log and SSH/Linux sections. Section anchors and three release metadata tests passed. Publication and signed release evidence are recorded after packaging.

## Scope limits

- Providers use standard LSP programs, not arbitrary in-process callbacks. Plugin language tools inherit the existing LSP client support and explicit edit workflow; unsolicited workspace/applyEdit stays rejected.
- DAP supports launch with internal-console adapters. Attach, reverse runInTerminal, changing breakpoints during a session, arbitrary VS Code debug extension compatibility, and a full graphical variable inspector are not included. The current window shows formatted stack/variable text and evaluation results.
- Remote transfers include only explicitly declared executable files. Programs must be self-contained or use preinstalled system tools/libraries. Resources and native views stay local. No server daemon, credentials, remote toolchain installer, sandbox, marketplace or automatic update system is added.
- Linux x86_64 was physically exercised. Linux aarch64 target selection is supported but an aarch64 binary/device run was not performed. Network cable loss was not simulated; actual SSH process termination, EOF and explicit reconnection were exercised. No automatic replay or exactly-once guarantee is claimed.
