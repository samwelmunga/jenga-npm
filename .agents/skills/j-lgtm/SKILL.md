---
name: j.lgtm
description: Approve and commit the current work, then continue to the next task. Shortcut that chains /commit followed by /continue.
keywords:
  - lgtm
  - approve
  - looks good
  - done
  - commit and continue
  - j-lgtm
examples:
  - "lgtm, commit this"
  - "looks good, move on"
  - "j-lgtm"
---

# LGTM — Approve, Commit, and Continue

`skills/j-lgtm/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-lgtm/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/lgtm/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Instructions

1. Invoke the `/commit` skill and wait for it to finish.

2. If the current workflow is part of a `/do` execution, return to that workflow. Otherwise, invoke the `/continue` skill.
