---
description: Route a topic to the right workers
argument-hint: [topic]
allowed-tools: Bash(bash .company-kit/scripts/recommend-routing.sh:*), Read(.company-kit/docs/operations/ROUTING_MATRIX.md), Read(.company-project/project-routing-overrides.md), Read(.company-project/project-context.md), Read(.company-project/cost-mode.md), Read(project-work/**)
---

Route this topic to the right company workers: $ARGUMENTS

Rules:

- If no topic was provided, ask for a one-line topic.
- Use `.company-kit/docs/operations/ROUTING_MATRIX.md` as the base rule.
- Apply `.company-project/project-routing-overrides.md` if it exists.
- Read `.company-project/cost-mode.md` if it exists.
- Run `bash .company-kit/scripts/recommend-routing.sh "$ARGUMENTS"`.
- Return only:
  - current cost mode
  - auto cost hint
  - recommended primary worker
  - optional supporting workers
  - whether this should stop at 1 worker or expand up to 5
  - why this routing fits
  - one recent similar pattern if present
  - the next slash command to run
