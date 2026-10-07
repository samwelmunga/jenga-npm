---
name: j.conventions
description: Guided wizard to record your project's conventions (commit format, branching, naming, comments, formatting and linting, testing, file layout, language and tooling, documentation placement) — detects what the project already does, offers general-standard presets, validates every input as it is given, writes conventions.json atomically, regenerates the matching pre-flight checklist items, and self-validates before reporting success.
keywords:
  - project conventions
  - coding standards
  - commit format
  - naming convention
  - lint rules
  - code style
  - branching strategy
examples:
  - "set up my project's conventions"
  - "record that we use Conventional Commits"
  - "what conventions does this project follow, and let me change them"
  - "we name files in kebab-case, write that down"
  - "tailor Jenga to how my project works"
  - "j.conventions"
---

# Conventions — Guided Project-Conventions Wizard

## Purpose

A project has conventions of its own (how it formats commits, names things, comments code, lays out files).
This wizard records them in `project/configs/conventions.json` (epic `E69`, contract in
`project/documentation/project-conventions.md`) one category at a time, then regenerates the matching
managed `conv-` items in the pre-flight checklist registry so the conventions are actually consulted at the
moments they matter. For each of the 9 categories it shows the standard the project **already follows**
(detected, with evidence and confidence), 2 or 3 **general-standard presets**, a skip option and a custom
option. Hand-editing `conventions.json` stays supported; the wizard carries every category you do not change
over unchanged in content.

**Project layer only.** The wizard records one file for this project. It has no other scope to choose, so it
never asks where to write.

**Generated checklist items are advisory or confirm only.** Judgment conventions (naming, comments, docs) become
`advisory` items; machine-verifiable ones (a lint or format command) become `confirm`. The wizard never offers a
blocking strength and never passes one.

