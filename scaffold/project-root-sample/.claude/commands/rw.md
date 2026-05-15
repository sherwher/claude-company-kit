---
description: Short alias for run-workers
argument-hint: [topic]
allowed-tools: Bash(bash .company-kit/scripts/run-session.sh:*), Bash(bash .company-kit/scripts/spawn-readiness-check.sh:*), Bash(bash .company-kit/scripts/spawn-telemetry-log.sh:*), Bash(tmux display-message:*), Bash(tmux list-panes:*), Read(.company-runtime/**), Read(.company-project/**), Read(project-work/**)
---

Run the company workers for this topic: $ARGUMENTS

Rules:

- Use the same behavior as `/run-workers`.
- If no topic was provided, ask only for a one-line topic.
- Prefer the current attached runner session (tmux or cmux) when available.
- If not inside an attached runner, still prepare the session and workers with an auto-generated session id, then follow the `sequential` runner flow described in `/run-workers` (the current Claude session continues as the prepared primary worker — load worker-request.md, enter plan mode, proceed). Do not stop and ask the user to open tmux just because no runner is attached.
- Keep the response short and operational.
