---
description: Route a topic, prepare the current workstream, and immediately run the recommended workers with agent teams
argument-hint: [topic]
allowed-tools: Bash(bash .company-kit/scripts/run-session.sh:*), Bash(bash .company-kit/scripts/spawn-readiness-check.sh:*), Bash(bash .company-kit/scripts/spawn-telemetry-log.sh:*), Bash(bash .company-kit/scripts/cmux-start-worker.sh:*), Bash(bash .company-kit/scripts/cmux-submit-worker-message.sh:*), Bash(tmux display-message:*), Bash(tmux list-panes:*), Read(.company-runtime/**), Read(.company-project/**), Read(project-work/**)
---

Run the company workers for this topic: $ARGUMENTS

Rules:

- If no topic was provided, ask only for a one-line topic.
- Prefer the current attached runner session (tmux or cmux) when available.
- If Claude is not running inside an attached runner, still prepare the session and workers with an auto-generated session id.
- First run `bash .company-kit/scripts/run-session.sh "$ARGUMENTS"`.
- Read `.company-runtime/sessions/<resolved-session>/dispatch-summary.md` and note the resolved runner.
- Spawn behavior depends on the resolved runner:
  - `tmux` / `cmux` (attached): immediately spawn the prepared workers as Sonnet agent teams in the current runner session.
  - On `cmux`, if agent teams is unavailable, the leader MUST auto-fallback by running `bash .company-kit/scripts/cmux-start-worker.sh <session> <worker> . right` per worker (single canonical helper — split, marker, launch, spawn-emit). Do not invent ad-hoc `cmux new-split` + `cmux send` combinations. On non-zero exit, retry once with `down` direction; only then report failure.
  - After spawn, send the first turn via `bash .company-kit/scripts/cmux-submit-worker-message.sh <session> <worker>` (cmux) or the tmux equivalent. Never use raw `cmux send "..."`.
  - `sequential` (detached fallback, the default when no multiplexer is attached): the current Claude session IS the worker shell. Load `worker-request.md` as the working brief, enter plan mode as the prepared primary worker, and proceed through the standard plan → leader approval → execute flow inline. Do this without asking the user to open tmux or split panes — that is exactly what the sequential runner exists for.
  - `manual`: only stop and report worker file paths when the user explicitly chose `--runner=manual`.
- Do not ask the user to manually split panes.
- Do not ask the user "shall I proceed?" between any sub-steps. Topic approval at `/rw` time covers the entire prepare → spawn → first-message chain. Pause only at: worker plan arrival, external-write approval, destructive-ops auto-approve deny, or two consecutive spawn failures.
- Prefer the prepared primary worker first. Also spawn supporting workers if they were prepared and the routing summary did not say to stop at 1 worker. Under `sequential`, run the primary worker turn first; supporting workers are picked up after the primary completes (sequential runner has no parallelism).
- Prefer agent teams first. If agent teams is unavailable AND the runner is `tmux`/`cmux`, stop and report worker files. Under `sequential`, never stop just because agent teams is unavailable — proceed inline as the worker.
- If a worker pane does not appear, run `bash .company-kit/scripts/spawn-readiness-check.sh worker-required <resolved-session>` and log failure with `bash .company-kit/scripts/spawn-telemetry-log.sh <resolved-session> <worker> . failure "<reason-code>"`.
- Keep the response short and operational.
