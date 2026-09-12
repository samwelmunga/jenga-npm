---
name: j.playbook-new
description: Guided wizard that walks you through authoring a new project-local playbook — id, name, description, keywords, examples, and an ordered list of skills — validates every input against the real catalogs, and self-validates the written file before reporting success.
keywords:
  - new playbook
  - create playbook
  - author playbook
  - project playbook
  - custom playbook
examples:
  - "I want to create my own playbook"
  - "help me author a new project-local playbook"
  - "set up a custom workflow chain for my project"
  - "j.playbook-new"
---

# Playbook New — Guided Playbook-Authoring Wizard

## Purpose

`skills/jenga/scripts/load-playbooks.sh` merges two playbook sources into one catalog: the
framework-owned `skills/jenga/playbooks/` tree, and a project-owned `project/.playbooks/`
directory (`E53_S09_T01`). This skill is the guided authoring path for the second source — it
walks the user step by step through the required fields, validates each one against the real,
live catalogs (never a hand-maintained list of skill names or existing playbook ids), writes
`project/.playbooks/<id>.json`, and re-validates the just-written file via
`skills/jenga/scripts/load-playbooks.sh lookup` before ever declaring success. Hand-editing the
written JSON file remains the escape hatch for anything this wizard doesn't author (see the "v1
scope cut" note below).

