---
name: lgtm
description: Approve and commit the current work, then continue to the next task. Shortcut that chains /commit followed by /continue.
keywords:
  - lgtm
  - approve
  - looks good
  - done
  - commit and continue
examples:
  - "lgtm, commit this"
  - "looks good, move on"
---

# LGTM — Approve, Commit, and Continue

## Instructions

1. Invoke the `/commit` skill and wait for it to finish.

2. If the current workflow is part of a `/do` execution, return to that workflow. Otherwise, invoke the `/continue` skill.
