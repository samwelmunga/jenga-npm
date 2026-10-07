# project/configs

This directory holds version-controlled configuration files consumed by Jenga AI skills at runtime.

---

## Changing settings: `jenga config`

`jenga config` is the supported way to change the settings in this directory. It is a plain terminal command, not a
skill: it runs no model and costs no tokens. It lists the five config files below, shows each key with its current
value, and edits the scalar (integer, string, boolean) settings with type and range validation.

```bash
jenga config                                        # interactive: pick a file, pick a key, enter a value
jenga config get scope-thresholds.inline_max_files  # print one value (read-only keys can be read too)
jenga config set scope-thresholds.inline_max_files 4
```

An address is `<file-id>.<key>`, where `<file-id>` is the config's file name without `.json`. Run it from inside the
project (it finds `project/configs/` through `scripts/resolve-root.sh`, so `JENGA_PROJECT_ROOT` and the usual upward
search apply). In a checkout of this repo, `node bin/jenga.js config ...` is the same command; in a consumer project it
is the installed `jenga` binary.

A `set` validates first, then writes the file atomically (a temp file renamed over the original), so a rejected value
leaves the file byte-identical. When the key belongs to a version-counted file, the same write also increments the
counter (see "Version counters" below).

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

Editable: the integer settings of `scope-thresholds.json` (every key except `threshold_version`) and of
`playbook-config.json` (`max_composition_depth`). Everything else is shown read-only, with a pointer to where to change it:

| Read-only key | Why, and where to edit instead |
|---------------|--------------------------------|
| `threshold_version`, `config_version` | Version counters: the command owns them, so a bump can never stack on a hand-set value. |
| `checklists.json` (`checklist_version`, `situations`, `items`) | Nested lists with their own validator: `scripts/validate-checklists.sh`; suggestions are filed through `scripts/checklist.sh`. |
| `conventions.json` (`conventions_version`, `categories`) | The project's recorded conventions (an optional file: absent until the `j.conventions` wizard writes it, shown as `[not present]`); validated by `scripts/validate-conventions.sh`, format in `project/documentation/project-conventions.md`. |
| `workflow.json` (`statuses`, `rapport_types`, `paths`, `agents`, `pipeline`) | Structural; see `templates/SCRUM_BOARD_SCHEMA.md` and `scripts/resolve-root.sh`, owned by `agents/scrum-master.md`. |
| `test-config.json` (`tools`) | Added only with user approval; see `agents/tester.md` (Tool Stack Management). |

Each config file is described by one descriptor, `templates/config-descriptors/<file-id>.json`, which declares every
key's label, type, bounds, default, description and bump rule. A new key or file is a descriptor edit, not a code change;
see `project/documentation/config-descriptors.md` for the descriptor format and exit-code contract.

### Version counters

`scope-thresholds.json` carries `threshold_version` and `playbook-config.json` carries `config_version`. A successful
`jenga config set` of any key in those files increments the counter by exactly 1, in the same write as the value. A
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
| `threshold_version` | integer | 4 | Version counter for this config. **Incremented by `jenga config set` on every successful change to any threshold value** (it is read-only there, so it cannot be set directly); a hand edit of any threshold must still increment it by hand. This makes threshold drift visible in git history and code review. |
| `inline_max_files` | integer | 3 | Maximum number of files a task may touch to qualify for `inline` execution scope (no subagent, no worktree). Raised from 1 to 3 (`threshold_version: 2`) — a 1-file cap forced small multi-file work (e.g. a `SKILL.md` plus one small script, the standard "delegate deterministic logic to a script" shape required by CLAUDE.md's Skill Implementation Principle) through the full worktree+tester pipeline, which costs disproportionately more than the change itself. See `E42_S04_T01` for the case that surfaced this. |
| `inline_max_lines` | integer | 75 | Maximum total lines changed for a task to qualify for `inline` execution scope. Raised from 20 to 75 alongside `inline_max_files` for the same reason — a small `SKILL.md` + script pair routinely exceeds 20 lines. |
| `story_max_files` | integer | 5 | Maximum number of files a task may touch to qualify for `story` scope bundling (multiple tasks executed in one developer context). |
| `bundle_lock_ttl_minutes` | integer | 30 | Time-to-live in minutes for a story-scope bundle lock. A lock older than this value is considered stale and may be reclaimed. |
| `max_concurrent_developers` | integer | 3 | Maximum number of developer subagents (including story-bundle dispatches, one slot per bundle) a single orchestrating session may run at once. Enforced by `scripts/acquire-concurrency-slot.sh`/`release-concurrency-slot.sh` against that session's `project/queue/concurrency-slots-<session_id>.json`. Added in `threshold_version: 3` (`E32_S15`). |
| `max_concurrent_testers` | integer | 3 | Maximum number of in-session tester invocations a single orchestrating session may run at once. On a full cap, the developer agent falls back to the existing `project/queue/handoffs/` mechanism instead of waiting. Added in `threshold_version: 3` (`E32_S15`). |
| `slot_ttl_minutes` | integer | 45 | Time-to-live in minutes for a held concurrency slot (developer or tester). A holder entry older than this value is considered stale and is reclaimed before the next cap check — this guards against a crashed subagent leaking its slot, not against cross-session contention (the counter file itself has no cross-session lifecycle). Added in `threshold_version: 3` (`E32_S15`). |
| `marker_ttl_minutes` | integer | 60 | Time-to-live in minutes for a pre-flight **situation marker** frame (`scripts/checklist-marker.sh`, the "which lifecycle phase is this session in" value the enforcing hook reads). A frame older than this is treated as **absent**, so a session that died mid-phase cannot wedge every later session in the repo. A judgement, not a measurement: longer than `slot_ttl_minutes` (45, which guards a single dispatch) and far shorter than the tick store's 1440-minute idle TTL (which bounds a whole orchestrated run); a phase that legitimately runs longer calls `checklist-marker.sh refresh --token <t>`, which extends its own frame's expiry in place (a repeated `write` is **not** a refresh: it pushes a second frame). Added in `threshold_version: 4` (`E67_S04`); full reasoning in `project/documentation/preflight-checklists.md` section 9, "Situation marker". |

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
