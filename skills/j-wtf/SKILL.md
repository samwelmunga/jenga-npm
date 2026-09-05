---
name: j:j-wtf
description: Polyfill alias of the wtf skill under a collision-safe directory name. Identical behavior to /wtf — Alias of /clearify — clarifies ambiguous, dense, or under-specified prompts and conversation on request. This folder exists only so the `/wtf` slash command resolves to a skill; behaviour is identical to `/clearify`. Use when the bare /wtf form is shadowed by another tool's own built-in command of the same name.
keywords:
  - wtf
  - confused
  - huh
  - what does this mean
  - I'm lost
  - j-wtf
  - polyfill
examples:
  - "wtf"
  - "wtf does this mean"
  - "wtf is going on here"
  - "j-wtf"
---

# WTF — Alias of /clearify

This skill is a literal-directory-name duplicate of `skills/wtf/`. It exists so that `/j-wtf` (and `j:j-wtf`) give a guaranteed-unshadowed way to reach the same flow as `/wtf`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/wtf` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh wtf` from `skills/wtf/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

## Instructions

`/wtf` is an alias of `/clearify`. Follow `skills/clearify/SKILL.md` in full — do not duplicate or reimplement its ambiguity-detection logic here. Read that file's `## Instructions` section and execute it exactly as written, using whatever prompt or conversation context is attached to this `/wtf` invocation.
