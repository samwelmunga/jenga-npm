# project/configs

This directory holds version-controlled configuration files consumed by Jenga AI skills at runtime.

---

## Changing settings: `jenga config`

`jenga config` is the supported way to change the settings in this directory. It is a plain terminal command: it runs
no model and costs no tokens. It lists the six config files below, shows each key with its current value, and edits the
scalar (integer, string, boolean) settings with type and range validation. From a chat session, use `/jenga-config`
instead (see "Changing settings from a chat session: `/jenga-config`" below); it runs this same command.

```bash
jenga config                                        # interactive: pick a file, pick a key, enter a value
jenga config get scope-thresholds.inline_max_files  # print one value (read-only keys can be read too)
jenga config set scope-thresholds.inline_max_files 4
```

An address is `<file-id>.<key>`, where `<file-id>` is the config's file name without `.json`. Run it from inside the
project (it finds `project/configs/` through `scripts/resolve-root.sh`, so `JENGA_PROJECT_ROOT` and the usual upward
search apply). In a checkout of this repo, `node bin/jenga.js config ...` is the same command; in a consumer project it
is the installed `jenga` binary, or, when `jenga` is not on PATH, the copy that `/jenga-config` installs into a per-user
cache (see below).

A `set` validates first, then writes the file atomically (a temp file renamed over the original), so a rejected value
leaves the file byte-identical. When the key belongs to a version-counted file, the same write also increments the
counter (see "Version counters" below).

### Changing settings from a chat session: `/jenga-config`

`/jenga-config` (also invoked as `j.jenga-config`) is the way to change these settings without leaving a chat session.
It costs no tokens beyond the conversation itself: the skill is a thin wrapper that only collects the file, the key and
the value, runs one script, and prints the script's output and exit code verbatim. Validation, the type and range
checks, the version-counter bump and the atomic write all happen inside `jenga config`, never in the model. It does
three things:

| Action | What it runs | Result |
|--------|--------------|--------|
| list | `jenga config` | The interactive picker over the six config files and their keys. It needs a terminal; with none, use `get` or `set`, or run `jenga config` in a terminal. |
| get | `jenga config get <file-id>.<key>` | Prints one value (read-only keys can be read too). |
| set | `jenga config set <file-id>.<key> <value>` | Validates, writes, and bumps the version counter where the file has one. |

**No global install is needed.** The skill runs `skills/jenga-config/scripts/run-config.sh` (under
`node_modules/@jenga-ai/agent/` in a consumer project), which resolves the CLI the same way every time:

1. A `jenga` already on PATH is used as is. It is never upgraded or replaced.
2. Otherwise the script installs `@jenga-ai/agent`, at the version pinned in the script, into a per-user cache directory
   with `npm install --prefix`, and skips the package's install scripts, which `jenga config` does not need. The cache is
   `JENGA_CLI_CACHE` if set, else `$XDG_CACHE_HOME/jenga-cli` if `XDG_CACHE_HOME` is set, else `~/.cache/jenga-cli`. The
   install runs only when the cached copy is absent, so later runs make no npm call.
3. It then reruns the same subcommand against that cached copy, from your project directory, so the project is found
   exactly as in the terminal form.

Nothing is installed into the global npm prefix, and neither the project's `package.json` nor its `node_modules` is
touched. If the install fails (offline, registry error), the script prints the reason to stderr and exits `7` without
running the command; `7` is specific to `/jenga-config` and is not part of the table below. Every other exit code is
the CLI's own, passed through unchanged.

**Values are committed per project.** A `set` edits the file in `project/configs/` itself, which is version-controlled
and shared with everyone on the project. There is no local override layer and no `--shared` flag: one value per project.

### Exit codes

`get`, `set` and the interactive flow share one table, so a script can rely on it.

