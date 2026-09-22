---
name: j.wtf
description: Alias of /clearify — clarifies ambiguous, dense, or under-specified prompts and conversation on request. This folder exists only so the `/wtf` slash command resolves to a skill; behaviour is identical to `/clearify`.
keywords:
  - wtf
  - confused
  - huh
  - what does this mean
  - I'm lost
  - j-wtf
examples:
  - "wtf"
  - "wtf does this mean"
  - "wtf is going on here"
  - "j-wtf"
---

# WTF — Alias of /clearify

`skills/j-wtf/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-wtf/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/wtf/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Instructions

`/wtf` is an alias of `/clearify`. Follow `skills/j-clearify/SKILL.md` in full — do not duplicate or reimplement its ambiguity-detection logic here. Read that file's `## Instructions` section and execute it exactly as written, using whatever prompt or conversation context is attached to this `/wtf` invocation.
