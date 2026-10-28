# Linvell 0.1.4 verification — 2026-10-28

- Native AppKit regression reproduces the original Project Tools constraint exception; card attachment now precedes activating shared-ancestor constraints. Overview and System/CPU cards both load.
- Hidden native views render light/dark Git graph and working changes with a real disposable merge repository. File labels remain inside their own rows; long paths truncate. Core tests stage and unstage one of two independent hunks without modifying the working file.
- Native WebKit/source views verify Markdown scrolling in both directions. Source block markers and a private client-world script coordinate scrolling while author JavaScript remains disabled.
- Activity selection is exclusive; raster output verifies visible selected indicators in light/dark themes. Local and SSH workspace records round-trip. Finder-open regression reuses the supplied workspace, and startup choice retains the stored location while permitting an empty window.
- Disposable real SSH fixture covers lazy expansion through two directory levels, unchanged remote project root, restored remote workspace, Unicode read/write/conflict protection, run/stop, loopback forwarding, preview HTML and remote service exit. No Git command is run on the remote fixture host.
- Swift Vim command composition is compared with system Vim using disposable fixtures. Native tests cover Chinese insertion/dot/undo, macro playback, replacement/backspace, visual text objects/counts/find and multi-caret text-object/count operations. System Vim is a test oracle only.
- Line editing tests cover adjacent and separate selections, Unicode columns, deletion at EOF, comment/indent round trips and native undo.
- Rollback tests verify one compressed archive after successive updates, latest-older-version migration, removal of old app bundles and preservation of an in-flight newer candidate.

Logs and fixture screenshots are stored outside the repository under the local build directory. Release signing, notarization, public artifact and website checks are recorded after packaging; unit tests alone do not establish those results.

Remaining limits include full Vim/VS Code compatibility, the full Vim regex/Ex language, remapping, visual/Replace macros, complete block-register semantics and full Git-client history rewriting/conflict editing. SSH authentication relies on existing system keys/agent/configuration. Physical Intel runtime, all display refresh rates, all mouse gestures and arbitrary SSH jump/auth topologies are not claimed tested.
