---
name: j:j-lgtm
description: Polyfill alias of the lgtm skill under a collision-safe directory name. Identical behavior to /lgtm — Approve and commit the current work, then continue to the next task. Shortcut that chains /commit followed by /continue. Use when the bare /lgtm form is shadowed by another tool's own built-in command of the same name.
keywords:
  - lgtm
  - approve
  - looks good
  - done
  - commit and continue
  - j-lgtm
  - polyfill
examples:
  - "lgtm, commit this"
  - "looks good, move on"
  - "j-lgtm"
---

# LGTM — Approve, Commit, and Continue

This skill is a literal-directory-name duplicate of `skills/lgtm/`. It exists so that `/j-lgtm` (and `j:j-lgtm`) give a guaranteed-unshadowed way to reach the same flow as `/lgtm`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/lgtm` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh lgtm` from `skills/lgtm/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

## Instructions

1. Invoke the `/commit` skill and wait for it to finish.

2. If the current workflow is part of a `/do` execution, return to that workflow. Otherwise, invoke the `/continue` skill.
