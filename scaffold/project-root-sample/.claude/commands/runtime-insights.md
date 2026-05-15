---
description: Show runtime dashboard for recent sessions, worker accuracy, and spawn failures
allowed-tools: Bash(bash .company-kit/scripts/runtime-insights.sh:*), Read(.company-runtime/**), Read(.company-project/routing-feedback.md)
---

Show the current runtime dashboard for this project.

Rules:

- Run `bash .company-kit/scripts/runtime-insights.sh`.
- Summarize only the most important 3 points.
- If there is no runtime data yet, say that directly and recommend running one workstream first.
- If spawn failures or low worker accuracy are visible, mention the dominant issue first.