**All deterministic work lives in scripts** (per `CLAUDE.md`'s "Scripts Over Inline Logic" principle): detection,
per-input validation, the draft, the atomic write, the checklist generation and the self-validation live in
`skills/j-conventions/scripts/conventions-entry.sh` (which calls `detect-conventions.sh`,
`scripts/validate-conventions.sh`, `scripts/generate-convention-checklist.sh` and
`scripts/validate-checklists.sh`). This skill only runs the conversation around those scripts and interprets
their results. It never builds JSON, checks a rule, resolves a path or writes a file itself.

## Script contract (what this skill relies on)

All calls are `skills/j-conventions/scripts/conventions-entry.sh <subcommand>`; option values are separate
arguments. `conventions-entry.sh --help` prints the full contract and is authoritative.

| Call | Result |
|---|---|
| `conventions-entry.sh path` | Prints the project's `conventions.json` path (whether or not it exists) |
| `conventions-entry.sh show [--category ID]` | Prints the recorded conventions (the empty skeleton when none); exit 1 when the named category is not recorded |
| `conventions-entry.sh categories [--format lines\|json]` | The 9 category ids in order with labels; `json` adds each category's `values` field list (type, required) and `applies_to` |
| `conventions-entry.sh detect` | The detector's JSON, unchanged: per category `detected`, `preset_match`, `evidence`, `confidence`, `preset_only` |
| `conventions-entry.sh presets CATEGORY-ID` | The category's 2-3 presets as JSON (`id`, `label`, `description`, `values`, `placeholder_fields`) |
| `conventions-entry.sh check CATEGORY-ID FIELD "VALUE"` | `{"valid": true}` or `{"valid": false, "reason": "..."}`, exit 0 for both; `check summary "VALUE"` checks a summary |
| `conventions-entry.sh draft-init` | Creates the draft (outside the project), prints its path; seeded from the recorded conventions when they exist |
| `conventions-entry.sh draft-set CATEGORY-ID --draft PATH --source detected\|preset\|custom [--preset ID] [--summary TEXT] [--value FIELD=VALUE]... [--unset FIELD]...` | Validates the whole result first; on refusal exit 1, the reason on stderr and the draft unchanged |
| `conventions-entry.sh draft-skip CATEGORY-ID --draft PATH` | Removes the category from the draft (nothing recorded for it) |
| `conventions-entry.sh draft-show --draft PATH [--category ID]` | Prints the draft or one category's entry; exit 1 when absent |
| `conventions-entry.sh draft-diff --draft PATH [--format json\|text]` | Draft against the recorded conventions: added, removed, changed, unchanged |
| `conventions-entry.sh commit --draft PATH` | Validates, writes `conventions.json` atomically, regenerates the `conv-` checklist items, self-validates both files; success JSON only after all passed, otherwise both files are restored, the reason is on stderr and the draft is kept |
| `scripts/validate-conventions.sh <path>` | Exit `0` only if the file is valid |
| `scripts/validate-checklists.sh <path>` | Exit `0` only if the registry is valid |

## Instructions

1. **Start.** Tell the user, briefly, what this does and that it is project-layer only: it records this
   project's conventions, nothing is written until the final confirmation, and cancelling at any point leaves
   no trace. Then run, in this order:
   - `conventions-entry.sh categories --format json` (the 9 categories, in order, with their fields),
   - `conventions-entry.sh detect` once and keep the result for the whole session (show the `warnings`, if
     any, in one line; a failing `detect` is shown verbatim and the wizard continues with presets only),
   - `conventions-entry.sh draft-init` and keep the printed path as the draft for the whole session. Its
     stderr note says whether the draft was **seeded from conventions already recorded**: if so tell the user
     "you have recorded conventions already; each category below starts at your recorded answer, so changing
     nothing keeps it". If `draft-init` fails (exit 4: the recorded file is not valid), show its message
     verbatim, say the file needs fixing by hand first, and stop.

2. **One category at a time**, in the order `categories` gave. For each category:
   1. Run `conventions-entry.sh presets <id>` and `conventions-entry.sh draft-show --draft <draft> --category <id>`
      (exit 1 means nothing is recorded for it yet).
   2. Present a numbered choice. Free text is always the last option, per `CLAUDE.md`'s Interaction Pattern:

      ```
      <Category label> — how does this project do it?
      1. Detected: <the detected values, in words> — <evidence> (confidence: <confidence>)
      2. <Preset label> — <preset description>
      3. <Preset label> — <preset description>
      4. Skip (record nothing)
      5. Other (describe below)
      ```

      - Include the **Detected** option first, only when that category's `detected` is not null and
        `preset_only` is false; quote the evidence and confidence exactly as the detector gave them. When
        `preset_match` names one of the presets, show that preset once, as the detected option (note "matches the
        general standard <preset label>"), not twice.
      - Then the 2-3 presets, each with its description; then **Skip (record nothing)**; then
        **Other (describe below)** last.
      - When a convention is already recorded for the category, mark the option that matches it
        `(current answer)` and treat "keep it" as the default. A recorded custom answer has no option of its
        own: add `Keep your recorded answer: <summary>` before Skip.
      - Nothing detected and no preset fits is fine: the user picks Skip or Other.
   3. Act on the choice:
      - **Detected:** `conventions-entry.sh draft-set <id> --draft <draft> --source detected`.
      - **Preset:** `conventions-entry.sh draft-set <id> --draft <draft> --source preset --preset <preset id>`.
        If the preset's `placeholder_fields` is not empty (for example the formatter-and-linter preset ships
        `<lint command>` and `<format command>`), those values are templates, not answers: for each field ask
        the user for the real command (validate it with `check <id> <field> "<value>"`, refuse and re-ask on
        `valid: false`) and pass it as `--value <field>=<command>`, or, if the user has none, pass
        `--unset <field>`. Never pass placeholder text and never proceed with a field left as a placeholder;
        if the user has no real commands at all, offer Skip instead. The script refuses a placeholder anyway.
      - **Skip:** `conventions-entry.sh draft-skip <id> --draft <draft>`.
      - **Other:** ask for a one-line summary (step 3), then the category's `values` fields from
        `categories --format json` one at a time (required ones first, then the optional ones, which the user
        may leave out), each validated as in step 3; then
        `conventions-entry.sh draft-set <id> --draft <draft> --source custom --summary "<summary>" --value <field>=<value>...`.
      - Record the answer only through `draft-set` / `draft-skip`. If `draft-set` exits `1`, show its stderr
        reason verbatim, say the draft is unchanged, and ask the question again.
   4. For the **commit-format** category, say this before presenting the options: **EST commit naming stays
      mandatory for board commits** (`task(E##_S##_T##):`, `story(...)`, `epic(...)`, because `/reconcile`
      relies on it); the format chosen here applies to **commits that are not board commits** only. The
      detector's evidence already excludes board commits.

3. **Validate every input as it is given.** Before accepting a typed value, run
   `conventions-entry.sh check <category> <field> "<value>"` (a summary: `check summary "<value>"`). On
   `{"valid": false, "reason": ...}` show the reason verbatim, do not store or "fix" the value, and ask again.
   Values are one line each; a multi-line answer is refused by the script, so ask the user to put it on one
   line. Do not offer or accept a blocking strength: conventions are advisory or confirm only.

4. **Review before anything is written.** Run `conventions-entry.sh draft-diff --draft <draft> --format text`
   and `draft-show --draft <draft>`, and present every category with its answer (or "not recorded") and what
   changed against the recorded conventions (added, changed, removed). Say that nothing has been written yet,
   and which file will be written (`conventions-entry.sh path`). Then offer:

   ```
   What would you like to do?
   1. Change <category 1 label>
   2. Change <category 2 label>
   ...
   9. Change <category 9 label>
   10. Looks good, write it
   11. Cancel (write nothing)
   12. Other (describe below)
   ```

   Choosing a category re-runs step 2 for that category (its recorded answer pre-selected) and returns to
   this review. Only option 10 continues. Option 11 stops with nothing written.

5. **Write.** On option 10 run `conventions-entry.sh commit --draft <draft>`. This validates, replaces
   `conventions.json` atomically, regenerates the `conv-` checklist items and self-validates both files. Branch on
   its exit status:
   - **`0`** and a JSON line with `"ok": true` — continue to step 6.
   - **non-zero** — show the stderr text verbatim and **do not** report success. Say what it means:
     exit `4` the draft or a written file failed validation, exit `7` the checklist generator failed, exit `6`
     another process holds the lock. For `4` and `7` after the write started, the script already restored the
     previous `conventions.json` and `checklists.json`; for `6` and for `4` before any write, nothing was
     touched. The draft is kept, so offer: `1. Retry the write`, `2. Go back and change an answer (step 4)`,
     `3. Abandon (nothing is recorded)`, `4. Other (describe below)`.

6. **Self-validate before declaring success — never skip this step.** Using the `path` and `registry` values from
   the commit result, run `scripts/validate-conventions.sh <path>` and `scripts/validate-checklists.sh <registry>`.
   - **Both exit `0`** — report success (step 7).
   - **Any other exit** — report the validator's messages verbatim and state plainly that the file is not valid.
     Never claim success.

   Under no circumstances report success without having seen `"ok": true` from `commit` **and** exit `0` from
   both validators.

7. **Report.** Say which categories were recorded, changed or removed (from the commit result and the review),
   the file written, and what was generated: one managed item `conv-<category id>` in the pre-flight checklist
   registry for each recorded category, **advisory or confirm strength — never blocking** — which agents tick at
   the `pre-task` and `pre-commit` moments. Remind the user that a commit-format convention applies to non-board
   commits and that EST naming stays mandatory for board commits, and that re-running `j.conventions` starts from
   the recorded answers.

## Edge Cases

- **A `conventions.json` already exists.** The draft is seeded from it (step 1), so a re-run pre-selects the
  recorded answers instead of starting blank. Categories the user leaves alone are carried over unchanged in
  content.
- **The recorded file is hand-edited and invalid.** `draft-init` refuses (exit 4) and shows the validator's
  messages. Tell the user it needs fixing by hand first; do not try to repair it.
- **Detection found nothing, or the detector is slow or failed.** Offer presets, Skip and Other for every
  category. Never present a guess as a detected standard.
- **A preset value is a placeholder** (`<lint command>`, `<format command>`). It is a template, not an answer:
  ask for the real command, leave an optional field unset, or skip the category (step 2.3).
- **The user cancels mid-wizard.** Nothing has been written: only `commit` touches the project, and the draft
  lives in a temp file outside it.
- **The lock is held** (another session is writing). `commit` exits `6` without writing; offer to retry shortly.
- **Out of scope.** Changing how the checklist registry is checked, authoring arbitrary checklist items
  (`j.conventions` only manages the `conv-` items it generated), and categories beyond the 9 listed.