**All deterministic work — slug/uniqueness validation, catalog lookups, and the JSON write
itself — lives in `skills/j-playbook-new/scripts/playbook-new.sh`** (per `CLAUDE.md`'s "Scripts
Over Inline Logic" principle). This skill's own job is only to run the conversational loop around
that script and interpret its JSON results — it never re-implements any validation or catalog
logic inline.

**v1 scope cut (deliberate, matches `E53_S09`'s story-level scope cut):** this wizard authors
plain, ordered, bare-string skill-name chains only — no `forward_from`, `resolve`, `conditional`,
or `playbook`-type (composition) `StepObject` fields. Hand-edit the written file directly if you
need any of those.

**Scope note — keywords and examples.** The playbook schema
(`skills/jenga/playbooks/schema.json`) requires every playbook to carry non-empty `keywords` and
`examples` arrays, exactly like every existing built-in playbook file already does — these are
what let `/jenga`'s own natural-language matching (`match-playbook.sh`) ever propose this playbook
from a free-text request. This wizard therefore asks for both, in addition to id/name/description/
skill-list, so the result is a genuinely useful, matchable playbook rather than one that merely
parses.

## Instructions

1. **Ask for an id** — a short, stable, kebab-case identifier (e.g. `my-release-flow`). Validate
   it by running:
   ```
   skills/j-playbook-new/scripts/playbook-new.sh validate-id "<id>"
   ```
   Parse the single JSON object printed to stdout:
   - `{"valid": true}` — continue to step 2.
   - `{"valid": false, "reason": "..."}` — show the `reason` to the user verbatim and re-prompt
     for a different id. Do not proceed until a validation call returns `valid: true`.

2. **Ask for a `name`** — a short, human-readable display name (e.g. "My Release Flow"), shown to
   users in confirmation prompts and routing output, mirroring every existing playbook's `name`
   field. No script validation needed beyond "non-empty" — re-prompt if the user gives an empty
   answer.

3. **Ask for a `description`** — one sentence explaining what this playbook accomplishes
   end-to-end. Re-prompt if empty.

4. **Ask for `keywords`** — one or more short phrases (1-3 words each) a user might type that
   should match this playbook, mirroring every existing playbook's `keywords` field (see
   `skills/jenga/playbooks/brainstorm-to-mirror.json` for a concrete example of the expected
   shape and specificity). Accept them one at a time or as a single comma-separated batch —
   your judgment, whichever the user's response shape suggests. Require at least one.

5. **Ask for `examples`** — one or more natural-language example prompts a user might type that
   should resolve to this playbook (again, mirror the existing built-in playbooks' style and
   level of specificity). Require at least one; at least one example should plausibly span the
   full breadth of the playbook's steps, not just its first one, so it's distinguishable from a
   single-skill match — use your judgment coaching the user toward this if their first example is
   too narrow.

6. **Ask for an ordered list of skill names** — one at a time, or as a single ordered batch —
   your judgment based on how the user responds. For **each** name entered, validate it by
   running:
   ```
   skills/j-playbook-new/scripts/playbook-new.sh validate-skill "<name>"
   ```
   Parse the JSON result:
   - `{"valid": true}` — accept it into the ordered list and continue.
   - `{"valid": false, "reason": "..."}` — show the `reason` verbatim and re-prompt for that
     position in the list (do not silently drop it or guess a correction).

   Once the user signals they're done adding skills, require **at least 2** total (a playbook is a
   chain — a single-skill "playbook" isn't a meaningful use of this mechanism). If fewer than 2
   were entered, tell the user this and continue prompting for more.

7. **Write the playbook.** Assemble the JSON payload from steps 1-6:
   ```json
   {
     "id": "<id>",
     "name": "<name>",
     "description": "<description>",
     "keywords": ["<keyword 1>", "..."],
     "examples": ["<example 1>", "..."],
     "steps": ["<skill 1>", "<skill 2>", "..."]
   }
   ```
   Pipe it to stdin of:
   ```
   skills/j-playbook-new/scripts/playbook-new.sh write
   ```
   Parse the JSON result:
   - `{"written": true, "path": "..."}` — continue to step 8.
   - `{"written": false, "reason": "..."}` — show the `reason` to the user verbatim. This should
     only happen if something changed between validation and write (e.g. a race, or a shape
     issue this wizard's own prompts didn't already catch) — do not silently retry; tell the user
     what failed and, if it's fixable (e.g. the id collided after all), loop back to the relevant
     earlier step.

8. **Self-validate before declaring success — never skip this step.** Run:
   ```
   skills/jenga/scripts/load-playbooks.sh lookup "<id>"
   ```
   Branch on the returned `status`:
   - **`"valid"`** — report success to the user: the playbook was written to
     `project/.playbooks/<id>.json` and is confirmed loadable. Mention it can now be invoked via
     `j.playbook <id>` or matched naturally through `j.jenga`.
   - **`"invalid"`** — report the `reason` field to the user **verbatim** — never a generic
     failure message. This is a real defect (the write succeeded but load-time validation still
     rejects it) — do not claim success.
   - **`"not_found"`** — report to the user that the write appears to have silently failed (the
     file the wizard just wrote could not be found by the loader) — this would indicate an
     environment problem (e.g. a different project root being resolved by the two scripts), not a
     normal outcome. Never claim success.

   Under no circumstances report success to the user without having seen `"status": "valid"` from
   this exact call.

## Edge Cases

- **The user wants to add `forward_from`/`resolve`/`conditional`/composition to a step.** Tell
  them this wizard doesn't author those fields (v1 scope cut) and that they can hand-edit
  `project/.playbooks/<id>.json` afterward — the schema supports these fields identically
  regardless of which directory a playbook file lives in.
- **The id collides with a project playbook that already exists on disk but is currently
  invalid** (e.g. a hand-edited file with a JSON syntax error) — `validate-id` still rejects it (it
  checks raw file existence, not just catalog membership) rather than silently overwriting a file
  the user may not realize is broken.
- **A skill name the user enters exists under multiple forms in the catalog** (e.g. both a bare
  and a `j-`-prefixed directory, during this repo's ongoing `E50` naming-contract transition) —
  accept whichever exact form the user typed if `validate-skill` reports it valid; this wizard
  does not impose a preference between forms the catalog itself doesn't distinguish.
- **The user cancels mid-wizard** — do not write anything; only step 7 ever touches disk, and only
  once a complete, locally-validated payload exists.
