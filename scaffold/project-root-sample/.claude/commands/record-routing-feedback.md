---
description: Record whether a routing decision was good, overkill, insufficient, or wrong
argument-hint: [topic] [primary-worker] [feedback] [optional support-workers]
allowed-tools: Bash(bash .company-kit/scripts/record-routing-feedback.sh:*), Read(.company-project/routing-feedback.md)
---

Record routing feedback for the last recommendation.

Rules:

- If topic, primary worker, or feedback is missing, ask for the missing value.
- Allowed feedback values are:
  - `good`
  - `overkill`
  - `insufficient`
  - `wrong-worker`
- Run `bash .company-kit/scripts/record-routing-feedback.sh "$1" "$2" "$3" . "$4"`.
- Return only:
  - feedback file path
  - saved feedback
  - one short note saying future routing can reuse this signal
