# SwiftTerm source provenance

Upstream: https://github.com/migueldeicaza/SwiftTerm
Pinned revision: 5c83a9d214e7354697624c11deb4e488bdcfabad (1.10.1)
License: MIT; retained in LICENSE and source headers.

Only the library sources are included. The macOS TerminalView exposes an optional displayUpdateScheduler callback, and queuePendingDisplay delegates to it when supplied. Linvell supplies one display-paced scheduler shared by all views in a window. The original fallback remains for clients which do not configure it. This avoids altering an ephemeral SwiftPM checkout or carrying an unconditional 60 Hz delay in the application.
