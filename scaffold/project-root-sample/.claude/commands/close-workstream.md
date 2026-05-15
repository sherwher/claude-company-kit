---
description: Close a workstream and optionally clean up its worktree
argument-hint: [session-id] [cleanup-worktree]
allowed-tools: Bash(bash .company-kit/scripts/close-session.sh:*), Read(.company-runtime/**), Read(.company-artifacts/**)
---

Close the session `$1`.

Rules:

- If `$1` is empty, ask for the session id before running anything.
- If `$2` is `cleanup-worktree`, run `bash .company-kit/scripts/close-session.sh $1 . --cleanup-worktree`.
- Otherwise run `bash .company-kit/scripts/close-session.sh $1`.
- Report whether metadata cleanup finished and whether worktree cleanup was requested.
