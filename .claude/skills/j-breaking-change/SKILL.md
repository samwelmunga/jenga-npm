---
name: j.breaking-change
description: Record why a release is major and which epics carry its breaking changes, as one record file under the documentation path, by asking the reason and then the epics in a numbered picker.
keywords:
  - breaking change
  - major release
  - major version
  - record breaking change
  - why is this major
  - j-breaking-change
examples:
  - "record a breaking change for the next release"
  - "j-breaking-change v6.0.0"
  - "write down why this release is major"
  - "which epics break compatibility in this release"
---

# breaking-change — Record Why a Release Is Major

`skills/j-breaking-change/` is the canonical, hand-edited directory for this skill.

## Purpose

`j.breaking-change [<version>]` writes one **breaking-change record**: the file that says why a release is
major and which epic(s) carry the breaking change(s). The record lives at
`<documentation>/breaking-changes/<version>.md`, where `<documentation>` is resolved from
`project/configs/workflow.json` by the writer script, never hardcoded. Its shape is defined in
`assets/record-template.md` and documented in `project/documentation/breaking-change-capture.md`.

**A manual run is allowed at any time, also outside a release.** This version of the skill does the manual run
only, and it **writes only the record file**. It does not write a `CHANGELOG.md` entry and does not make a
`BREAKING CHANGE:` footer commit: those belong to the release flow (`E91_S04`). The `--release` mode used from the
`deploy-public` workflow (`E91_S03`) is not part of this version either.

The skill holds the conversation and the judgment only. Every deterministic step is a script call.

## Scripts

All scripts live in this skill's `scripts/` directory. Resolve it once:

```bash
BC_DIR="$([ -d skills/j-breaking-change/scripts ] && echo skills/j-breaking-change/scripts || echo node_modules/@jenga-ai/agent/skills/j-breaking-change/scripts)"
```

| Script | Task | Used for |
|---|---|---|
| `skills/j-breaking-change/scripts/write-record.sh` | `E91_S01_T01` | writing the record; exit 5 means a record for that version already exists |
| `detect-major.sh` | `E91_S02_T01` | classifying a version against the latest tag (`major`, `minor`, `patch`, `none`, `invalid`) |
| `epic-picker.sh` | `E91_S02_T03` | rendering the epic picker and parsing the answer into validated epic ids |
| `list-epics.sh` | `E91_S02_T02` | used by `epic-picker.sh` to list and validate epics; not called directly |

Run each from `$BC_DIR`. **If a script is missing, stop** and tell the user which one and which task adds it.
Never reproduce a script's logic by hand: no hand-built epic list, no hand-parsed answer, no hand-written record.

## Instructions

### Step 1 — Resolve the version (ask only when it cannot be derived)

- If the invocation carried a version (`j.breaking-change v6.0.0`), use it and do not ask.
- Otherwise read the package version with `jq -r .version package.json` and classify it with
  `detect-major.sh - v<package version>` (`-` means the latest tag is the baseline). Then ask:

      Which version is this record for?
      1. v<package version> (from package.json; <classification> over the latest tag)
      2. Other (type the version, e.g. v6.0.0)

  Leave option 1 out when `package.json` has no version. When the classification is not `major`, say so in the
  option text; a record for a non-major version is still allowed in a manual run.

The version is passed to `write-record.sh` as given; that script rejects a malformed one (exit 2). On exit 2 show its
message and ask again.

### Step 2 — Ask the reason

Ask one open question; the answer is prose, so a numbered list would not help:

> Why is this release major? Name what breaks for users and what they must change.
> Example: "The scope test gate defaults changed (test_run_task, test_run_story, test_run_epic are now none,
> scoped, none), so projects relying on the old defaults run fewer tests at task close."

Keep the answer verbatim: do not rephrase, shorten or reformat it.

### Step 3 — Pick the epics

Render the picker with `epic-picker.sh render completed -` (epics with commits since the latest tag) and show its output
exactly as printed. It ends with an option to switch to all epics and a free-text option last.

Pass the user's answer to `epic-picker.sh parse completed - "<answer>"` (or `parse all - "<answer>"` on the all-epics view).
One answer may hold several epics (`1,3`, `2-4`, `E12, e40`).

- Exit 0: the validated epic ids, one per line. Keep them in the printed order.
- Exit 10: the user picked the switch option; render the other view (`render all` or `render completed -`) and ask again.
- Exit 2: a number is out of range or an id is not on the board. Show the offending token named on stderr, for example
  "E99 is not an epic on the board", and ask again with the same view.

### Step 4 — Confirm

Show the summary, then the choices:

    Version: <version>
    Reason:  <reason>
    Epics:   <id> - <title>, ...

    What would you like to do?
    1. Confirm and write the record
    2. Edit the reason
    3. Edit the epics
    4. Cancel (nothing is written)
    5. Other (describe below)

Option 2 returns to Step 2, option 3 to Step 3, then back here. On option 4 stop and write nothing.

### Step 5 — Write the record

On confirm run:

```bash
"$([ -f skills/j-breaking-change/scripts/write-record.sh ] && echo skills/j-breaking-change/scripts/write-record.sh || echo node_modules/@jenga-ai/agent/skills/j-breaking-change/scripts/write-record.sh)" \
  --version "<version>" --reason "<reason>" --epics "<E12,E34>"
```

Pass the reason as one argument, unchanged. Act on the exit code:

| Exit | Meaning | Do |
|---|---|---|
| 0 | written | Report the absolute path printed on stdout. |
| 5 | a record for this version already exists | stderr names the existing file; show its content, then ask the choice below. |
| 2 | an input was refused | Show the message; return to the step that owns that input. |
| 4 | an epic is not on the board | Show the message; return to Step 3. |
| 3, 6 | environment or write failure | Show the message and stop. |

On exit 5:

    A record for <version> already exists. What would you like to do?
    1. Keep the existing record (nothing is written)
    2. Replace it with the one just confirmed
    3. Cancel
    4. Other (describe below)

On option 2 run the same command with `--replace` added and report the path. Options 1 and 3 write nothing.

## What this skill never does

- It never writes anything other than the record file: no `CHANGELOG.md`, no commit, no board change.
- It never overwrites an existing record without the explicit "Replace" choice.
- It never edits `.claude/` or `.agents/`; those are generated outputs.
