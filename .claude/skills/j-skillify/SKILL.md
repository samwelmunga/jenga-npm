---
name: j.skillify
description: Refactor one or more existing skills into a cleaner, more maintainable structure — extracting hardcoded content into asset files, offloading deterministic steps into scripts, and reorganizing the skill body to reflect the leaner result. Use this whenever the user wants to clean up, improve, or restructure an existing skill, mentions that a skill has hardcoded content that could be templated, or asks to "skillify", "refactor", or "tidy up" a skill. Trigger even if the user just pastes a skill and says something like "can we make this better?".
keywords:
  - j-skillify
---

# Skillify — Refactor a Skill into a Cleaner Structure

`skills/j-skillify/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-skillify/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `docs/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/skillify/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## What this skill does

Takes one or more existing skills and refactors them by:
- Extracting hardcoded file content (JSON, Markdown, config, etc.) into `assets/` templates
- Extracting hardcoded directory lists into `assets/` reference files
- Moving deterministic multi-step sequences into `scripts/` bash scripts
- Rewriting the skill body to delegate to those scripts and assets, keeping instructions lean

See `assets/init-old/SKILL.md` and `assets/init-new/SKILL.md` for a concrete before/after example.

---

## Instructions

### 1. Read the skill(s)

Read every SKILL.md the user references. If they also reference scripts or assets already in the skill, read those too.

### 2. Identify refactor opportunities

For each skill, look for:

| Pattern | Refactor to |
|---|---|
| Hardcoded file content written inline (heredoc, echo, cat) | `assets/<name>_template.<ext>` copied via `cp` |
| Hardcoded list of directories or paths | `assets/<name>.txt` read via a `while read` loop |
| Sequential deterministic steps (create files, run commands) | `scripts/<name>.sh` executed by the skill |
| `SCRIPT_DIR` defined repeatedly across steps | Define once at top of script |

### 3. Confirm the plan with the user

Before making changes, summarise what you found and what you propose to extract. List:
- Which files will move to `assets/`
- Which steps will move to `scripts/`
- What the updated skill body will look like

Get a thumbs-up before proceeding.

### 4. Produce the outputs

For each change:
- Write the extracted asset files with their content
- Write or update the bash script(s), following the structure in `assets/init-new/SKILL.md`
- Rewrite the skill body so each offloaded step becomes a single `cp` or script call with a short explanation

### 5. Update the skill body

The rewritten SKILL.md should:
- Keep narrative and conversational steps in the skill body (things Claude decides or explains)
- Delegate all deterministic file/directory operations to scripts
- Reference asset files by name so it's clear what exists where
- Stay concise — if a step is now just "run the script", say so in one line

---

## Reference files

- `assets/init-old/SKILL.md` — The init skill before refactoring (hardcoded heredocs, inline JSON, hardcoded directory list)
- `assets/init-new/SKILL.md` — The init skill after refactoring (all content in assets, steps delegated to `init.sh`)

Read these when you need a concrete example of the before/after pattern.
