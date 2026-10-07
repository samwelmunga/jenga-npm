# Pre-Flight Checklists: Registry Schema

Authoritative contract for checklist registry files (epic `E67`). A registry declares standing,
project-scoped checks (investigations, considerations, required actions) and, for each, **which
lifecycle situations it applies to** and how strictly it is enforced. This document is the single
source for the file format. The validator (`scripts/validate-checklists.sh`, `E67_S01_T02`), the shipped
default (`templates/checklists.json`, `E67_S01_T03`) and the checker (`scripts/checklist.sh`, `E67_S02`)
implement exactly what is written here; where they disagree with this document, this document wins.

Items generated from a project's recorded conventions (`conv-` items) are described in section 9
and in [project-conventions.md](project-conventions.md).

Sections 1 to 8 define the schema. Section 9 lists what is deliberately **not** defined yet and which
task owns it. Section 10 is a complete worked file.

## 1. File format

A registry file is a single JSON object:

```json
{
  "checklist_version": 1,
  "situations": [],
  "items": []
}
```

| Field | Type | Required | Meaning |
|---|---|---|---|
| `checklist_version` | integer | yes | Schema version. Must be exactly `1`. |
| `situations` | array of string | no (default `[]`) | Extends the base situation vocabulary for this file (section 4). |
| `items` | array of object | yes (may be empty) | The checklist items (section 2). |

Unknown top-level or item keys are ignored by the validator, with one exception: an item's optional
`provenance` key is checked when present (section 9, Provenance fields). A missing required field is an error; a
misspelt one therefore surfaces as a missing field rather than being silently accepted.

Each file is validated **on its own**. Nothing in a file is inherited from any other file.

## 2. Item

Each element of `items[]` is an object. Every field is required except `verify`, which is governed by
the `kind` coupling in section 5.

| Field | Type | Required | Accepted values and meaning |
|---|---|---|---|
| `id` | string | yes | Stable identifier matching `^[a-z0-9]+(-[a-z0-9]+)*$` (kebab-case). Unique within the file. Anything that later refers to an item refers to it by `id`, so an `id` is never reused for a different item. |
| `text` | non-empty string | yes | The human-readable checklist statement, written so it can be shown verbatim to a user or agent. |
| `situations` | non-empty array of string | yes | The lifecycle situations the item applies to (section 4). No duplicates within the array. Each entry must be a base situation or one declared in this file's top-level `situations`. |
| `kind` | `"machine"` or `"judgment"` | yes | How the item is satisfied (section 5). |
| `verify` | non-empty string | `machine`: yes. `judgment`: forbidden | A shell command line (section 5). |
| `enforcement` | `"block"`, `"confirm"` or `"advisory"` | yes | How strictly an unsatisfied item is enforced at check time (section 6). |
| `tick_scope` | `"run"` or `"persistent"` | yes | How long a recorded tick lasts (section 7). |

Values are case-sensitive: `"Machine"` and `"BLOCK"` are rejected.

An item may also carry an optional `provenance` object recording where it came from; it is not required, and
an item with none is valid. See section 9, Provenance fields.

## 3. What the validator rejects

The validator rejects a file for any of the following, naming the offending item `id` wherever one exists,
and exits non-zero. Each failure class has its own message.

| Failure class | Condition |
|---|---|
| malformed JSON | The file does not parse, or its top level is not an object. |
| missing required field | A required top-level field or item field is absent (or of the wrong type). |
| unknown situation | An item names a situation that is neither base (section 4) nor declared in this file's `situations`. |
| unknown `kind` | `kind` is anything other than `machine` or `judgment`. |
| missing `verify` | `kind: machine` with no `verify`, or an empty or whitespace-only one. |
| `verify` on a judgment item | `kind: judgment` with a `verify` key present at all, whatever its value (even `""` or `null`). |
| bad `enforcement` | `enforcement` is anything other than `block`, `confirm` or `advisory`. |
| bad `tick_scope` | `tick_scope` is anything other than `run` or `persistent`. |
| duplicate item `id` | Two items in the same file share an `id`. |

A malformed `id`, an empty `text`, an empty `situations` array, a duplicate entry in an item's
`situations`, and a bad extension name in the top-level `situations` (section 4) are also rejected as
structural errors. The exact message text is the validator's own contract (`E67_S01_T02`); this table fixes
which conditions must be rejected, not their wording.

A present `provenance` object is also checked, and a malformed one is rejected with its own messages (section 9,
Provenance fields).

## 4. Situation vocabulary

A **situation** is a lifecycle phase, not a skill name. Phases survive skill renames; a skill-name
vocabulary would not. The base vocabulary is a closed list (case-sensitive):

| Situation | Applies when |
|---|---|
| `pre-commit` | Work is about to be committed. |
| `pre-task` | A board task is about to start executing. |
| `pre-release` | A release is about to be published or mirrored. |
| `pre-reconcile` | The board is about to be reconciled against actual implementation state. |

Which gating skill invokes the checker for which phase is a separate mapping (section 9).

This project's own instance extends the base list with two release-specific phases, `pre-publish` and
`pre-mirror`, declared in its `situations` array. Why they exist, and how the release skills fire them after
`pre-release`, is in section 9.

### Extending the vocabulary

A file extends the vocabulary by listing extra names in its own top-level `situations` array:

```json
{ "checklist_version": 1, "situations": ["pre-deploy"], "items": [] }
```

An extension name must match `^[a-z][a-z0-9-]*$`, must not duplicate a base name, and must not repeat
within the array. An item's `situations` entries must each be in the base list or in the **same file's**
`situations`: validation is per file, so a file that uses an extended situation must declare it itself.
An item naming a situation that is neither is an `unknown situation` error.

Declaring a situation only makes the name valid in that file. It does not make anything fire it: which
gating points invoke the checker, and with which situation, is defined outside this schema (section 9).

## 5. Kind and `verify`

`kind` splits items by how they are satisfied. Without the split a tick would record an assertion rather
than a verification.

- **`machine`**: satisfied by a command exiting `0`. The checker runs it and scores pass or fail.
- **`judgment`**: satisfied by a person (or agent acting for the user) confirming it. The item is surfaced
  for confirmation and the checker records who confirmed.

### The coupling, in both directions

| `kind` | `verify` | Result |
|---|---|---|
| `machine` | present, non-empty | valid |
| `machine` | absent, empty or blank | rejected (`missing verify`) |
| `judgment` | absent | valid |
| `judgment` | present, with any value | rejected (`verify on a judgment item`) |

A `machine` item **requires** `verify`; a `judgment` item **forbids** it. There is no machine item
without a command, and no judgment item that quietly carries one.

### `verify` semantics

`verify` is a shell command line, run from the repository root. Exit status `0` means the item passes; any
non-zero status means it fails. Because it sits inside a JSON string, backslashes and double quotes in
the command must be JSON-escaped (see the worked example below). A `verify` command should be
non-interactive and read-only: the checker may run it every time a gate fires.

### Worked example: `machine`

```json
{
  "id": "no-untracked-env-files",
  "text": "No untracked .env files are present in the working tree.",
  "situations": ["pre-commit", "pre-release"],
  "kind": "machine",
  "verify": "! git ls-files --others --exclude-standard | grep -q '\\.env$'",
  "enforcement": "block",
  "tick_scope": "run"
}
```

`grep -q` exits `0` when it finds a stray `.env`, the leading `!` inverts that, so the command exits `0`
(item passes) only when none exists. The JSON `\\.` reaches the shell as `\.`.

### Worked example: `judgment`

```json
{
  "id": "contributing-guide-read",
  "text": "I have read the project's contributing guide and will follow its conventions.",
  "situations": ["pre-task"],
  "kind": "judgment",
  "enforcement": "confirm",
  "tick_scope": "persistent"
}
```

There is no command to run, so there is no `verify`. The checker shows `text` and asks for confirmation.

## 6. Enforcement: behaviour at check time

An item is **satisfied** when its `verify` exited `0` (`machine`) or it has been confirmed (`judgment`),
and **unsatisfied** otherwise. A satisfied item never prompts and never halts, whatever its enforcement.
`enforcement` only changes what happens to an unsatisfied item.

| `enforcement` | Observable behaviour when the item is unsatisfied |
|---|---|
| `block` | The gated action **halts before any work is done** and does not proceed. The unsatisfied item is reported. There is no "proceed anyway" option: the only ways forward are to satisfy the item (fix the cause and re-run, or for a `judgment` item confirm it) or to stop. |
| `confirm` | The user is **prompted before the action proceeds**, using the numbered-options format of `CLAUDE.md`'s Interaction Pattern (free text always the last option). The user must make an explicit choice: satisfy the item, proceed without satisfying it, or stop. Silence does not count as proceeding. |
| `advisory` | The item is **only reminded**: its `text` (and, for a failing `machine` item, the failure) is shown. The action is never halted and no response is required. |

Per kind:

| | `block` | `confirm` | `advisory` |
|---|---|---|---|
| `machine`, `verify` exits `0` | no output required, action proceeds | same | same |
| `machine`, `verify` exits non-zero | halt, failure reported | prompt showing the failure; user chooses proceed or stop | failure shown as a warning; action proceeds |
| `judgment`, not confirmed | prompt offering confirm or stop; unconfirmed means halt | prompt offering confirm, proceed without confirming, or stop | `text` shown as a reminder; action proceeds |

Only a satisfied item is ever recorded as ticked: proceeding past a `confirm` or `advisory` item without
satisfying it does not tick it.

### How `checklist.sh check` reports section 6 (`E67_S02_T02`)

`scripts/checklist.sh check <situation>` prints one JSON array on stdout, one object per applicable item,
and its exit code is the backstop for a caller that ignores the array. Each object carries `id`, `text`,
`kind`, `enforcement`, `tick_scope`, `tick_state`, `result`, `action`, `reason`, `cause` and `exit_status`.

