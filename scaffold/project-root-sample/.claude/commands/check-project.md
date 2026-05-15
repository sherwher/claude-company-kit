---
description: Check template readiness and summarize gaps
allowed-tools: Bash(bash .company-kit/scripts/check-template.sh:*), Read(.claude/settings.json), Read(.company-project/**), Read(project-work/**)
---

Check whether this project is ready to run the company template.

Rules:

- Run `bash .company-kit/scripts/check-template.sh`.
- If the check passes, summarize the project as ready and point to the next recommended command.
- If the check fails, summarize the first blocking gap only and point to the file or path that needs attention.
- Keep the response short and operational.
