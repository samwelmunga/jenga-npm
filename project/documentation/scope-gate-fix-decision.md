# Decision: how to make the scope test gate passable

**Status:** decided
**Decided by:** developer, task `E72_S07_T01` (spike)
**Date:** 2026-11-01
**Supersedes nothing.** Sizes `E72_S07_T02` and `E72_S07_T03`.
**Measured against:** worktree `bundle-E72_S07` at `450339d2` (`main` HEAD of 2026-11-01).

---

## 1. The decision

**Both options are implemented, and option 1 is implemented differently from the way the story describes it.**

| # | Option | Verdict | Why |
|---|---|---|---|
| 1 | Make `scoped` genuinely scoped | **Build** — but as a *gate* change, not a catalog split | A catalog split is neither necessary nor sufficient; a project-local map alone is necessary but **not sufficient**. The missing piece is that `scope-test-gate.sh` ignores `map-scope.sh`'s `mapped_tests`. |
| 2 | Make elevated-session-sensitive suites skip | **Build** | Option 1 cannot help `test_run_epic: full`, which by definition runs everything. Without option 2 an epic gate stays unpassable in an elevated session. |

**Headline for `T02`: the fix is to make `scope-test-gate.sh` consume `mapped_tests` and synthesise a narrowed
suite command.** Neither `discover-tests.sh`'s suite-granularity contract nor `test-config.json`'s `tools` schema
needs to change, and `build-catalog.sh`'s deduplication is not touched. This is a materially smaller and safer
change than the catalog split the story contemplated, and the evidence in §3 is why.

---

## 2. The measurement that decides it

Change set: the `E28_S19` story, derived with the same commit-subject rule `scope-test-gate.sh` uses
(`task(E28_S19_T##)` plus matching merge subjects) — **31 changed files**, of which 11 are `*.sh` and 2 are `*.bats`.

Discovery and mapping were run read-only (`discover-tests.sh`, `map-scope.sh`); no suite was executed.

| Map used | `mapped_suites` | `mapped_tests` (test files) | Command that would actually run | Test cases that would actually run |
|---|---|---|---|---|
| Shipped default `templates/test-scope-map.json` | `["bats:tests"]` — **1** | **261** | `bats tests/*.bats` | **5666** |
| Tightly targeted project-local map (4 rules, drafted for this measurement) | `["bats:tests"]` — **1** | **11** | `bats tests/*.bats` | **5666** |

Read the last two columns. **A 24-fold narrowing of the resolved test-file set changed what actually runs by
nothing at all.**

Today's catalog is **261 `.bats` files / 5666 `@test` cases**, not the 170 / 3471 the story quotes from
2026-10-22. The story's figures are stale; the problem they describe is not.

### Why the map cannot narrow execution on its own

`map-scope.sh`'s algorithm resolves each changed file to *test files*, then resolves each test file to the
*suites* whose `paths` match it. `discover-tests.sh`'s bats detector emits **one suite per directory, not per
file** (its header states this deliberately), so this repository has exactly one bats suite:

```
id      bats:tests
command bats tests/*.bats
paths   ["tests/*.bats"]
```

Every test file in `tests/` therefore resolves to that one suite, whose command globs the whole directory.
`scope-test-gate.sh`'s narrowing step (its line 643) filters `discovery.suites` by `mapped_suites` id and carries
each survivor's `command` through **unchanged**:

```bash
jq -c --argjson ids "$(jq -c '.mapped_suites' "$MAP_FILE_OUT")" \
  '.suites |= map(select(.id as $i | ($ids | index($i)) != null))' \
  "$DISCOVERY_FILE" > "$derived"
```

So the gate narrows the *suite list* from 1 to 1 and then runs all 261 files. It prints `scoped policy: 1 suite(s)
map to the changed files`, which is true and deeply misleading.

**`grep -n 'mapped_tests' skills/j-test/scripts/scope-test-gate.sh` returns nothing.** `map-scope.sh`'s own header
says `mapped_tests` exists so a caller can "narrow a run when the runner takes file arguments (a whole-suite run
stays valid)". The hook was designed and published in `E72_S03_T02` and never wired up by `E72_S06_T03`. That
omission is the entire root cause, and it is a two-line-shaped fix rather than a schema change.

---

## 3. Spike questions, answered

### Q1. Can finer bats suites be expressed with the existing `test-config.json` `tools` schema, or does it need a new key?

**No, the `tools` schema cannot express them — and no new key is needed either, because the granularity should not
live there.**