| Item | `result` | `action` (by `block` / `confirm` / `advisory`) |
|---|---|---|
| `machine`, `verify` exits `0` | `passed` | `proceed` |
| `machine`, `verify` fails | `failed` | `halt` / `prompt` / `remind` |
| `judgment` (the script cannot confirm it) | `requires_confirmation`, never `passed` | `halt` / `prompt` / `remind` |
| already ticked (section 7) | `already_ticked`, not re-verified or re-asked | `proceed` |

A `machine` item whose `verify` is missing, not executable or runs past the timeout is `failed`, with
`cause` of `not_found`, `not_executable` or `timeout` respectively (and `nonzero_exit` or `signal` for an
ordinary failure); it is never reported as passed.

| Exit | Meaning |
|---|---|
| `0` | No applicable `block` item is unsatisfied and no applicable `confirm` item needs a decision. `advisory` failures and unconfirmed `advisory` judgment items do not count. |
| `10` | An applicable `block` item is unsatisfied (failed `machine`, or unconfirmed `judgment`). The action must halt. |
| `11` | No `block` item is unsatisfied, but a `confirm` item is: the user must be prompted (section 6), because the script cannot prompt. |

Anything non-zero means "do not proceed silently". Setup errors (invalid registry `1`, usage `2`, unknown
situation `3`) leave stdout empty. The full contract, including the timeout and the trust model for running
`verify` strings, is the header comment of `scripts/checklist.sh`.

## 7. Tick scope: how long a tick lasts

A **tick** records that an item was satisfied. `tick_scope` decides how long it counts. A **run** is one
execution of a gated phase from start to finish; its exact boundary is defined with the tick state (section 9).

| `tick_scope` | Observable behaviour |
|---|---|
| `run` | A tick made during a run is **discarded when the run ends**. The next run starts with the item unticked, so a `machine` item's `verify` runs again and a `judgment` item is asked again. Within a single run, a ticked item is not re-evaluated. |
| `persistent` | A tick **survives the end of the run and across sessions**. At later checks the item is already ticked, so its `verify` is not re-run and a `judgment` item is not re-asked, until the tick is removed (how, and where ticks are stored, is section 9). |

**When each is appropriate.** Use `run` for anything whose truth can change between runs. That is most
`machine` items (tests pass, no stray files, the tree is in a given state), and any confirmation that must
be renewed each time. Use `persistent` for one-time facts and acknowledgements that stay true once
established (the contributing guide has been read, a one-time setup is done). A `persistent` `machine`
item is not re-verified after its first pass, so reserve it for conditions that cannot regress.

## 8. File locations and the public-mirror split

There are two registry files. They share this schema and are separate files.

| File | Location | Role |
|---|---|---|
| Shipped default | `templates/checklists.json` | Generic default distributed with the framework. |
| Project instance | `checklists.json` inside the project's configs directory, `project/configs/checklists.json` in this repository | This project's own checklist. |

The project instance is located through the root resolver and never through a hardcoded `project/`
literal:

```bash
"$(scripts/resolve-root.sh get configs)/checklists.json"
```

`scripts/resolve-root.sh get configs` prints the configs directory (the `configs` path key), run in the
caller's working directory or at `JENGA_PROJECT_ROOT`. It sits beside `test-config.json` and
`scope-thresholds.json`, the existing config-surface precedent.

### Public-mirror split

`project/configs/` is **not** blocklisted in `.publicignore` (unlike `project/board/`, `project/queue/`
and `project/.playbooks/`). The project instance therefore ships downstream through `/j-mirror-public`
exactly as `test-config.json` does, and a maintainer should treat everything in it as publishable.

