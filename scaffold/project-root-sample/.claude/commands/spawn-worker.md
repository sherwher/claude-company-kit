---
description: Prepare one company worker for the current or existing workstream
argument-hint: [worker] [optional session-id]
allowed-tools: Bash(bash .company-kit/scripts/resolve-skill-packs.sh:*), Bash(bash .company-kit/scripts/prepare-worker.sh:*), Bash(bash .company-kit/scripts/spawn-readiness-check.sh:*), Bash(bash .company-kit/scripts/spawn-telemetry-log.sh:*), Bash(bash .company-kit/scripts/cmux-start-worker.sh:*), Bash(bash .company-kit/scripts/cmux-submit-worker-message.sh:*), Bash(tmux display-message:*), Bash(tmux list-panes:*), Read(.company-project/**), Read(project-work/**)
---

Prepare a worker for the current session.

Rules:

- If the worker argument is missing, ask only for the worker name.
- If session id is omitted and Claude is inside an attached runner (tmux or cmux), use the current session name (tmux session for tmux; `cmux current-workspace` output for cmux).
- If session id is omitted and Claude is not inside an attached runner, ask for the target session id or ask the user to run `/rw <topic>` first.
- First run `bash .company-kit/scripts/spawn-readiness-check.sh leader <resolved-session>`.
- Then run `bash .company-kit/scripts/spawn-telemetry-log.sh <resolved-session> <worker> . attempt "leader-ready"`.
- First run `bash .company-kit/scripts/resolve-skill-packs.sh <worker>`.
- Then run `bash .company-kit/scripts/prepare-worker.sh <worker> <resolved-session>`.
- Tell the leader to spawn one Sonnet worker with agent teams when an attached runner (tmux or cmux) is available. Do not ask the user to manually split panes as the default path.
- If agent teams is unavailable AND the resolved runner is `cmux`, the leader MUST auto-fallback by running `bash .company-kit/scripts/cmux-start-worker.sh <resolved-session> <worker> . right` (single canonical path — pane split, cmux-target marker, Claude launch, spawn marker emit are all handled by this script). Do not invent ad-hoc `cmux new-split` + `cmux send` combinations. If exit is non-zero, retry once with direction `down`. Only stop and report failure after the second attempt fails.
- If agent teams is unavailable AND the resolved runner is `tmux`, the leader auto-spawns via the tmux equivalent helper without asking the user.
- After spawn, send the first worker turn via `bash .company-kit/scripts/cmux-submit-worker-message.sh <resolved-session> <worker>` (cmux) or the tmux equivalent. Never use raw `cmux send "..."` / `tmux send-keys -l` — those skip the Enter submit and trap the worker in plan-mode interview.
- Do not ask the user "shall I proceed?" between any of these steps. Topic approval at `/rw` time covers the entire prepare → spawn → first-message chain. Stop only at the explicit pause points defined in the project CLAUDE.md auto-progress policy (worker plan arrival, external write, destructive ops, double spawn failure).
- If the resolved runner is `sequential` (no multiplexer attached), do NOT stop. The current Claude session takes the worker role: load `worker-request.md` and proceed in plan mode as that worker. The pane-readiness check below applies only to `tmux`/`cmux`.
- After the leader tries to spawn the worker (tmux/cmux only), run `bash .company-kit/scripts/spawn-readiness-check.sh worker-required <resolved-session>`.
- If that readiness check succeeds, run `bash .company-kit/scripts/spawn-telemetry-log.sh <resolved-session> <worker> . success "worker-pane-detected"`.
- If that readiness check fails on `tmux`/`cmux`, run `bash .company-kit/scripts/spawn-telemetry-log.sh <resolved-session> <worker> . failure "<reason-code>"` and stop. (On `sequential` the readiness check is skipped — sequential.sh emits `spawn_ready` itself.)
- Do not continue the requested work in the current pane when a `tmux`/`cmux` spawn fails. Report the failure and stop. Under `sequential`, continuing the worker turn inline is the intended behavior, not a violation — the leader is acting through the prepared worker role, not bypassing it.
- Tell the leader not to spawn more than 5 workers in a single session.
- Summarize only:
  - recommended packs
  - spawn readiness result
  - `worker-request.md` path
  - main `project-work/` paths to read first
  - one short natural-language request the user can say next
  - one short reminder that agent teams is the default path
