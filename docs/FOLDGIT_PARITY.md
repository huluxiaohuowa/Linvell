# FoldGit source comparison

The comparison uses FoldGit commit dcd533d494d03ccb288d8614b31ec771fbf2a720 and Linvell 0.2.17. FoldGit's original MIT copyright and permission text are included in the app's ThirdPartyNotices.txt.

| Workflow | Linvell entry and behavior | Verification |
| --- | --- | --- |
| Repository organization | Git → Repositories, clone/open, folder import, display aliases, groups, archive/restore, drag ordering | Native repository-picker tests and disposable Git clone |
| Working changes | Working/staged lists, directory folding and staging, file/hunk/all staging and unstaging, commit, amend, templates, snippets | Real Git index operations and native controls |
| History | Current/all refs, repository-wide background search, cached batches, pagination, HEAD navigation, branch/tag and commit actions | Old-branch/CJK search and transport tests |
| Directory review | Git → Repository Review, file filter, syntax-highlighted source with line numbers, file history, first-parent merge patches, source opening, refresh | Native panel tests and live SSH source preview |
| Multiple patches | Git → Review Changed Files, individual or bulk patch expansion, separate folder folding | Native multi-patch rendering and screenshots |
| Image comparison | Before/After preview for working changes, commits and reference comparisons | Binary-preserving local/SSH blob tests and native image views |
| Revision comparison | Branch/tag picker selects two refs and opens the shared review surface | Real Git path and patch comparison |
| Large source files | Explicit plain-text load for files up to the editor's 16 MiB preview boundary | Bounded source read tests |
| Diff presentation | Unified/side-by-side/automatic modes, line wrapping, inline change highlighting | Native layout and Unicode tests |
| Worktrees | Discovery, open/create/move/lock/unlock/remove/prune, target selection, merge conflict comparison/edit/continue/abort | Real local Git and actual SSH workflows |
| Cleanup | Ancestor and content-equivalence checks, per-item choices, ignored-file preview, guarded local branch deletion | Squash cleanup, changed HEAD and new ignored-file regressions |
| Status | Visible worktree refresh and changed-file/ahead/behind detail, pause background refresh | Native state and real Git status |
| Diagnostics | Search command records, filter failures, export, operation-to-record links | Operation-correlated journal and native log tests |
| Sync/settings | Fetch/pull/push, Auto Fetch interval and last success, failure detail, graph/time/default expansion, external applications | Native settings and existing Git transport |
| Menus/shortcuts | Git menu for references, worktrees, review, diagnostics, Fetch and settings | Native menu targets |

Linvell uses its existing editor, AppKit views and SSH transport. Command journals retain command names, timing, outcomes and operation identifiers. File contents and credential-bearing arguments remain outside the journal.

The SSH acceptance fixture runs a real OpenSSH server on an isolated loopback port with disposable keys. It exercises the production SSH argument-vector and JSON file protocols. It covers source previews, binary blobs, whole-repository search, hunks, commit, comparison, conflicts and worktree cleanup. Build and test artifacts stay under the local build directory.