That is why the shipped default is a separate file. `templates/checklists.json` must stay **free of
project-specific policy**: it holds only generic items that make sense in any consumer project, and
nothing Jenga-internal (this repository's board, queue, mirror or release specifics). Policy particular to
this project belongs in the instance, which ships as this project's own checklist and not as a framework
default.

One kind of instance item is generated rather than written: the `conv-` items rendered from a project's
recorded conventions (section 9, "Provenance fields"). A project's conventions are policy particular to that
project, so they live only in its instance and never in the shipped default; see
[project-conventions.md](project-conventions.md), "Checklist generation".

## 9. Reserved for later work

The items below are deliberately **not defined** by this document. Each is owned by a named task, which
fills in its subsection here when it lands. Until then, do not rely on or invent any behaviour for them.

### Provenance fields (`E67_S05_T01`)
<!-- RESERVED: E67_S05_T01 -->

An item may carry an optional `provenance` object recording where it came from. It exists so an item added
by the Scrum Master after an agent suggested it (`Type: checklist_suggestion`, `templates/PROBLEM_RAPPORT_TEMPLATE.md`)
stays traceable to why it exists. **Authored items remain valid with no `provenance` key at all**, and an item
without one is validated exactly as before; absence means "authored by hand".

Only the Scrum Master ever writes `project/configs/checklists.json` by hand, and only after the user confirms. Agents
suggest through a rapport and never write a `provenance` key themselves. The one other writer is
`scripts/generate-convention-checklist.sh` (run by the `j.conventions` wizard), which touches only its own
`conv-` items (below).

| Field | Type | Required | Meaning |
|---|---|---|---|
| `provenance.source` | `"authored"`, `"suggested"` or `"convention"` | yes, if `provenance` is present | `authored`: written by a person. `suggested`: proposed by an agent and accepted. `convention`: generated from the project's `conventions.json` (`E69_S03_T01`). |
| `provenance.category` | non-empty string | `convention`: yes | The conventions category id (for example `naming`) the item was generated from, so the item stays traceable. |
| `provenance.suggested_by` | non-empty string | `suggested`: yes | The agent that filed the suggestion (`developer` or `tester`). |
| `provenance.origin` | `"precautionary"` or `"recurrence"` | `suggested`: yes | `precautionary`: a risk the agent saw that has not (yet) caused a failure. `recurrence`: a measure to stop an issue that already happened from happening again. |
| `provenance.evidence` | non-empty string | `suggested`: yes | The concrete, checkable fact behind the suggestion. For `recurrence` it must also name the originating incident. |
| `provenance.accepted_on` | ISO 8601 date string | `suggested`: yes | When the user confirmed the item (`YYYY-MM-DD`, optionally followed by a time). |

For `authored`, nothing beyond `source` is required or interpreted. Unknown keys inside `provenance` are
ignored, like unknown item keys. A top-level `provenance` key (outside `items[]`) is still just an unknown key.

**`convention` items.** An item with `provenance.source: "convention"` is managed by
`scripts/generate-convention-checklist.sh` (id prefix `conv-`), which rewrites, adds and removes such items from
the project's `conventions.json` and never touches any other item. Only a non-empty string `category` is required;
none of the `suggested` fields apply. The validator deliberately has no enforcement rule for them: a hand-edit that
raises a generated item to `block` must not make the whole registry unreadable, so the never-`block` guarantee is
held by the generator and by `scripts/validate-conventions.sh`. See [project-conventions.md](project-conventions.md)
for the generator contract.

Managed `conv-` items in practice (full contract in [project-conventions.md](project-conventions.md),
"Checklist generation"):

- **Identity.** The id is `conv-<category id>` (for example `conv-naming`) and `provenance.source` is
  `"convention"`. An item is managed only when both hold; a `conv-` id with other provenance is an ordinary
  item the generator will refuse to overwrite (it exits `1` on the collision rather than replacing it).
- **Generator-owned.** The generator adds, rewrites and removes these items on every run, so a category that
  leaves `conventions.json` loses its `conv-` item. It touches nothing else: authored items, `suggested` items
  and the file's other top-level keys are carried through unchanged, and managed items follow all of them.
- **Never `block`.** Generated items are `advisory` or `confirm`, never `block`; `confirm` appears only for
  the one machine-verifiable category (a recorded lint command).
- **Never edited by hand.** A hand edit is overwritten by the next run. To change one, edit the convention
  (through `j.conventions` or in `conventions.json`) and re-run the generator.
- **Coexistence.** If no instance exists yet, the generator seeds it from `templates/checklists.json` plus its own
  items, because the checker selects one whole file and never merges instance and default.

**Evidence bar.** `evidence` is held to the same bar `crucial_escalation` uses: at least one concrete,
checkable fact (a specific file or path, an exact error message, a reproduction count, or a quantifiable
impact). A bare "this seems risky" is not evidence. Judging that is the Scrum Master's job at review; the
validator can only require that `evidence` is present and non-empty.

**A `recurrence` must cite its incident.** The `evidence` of a `recurrence` item must name the originating
incident, as one of: a rapport path (a `.md` path containing `rapports/`), a commit SHA (7 to 40 hex
characters, containing at least one digit and one letter), or a task id (`E##_S##_T##`). The validator checks
that evidence *names* such an incident, not that the incident exists.

Example of an accepted `recurrence` item's provenance:

```json
"provenance": {
  "source": "suggested",
  "suggested_by": "tester",
  "origin": "recurrence",
  "evidence": "37 bats assertions passed while false; see project/rapports/problems/E50_S07_T07-inert-bats-assertions-suite-wide.md.",
  "accepted_on": "2026-10-03"
}
```

**What the validator rejects.** Each has its own message (`scripts/validate-checklists.sh` header lists the
exact tokens): `provenance` that is not an object; `source` absent or not `authored`/`suggested`/`convention`; a
`suggested` item missing `suggested_by`, `evidence` or `accepted_on`; a `convention` item missing `category`; `origin` absent or not `precautionary`/`recurrence`;
an `accepted_on` that is not an ISO date; and a `recurrence` item whose `evidence` names no incident.

### Tick state: locations and concurrency keying (`E67_S02_T03`)
<!-- RESERVED: E67_S02_T03 -->

Defined by `scripts/checklist.sh tick`; the script header is the full contract. The behaviour that sections 6
and 7 state is provided as follows.

**What a run is.** A run is one execution of a gated phase by one orchestrating session. The script cannot
observe a run's boundaries, so the **caller names the run**: it picks a run id when the phase begins, passes
the same id to every `check`, `list` and `tick` of that phase (`--run <id>` or `JENGA_CHECKLIST_RUN_ID`), and
picks a **new** id for the next execution, for example `<session id>-<situation>-<UTC timestamp>`. A run ends
when its id is no longer used: the next run has a new id and so starts with every run-scoped item unticked.
Reusing an id is a caller bug and the one way to carry a tick into a later run (the idle TTL below bounds it).
A run id is 1 to 128 characters of letters, digits, `.`, `:`, `_` and `-`, starting with a letter or digit.

There is deliberately **no default run id**. A default shared by two runs would let a `run` tick written in
one show up in the next, so ticking a `run`-scoped item with no run id is an error (exit `7`). Reading is the
safe mirror: `list`/`check` with no run id see run-scoped items as unticked, so a forgotten `--run` costs a
re-verification and never a skipped check. `persistent` items need no run id.

**Where ticks are stored.** In the directory `"$(scripts/resolve-root.sh get queue)/checklist-ticks/"`
(`project/queue/checklist-ticks/` in this repository), resolved through the root resolver. It is deliberately
**not** under the configs directory: `project/configs/` ships downstream (section 8), whereas
`project/queue/` is blocklisted in `.publicignore`, and `.gitignore` ignores the directory's contents so tick
state is never committed.

| File | Holds |
|---|---|
| `persistent.json` | Every `persistent` tick, in one shared file. |
| `run-<digest>.json` | The `run` ticks of one run, one file per run id (`digest` is the first 24 hex characters of the sha256 of the run id, so ids that differ only by case cannot share a file on a case-insensitive filesystem). |
| `<file>.lock.d`, `.tmp-<file>.<pid>` | Transient: the lock directory and the in-flight write. |
| `persistent.json.corrupt` | The last unusable store, moved aside. |

Each file is `{"version": 1, "run_id": "<id>" (run files only), "ticks": {"<item id>": record}}`, where a record
is `definition_hash`, `tick_scope`, `ticked_by`, `ticked_at` (UTC) and `note` (or `null`).

**Who confirmed.** `ticked_by` is the actor (`--by <actor>`, else `JENGA_CHECKLIST_ACTOR`, else
`os-user:<login>`; the default names only the OS account, so an agent should pass `--by`), `ticked_at` is the
time, and `note` is the optional `--note` text. `tick` does not verify the item: the caller ticks an item only
once it is satisfied (a `machine` item after `check` reported it passed, a `judgment` item after the user
confirmed it), per section 6.

**Concurrency keying.** Per-run state is one file per run id, so concurrent runs never touch the same file
(the same fix E37_S01 applied to the shared single-slot `.session_handoff.json`). The files that can be shared
(`persistent.json`, and a run file shared by parallel workers of one run) are only ever modified inside
`scripts/with-lock.sh <file> --`, so two ticks of different items both land; if the lock cannot be acquired
the tick is not recorded and exits `8`. Writes are temp-file-then-rename, so unlocked readers see a whole old
or whole new file.

**A tick is bound to the item's definition.** The record stores a hash of the item's `kind`, `text` and
`verify`. If the item has since been edited, the tick is treated as absent (with a warning on stderr), so an
old acknowledgement can never satisfy a tightened rule. Editing `enforcement`, `situations` or `tick_scope`
does not invalidate a tick.

**Lifecycle and clean-up.** A `run` tick is discarded in effect when its run ends (the next run has a new id);
its file is deleted once idle for `RUN_STATE_TTL_MINUTES` (1440; override `JENGA_CHECKLIST_RUN_TTL_MINUTES`), by
a prune that runs after every successful tick, re-checks each file under its own lock, and can never touch
`persistent.json` or a younger run file. A run file that old is also read as unticked. A `persistent` tick
lives until removed, outside the scope of every existing queue sweep (`sweep-stale-context-digests.sh` and
`on_session_end.sh` act only on `queue/context/` and `queue/handoffs/`); a future queue-wide sweep must
exclude `checklist-ticks/`.

**Removing a persistent tick.** `scripts/checklist.sh tick --clear <id>` removes it (add `--run <id>` to also
remove that run's tick). It is idempotent and does not need the registry, so a tick for a since-deleted item
can still be cleared. Deleting a state file by hand is always safe: the worst outcome is re-evaluation.

**Corruption.** An unreadable or malformed state file reads as unticked with a warning on stderr, never as a
pass; the next tick of that file moves it aside to `<file>.corrupt` and starts a fresh one.

**Known limit.** State is rooted at the resolved project root. A session inside a git worktree resolves that
worktree's own tree, so its ticks are not shared with the main tree unless `JENGA_PROJECT_ROOT` points both at
one root.

### Phase-to-skill mapping (`E67_S03_T01`)
<!-- RESERVED: E67_S03_T01 -->
Which gating skill fires which phase, and at what point in its flow. `/j-commit`, `/j-do` and
`/j-reconcile` each map to one base phase. The two release skills fire **two** phases each: the shared base
phase `pre-release` first, then a skill-specific extension phase.

| Skill | Phase(s), in firing order | Fires |
|---|---|---|
| `/j-commit` | `pre-commit` | Immediately before the commit command, after staging and after the reconcile and doc-sync steps. Also fires in `--inline` mode. |
| `/j-do` | `pre-task` | Once per dispatched unit of work, before a worktree is created and before a concurrency slot is acquired. The exact step on each of its five execution paths is defined in the "`/j-do`: firing points and deferral" subsection below. |
| `/j-reconcile` | `pre-reconcile` | After scope resolution (read-only), before any board file is touched. Not fired when `/j-commit` runs its mandatory reconcile step (see below). |
| `/j-publish` | `pre-release`, then `pre-publish` | Before any outward-facing action of a gated sub-command. `E67_S03_T04` decides which sub-commands are gated. |
| `/j-mirror-public` | `pre-release`, then `pre-mirror` | Before anything is pushed to the public remote. `E67_S03_T04` settles whether `--dry-run` and `--inventory`, which push nothing, are ungated. |

### Why the release skills do not share one phase

`/j-publish` and `/j-mirror-public` have different consequences. Publishing releases a package from the
public repository; mirroring pushes this private repository's content to that public repository. An item
that belongs to one is a wrong or meaningless question at the other. This project's own instance shows it:
"this release is being published from the public repository" is a sensible `confirm` at publish time and
nonsense at mirror time, where mirroring *is* the act of sending private content to the public repository.

One shared `pre-release` phase cannot express that, because an item can only name phases, not skills. So
the base phase `pre-release` keeps the checks that hold for **any** release (a clean working tree, a passing
test suite), and each skill adds its own extension phase for the rest.

Registry selection is whole-file with no merging (see "Combining the two files"), so a project instance that
wants those generic `pre-release` checks must include them itself. This project's instance does; it copies the
shipped default's two release items rather than inheriting them. Both stay within the schema's existing
extension mechanism (section 4), so the base vocabulary is unchanged.

**Extension phases must be declared.** `pre-publish` and `pre-mirror` are valid only in a file whose own
`situations` array lists them; this project's `project/configs/checklists.json` does. The shipped default
`templates/checklists.json` declares neither because it has no items for them. A registry that omits the
declaration answers `checklist.sh check pre-publish` with exit `3` (unknown situation).

A skill therefore treats exit `3` from its **second, skill-specific** phase as "no items for this phase" and
continues without a message. Exit `3` from a **base** phase is a genuine error and is surfaced, because the
base phases are always valid. With no registry at all, every phase answers exit `0` with `[]`.

### Why a reconcile run by `/j-commit` does not fire `pre-reconcile`

`/j-commit` runs `/j-reconcile` as its mandatory first step, before the commit's own `pre-commit` gate. At that
moment the work being committed is, by definition, uncommitted. A `pre-reconcile` item warning about
uncommitted changes would therefore fire on every commit, which turns a safeguard into noise that people learn
to ignore. A reconcile that is part of a commit flow does not fire `pre-reconcile`; the commit's own
`pre-commit` gate covers it. A `/j-reconcile` the user invokes directly still fires it. The shipped default
carries no `pre-reconcile` item for this reason; add one to a project registry for checks that make sense
before a standalone reconcile.

### Skill-name stability

The phase names, not the skill names above, are the contract. Renaming a skill changes only this table.

### Calling the checker from a skill (`E67_S03_T02`)

The one definition of how a gating skill calls `scripts/checklist.sh`. Each gating skill's `SKILL.md` carries
only a short block naming its phase and firing point (the table above) and pointing here; it does not restate
this protocol. Everything deterministic is in the checker. What follows is the part that needs judgment.

**1. Mint a run id once per execution.** A run is one execution of the gated skill from start to finish
(section 7). Before the first check, mint an id that is unique to this execution and use that same id for every
`check` and `tick` of every phase the execution fires:

```bash
RUN_ID="<skill>-$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
```

for example `commit-20261003T160312Z-4f2a9c`. A run id is 1 to 128 characters of letters, digits, `.`, `:`,
`_` and `-`, starting with a letter or digit, so it can never contain `/` or `..`. Never reuse an id for a later
execution: that is the one way a run-scoped tick leaks forward.

**2. Call the checker.** Use the repository's dual-path idiom, and pass the phase and the run id:

```bash
bash "$([ -f scripts/checklist.sh ] && echo scripts/checklist.sh || echo node_modules/@jenga-ai/agent/scripts/checklist.sh)" check <phase> --run "$RUN_ID"
```

Stdout is one JSON array (section 6); read each item's `id`, `text`, `kind`, `enforcement`, `result`, `action`
and `reason`. The exit code is the backstop and is read first.

**3. Branch on the exit code and each item's `action`.**

| Exit | What the skill does |
|---|---|
| `0` | Proceed. Items whose `action` is `remind` are shown as short reminders (the `text`, and for a failed `machine` item the `reason`); they never halt the skill and never prompt. Items whose `action` is `proceed` produce no output. |
| `10` | **Halt before doing any work.** Name each item whose `action` is `halt`: its `id`, its `text` and why (`reason`). A failed `machine` item has no override: the user fixes the cause and the skill re-runs the check, or stops. An unconfirmed `judgment` item whose `action` is `halt` is put to the user (rule 4): confirm it, or stop. After any confirmation, re-run the same `check` with the same run id and branch again on the new exit code. Nothing the skill gates has happened yet. |
| `11` | No `block` item is unsatisfied, but at least one `confirm` item needs a decision. For each item whose `action` is `prompt`, ask the user with `CLAUDE.md`'s numbered Interaction Pattern (free text always last) and proceed **only on an explicit choice**. A failed `machine` item offers: proceed without satisfying it, stop, or (after the user fixes the cause) re-check. An unconfirmed `judgment` item offers: confirm it, proceed without confirming it, or stop. Silence, or free text the skill cannot map to one of those, means stop. Choosing to proceed does not tick the item (section 6). |
| any other non-zero | Surface the checker's stderr to the user and do not proceed silently, with the one exception in rule 6. Setup errors (`1` invalid registry, `2` usage, `4` python3 missing, `5` internal) leave stdout empty. |

**4. A judgment item is never self-certified.** The checker cannot confirm a `judgment` item (it is reported as
`requires_confirmation`, never `passed`), and neither may the agent running the skill: the agent does not decide
that a judgment item is satisfied. The item's `text` is put to the user, and only after the user explicitly
confirms is it ticked:

```bash
bash "$([ -f scripts/checklist.sh ] && echo scripts/checklist.sh || echo node_modules/@jenga-ai/agent/scripts/checklist.sh)" tick <id> --run "$RUN_ID" --by user:via-<skill>
```

`--by` names who took the responsibility, so a confirmation by the user is recorded as `user:via-<skill>` and
never as an `agent:` actor. **Only a satisfied item is ever ticked.** An item the user declined to confirm, or
that was proceeded past, stays unticked. The only other item a skill ticks is a `machine` item that `check`
reported as `passed` and whose `tick_scope` is `persistent` (`--by agent:<skill>`), so that a one-time fact is
not re-verified; a `passed` run-scoped item is simply re-verified if the check is repeated in the same run.

**5. An absent or empty registry is a silent no-op.** With no registry file, an empty `items` array, or no item
naming the phase, `check` prints `[]` and exits `0`. The skill then produces no output, no warning and no
prompt, and behaves exactly as it did before the gate existed.

**6. Exit `3` depends on which phase it came from.** A skill that fires a base phase (`pre-commit`, `pre-task`,
`pre-release`, `pre-reconcile`) treats exit `3` as a genuine error and surfaces it. A skill that fires a second,
skill-specific extension phase (`pre-publish`, `pre-mirror`) treats exit `3` from that phase as "no items for
this phase" and continues without a message (see "Why the release skills do not share one phase").

### `/j-do`: firing points and deferral (`E67_S03_T03`)

How `skills/j-do/SKILL.md` applies "Calling the checker from a skill" to phase `pre-task`. The skill carries a
short gate step, `### 4.1.2. Pre-task gate`, and points here for the reasoning.

**Position.** The gate sits after `### 4.1` (override validation, which only reads) and before `### 4.1.5`
(the `--trivial` override), the locked-task guard in `### 4.2`, every worktree creation and every `### 4.4`
slot acquisition. The invariant it buys: a `block` failure halts before any worktree exists and before a
concurrency slot is consumed, so there is nothing to release, and the item is left exactly as it was, still
`Pending`, with no status write. Putting it before 4.1.5 matters as much as putting it before 4.4, because
4.1.5 and the locked guard rewrite `execution_scope`, `jenga_assigned` and `override_justification`; a gate
placed after them would leave a half-applied override behind on a halt. An item that fails override
validation never reaches the gate, so a malformed task does not cost the user a checklist prompt.

**The five places a unit of work starts.** One gate step serves all of them:

| Path | How it reaches the gate |
|---|---|
| Inline Execution Path (`### 4.2`) | Falls through step 4, 4.1, 4.1.2, 4.1.5, then 4.2. Fires with no subagent, worktree or slot involved. |
| Light Execution Path (`### 4.3`) | Same fall-through; the gate has fired before 4.3's status write and slot acquisition. |
| Standard task-scope invocation (`### 5`) | Same fall-through; the gate has fired before step 5's slot acquisition and worktree. |
| Story-Bundle mode (`### 1.5`) | Skips steps 2 to 4, so it calls the gate explicitly, once for the bundle, after the story file is read and **before** the epic lock is acquired. A halt leaves no lock, manifest or slot. It never fires per task inside the bundle. |
| `Fallback to Full Task-Scope Pipeline` | Does **not** fire. A fallback re-routes a unit already gated once, so it reuses that gate's result and run id. |

**Once per unit.** A unit is whatever step 4 resolved, or the story for a bundle. The gate fires once per
unit and never twice for the same one: the fallback is the only path that could revisit a unit, and it is
excluded by name. `capacity_blocked` is a separate matter: that item is re-dispatched as a new `/do`
invocation on a later wave, which is a new unit and gets a new run id, so its judgment items are asked again.
That cost is accepted, because gating after slot acquisition would break the invariant above.

**Run id.** Section 9's "mint once per execution" is read here as once per dispatched unit: each pass through
`/j-do`'s step 8 loop mints a fresh id (`do-<UTC time>-<random>`). One id for a whole looping session would let
a judgment item the user confirmed for one task silently satisfy the next, different task. The id is kept in
the session for the rest of the unit so the fallback can reuse it and re-ask nothing.

**Who confirms a judgment or `confirm` item.** `/j-do`'s own session does, never the developer subagent it
spawns afterwards. When the user can answer a prompt in that session (a standalone `/j-do`, including one run
by `/j-dooo`, whose `/do` runs in the foreground and only launches the developer in the background), the item
is put to them with the numbered prompt and is ticked with `--by user:via-do` only after an explicit
confirmation.

**Background deferral.** A background sub-agent has no live user channel (the E39 ruling: only the foreground
session can pause and confirm). `/j-do` treats itself as having none when it was handed a caller-supplied
session id (`### 4.4` case (b), as `/jenga` Phase 4 does) or when it cannot tell. It then never self-certifies
and never proceeds past an unresolved item. Any exit `10` or `11` outcome defers the unit instead:

- Nothing is started: no worktree, no slot, no subagent, and no status write. If the caller already moved the
  item to `In Progress`, `/j-do` reverts it to `Pending` with the same locking protocol `### 4.4` uses.
- One `preflight_deferred` entry is appended to `project/logs/events.json` (`event`, `agent: orchestrator`,
  `session_id`, `item_id`, `phase`, `run_id`, `items`, `date`). It is deliberately not `capacity_blocked`: the
  cause differs, and `capacity_blocked` drives a consecutive-wave counter and a `capacity_starvation` trigger
  that this event must not feed.
- The unit is reported as "deferred", never "failed". A failed machine item under `block` is deferred too, not
  only an unconfirmed judgment item, since a background agent can neither fix the cause nor choose to proceed.

A `remind` or `advisory` item never defers. It is passed to the developer subagent as a "Pre-flight reminders"
block in the context payload (and shown directly on the inline path, which has no subagent).

**Known gap.** `preflight_deferred` has no consecutive-wave counter and no escalation trigger, unlike
`capacity_blocked`. `/jenga` Phase 4's Pending rescan may therefore re-dispatch a deferred unit on each wave
and defer it again until a user acts. Closing that is a change to `/jenga` and `/j-dooo`, which this task does
not make.

### Situation marker (`E67_S04_T01`)

The channel through which the hook-enforced layer learns which situation is active. Defined by
`scripts/checklist-marker.sh`; that script's header is the full contract and this section is the schema and
lifecycle half of it.

**Why it exists.** A hook fires on a tool event and is told nothing else. It cannot see that a gating skill
is mid-phase, which phase that is, or which run id that phase minted — so without a marker it cannot
distinguish `pre-commit` from `pre-task` and has no phase to pass to `check`. Nothing else in this feature
carries that information. A gating skill writes the marker when it enters its phase and clears it when it
leaves; the hook (`E67_S04_T02`) reads it, runs `checklist.sh check <situation>` for whatever it finds, and
blocks on a failed `block` item. With no marker the hook does nothing at all, which is what makes an
ordinary session behave exactly as it did before the gate existed (section 9's "absent or empty registry is
a silent no-op", one layer down).

The marker is deliberately **not** part of the registry or the tick store. It holds no policy and no
acknowledgement — only "which phase is this session in right now".

#### Format

One file per session key, under the queue directory:

```
"$(scripts/resolve-root.sh get queue)/checklist-markers/marker-<digest>.json"
```

where `<digest>` is the first 24 hex characters of sha256 of the session key — the same file-per-key rule,
with the same digest length, that the tick store uses for `run-<digest>.json`. The file holds a **stack**
of frames:

```json
{
  "version": 1,
  "session_id": "d501ed75-3361-575a-bb91-8d6558bd37e1",
  "stack": [
    {
      "token": "pre-commit-9d5561da805bf0b4",
      "situation": "pre-commit",
      "run_id": "commit-20261003T160312Z-4f2a9c",
      "skill": "j.commit",
      "written_at": "2026-10-03T19:40:41Z",
      "expires_at": "2026-10-03T20:40:41Z",
      "writer_pid": 19681
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `version` | File-format version, currently `1`. |
| `session_id` | The resolved session key this file belongs to. Re-checked on read (see "Keying"). |
| `stack[]` | The phases currently entered, outermost first. The **active** phase is the topmost live frame. |
| `token` | Identifies one frame, so a caller can clear or refresh exactly the frame it pushed. Returned by `write`; stable for the frame's life (`refresh` keeps it). |
| `situation` | The lifecycle phase (section 4's vocabulary). Validated against `^[a-z][a-z0-9-]*$` only — the marker never reads the registry, so it is cheap and cannot fail because of a registry problem. |
| `run_id` | The run id the phase minted (section 7, "What a run is"), or `null`. A reader passes it back to `checklist.sh` as `--run` so that run's run-scoped ticks are visible; without it `check` sees run-scoped items as unticked, which is the checker's own safe default. |
| `skill` | Which skill entered the phase. Diagnostics only; nothing branches on it. |
| `written_at` / `expires_at` | UTC, to the second. `expires_at` is `written_at` + `marker_ttl_minutes`. |
| `writer_pid` | Diagnostics only. Deliberately **not** a liveness signal — see "Stale-marker recovery". |

`read` prints the active frame as one JSON object, adding `depth` (`1` for the outermost frame), or prints
**nothing** when no phase is active. `read --field <name>` prints a single field as a bare line, for a
caller that wants one value without a JSON parser.

#### Lifecycle

```bash
MARKER="$([ -f scripts/checklist-marker.sh ] && echo scripts/checklist-marker.sh || echo node_modules/@jenga-ai/agent/scripts/checklist-marker.sh)"

TOKEN="$(bash "$MARKER" write --situation <phase> --run "$RUN_ID" --skill <skill>)"   # on entry
...                                                                                    # the gated phase
bash "$MARKER" refresh --token "$TOKEN"      # only a phase that may outlive the TTL; exit 3 = frame gone
bash "$MARKER" clear --token "$TOKEN"                                                  # on exit
```

1. **Entry.** `write` pushes a frame and prints its token. It is called **once per phase entry**, straight
   after the run id is minted and *before* the first `check` — the hook must be able to see the phase for
   the whole of it, including the check itself.
2. **Exit.** `clear` pops the frame, on **every** exit path: success, a `block` halt, a user declining a
   `confirm` item, a deferral, or an error. Clearing is idempotent and never fails — no marker file, no
   matching frame, or an already-expired frame all succeed silently — specifically so a caller on an error
   path can clear unconditionally without having to know whether its `write` landed.
3. **Abnormal exit.** A session that dies cannot clear anything, which is what "Stale-marker recovery"
   below exists for. The design does not rely on the clear happening.
4. **`write` always pushes; `refresh --token` extends.** `write --situation <s>` is a **pure push**: every
   call adds a new frame with a new token, whatever the stack already holds. It does no matching against
   existing frames at any depth and has no refresh heuristic. A phase that outlives the TTL extends **its own
   frame** with `refresh --token "$TOKEN"`, which updates the expiry of exactly the live frame with that
   token, wherever it sits in the stack, **in place**: its token and its position (so its depth) are
   unchanged, nothing is pushed, and no other frame is touched. Refreshing an **outer** frame while an inner
   phase is nested on top therefore never changes the active phase — it stays the innermost one.

   **`refresh` never silently succeeds.** A token that names no live frame — never written, already cleared,
   or expired — writes nothing, prints "no live frame" on stderr and exits **`3`**, so the caller can branch
   and `write` again for a fresh frame and a fresh token if its phase is still running. A silent no-op would
   leave a caller believing it is still gated when it is not. An expired frame is **never resurrected**:
   once its expiry has passed it is gone, and only a new `write` brings the phase back.
   With no marker file there is no live frame either, so that is also exit `3` (and `refresh` does not
   create the directory); with no session key it exits `7`, like `write`.

   **Exit code `3` is the marker's own.** `checklist-marker.sh` uses `0 1 2 3 4 5 7 8 9`. `3` was chosen
   over the equally free `6` only because it is the lowest free code. These codes are **not parallel to
   `checklist.sh`'s** — there `6` is "not an item", `7` is "run-scoped, no run id" and `3` is "unknown
   situation", whereas here `7` is "no session key" and `8` is "not written / cleared". Read the marker's
   own table in its header, not `checklist.sh`'s.

   **The no-growth guarantee is withdrawn.** An earlier version of this section (and of the script's header)
   guaranteed that "a caller that writes twice cannot grow the stack", first by refreshing only a matching
   *topmost* frame and then by refreshing a matching frame *anywhere*. Both were guesses at what
   `write --situation <s>` means, because "I am entering a new `<s>` phase" and "I am still in my `<s>`
   phase" are indistinguishable from the argument. Matching only the top mishandled nesting: a long
   `/j-do` `pre-task` phase carrying a `/j-commit` `pre-commit` frame pushed a *third* `pre-task` frame,
   which made `read` report `pre-task` while the session was inside `pre-commit` and left the outer
   frame's expiry untouched (finding 2 of the rapport below). Matching anywhere mishandled the same
   situation re-entered non-adjacently — `pre-commit` -> `pre-task` -> `pre-commit`: the inner `write`
   returned the **outer** frame's token, `read` reported `pre-task`, and the inner `clear --token` then
   popped the still-running `pre-task` frame, leaving it ungated. Both are fixed by removing the guess: the
   caller knows which it means, so it says so. A distinct token per refresh was also considered and
   rejected — it makes the caller's stored token stale, so its `clear --token` matches nothing and the
   frame leaks to the TTL.

   **The accepted cost:** a caller that writes twice by mistake now **does** grow the stack, by one frame
   per call. That is a caller bug, bounded by the TTL and by pruning, and far cheaper than silently
   un-gating an enclosing phase. Callers must not rely on a repeated `write` being idempotent.
   (`project/rapports/problems/E67_S04_T01-marker-noop-cost-claim-and-nested-refresh.md`.)

   **Expiry still wins.** Expired frames are dropped on every `write` (and `refresh`, `clear`) before
   anything else happens, so a `write` can never resurrect a stale frame — it pushes a new one.
   Stale-marker recovery is not weakened.

**Nesting is why it is a stack.** Phases nest in practice: `/j-commit` (`pre-commit`) is reachable from
inside `/j-do`'s `pre-task` phase, and `/j-commit` itself calls `/j-reconcile`. If the marker held a single
value, the inner phase's `clear` would delete the outer phase's marker and the rest of the outer phase
would run ungated — a silent hole, visible only as "the hook sometimes does not fire". With a stack, the
active phase is the innermost one currently running, which is the phase a tool call is actually happening
inside. Clearing a frame also clears every frame **above** it, since an inner phase cannot still be running
once the phase containing it is leaving.

#### TTL

`marker_ttl_minutes` in `scope-thresholds.json` (the configs directory; documented in
`project/configs/README.md`), **read fresh from config on every operation** — exactly the way
`scripts/acquire-concurrency-slot.sh` reads `slot_ttl_minutes` from the same file. Nothing about the TTL is
compiled into the script. A missing file or a missing/invalid key is an environment error (exit `5`) for
`write`, `refresh`, `clear` and `prune`, and "no phase is active" for `read`, which must never fail.
`JENGA_CHECKLIST_MARKER_TTL_MINUTES` overrides it as a **test seam only**, in the style of
`JENGA_CHECKLIST_RUN_TTL_MINUTES`.

The shipped value is **60 minutes**, and it is a judgement rather than a measurement. Too long re-creates
the wedge the TTL exists to prevent — a dead session keeps gating for as long as the TTL lasts. Too short
lets a long but perfectly healthy phase quietly stop being gated. 60 is longer than `slot_ttl_minutes`
(45, which guards a single dispatch against a crashed subagent) and far shorter than the tick store's
1440-minute idle TTL (which bounds a whole orchestrated run). A phase that genuinely runs longer is
expected to call `refresh --token "$TOKEN"`, which extends exactly its own frame in place (and does so
correctly even when an inner phase is nested on top — see lifecycle item 4 above, which is what makes this
a real mitigation rather than a claimed one). If `refresh` exits `3` the frame has already expired and the
phase `write`s again. Re-`write`ing without a `refresh` is **not** a refresh: it pushes a second frame.
Change the value in the config, not in the script.

#### Stale-marker recovery

An expired or orphaned marker is treated as **absent**, so a session that died mid-phase cannot wedge every
later session in the repository. This is the marker's primary failure mode and is handled by three
mechanisms, not one:

1. **A TTL per frame.** A frame whose `expires_at` is at or before now is never reported by `read`, and is
   dropped by `write` and `clear` before they do anything else. A dead session therefore stops gating
   anything after at most the TTL, with no cleanup and no human in the loop. A frame whose `expires_at`
   cannot be parsed is expired by definition — an unreadable expiry is never trusted into a gate. Expired
   frames are dropped **individually** rather than truncating everything above them: because `refresh`
   extends a frame in place, the stack is not necessarily ordered by expiry, and an expired outer frame can sit
   below an inner one that was just refreshed and is demonstrably alive.
2. **Per-session keying.** A reader only ever opens its own key's file, so another session's abandoned
   marker is not merely expired, it is **unreachable**. No session can be wedged by a phase it never
   entered — the strongest form of the guarantee, and one that holds regardless of the TTL.
3. **Pruning.** Every `write` and `clear` (and the explicit `prune`) deletes marker files with no live
   frame left, plus `.tmp-*` files and `.lock.d` directories older than the TTL (crashed writers), so
   abandoned files do not accumulate in the queue directory. Pruning is best effort, never fails the
   operation that triggered it, and only ever matches `marker-*.json`, `.tmp-*` and `*.lock.d` — it cannot
   touch a neighbouring feature's state. Same model as the tick store's prune-on-every-tick.

**The TTL is load-bearing, not belt-and-braces.** `claude --resume` keeps the **same** session id, so a
session that died mid-phase and is resumed an hour later resolves the same key and would read its own
abandoned frame straight back. Per-session keying does not help there; only the TTL does.

**What is deliberately not used as a liveness signal: the writing process's pid.** The writer is a
short-lived script invocation that has already exited by the time anyone reads the marker, and its parent
is a per-command shell, so a pid-liveness check would report almost every marker as orphaned and skip the
gate. `writer_pid` is recorded for diagnostics only. The liveness key that does work is the session key
itself (mechanism 2), bounded by the TTL (mechanism 1).

#### Keying and concurrency

Consistent with the tick state keying above, and for the same reason: **one file per key**, so two
concurrent sessions in different phases write and read two different files and can no more collide than
two concurrent runs can. This is the fix `E37_S01` made for `handoffs/` applied a third time — a single
shared path whose last writer silently wins is the bug being avoided.

Nothing in a script can observe which session it is running in, so — exactly as the tick store's run id is
*named by its caller* — the session key is **resolved**, through one probe order used identically by the
writer and the reader:

| Order | Source |
|---|---|
| 1 | `--session <key>` |
| 2 | `JENGA_CHECKLIST_SESSION_ID` (an explicit override, and the tests' seam) |
| 3 | `CLAUDE_CODE_SESSION_ID` — the harness's own session id, exported into every child process. The normal source, and the same value a hook receives as `session_id` in its stdin payload. |
| 4 | `JENGA_SESSION_ID` — the session id `hooks/on_session_end.sh` already uses. |

**In normal operation neither side passes `--session`:** both resolve from the same environment, so they
cannot disagree. That is the whole reason the probe order lives in one place instead of each caller picking
a value. A hook in particular should let the script resolve the key rather than passing the `session_id`
from its payload — the two are the same value today, and if a future harness ever made them differ, a
payload-supplied key would silently stop matching what the skill wrote. A key is 1 to 128 characters of
letters, digits, `.`, `:`, `_` and `-`, starting with a letter or digit, so it can never contain `/` or
`..` and is always safe in a filename.

No key at all is **asymmetric**, the same way a missing run id is for the tick store:

- `write` (and `refresh`) is an **error** (exit `7`). A marker written under a guessed or shared default key would be
  visible to a session that never entered the phase — precisely the cross-session wedge this design exists
  to prevent — so there is no fallback key.
- `read` reports "no phase is active" (exit `0`). A forgotten key costs a skipped gate, never a gate
  applied to the wrong session. Fail-open is the correct direction for the reader and the only one
  consistent with "with no marker present the hook is a silent no-op".

The resolved key is **also stored inside the file** as `session_id` and re-checked on read: a file whose
`session_id` is not the key being read is treated as absent, with a warning. So even a digest mix-up or a
hand-copied file cannot make one session read another's phase.

Within one session, every read-modify-write goes through `scripts/with-lock.sh <file> -- <command>` (a
`mkdir`-based lock, not `flock`, which macOS does not ship) and lands as a temp file in the same directory,
fsynced and renamed over the target. A concurrent reader therefore sees a whole old or whole new file,
never half of one. Readers take no lock, so `read` cannot be blocked by a writer and cannot block one. If
the lock cannot be acquired within `with-lock.sh`'s timeout, the operation is **not** performed and exits
`8`; a marker is never written unlocked.

#### `read` never fails, and what its no-marker path costs

Every state problem — no marker file, a corrupt one, an unresolvable queue directory, a missing or invalid
TTL, a `session_id` that does not match the requested key — is reported as "no phase is active": a warning
on stderr, nothing on stdout, exit `0`. This is the same degradation `checklist.sh`'s `tick_state_of` makes
to `unticked`, and for the same reason: a broken lookup must not break the session that is merely passing
through it. Only a usage error exits non-zero (`2`), because that is a caller bug rather than a state
problem.

`read`'s no-marker check is **pure bash** — a directory test and a glob for any `marker-*.json`, with no
`python3`, no `scope-thresholds.json` read and no marker parsing. A glob rather than a digest lookup,
deliberately: computing this session's own digest would itself cost a spawn, and "no marker file exists at
all" is the case an ordinary session is in. Only once some marker exists does anything further run, and the
per-session check still happens there, so the glob is a fast reject and never a way to read another
session's phase.

**It is not free, and `E67_S04_T02` should budget against the real figure.** Resolving the marker directory
costs one `resolve-root.sh get queue` subprocess (it climbs for `workflow.json` and runs `jq` twice), which
is unavoidable here because the queue path must not be a hardcoded working-tree literal (`E34_S01`).
Measured in this repository with no marker present, 20 calls, bash 3.2 on Darwin:

| Condition | Cost |
|---|---|
| Normal operation (`JENGA_CHECKLIST_MARKER_DIR` unset) | **40.4 ms/call** |
| With that test seam set — i.e. skipping the resolver | 20.4 ms/call |
| A bare `bash -c true`, for scale | 10.8 ms/call |

An earlier version of this section claimed the path "spawns no subprocess at all", which was only ever true
with the test seam set. Corrected after the tester measured it on `E67_S04_T01` (see
`project/rapports/problems/E67_S04_T01-marker-noop-cost-claim-and-nested-refresh.md`, finding 1).

`E67_S04_T02` owns the hook that pays this on **every tool event** and is the only place that can judge
whether ~40 ms is material. If it is, the lever is to keep the resolver off the hot path — probing a
conventional relative path first, or caching the resolved queue directory for the session — which adds a
second resolution rule and so is a deliberate design decision for that task, not a tweak to make here.
Sourcing `resolve-root.sh` instead of spawning it was measured and is **not** the answer (22.9 ms versus
24.5 ms: its two internal `jq` calls dominate, not the `bash` spawn).

**Answered.** `E67_S04_T02` judged it material and took the first of those levers: the hook does not call
this subcommand to find out whether a marker exists at all, and reaches its no-marker answer in pure bash
for 11.0 ms/call. The figures, the fallback that keeps it honest, and why the second resolution rule is
safe are in "The enforcing hook" below. Nothing about `read` itself changed.

#### State location and the public-mirror split

`checklist-markers/` sits beside the tick store's `checklist-ticks/` under the queue directory, for the
same two reasons given in "Tick state" above: the queue directory is blocklisted in `.publicignore`, so
marker state never ships downstream through `/j-mirror-public`, and `.gitignore` ignores the
subdirectory's contents (all but `.gitkeep`), so a transient "which phase am I in" value is never
committed. A committed marker would gate every clone on a phase that is not running.

The sweeping that exists in the queue today is scoped to other subdirectories
(`sweep-stale-context-digests.sh` to `context/`, `on_session_end.sh` to `handoffs/`), none to this one. A
marker is transient by design, so unlike the tick store's `persistent.json` a future queue-wide sweep
deleting one would be harmless.

**Known limit, inherited from the root resolver and not re-litigated here** (it is already recorded for
tick state above): state is rooted at the resolved project root, so a session running inside a git worktree
resolves that worktree's own tree. A marker written in a worktree is not visible from the main tree and
disappears with the worktree; set `JENGA_PROJECT_ROOT` to share one root. In practice this is benign for
the marker, because a session's hook and its gating skill run in the same tree and so agree.

#### Calling it from a skill

Each gating skill's `SKILL.md` carries only two short lines — the `write` on entry and the `clear` on exit
— and points here, exactly as it does for the checker call in "Calling the checker from a skill". The
protocol is:

1. Mint the run id (rule 1 of that section).
2. `write --situation <phase> --run "$RUN_ID" --skill <skill>`, capturing the token, **before** the first
   `check`.
3. Run the phase and its checks as that section already defines.
4. `clear --token "$TOKEN"` on every exit path, including a `block` halt, a declined `confirm`, a deferral
   and an error.

A skill that fires two phases in one execution (`pre-release` then `pre-publish` / `pre-mirror`) writes a
frame per phase with the one shared run id, and clears them innermost-first — or simply clears the
outermost frame, which pops the inner one with it.

A failure of `write` is **not** a reason to abandon the phase: the gate the skill itself performs by calling
`checklist.sh` is unaffected, and only the hook-enforced backstop is lost. Report the marker's stderr and
continue with the checker-driven gate.

### The enforcing hook (`E67_S04_T02`)

`hooks/on_preflight_check.sh`. The layer that makes enforcement independent of an agent choosing to call
the checker — without it the feature still relies on an agent remembering, which is the problem the epic
exists to solve, one level down. It fires on a tool event, reads the situation marker to learn which phase
is active, runs `checklist.sh check <phase>`, and **refuses the tool call** when a `block`-enforcement item
is unsatisfied.

Its independence is partial and worth stating plainly: the marker is written by the gating skill, so the
hook is a backstop against a skill that entered a phase and then *ignored the checker's answer*, not
against a skill that never entered the phase at all. That is the gap "Calling it from a skill" above
already names ("only the hook-enforced backstop is lost").

#### Event, matcher and payload

Registered under `hooks.PreToolUse` with the matcher `Bash|Task|Agent`. `PreToolUse` is the only event that
can refuse an operation before it happens. The matcher is narrow because only those tools can actually
*take* a gated action — every `git commit`, `git push`, `npm publish`, `gh release` and `mirror.sh` run is a
`Bash` call, and a developer dispatch is a `Task`/`Agent` call. That narrowing matters more for "no
measurable session impact" than any micro-optimisation inside the script: `Read`, `Edit`, `Grep`, `Glob`
and every other tool never spawn the hook **at all**.

The hook reads the harness's payload as one JSON object on stdin and needs two fields from it:
`.tool_name` and, for a `Bash` call, `.tool_input.command`. It takes no arguments.

The cost of the narrowing, stated rather than hidden: a board write made through `Edit`/`Write` during
`pre-reconcile` is **not** gated by the hook. The hook gates irreversible *commands*; the skill-level gate
remains the layer that covers everything else.

#### What it gates, and why not every tool call

Refusing every tool call while a phase is active would be a wedge, not enforcement. With a `block` item
failing, the agent could not run the item's `verify`, could not `tick` it, and could not even `clear` the
marker — every one of those is itself a tool call. The only ways out would be the marker's TTL or killing
the session. So the hook gates each phase's **own irreversible operation** and nothing else, which leaves
every remediation path open:

| Active phase | Gated operation |
|---|---|
| `pre-commit` | `git … commit` |
| `pre-task` | subagent dispatch (`Task`/`Agent`), `git worktree add` |
| `pre-reconcile` | `git merge`, `git worktree remove` |
| `pre-release` | `npm publish`, `gh release`, `git push`, `git tag` |
| `pre-publish` | `npm publish`, `gh release`, `git push`, `git tag` |
| `pre-mirror` | `git push`, `mirror.sh` |
| any other phase | the **union** of every row above, plus `git reset --hard` |

The last row is the default for an extension phase the table does not name (`pre-deploy`, …), so a project
that declares its own phase still gets the standard irreversible-action set gated rather than silently
getting no hook. The table is in the script, as one `case` statement; it is not configurable, and adding a
phase to it is a deliberate edit.

Matching is by **deliberately loose globs** (`*git*commit*`, not an exact command parse) because the error
is not symmetric: **over-matching costs one wasted `check`; under-matching is missed enforcement.**
`git -C /p commit`, `cd x && git commit` and a commit buried in an `&&` chain all have to match, and a
loose glob gets all three. The accepted cost is that `echo "git commit"` matches too and triggers a
harmless check.

The union is also used as a **pre-filter**: the command is tested against it *before* the marker is read,
so an ordinary `Bash` call inside a long `pre-task` phase pays one `jq` parse rather than a marker read as
well.

#### The run id is read from the marker, and it is load-bearing

The hook passes the marker frame's `run_id` to `check` as `--run`. Without it, a run-scoped item the gating
skill had already ticked would read as unticked and the hook would refuse an operation whose gate
legitimately passed. This is the whole reason `write --run` exists (see "Format" above).

The hook passes **no** `--session`: per "Keying and concurrency" above, a hook lets
`checklist-marker.sh` resolve the session key from the environment rather than passing the `session_id`
from its own payload. The two are the same value today, and a payload-supplied key would silently stop
matching what the skill wrote if a future harness ever made them differ.

#### The decision

| `check` exit | Hook decision |
|---|---|
| `0` | allow, silently. `remind` items are the gating skill's business; the hook never narrates. |
| `10` | **refuse.** Each item whose `action` is `halt` is named in the reason, with its `id`, `text` and `reason`. |
| `11` | `permissionDecision: "ask"` — which is exactly what `confirm` enforcement means. A harness that does not support `ask` degrades to allow, the safe direction. |
| `3` | allow, silently: an extension phase no item names, per rule 6 of "Calling the checker from a skill". |
| `1`, `2`, `4`, `5` | allow, with a loud warning on `stderr`. See below. |

A refusal is emitted **both** ways: exit status `2` (the documented `PreToolUse` blocking status, whose
`stderr` is fed back to the model) **and** a `permissionDecision: "deny"` JSON object on stdout. Be clear
about which one does the refusing under Claude Code: it processes stdout JSON only on exit `0` and ignores
it on exit `2`, so **exit `2` plus `stderr` is what blocks the call**, and the JSON is there for a host that
reads it. The refusal never depends on the JSON being understood. The `ask` decision is the opposite case: it
exits `0` and the JSON is the whole mechanism. The hook returns no other non-zero status, deliberately — a hook that exited `1` on its own
internal problem would turn a bug in it into a visible error on every tool call.

**Fail-open on a setup error is deliberate.** `check` exits `1`/`2`/`4`/`5` for an invalid registry, a
usage error, a missing `python3` and an internal error. Refusing on those would wedge a user whose
`python3` is missing out of **every** `git commit`, with no way past the hook. The skill-level gate is the
layer that refuses to proceed on a setup error (rule 3 of "Calling the checker from a skill"); the hook is
a backstop against a failed policy **item**, not against a broken toolchain. The accepted cost is that a
corrupted registry disables the hook — loudly, never silently.

#### The no-marker path: what it actually costs

`E67_S04_T01` measured `checklist-marker.sh read` with no marker at **40.4 ms/call** and left the "is that
material on the hot path" decision to this task (see "`read` never fails" above, and the rapport it cites).
On a hook that fires per tool call it is material, so **the hook does not call the marker script to find
out whether a marker exists.** Its first stage is pure bash with zero subprocesses — no fork, no exec, no
`$(…)`:

1. stdin is drained with the `read` **builtin**, never `cat`.
2. The marker directory is located without `resolve-root.sh`: `JENGA_CHECKLIST_MARKER_DIR` if set, else an
   upward walk from `$PWD` for `project/configs/workflow.json` then `.project/configs/workflow.json` —
   the resolver's own step 2, which is already pure bash inside the resolver — honouring
   `JENGA_PROJECT_ROOT` first exactly as the resolver does.
3. `paths.queue` is read out of that `workflow.json` with the `read` builtin and bash string slicing. No
   `jq`.
4. If `<queue>/checklist-markers` does not exist, or exists and holds no `marker-*.json` (a glob, not a
   digest lookup — same reasoning as `read`'s own fast reject), the hook exits `0` silently. The directory
   is created by the first marker `write`, so "no marker file" is exactly the ordinary session's case.

This is lever (a) of the two that section offered ("probing a conventional relative path first"). Lever (b),
sourcing the resolver, was already measured there and ruled out.

**Correctness is never traded for the fast path, only speed.** The pure-bash probe is an *accelerator*
whose failure mode is falling back to the real resolver, never skipping the gate: if `paths.queue` cannot
be read in pure bash (a `workflow.json` whose key and colon sit on different lines, for instance), the hook
goes straight to `checklist-marker.sh read`, which resolves the directory properly. Both branches are
exercised: a registry with a non-conventional `paths.queue` is honoured by the pure-bash parse, and an
unparseable layout defers instead of probing blind.

Measured in this repository, bash 3.2 on Darwin, `n` = 20–30 per figure:

| Case | Cost |
|---|---|
| A bare `bash -c true`, for scale | 9.9 ms/call |
| **The hook, no marker — the ordinary session** | **11.0 ms/call** |
| The naive design (`checklist-marker.sh read` first) | 34.9 ms/call |
| Active phase, a `Bash` call that is not the gated operation | 18.2 ms/call |
| Active phase, the gated operation (marker read + `check` running its `verify` commands) | 414 ms, once |

So the no-marker path is **1.1 ms over the cost of starting `bash` at all**, and that is only paid on
`Bash`/`Task`/`Agent` calls. The 414 ms figure is the full gate and is paid once, on the operation being
gated, with its own registry's `verify` commands dominating it.

Re-measured on the resumed run (same machine, `n` = 60, two rounds, payload on stdin as the harness sends
it): bare `bash -c true` 8.1 and 8.3 ms; the hook with no marker 9.1 and 9.6 ms, i.e. **+1.0 to +1.3 ms over
a bare `bash` start**; the naive `checklist-marker.sh read` 30.8 and 29.4 ms; the hook from a directory with
no `workflow.json` anywhere above it 8.3 ms. Invoked through the registered `settings.json` command string
(an outer shell, the `for`/`[ -x ]` probe, then `exec` of the hook) it is 18.9 to 19.6 ms against 13.9 to
14.2 ms for two bare `bash` starts; that harness-side cost, a shell plus a script start, is paid by any
command hook and is not removable by editing the script. The absolute figures drift with machine load
between runs (compare the table above); the **delta over a bare start** is the stable number.

**Known limit, inherited from the root resolver.** Stage 1 keys off `$PWD` and `JENGA_PROJECT_ROOT`, the
same inputs `checklist-marker.sh` uses, so the hook and the gating skill agree whenever they share a
working directory — which they do within a session, including inside a worktree. Adding
`CLAUDE_PROJECT_DIR` as a *fourth* anchor would not help: the authoritative `read` that follows still
resolves from `$PWD`, so a directory the marker script would never write to could only produce a false
"maybe" and then an allow. Set `JENGA_PROJECT_ROOT` to pin both ends to one root.

#### Why it holds at permission level 5 (Unrestricted)

The hook's decision is computed from the marker and the registry and **nothing else**. It never reads
`.jenga-permission-level.json`, `settings.json` or any permission state, so there is no code path by which a
level could relax it, and `PreToolUse` is evaluated ahead of permission resolution, so a `deny` is not
something an `autoMode.allow` entry can pre-empt. There is deliberately **no environment variable that
disables the hook**: the only way off is unregistering it.

**The real risk to that property is the level switch, not the script, and it is why the hook is registered
in six files rather than one.** All five `templates/permission-levels/level-*.json` are *complete*
`settings.json` documents, and `scripts/jenga-permission-level-switch.sh` copies the matching one over
`.claude/settings.json` and `.agents/settings.json` as a **whole-file overwrite**.
`skills/jenga-permission-level/SKILL.md` states the invariant: "All 5 templates carry byte-identical
`defaultMode`, `env`, `hooks`, and `permissions.allow`; that invariant is what keeps the overwrite safe…
any top-level key present in a destination file but absent from the templates is **silently dropped** by a
switch." A hook registered only in the root `settings.json` would therefore be deleted by
`/jenga-permission-level 5` — the exact level the acceptance criterion names. This is not hypothetical: it
is the bug `E15_S04_T01` fixed for the `WorktreeCreate` commit guard, and
`tests/permission-level-template-commit-guard.bats` exists to keep it fixed.

The `PreToolUse` block is therefore byte-identical across the root `settings.json` and all five templates.
**Change all six together.**

#### Registration

```json
"PreToolUse": [
  {
    "matcher": "Bash|Task|Agent",
    "hooks": [
      {
        "type": "command",
        "timeout": 30,
        "command": "for H in \"${CLAUDE_PROJECT_DIR:-.}/hooks/on_preflight_check.sh\" \"${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/on_preflight_check.sh\" \"${CLAUDE_PROJECT_DIR:-.}/node_modules/@jenga-ai/agent/hooks/on_preflight_check.sh\"; do [ -x \"$H\" ] && exec \"$H\"; done; exit 0\n"
      }
    ]
  }
]
```

Three deliberate choices in that command string:

- It prefers the **root `hooks/` copy**, then `.claude/hooks/`, then
  `node_modules/@jenga-ai/agent/hooks/` — the repository's usual dual-path idiom. The monorepo therefore
  runs the canonical, hand-edited source rather than a possibly stale mirror, while a consumer install
  still resolves. (`SessionEnd` points straight at `.claude/hooks/`; this hook deliberately does not.)
- It uses `${CLAUDE_PROJECT_DIR:-.}` parameter expansion, **not** `$(git rev-parse --show-toplevel)` as
  `WorktreeCreate` does, because this hook fires on every `Bash` call and must not spend a `git`
  subprocess to find itself.
- A missing script is a clean `exit 0`, not an error, so a partially installed tree degrades to "no hook"
  rather than to a failure on every tool call.

#### Test seams

In the style of `checklist.sh` and `checklist-marker.sh`; unset in normal use.

| Variable | Effect |
|---|---|
| `JENGA_CHECKLIST_MARKER_DIR` | look for markers here (the same seam the marker script uses, and the one that skips the upward walk) |
| `JENGA_PREFLIGHT_HOOK_SCRIPT_DIR` | find `checklist-marker.sh` and `checklist.sh` here |
| `JENGA_PREFLIGHT_HOOK_DEBUG` | non-empty: trace each stage's decision to `stderr` |

### Combining the two files
<!-- RESERVED: E67_S02 (checker) -->
Decided with the checker (`E67_S02_T01`). The checker (`scripts/checklist.sh`) reads **exactly one** of
the two files, selected whole:

1. If the project instance exists (`"$(scripts/resolve-root.sh get configs)/checklists.json"`), it is the
   registry and the shipped default is not read.
2. Only when **no** project instance exists is the shipped default (`templates/checklists.json`) the
   registry. In a consumer project that file lives inside the installed package, so the checker locates
   it relative to its own location, with the repository's `templates/` /
   `node_modules/@jenga-ai/agent/templates/` dual-path idiom as a fallback.
3. If neither exists there is no registry, and the checker prints nothing and exits `0`.

There is **no item-level merging**: the items of the two files are never combined, concatenated or
overridden by `id`, and an `id` collision between them is therefore not a case the checker has to handle.
Merging is out of scope. A project that wants the shipped items alongside its own copies the ones it wants
into its instance. An existing project instance with an empty `items` array is a deliberate "nothing
applies here" and does **not** fall back to the shipped default.

This follows from section 1: each file is validated on its own and nothing is inherited between files, so
"which items apply" is answered by opening one file. The checker validates only the file it selected,
before reading any item, and refuses to list from an invalid one. The full behaviour (output format, exit
codes, unknown-situation handling) is documented in the header comment of `scripts/checklist.sh`.

### Release skills: gated sub-commands and modes (`E67_S03_T04`)

Both release skills fire `pre-release` first and their extension phase second, with **one run id** shared by
both phases (rule 1 of "Calling the checker from a skill"). The second phase is only called once the first has
been resolved: a `block` failure from `pre-release` halts and `pre-publish` / `pre-mirror` is never reached. The
rule that exit `3` from the second phase is silent and exit `3` from `pre-release` is an error is the one in
"Why the release skills do not share one phase". The test applied to every row below is the scripts' actual
behaviour, not the sub-command's name: **gated means it takes an action on the registry, the git remote or CI
that cannot be taken back; everything local or read-only is ungated.**

`/j-publish`:

| Sub-command / mode | Gated | Reasoning |
|---|---|---|
| `deploy` (not `--dry-run`) | yes | Publishes the release (`npm publish`, App Store upload, a pushed commit plus a triggered workflow for `npm-ci`, or for `droplet` a committed `workflow_dispatch` deploy workflow, which the script itself neither pushes nor triggers) and creates the tag. The point of the feature. |
| `deploy --dry-run` | no | Every adapter skips its outward step (`npm publish --dry-run`, YAML printed with no commit or push, no upload, no tag). Only local `CHANGELOG.md` and ledger writes happen. A rehearsal is how a failing item is diagnosed, so gating it would block the fix. |
| `stage publish` (not `--dry-run`) | yes | `npm stage publish` (or `gh workflow run ... -f mode=stage` for `npm-ci`) uploads the tarball to the registry's staging area. Not live, but it is the first outward step, and "tree clean, tests pass" is about what that tarball contains. |
| `stage approve` (not `--dry-run`) | yes | `npm stage approve` makes the staged version live. This is the irreversible step, and it is a separate execution from `stage publish`, so it is asked again. |
| `stage reject` | no | Does call the registry, but only to discard a staged version, which is the safe direction. A `block` failure here would leave the user unable to throw away a bad tarball. |
| `stage list`, `view`, `download` | no | Read from the registry, change nothing. |
| `stage test` | no | Installs the staged tarball into a scratch directory outside the repo and writes a local ledger entry. |
| `stage <any>` with `--dry-run` | no | Prints the resolved command and makes no registry call. |
| `setup` | no | The wizard only merges or creates the local `publish.json` (validated, rolled back on failure) and records env-var names, never values. It runs no git, registry or CI command. A `deploy` that auto-launches it is already past its own gate. |
| `history`, `release-notes` | no | Read-only reporting (`release-notes` writes only a local `CHANGELOG.md` or draft). |

`/j-mirror-public`:

| Mode | Gated | Reasoning |
|---|---|---|
| bare run | yes | Pushes the squash commit to the public staging branch; a push to a public repository is not reversible in any useful sense. |
| `--force` | yes | As a bare run, and additionally pushes a rescue tag to the public remote. |
| `--force --yes` | yes | As `--force`. `--yes` skips only the typed `destroy` prompt. |
| `--force --dry-run`, `--force --inventory` | yes | `mirror.sh` accepts these combinations, and its `--force` path pushes the rescue tag to the public remote before the dry-run exit. Any invocation carrying `--force` is gated. |
| `--dry-run`, `--inventory` (no `--force`) | no | Read-only previews: they push nothing, and they are how a failing item is diagnosed. |
| `--exclude <path>` | no | Purely local: appends one line to `.publicignore`, which can only narrow what ships. |

**Position of the gate.** In both skills it sits **before the sub-command's script is invoked at all**, after
only the read-only config validation `/j-publish` already did. For `/j-mirror-public` that is ahead of the
public-tip fetch and scratch-worktree refresh, the safety check, the permission-level and publish-config
invariants, the `--force` enumeration and typed confirmation, the rescue-tag push and the push itself. The
invariant is that a `block` failure halts before **any** outward-facing action with nothing mutated. The cost is
that a run which the script's own safety check would have aborted still runs the checklist first, and may ask a
question first. That is accepted: the typed `destroy` confirmation stays the last question before mutation, and
the checklist is the broader, earlier one. For `/j-publish deploy` the position is also forced by the script
itself, whose step 6 edits `CHANGELOG.md` and would otherwise dirty a "clean working tree" item.

**A `confirm` or `block` judgment item with no live user is never silently passed.** `--yes` (`/j-publish`,
`/j-mirror-public --force`) and `--non-interactive` configure the scripts' own prompts and answer no checklist
item: a `confirm` item needs an explicit choice and a `judgment` item needs an explicit confirmation, and
neither can be given without a user. When none can be asked (a headless run, or a user who does not answer), the
skill stops, states which item and why, and does not proceed. This follows the `gated`-tier rule of `E39`, that
an unresolved risk judgment can never be passed by silence or by a harness-side auto-approval. A failed `machine`
item at `block` has no override at all, interactive or not.

**Limitation: this wiring is prose, not enforcement.** The gate is instructions in two `SKILL.md` files and is
honoured by the agent that runs the skill. It is not enforced at the `mirror.sh` or publish-script level, and
nothing stops `bash skills/j-mirror-public/scripts/mirror.sh` or a publish script being run directly, or the
prose being skipped by an agent that does not follow it. The hook layer in `E67_S04` is what makes the gate hold
regardless of the agent. Embedding the gate in the scripts was deliberately not done here.

## 10. Complete example

A valid file exercising an extended situation, both kinds, and all three enforcement levels:

```json
{
  "checklist_version": 1,
  "situations": ["pre-deploy"],
  "items": [
    {
      "id": "no-untracked-env-files",
      "text": "No untracked .env files are present in the working tree.",
      "situations": ["pre-commit", "pre-release"],
      "kind": "machine",
      "verify": "! git ls-files --others --exclude-standard | grep -q '\\.env$'",
      "enforcement": "block",
      "tick_scope": "run"
    },
    {
      "id": "contributing-guide-read",
      "text": "I have read the project's contributing guide and will follow its conventions.",
      "situations": ["pre-task"],
      "kind": "judgment",
      "enforcement": "confirm",
      "tick_scope": "persistent"
    },
    {
      "id": "announce-deploy-window",
      "text": "Tell the team that a deploy is about to start.",
      "situations": ["pre-deploy"],
      "kind": "judgment",
      "enforcement": "advisory",
      "tick_scope": "run"
    }
  ]
}
```