A `tools` entry is `{tool_name, type, comment}`. Per `discover-tests.sh`'s overlay contract, a configured type that
no detected suite carries becomes `config:<tool>:<type>` with ecosystem `config`, **inheriting the tool's first
detected command**. It carries no `paths` and no command of its own. Observed live on this repository:

```
bats:tests               cmd: bats tests/*.bats   paths: ["tests/*.bats"]
config:bats:integration  cmd: bats tests/*.bats   paths: ["tests/*.bats"]
```

The two `tools` entries (`bats`/unit and `bats`/integration) produce two ids with **identical commands and
identical paths**. The schema can retype a suite and invent a label; it cannot subdivide one. Adding more `tools`
entries would add more aliases for the same whole-directory command.

The smallest key that *would* work is a per-tool list of `{name, paths, type}` groups, which the gate would turn
into one suite per group. **It is not recommended** — see Q2 for why it is actively expensive, and §2 for why it is
unnecessary.

### Q2. Does the existing deduplication in `build-catalog.sh` break if bats becomes several suites, and what happens to the `npm:test` alias?

**Yes, it breaks, and this is the single strongest argument against the catalog split.**

`build-catalog.sh` folds suites that would run the same thing, keyed on the exact `command` string, with an npm
alias rule: for an npm suite the key is the *body of the npm script* read from `package.json`. Here
`scripts.test` is `bats tests/*.bats`, so `npm:test` currently shares a key with `bats:tests` and
`config:bats:integration`, and all three fold into one entry. Its header says why in as many words: *"without this
a run-all would run the hour-long bats suite twice."*

Split bats into N groups with N distinct commands and that key stops matching anything. `npm:test`'s body is still
`bats tests/*.bats`, so it survives as its own runnable entry **alongside** all N groups. A `full` run would then
execute the entire 261-file catalog once via `npm test` **plus** every group — every test twice, and the one thing
`build-catalog.sh` was explicitly written to prevent. Repairing it would mean teaching the deduplicator that an npm
alias whose glob is a superset of the groups' globs folds them in: new logic in the one place whose header warns
against exactly this.

There is a second, independent cost. `build-catalog.sh --render` is `j.test`'s numbered picker. Per-file granularity
turns it into a **261-entry numbered list**. The picker becomes unusable, and that is a user-facing regression in a
skill this story has no mandate to touch.

The recommended fix avoids both: the `full` path is untouched (one bats suite, dedup intact, picker intact), and
only the `scoped` path rewrites the command.

### Q3. With a project-local scope map, how many files would the `E28_S19` change set actually have selected?

**11 test files instead of 261** — but only in `mapped_tests`, and with no effect on what runs until the gate
consumes it. Full table in §2. The 11:

```
tests/mirror-nested-suite-flag.bats       tests/mirror-staging-branch-push.bats
tests/mirror-never-public-refs.bats       tests/mirror-test-subject-invariant.bats
tests/mirror-orphaned-twin-rewrite.bats   tests/smoke-test-error-table.bats
tests/mirror-permission-level-invariant.bats  tests/smoke-test-root-climb.bats
tests/mirror-publicize-wiring.bats        tests/smoke-test-skills.bats
tests/mirror-release-prep.bats
```

Two of those 11 are the changed test files themselves (`mirror-never-public-refs.bats`,
`smoke-test-skills.bats`), picked up by the map's "editing a test runs it" rule. That rule is correct and should be
kept.

So: **261 → 11 test files, a 96% reduction**, once `T02` wires `mapped_tests` through. That is the number `T02`
should reproduce and record.

### Q4. Is "the session is elevated" cleanly detectable from inside a bats suite, and is `.jenga-permission-level.json` plus settings divergence the right signal, or is there a narrower one?

**Yes, cleanly detectable. The right signal is the settings field-diff alone. `.jenga-permission-level.json` must
NOT be part of it.**

The signal is not a judgement call — it is already specified by the code under test.
`check_permission_level_invariant` in `skills/j-mirror-public/scripts/mirror.sh` carries a section headed
**"DESIGN DECISION — field-diff is the GATE, session_level is DIAGNOSTIC ONLY"**, and the gate it applies is:

> `.claude/settings.json` and `.agents/settings.json`'s `permissions.deny` and `autoMode.allow`, compared against
> `templates/permission-levels/level-2-guarded.json`.

