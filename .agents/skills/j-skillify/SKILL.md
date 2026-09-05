---
name: j:j-skillify
description: Polyfill alias of the skillify skill under a collision-safe directory name. Identical behavior to /skillify — Refactor one or more existing skills into a cleaner, more maintainable structure — extracting hardcoded content into asset files, offloading deterministic steps into scripts, and reorganizing the skill body to reflect the leaner result. Use this whenever the user wants to clean up, improve, or restructure an existing skill, mentions that a skill has hardcoded content that could be templated, or asks to "skillify", "refactor", or "tidy up" a skill. Trigger even if the user just pastes a skill and says something like "can we make this better?". Use when the bare /skillify form is shadowed by another tool's own built-in command of the same name.
keywords:
  - j-skillify
  - polyfill
---

# Skillify — Refactor a Skill into a Cleaner Structure

This skill is a literal-directory-name duplicate of `skills/skillify/`. It exists so that `/j-skillify` (and `j:j-skillify`) give a guaranteed-unshadowed way to reach the same flow as `/skillify`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/skillify` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh skillify` from `skills/skillify/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

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