| Code | Meaning |
|------|---------|
| `0` | Success (a `set` of the value already in the file also exits `0`, reports `(unchanged)` and does not bump). |
| `2` | Usage error: missing or surplus arguments, an unknown sub-command or flag. |
| `3` | Unknown config file or unknown key. |
| `4` | Invalid value: wrong type, outside `min`/`max`, not in `allowed`, or failing `pattern`. |
| `5` | Read-only key: `set` is refused and nothing is written. |
| `6` | Config file missing or malformed, or the configs directory could not be resolved. |

### What is editable

Editable: the integer settings of `scope-thresholds.json` (every key except `threshold_version`), of
`playbook-config.json` (`max_composition_depth`), the string and boolean settings of `audit-config.json` (every key except
`config_version`; see the "audit-config.json" section below), and the string settings of `test-config.json`: the two that control the
commit-time test prompt (`commit_prompt_default`: empty, `skip`, `scoped` or `full`, empty meaning always prompt;
`commit_scope_map_file`: a relative `.json` path, default `templates/test-scope-map.json`) and the three that set which
test run must pass before a board scope is closed (the scope test policy, see the "Scope test policy" section of
`project/documentation/test-runner.md`):

| Editable key | Default | Allowed values |
|--------------|---------|----------------|
| `test_run_task` | `none` | `none`, `scoped`, `full` |
| `test_run_story` | `scoped` | `none`, `scoped`, `full` |
| `test_run_epic` | `none` | `none`, `scoped`, `full` |

An absent key reads as its default, and a present-but-invalid value reads as the default with a warning on stderr.

Editable too: `test_default_suite_set`, the **bounded default suite set** (`E72_S08_T06`) — see the next section.

#### `test_default_suite_set` — the floor beneath a `scoped` gate

A `scoped` gate whose changed files map to **no suite at all** runs this set instead of the full catalog. It is the
floor: never the whole catalog, never empty. Only the "nothing mapped" cause reaches it — an id with **no commits**
keeps `exit 3`, because no change set could be derived there at all and a default run would report a pass for a
change nobody knows.

The value is a flat, **comma-separated list of root-relative test-file globs** in the same dialect the scope map uses:

```bash
jenga config get test-config.test_default_suite_set
jenga config set test-config.test_default_suite_set "tests/smoke-test-skills.bats,tests/resolve-root.bats"
```