Only those two fields, deliberately not a whole-file diff (the file carries `defaultMode`, `env`, `hooks` and more
that change for unrelated legitimate reasons). `session_level` is read **only to annotate the failure message**.
Its stated reason for refusing to gate on it is that it can be stale in **both** directions — a stale `2` while the
files are still loosened would false-pass, a stale `5` after `/self-sync` already restored them would false-fail.

So the precondition check must be the **same field-diff**, for the decisive reason that *any other signal can
disagree with the thing the suite is asserting on*. A skip predicated on `session_level` could skip a case that
would have passed, or run one that cannot. The field-diff is correct by construction because it reads the exact
state the subject reads.

Alternatives considered and rejected:

- **`.jenga-permission-level.json` `session_level != 2`** — rejected for the reason the subject itself gives; it is
  diagnostic, not authoritative.
- **Whole-file diff of the settings files** — rejected: false-positives on `hooks`/`env`/`defaultMode` changes,
  which this repository makes often (the `PreToolUse` pre-flight block is registered across six files).
- **An environment variable set by the gate** — rejected: it would make the suite's honesty depend on its caller, so
  a hand-run `bats tests/mirror-*.bats` would silently lose the skip.

**A live state check, and it changes what `T04` can claim.** Measured today, 2026-11-01, in both the main checkout
and this worktree:

```
.claude/settings.json : deny_match=YES  allow_match=YES
.agents/settings.json : deny_match=YES  allow_match=YES
.jenga-permission-level.json : {"session_level":2}
```

All three files are clean in git. **The elevated-session condition the story's evidence rests on is no longer
present.** The user restored level 2 at some point after 2026-10-22. Consequences, which `T04` must not paper over:

1. The 19-assertion cluster **will not currently fail**, so `T04` cannot demonstrate a gate passing "while
   `session_level` is 5" without changing the permission level — which the story forbids. That acceptance criterion
   is **not satisfiable as written** and `T04` must report it as such rather than arrange a green run.
2. Option 2 therefore has to be verified against a **simulated** off-baseline fixture (a scratch root whose settings
   files diverge), not against ambient session state. That is better coverage anyway — it is reproducible.
3. A related insulation effect worth recording: the suite resolves `REPO_ROOT` through
   `git rev-parse --show-toplevel`, so a gate run **from a task worktree** reads that worktree's settings files,
   which come from `HEAD` and match the baseline. A run from the main checkout does not. This is why the failure is
   environment-specific, and why a tester running from a worktree may never reproduce it.

### Q5. Should the skip live in the suites themselves, in the gate's selection, or both? Which keeps a skip from ever being counted as a pass?

**Both, with one shared definition — and the gate's verdict must rest on the gate's exclusion, never on the suite's
skip.**

The reasoning turns on a sharp constraint. `run-suites.sh` keys its verdict **strictly on the suite command's exit
status** and never parses output — its own header, and `check_test_subject_invariant`'s, both record that an earlier
hand-verification produced a false "all clear" because output was piped through `tail -40`. A bats `skip` is not a
failure, so **bats exits 0 and a suite-only skip reaches the gate as a pass.** That is precisely the "worse outcome
than the current honest failure" the story's `T02` warns about. A suite-only skip is therefore **unacceptable on its
own.**

The design:

- **One definition:** a new `skills/j-test/scripts/baseline-permissions.sh` is the sole decider, with the field-diff
  from Q4 and an in-file marker listing which suites require the precondition.
- **The gate excludes.** `scope-test-gate.sh` drops a marked suite from selection when the precondition is
  unsatisfied, names it with its reason in stdout, and lists it in the JSON under a new `excluded_suites` key. An
  excluded suite is **never** added to `passed`.
- **The suite also skips**, calling the same script, so a hand-run `bats tests/mirror-*.bats` is honest too. But the
  gate never depends on this — by the time the suite runs, the gate has already decided whether it counts.
