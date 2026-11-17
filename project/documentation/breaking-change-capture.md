# Breaking-change capture

Epic `E91`. This document describes the breaking-change **record**: the file that says why a release is major and which
epics carry the breaking changes. It covers the record format and the script that writes it (`E91_S01_T01`). The skill
that asks the user, the footer commit and the release workflow wiring are documented alongside the tasks that add them
(see `breaking-change-footer-placement.md` for the footer decision).

## Where a record lives

```
<documentation>/breaking-changes/<version>.md
```

- `<documentation>` is `scripts/resolve-root.sh get documentation`, the `paths.documentation` key of
  `project/configs/workflow.json` (conventional default `project/documentation`). It is never `docs/` and never a
  hardcoded literal.
- `<version>` is the bare tag form with the leading `v`, for example `v6.0.0` or `v6.0.0-rc.1`: the tag the release will carry.
- One record per version. `breaking-changes/` is created on first write.

## Record format

The shape is defined once, in `skills/j-breaking-change/assets/record-template.md`, which `write-record.sh` renders; the
header comment of `write-record.sh` describes the same shape.

```
---
version: v6.0.0
date: 2026-11-12
baseline: v5.0.1
epics: E12, E34
---

## Reason

<the user's reason, verbatim, any number of lines>

## Affected epics

E12 - <title of E12 from the board at write time>
E34 - <title of E34>

## Details

<optional free text>
```

| Part | Rule |
|---|---|
| `version` | `vX.Y.Z`, optionally with a pre-release suffix (`-rc.1`). |
| `date` | UTC, `YYYY-MM-DD`, taken when the record is written. |
| `baseline` | The tag the release was measured against; nothing after the colon for a manual run without one. |
| `epics` | Epic ids in the order given, separated by `, `. At least one. |
| `## Reason` | The reason verbatim: colons, quotes, backslashes and newlines are kept as given. |
| `## Affected epics` | One `<id> - <title>` line per epic, no bullet marker, so `^E[0-9]+ - ` matches each line. |
| `## Details` | Free text, empty when none was given. |

The headings `## Reason`, `## Affected epics` and `## Details` are reserved. A line that is exactly one of them inside the
reason or details would make the sections ambiguous, so `write-record.sh` refuses such input (exit 2) instead of rewriting it.

### Reading a record with plain shell

No agent is needed. In these recipes `FILE` is the record path.

```bash
# header value (k = version | date | baseline | epics); the header is the lines between the first two "---" lines
awk -v k=version 'NR==1{next} /^---$/{exit} index($0,k":")==1{sub("^"k": *","");print;exit}' FILE

# epic ids, one per line
awk -v k=epics 'NR==1{next} /^---$/{exit} index($0,k":")==1{sub("^"k": *","");print;exit}' FILE | tr ',' '\n' | tr -d ' '

# reason, verbatim (drop the blank line on each side if you need the bare text)
awk '/^## Reason$/{r=1;next} /^## Affected epics$/{r=0} r' FILE

# reason collapsed to one line (what the BREAKING CHANGE footer carries)
awk '/^## Reason$/{r=1;next} /^## Affected epics$/{r=0} r' FILE | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'

# affected epics, "<id> - <title>" lines
awk '/^## Affected epics$/{r=1;next} /^## Details$/{r=0} r && /^E[0-9]+ - /' FILE
```

## `write-record.sh`

`skills/j-breaking-change/scripts/write-record.sh`

```
write-record.sh --version vX.Y.Z --reason <text> --epics E12,E34 [--baseline <tag>] [--details <text>] [--replace]
```

- Validates, in this order and before creating anything: the version shape, a non-blank reason, the epic list shape
  (`E` plus digits, comma separated, duplicates written once), the baseline charset, and the reserved headings.
- Looks every epic up on the board as `<epics dir>/<id>_*.md`, with the trailing underscore (`E1` never matches
  `E10_x.md`), and takes the title from the epic's frontmatter. The epics directory is `resolve-root.sh get epics`.
  Until `E91_S02_T02` lands its shared validation, this is a direct check.
- Resolves paths only through `scripts/resolve-root.sh` (no second resolver), from the current directory or
  `JENGA_PROJECT_ROOT`.
- Refuses to overwrite an existing record unless `--replace` is given; the existing file stays byte-identical.
- Writes atomically: a temp file in `breaking-changes/`, then a no-clobber `ln` (or `mv -f` with `--replace`).
- Prints the absolute path of the written record as the only stdout line; everything else goes to stderr.
- bash 3.2 compatible, no network, no git commands.

### Exit codes

| Code | Meaning | File created |
|---|---|---|
| 0 | Written | yes |
| 2 | Usage or input error: unknown flag, missing value, malformed version, empty reason, malformed epic list or baseline, reserved heading in reason/details | no |
| 3 | Environment: `resolve-root.sh`, the template, or the documentation/epics path could not be located | no |
| 4 | An epic id is not on the board, or its file has no title | no |
| 5 | A record for this version exists and `--replace` was not given | no (existing file untouched) |
| 6 | The directory, temp file or final move failed | no |

Code 5 is dedicated so the `j.breaking-change` skill can branch to its keep, replace or cancel question.