| | |
|---|---|
| Default | `""` — **not configured** |
| Allowed | `""`, or one or more globs separated by single commas (no spaces, no `[ ] { } \| \\`, no leading `/`, no `..` segment) |
| Resolver | `skills/j-test/scripts/resolve-default-suites.sh` |
| Subset guard | `skills/j-test/scripts/assert-bounded-subset.sh` (shared with `E72_S08_T03`'s `scoped` ≠ `full` invariant) |

**It is globs, not suite ids,** because `discover-tests.sh` emits one bats suite per *directory*: this project's whole
catalog is the single suite `bats:tests`, so a set named at suite granularity would be the entire catalog and could
not be bounded. And it is a **flat string, not an array**, because the descriptor schema can only express an editable
key as a scalar — an array value could never be set through `jenga config` at all.

Three outcomes are refusals rather than runs, each with the offending value named, and **none of them is ever a
pass**:

- **Not configured** (absent, `null` or empty): the resolver exits `4` and prints the `jenga config set` line to fix
  it. The shipped descriptor default and the `j.init` scaffold template are both `""` on purpose — naming this
  project's own test files in a generic default would be wrong for every consumer, and naming nothing honestly says
  "you have not set this yet". A project that has never heard of the key gets an actionable refusal, not a silent
  pass and not the full catalog.
- **Zero runnable test files** (the globs match nothing, or every file they match is run by no runnable suite): exit
  `5`. A floor that quietly resolves to nothing is a gate going green having executed nothing.
- **The entire runnable catalog** (including a one-file catalog, where equality is unavoidable): exit `6`. A bounded
  default set equal to everything is a contradiction whatever the catalog's size.

An invalid glob, or an empty element from a leading, trailing or doubled comma, is exit `3` — the same code
`commit_scope_map_file` gets for a path that points nowhere, and for the same reason: an explicit setting that is
wrong is a misconfiguration, never a silent fallback.

**This project's set is six suites, resolving to 6 of 272 runnable test files.** What may be in it is a *property*,
not a runtime budget: no suite that mutates a tracked artefact of the tree it runs in is eligible, regardless of
speed, and the same bars a suite that drives a real outward push or that depends on ambient permission state. The
membership and the reasoning behind it, including what was considered and rejected, are in the "The bounded default
suite set" section of `project/documentation/test-runner.md`.

Note that `test-config.json` carries **no version counter**, so a successful `set` on this key (as on every other
editable key of this file) prints no bump suffix. That is deliberate, from `E72_S01_T04`, and is pinned by
`tests/config-descriptors.bats` and `tests/config-get-set-e2e.bats`.

#### `commit_scope_map_file` — override it, do not edit the shipped map

The default value, `templates/test-scope-map.json`, is the **shipped generic starting point**, and its own `_comment`
says a project overrides it "by pointing `commit_scope_map_file` at its own map, not by editing this shipped copy".
Editing the shipped file would push this project's mapping policy out to every consumer of the package.

Overriding it matters more than it looks. The shipped map's `**/*.sh` → `tests/**/*.bats` rule maps **any** shell edit
to **every** bats file, so a `scoped` gate for a one-script change selects the whole catalog. Write a project map with
targeted rules and point this key at it:

```bash
jenga config set test-config.commit_scope_map_file project/configs/test-scope-map.json
```

The value must be a relative path, free of `..` segments, ending in `.json`, resolved against the project root. A
configured file that does not exist is an error (exit 3), never a silent fallback to the default — an explicit setting
pointing nowhere is a misconfiguration.

Note that a precise map narrows which test *files* are resolved; what makes the run itself narrower is
`skills/j-test/scripts/narrow-suites.sh`, and a suite that cannot pass right now is excluded by
`skills/j-test/scripts/baseline-permissions.sh`. An excluded suite is always named in the gate's output and never
counted as passed.

A map can also **declare** a deliberate omission through its top-level `excluded_tests` key, so that a file no rule
selects is reported as "deliberately kept out" rather than being silently absent. This project declares three
(2026-11-01): `tests/mirror-test-subject-invariant.bats`, `tests/mirror-permission-level-invariant.bats` and
`tests/mirror-staging-branch-push.bats` — the first for its ~2 h runtime and its mutation of the real `.publicignore`,
the other two because each drives the real `mirror.sh` end-to-end with real `git push`es. The declaration **subtracts
nothing**: removing the file from every rule is what excludes it, and the declaration only makes that visible. It also
holds **only on the `scoped` path** — under policy `full`, and on either fallback to the full catalog, all three run.
`test_run_epic` is `none` in this project today, so no epic rollup takes either path. Both are documented in the "Suite granularity" and "Suites that cannot pass right now" sections of
`project/documentation/test-runner.md`.

Everything else is shown read-only, with a pointer to where to change it:

| Read-only key | Why, and where to edit instead |
|---------------|--------------------------------|
| `threshold_version`, `config_version` | Version counters: the command owns them, so a bump can never stack on a hand-set value. |
| `checklists.json` (`checklist_version`, `situations`, `items`) | Nested lists with their own validator: `scripts/validate-checklists.sh`; suggestions are filed through `scripts/checklist.sh`. |
| `conventions.json` (`conventions_version`, `categories`) | The project's recorded conventions (an optional file: absent until the `j.conventions` wizard writes it, shown as `[not present]`); validated by `scripts/validate-conventions.sh`, format in `project/documentation/project-conventions.md`. |
| `workflow.json` (`statuses`, `rapport_types`, `paths`, `agents`, `pipeline`) | Structural; see `templates/SCRUM_BOARD_SCHEMA.md` and `scripts/resolve-root.sh`, owned by `agents/scrum-master.md`. |
| `test-config.json` (`tools` only) | Added only with user approval; see `agents/tester.md` (Tool Stack Management). |

Each config file is described by one descriptor, `templates/config-descriptors/<file-id>.json`, which declares every
key's label, type, bounds, default, description and bump rule. A new key or file is a descriptor edit, not a code change;
see `project/documentation/config-descriptors.md` for the descriptor format and exit-code contract.

### Version counters

`scope-thresholds.json` carries `threshold_version`, while `playbook-config.json` and `audit-config.json` each carry
`config_version`. A successful `jenga config set` of any key in those files increments the counter by exactly 1, in the same write as the value. A
`set` that leaves the value unchanged writes nothing and does not bump. `checklists.json` has **no** bump rule:
`checklist_version` is pinned to the integer `1` by `scripts/validate-checklists.sh`, so a counter that must not move
cannot be incremented. `workflow.json` and `test-config.json` carry no counter.

If you edit one of these files **by hand** instead (for example to add a new key, which `jenga config` does not do),
nothing bumps the counter for you: increment it yourself, in the same commit.

---

## scope-thresholds.json

Runtime threshold values used by `/jenga` and `/do` to determine execution scope per task.

### Fields

| Field | Type | Current Value | Description |
|-------|------|---------------|-------------|
| `threshold_version` | integer | 7 | Version counter for this config. **Incremented by `jenga config set` on every successful change to any threshold value** (it is read-only there, so it cannot be set directly); a hand edit of any threshold must still increment it by hand. This makes threshold drift visible in git history and code review. |
| `inline_max_files` | integer | 3 | Maximum number of files a task may touch to qualify for `inline` execution scope (no subagent, no worktree). Raised from 1 to 3 (`threshold_version: 2`) — a 1-file cap forced small multi-file work (e.g. a `SKILL.md` plus one small script, the standard "delegate deterministic logic to a script" shape required by CLAUDE.md's Skill Implementation Principle) through the full worktree+tester pipeline, which costs disproportionately more than the change itself. See `E42_S04_T01` for the case that surfaced this. |
| `inline_max_lines` | integer | 75 | Maximum total lines changed for a task to qualify for `inline` execution scope. Raised from 20 to 75 alongside `inline_max_files` for the same reason — a small `SKILL.md` + script pair routinely exceeds 20 lines. |
| `story_max_files` | integer | 5 | Maximum number of files a task may touch to qualify for `story` scope bundling (multiple tasks executed in one developer context). |
| `bundle_lock_ttl_minutes` | integer | 30 | Time-to-live in minutes for a story-scope bundle lock. A lock older than this value is considered stale and may be reclaimed. |
| `max_concurrent_developers` | integer | 4 | Maximum number of developer subagents (including story-bundle dispatches, one slot per bundle) a single orchestrating session may run at once. Enforced by `scripts/acquire-concurrency-slot.sh`/`release-concurrency-slot.sh` against that session's `project/queue/concurrency-slots-<session_id>.json`. Added in `threshold_version: 3` (`E32_S15`). |
| `max_concurrent_testers` | integer | 4 | Maximum number of in-session tester invocations a single orchestrating session may run at once. On a full cap, the developer agent falls back to the existing `project/queue/handoffs/` mechanism instead of waiting. Added in `threshold_version: 3` (`E32_S15`). |
| `slot_ttl_minutes` | integer | 45 | Time-to-live in minutes for a held concurrency slot (developer or tester). A holder entry older than this value is considered stale and is reclaimed before the next cap check — this guards against a crashed subagent leaking its slot, not against cross-session contention (the counter file itself has no cross-session lifecycle). Added in `threshold_version: 3` (`E32_S15`). |
| `marker_ttl_minutes` | integer | 60 | Time-to-live in minutes for a pre-flight **situation marker** frame (`scripts/checklist-marker.sh`, the "which lifecycle phase is this session in" value the enforcing hook reads). A frame older than this is treated as **absent**, so a session that died mid-phase cannot wedge every later session in the repo. A judgement, not a measurement: longer than `slot_ttl_minutes` (45, which guards a single dispatch) and far shorter than the tick store's 1440-minute idle TTL (which bounds a whole orchestrated run); a phase that legitimately runs longer calls `checklist-marker.sh refresh --token <t>`, which extends its own frame's expiry in place (a repeated `write` is **not** a refresh: it pushes a second frame). Added in `threshold_version: 4` (`E67_S04`); full reasoning in `project/documentation/preflight-checklists.md` section 9, "Situation marker". |
| `recording_ttl_minutes` | integer | 90 | Time-to-live in minutes for the **active-recording pointer** (`skills/j-workflow-recorder/scripts/active-recording.sh`, the per-session record of which `_RECORDING.md` is the live one). A pointer older than this is treated as absent, so a session that died mid-recording cannot wedge a later one. **Chosen value: 90, by the user on 2026-11-02.** Reason: a live recording renews its own pointer in place through `active-recording.sh refresh`, so a short ceiling is safe and only has to outlast a dead session, while the earlier unapproved fallback of 720 minutes (12 hours) would have let a session that died yesterday still look live today. Too short a value would drop a healthy recording's pointer between refreshes; too long a value lets a dead session's pointer outlive it. For reference `marker_ttl_minutes` is 60 and `slot_ttl_minutes` is 45. The script reads it fresh on every operation, falls back to 90 when the key is absent, and exits 5 when it is present but not a positive number. Added in `E89_S05_T04`. |

### Versioning Convention

To change a threshold, use the command:

```bash
jenga config set scope-thresholds.inline_max_files 4
```

It validates the value, then writes the new value **and** the incremented `threshold_version` together, so the two can
never land separately. Then commit the change with a message describing which threshold changed and why.

The reasoning is unchanged by the automation. Threshold drift must stay visible in git history and code review, so every
threshold change is still its own distinct, reviewable commit, and the `threshold_version` increment in that diff is what
makes a change obvious even when the value itself looks harmless. The command removes the manual step (and the chance to
forget it), not the review.

If you edit `scope-thresholds.json` by hand instead, the old rule still applies: update the value(s), increment
`threshold_version` by 1, and commit them together.

### Consuming Skills

- `skills/jenga/SKILL.md` — reads all threshold fields at Phase 0 startup
- `skills/do/SKILL.md` — reads all threshold fields at Step 0 startup
- `scripts/acquire-concurrency-slot.sh` / `scripts/release-concurrency-slot.sh` — read
  `max_concurrent_developers`, `max_concurrent_testers`, and `slot_ttl_minutes` fresh on every
  acquire attempt against a single orchestrating session's
  `project/queue/concurrency-slots-<session_id>.json` counter file (`E32_S15_T02`)
- `skills/j-workflow-recorder/scripts/active-recording.sh` — reads `recording_ttl_minutes` fresh on every
  operation that stamps or tests a pointer's expiry (`E89_S01_T03`, shipped by `E89_S05_T04`). An absent key
  falls back to its built-in default of 90; a present but invalid one is a hard error (exit 5)
- `scripts/checklist-marker.sh` — reads `marker_ttl_minutes` fresh on every `write`, `clear` and
  `prune`, to decide when a situation-marker frame has expired (`E67_S04_T01`). A missing file or
  key is a hard error for those three; `read` degrades to "no phase is active" instead, because the
  enforcing hook's read path must never fail a session

Both skills halt with a clear error if this file is missing or contains invalid JSON.

---

## playbook-config.json

Deliberately a **separate file** from `scope-thresholds.json` (`E53_S05_T01`) — the fields above
are specifically `/jenga`/`/do` task **execution-scope** thresholds, a different concern from
playbook nesting-depth safety limits. Read by `skills/jenga/scripts/load-playbooks.sh` only.

### Fields

| Field | Type | Current Value | Description |
|-------|------|---------------|-------------|
| `config_version` | integer | 1 | Version counter for this config, mirroring `scope-thresholds.json`'s own `threshold_version` convention. Incremented by `jenga config set` on every successful change to a value below (read-only there); a hand edit must still increment it by hand. |
| `max_composition_depth` | integer | 3 | Maximum playbook-to-playbook composition nesting depth `load-playbooks.sh` allows before dropping a playbook (with a stderr warning) at load time. A **tunable safety default**, not an architectural ceiling — depth 1 is a playbook's own steps; depth 2 is one level of composition; a chain nesting deeper than this value is rejected. Missing file, missing field, or a non-positive-integer value all fall back to the hardcoded default of 3. |

### Consuming Skills

- `skills/jenga/scripts/load-playbooks.sh` — reads `max_composition_depth` once per invocation,
  resolving the project root the same way `skills/jenga/scripts/run-playbook-step.sh` already does
  (`JENGA_PROJECT_DIR` -> `CLAUDE_PROJECT_DIR` -> `git rev-parse --show-toplevel` -> `pwd`; the
  existing `JENGA_PLAYBOOKS_TEST_ROOT` fixture override is reused for this lookup too — see that
  script's own header). Missing or invalid config is a soft fallback to the default, never a halt
  (composition depth-limiting is a safety default, not a required setup file).

---

## audit-config.json

Settings for the dependency audit. Read by `scripts/audit-deps.sh`, the audit script that lands in a later task of
`E85_S01`; until it exists nothing consults this file, but the keys, defaults and validation are already live in
`jenga config`. A separate file from the others because it carries a different concern: whether, and how strictly,
Jenga may run `npm audit` against the project, which contacts the network.

### Fields

| Field | Type | Default | Allowed | Description |
|-------|------|---------|---------|-------------|
| `config_version` | integer | 1 | read-only | Version counter for this config, mirroring `playbook-config.json`'s. Incremented by `jenga config set` on every successful change to a value below (read-only there, so it cannot be set directly); a hand edit must still increment it by hand. |
| `mode` | string | `ask` | `off`, `ask`, `on` | Consent for running the audit; see "What `mode` means" below. |
| `severity_threshold` | string | `high` | `low`, `moderate`, `high`, `critical` | The lowest severity that counts as a finding. Anything below it is ignored. |
| `offline_behavior` | string | `warn` | `warn`, `fail` | What happens when the audit cannot run (no `npm`, no lockfile, registry unreachable). `warn` exits 0 with an "unavailable" status; `fail` exits 3. |
| `production_only` | boolean | `false` | `true`, `false` | When `true`, only production dependencies are audited (`npm audit --omit=dev`). |

### What `mode` means

`mode` is the project's consent setting for the audit, so it decides who may start one:

- `off` always refuses: the audit never runs, whatever flags are passed.
- `ask` (the default) never audits without being told to: the audit runs only when the caller passes `--approved` or
  `--ci`, and otherwise refuses.
- `on` is the user's standing opt-in. It is made by the user's own `jenga config set audit-config.mode on` and nothing
  else, and it lets the audit run without a flag.

`--approved` is passed only by an agent that has just obtained the user's approval in the session and logged it.
`--ci` is passed only by a committed workflow. An agent must never set `mode` to `on` itself: a standing opt-in the
user did not make is not consent.

### Changing a value

```bash
jenga config get audit-config.severity_threshold        # prints: high
jenga config set audit-config.severity_threshold critical
```

A value outside the allowed list exits `4` and leaves the file byte-identical; `config_version` is refused with exit
`5`.

### Consuming Skills

- `scripts/audit-deps.sh` — the only reader (added by a later task of `E85_S01`).

---

## checklists.json

This project's own pre-flight checklist registry (`E67`): standing, situation-tagged items that gating
skills verify at defined lifecycle phases (`pre-commit`, `pre-task`, `pre-release`, `pre-reconcile`).
Unlike a board item's Acceptance Criteria, these outlive any single epic, story or task.

A separate generic default ships at `templates/checklists.json`. **This file is the project instance, and
because `project/configs/` is not blocklisted in `.publicignore`, it ships downstream through
`/j-mirror-public` exactly as `test-config.json` does** — treat everything in it as publishable, and keep
policy that is generic to any consumer in the template instead.

### Shape

A top-level `checklist_version` (integer, pinned to `1` by the validator, so it has no bump rule and `jenga config` never changes it; every key here is read-only to `jenga config`), an optional `situations` array that extends the four-phase
vocabulary, and an `items` array. Each item carries `id`, `text`, `situations[]`, `kind` (`machine` or
`judgment`), `enforcement` (`block`, `confirm` or `advisory`), `tick_scope` (`run` or `persistent`), and a
`verify` shell command if and only if `kind` is `machine`. The full schema, including what each
enforcement level and tick scope means at check time, is in
`project/documentation/preflight-checklists.md`.

### Validation

```bash
bash scripts/validate-checklists.sh templates/checklists.json project/configs/checklists.json
```

Exits non-zero with one specific message per failure. The `checklist-registries-valid` item in this file
runs exactly that command at `pre-commit`.

### Consuming Skills

None yet. The checker (`scripts/checklist.sh`) lands in `E67_S02` and the skill wiring in `E67_S03`; until
then this file is validated but not consulted by any skill.

---

## tidy-config.json

`j.tidy`'s nag thresholds (`E56_S06_T02`): how old an entry must be to count as stale, and the worktree
count, branch count and disk ceilings whose crossing the sweep report calls out prominently. A generic
default ships at `templates/tidy-config.json`; **this file is the project instance and replaces the
shipped default whole — there is no merging**, the same arrangement as `checklists.json`. Like
`test-config.json`, it ships downstream through `/j-mirror-public`, so treat everything in it as
publishable.

These values live in a config file rather than in `skills/j-tidy/scripts/report.sh` deliberately: that
script contains no threshold value at all, so there is nothing to drift. When no instance and no template
can be resolved, the report says the ceiling checks were skipped instead of substituting a built-in
number, because a hidden default would misreport a project that never configured one.

### Fields

| Key | Type | Default | Meaning |
|---|---|---|---|
| `config_version` | integer | `1` | Shape version. Read-only. |
| `retention_age_days` | integer | `14` | Age, from the entry's last commit, at which the report counts it as stale. |
| `worktree_count_ceiling` | integer | `40` | Registered worktrees above this are reported as a crossed ceiling. |
| `branch_count_ceiling` | integer | `80` | Local branches with no worktree above this are reported as a crossed ceiling. |
| `disk_ceiling_mb` | integer | `2048` | Measured worktree disk above this is reported as a crossed ceiling. Skipped when `--no-disk` meant disk was never measured. |
| `report_max_rows_per_group` | integer | `15` | Entries listed per (verdict, population) group before truncation. Truncation **always** states how many entries were not shown. |
| `notes` | object | — | Per-key rationale, including the measured baseline the defaults were chosen against. JSON has no comments; this is the same convention `test-config.json` uses with its per-entry `comment` fields. |

### Changing a value

**Hand-edit this file.** It has no `jenga config` descriptor yet, so `jenga config set tidy-config.<key>`
and `/jenga-config` do not reach it — the descriptor suite and the config-list renderer enumerate the
descriptor-backed files by name, and adding a seventh is its own piece of work. `report.sh` re-reads the
file on every run, so an edit takes effect immediately with nothing to restart.

To see what a run actually resolved, and from which file:

```bash
bash skills/j-tidy/scripts/report.sh --print-thresholds
```

### Consuming Skills

- `j.tidy` — `skills/j-tidy/scripts/report.sh` (resolution order: `JENGA_TIDY_CONFIG_FILE`, then this
  file, then `templates/tidy-config.json`).
- `j.reconcile` — indirectly, by invoking `j.tidy` as a step.