- **Empty-after-exclusion is exit 3.** If exclusion empties the selection, the gate exits 3 ("nothing was
  verified"), never 0. This preserves `E72_S06`'s contract exactly.

The marker follows `E77_S02_T01`'s precedent — an in-file comment tag, not a list in `test-config.json` — for that
decision's strongest recorded reason: **`test-config.json` ships publicly, and a list entry would publish the name
of a `.publicignore`-blocklisted file.** `tests/mirror-test-subject-invariant.bats` is exactly such a file. Proposed
form, parallel to `# jenga:manual-only: <reason>`:

```
# jenga:requires-baseline-permissions: <reason>
```

Reason mandatory, within the first 40 lines, empty reason is an error — so a suite can never be quietly excluded
without saying why.

### Q6. Does skipping hide a real regression class — are any of the 19 assertions capable of catching a genuine defect that only shows up on a real push?

**Yes, it hides a real class. Assessed: the residual risk is acceptable, because the production guard does not
depend on the suite.**

What gets skipped is **not** the guard's own coverage. The suite's 12 cases split cleanly:

- **Negative path — unaffected.** "real push is refused when the session is elevated to level 5", "refusal names
  both off-baseline files", "refusal leaves the bare remote with zero refs", and the rest set up their *own*
  elevated fixture by overwriting the three real files, so they pass regardless of ambient state. The assertion that
  the guard refuses a bad push keeps running.
- **Positive path — this is what is lost.** "real push proceeds normally at the level-2 baseline", "a successful
  baseline push actually lands a commit on the bare remote", "the passing-case log reports the actual
  session_level", "a missing settings file is a harmless skip, not a failure". These need ambient baseline state, and
  they are the only end-to-end proof that a legitimate push *works* rather than merely that an illegitimate one is
  blocked. Same shape in `mirror-staging-branch-push.bats`: the `--force` rescue-tag anchoring and
  staging-branch-targeting cases are genuine regression coverage that only a real push exercises.

So the concealed class is: *a defect that breaks a legitimate push, introduced during an elevated session.* That is
a real class, not a theoretical one.

Three things bound it, which is why the risk is accepted rather than merely noted:

1. **The shipped artifact is protected independently of the suite.** `check_permission_level_invariant` runs inside
   `mirror.sh` at push time, at every permission level. An elevated session cannot ship a loosened `settings.json`
   whether or not the suite ran. The skip costs verification, not safety.
2. **The condition is self-clearing and gated downstream.** The suite is excluded only while the tree is
   off-baseline. Restoring the baseline — which `mirror.sh` *forces* before any real push, since the invariant
   refuses otherwise — re-includes it. There is no path to shipping that skips both the suite and the invariant.
3. **The exclusion is loud.** Per Q5 it is named in stdout and in `excluded_suites`, and an all-excluded run exits
   3. A reader cannot mistake a gate that skipped this coverage for one that ran it.

The honest residual: a story closed in an elevated session has **not** had its real-push positive path verified, and
the gate will say so rather than imply otherwise. `T04` should state this explicitly in its record.

### Q7. Is either fix sufficient alone, given `test_run_epic: full`?

**No. Neither is sufficient alone. Both are required.**

- **Option 1 alone is insufficient.** `test_run_epic` is `full`, and `full` means the whole runnable catalog by
  definition — there is no selection to narrow. An epic gate in an elevated session runs the baseline-sensitive
  suites and fails. Narrowing `scoped` cannot reach `full`. **Stated plainly, as the task's third acceptance
  criterion requires: a catalog split alone leaves `test_run_epic: full` still failing.**
- **Option 2 alone is insufficient.** It removes the 19-assertion cluster as a cause, but `scoped` still expands to
  all 261 files / 5666 cases, so *any* unrelated red assertion anywhere reproduces the identical project-wide block.
  The 4 pre-existing non-cluster failures are a live demonstration: they are unrelated to the cluster and they alone
  would fail every story's gate today.

The two fixes address orthogonal causes — breadth of selection, and a condition the suite cannot control. Fixing one
leaves the other intact.

---

## 4. Consequences for `T02` and `T03`

### `E72_S07_T02` — **confirmed, re-sized smaller**

The story and the task frontmatter anticipated changing `test-config.json`'s *shape*. **It does not need to
change.** `scope_rationale` reads "touches `project/configs/test-config.json` plus 1-3 scripts"; the real shape is:

| File | Change |
|---|---|
| `skills/j-test/scripts/scope-test-gate.sh` | Consume `mapped_tests`; synthesise the narrowed command; add `excluded_suites` and the narrowed counts to the JSON and the stdout summary; exit 3 when exclusion empties the selection |
| `skills/j-test/scripts/baseline-permissions.sh` | **New.** The sole definition of the precondition (field-diff from Q4) and the marker reader |
| `tests/mirror-permission-level-invariant.bats`, `tests/mirror-staging-branch-push.bats`, `tests/mirror-test-subject-invariant.bats` | Add the `# jenga:requires-baseline-permissions:` marker and the in-suite skip |
| `tests/scope-test-gate-*.bats` | Coverage for narrowing, exclusion, the JSON keys and the exit-3 path |
| `project/configs/README.md`, `project/documentation/test-runner.md` | Document the granularity, the skip/exclusion rule, and the `commit_scope_map_file` override |

Its `advisory` crucial tier stands and its `crucial_note` is the right worry: *"The dangerous outcome is a gate that
silently passes less than it should."* §3 Q5's exit-3 rule and `excluded_suites` key exist to make that outcome
visible, and `T02`'s deliberate-defect criterion is the check that matters most.

Two constraints the implementer must not relax:

- Command length is fine — the full 261-file list is **8745 bytes** against an `ARG_MAX` of **1048576**, a 120x
  margin — but the narrowed command must be built from `mapped_tests` with proper quoting, not string-concatenated
  from a glob.
- `npm:test` must stay out of the scoped path. It already is: it carries `paths: []` and `map-scope.sh`'s extension
  fallback only reaches npm for the `.js` family, which is why the §2 measurement selected `bats:tests` alone. Do not
  "fix" that.

### `E72_S07_T03` — **confirmed, but its premise needs correcting, and it must not build a second mechanism**

The task is sound in direction and its stated mechanism is **insufficient on its own**, for the §2 reason: a
project-local map changes `mapped_tests` but not what runs. Its first acceptance criterion — *"no longer selects it,
demonstrated by a recorded run"* — is only truthfully satisfiable **after** `T02` wires `mapped_tests` through.
`T03` therefore depends on `T02` in substance, not merely in sequence. The project-local map is still necessary:
without it the `**/*.sh` → `tests/**/*.bats` rule hands `T02`'s narrowing all 261 files and the narrowing achieves
nothing.

There is a second gap the task should record rather than engineer around. `map_version: 1` **does not support
negation** (`map-scope.sh` rejects a leading `!` as a validation error), and the map's "editing a test runs it" rule
means a change *to* `tests/mirror-test-subject-invariant.bats` selects it no matter what the rules say. So a map can
keep the file out of a gate for a change to `mirror.sh`, but **cannot** keep it out for a change to itself.

**On the `E77_S02` overlap — a finding `T03` must carry, because the task's assumption is wrong.**
`E77_S02_T01` is marked `Passed` and its acceptance criteria are all ticked, but **`skills/j-test/scripts/manual-only.sh`
does not exist on `main`.** It was committed in `d11a226b4` and that commit is **not an ancestor of `main` HEAD**; it
lives on `E77_S02_T01-manual-only-marker` and `bundle-E77_S06`. No `tests/*.bats` file carries a
`jenga:manual-only` marker, and `E77_S02_T02`–`T09` are all still `Pending`.

Therefore:

- The manual-only mechanism is **not available to build on today** — this is a board-versus-git discrepancy worth
  raising independently of this story.
- `T03` must **not** reimplement it. Two mechanisms for "do not run this file automatically" is the outcome the task
  itself names as the one to avoid.
- The division of ownership that avoids duplication: **`E77_S02` owns "never run this file automatically, in any
  run, including a change to the file itself"** (the in-file marker). **`E72_S07_T03` owns the project-local map**,
  which is required for `T02`'s narrowing regardless and which handles the common case. `T03` should record the
  deferral for the self-edit case rather than close it.
- `T03`'s sixth acceptance criterion — amend `E77_S02`'s AC list so the two stories do not both claim ownership —
  stands, and should additionally note that `E77_S02`'s AC list does not mention `scope-test-gate.sh` (which landed
  later, under `E72_S06`), so `E77_S02_T04`'s scope needs widening to cover it.

Neither task is recommended for deletion.

---

## 5. What this spike did not settle

- **Whether the project-local map's rule set is right.** §2's 4-rule draft existed to produce one measurement. A
  production map needs per-area rules across ~60 skills plus `scripts/`, `hooks/`, `templates/` and `agents/`, and
  the judgement call is what to do about files no rule covers. A catch-all back to `tests/**/*.bats` would undo the
  whole fix; no catch-all means an uncovered change maps to zero suites and the gate falls back to `full` — which is
  safe but defeats the purpose. **`T03` must decide this explicitly and record it.** This spike does not.
- **Whether the 4 pre-existing non-cluster failures still reproduce.** Not re-measured here; no suite was run.
  `T04` owns it.
- **The runtime of a narrowed gate.** Not measurable without running suites. `T04` owns the before/after figures.
