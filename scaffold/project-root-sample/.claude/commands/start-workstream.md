---
description: Start or reuse a company workstream session
argument-hint: [optional session-id] [optional topic]
allowed-tools: Bash(bash .company-kit/scripts/prepare-session.sh:*), Bash(bash .company-kit/scripts/recommend-routing.sh:*), Bash(git worktree list:*), Read(.company-project/**), Read(project-work/**), Read(START_HERE.md)
---

Prepare or reuse the current session.

Rules:

- If `$1` is empty and Claude is already running inside an attached runner (tmux or cmux), use the current session name as the session id (tmux session name for tmux; `cmux current-workspace` for cmux).
- If `$1` is empty and Claude is not inside an attached runner, generate a short session id from the topic.
- Before starting, quickly check `START_HERE.md`, `.company-project/project-standards.md`, and `project-work/00-project/working-agreements.md` if they exist.
- Run `bash .company-kit/scripts/prepare-session.sh $1 "$2"` when a topic exists, otherwise run `bash .company-kit/scripts/prepare-session.sh $1`.
- If a topic was also provided in `$ARGUMENTS`, run `bash .company-kit/scripts/recommend-routing.sh "$2"` and use it to recommend the most likely primary worker.
- Report only:
  - session name
  - current cost mode
  - worktree path if present
  - `leader-session.md` path
  - recommended next command
  - one short natural-language request the user can say next
