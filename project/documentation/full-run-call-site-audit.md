# Audit: every call site that can reach a full test run

**Task:** `E72_S08_T04` · **Story:** `E72_S08` · **Epic:** `E72`
**Date:** 2026-11-02 (UTC) · **Tree audited:** `main` at `d89a15e8` (after `T01`, `T07`, `T06` and `T02` merged)

> **Revised 2026-11-02 after verification.** The tester's review of `E72_S08_T04` found one Tier A false
> positive, one wrongly-rejected Tier A suite, two wrong citations (one of which changed a rule), two
> overstated arguments and two missing table rows. All are corrected in place below and recorded in
> `project/rapports/problems/E72_S08_T04-audit-completeness-and-unpinned-config-rules.md`. The audit's two
> conclusions — no fourth automatic route, and no board item for the `run_full` grep hole — both survived.

`T01` re-tiered the per-scope policy to `none` / `scoped` / `none`, `T02` removed the scoped-to-full
escalation, `T06` supplied the bounded floor that replaced it, and `T03` adds the standing `scoped` ≠ `full`
invariant. Those close the three *known* routes to an automatic full run. **This document exists to prove
there is no fourth**, and to record the inverse finding folded in on 2026-11-02: config files whose own
asserting suite no rule mapped them to, so editing them reached no coverage at all.

Every row below was found by a recorded `grep` over the repository's root sources, not from memory. The
greps are reproduced in [Appendix A](#appendix-a--the-recorded-greps) so the sweep can be repeated.

---

## 1. The audit table

"Chosen by whom" is the column that matters. A route to `full` is acceptable when a human chose it in the
moment, or when the user recorded that choice in configuration beforehand. It is **not** acceptable when
code selects `full` with no human in the loop and no recorded user default.

| Path | What it invokes | Modes reachable | `full` chosen by whom | Verdict |
|---|---|---|---|---|
| `skills/j-test/scripts/scope-test-gate.sh` | `discover-tests.sh` → `narrow-suites.sh` → `build-catalog.sh` → `run-suites.sh`; `scope-policy.sh` for the mode | `none`, `scoped`, `default-set`, `full` | **The user's recorded config only.** `MODE` comes solely from `scope-policy.sh` (line 615); `run_full` has exactly one call site, line 857, guarded by `if [ "$MODE" = "full" ]`. There is no flag, env var or internal condition that reaches `full` otherwise. | **OK.** The gate itself can no longer escalate. |
| `skills/j-test/scripts/resolve-default-suites.sh` | nothing — resolves a suite *list* | contributes the `default-set` selection | **Nobody chooses `full` here.** Invoked by `scope-test-gate.sh:1209–1228` on the `no-mapped-suites` branch — i.e. **inside the automatic path**, which is why it belongs in this table. It resolves `test_default_suite_set` into a selection and that selection goes through `run_selection`, never `run_full`. | **OK.** *Added 2026-11-02 after verification: the first version of this table omitted it, having rowed `test-gate-scoped.sh` for being a catalog-builder but not these two.* |
| `skills/j-test/scripts/assert-bounded-subset.sh` | nothing — a guard | refuses | **A refusal, not a mode.** `T06`'s shared guard; `scope-test-gate.sh:1226` refuses a floor that equals the runnable catalog rather than executing it. `T03` reuses it for the scoped-selection invariant. | **OK.** Same note as above. |
| `skills/j-test/scripts/scope-policy.sh` | nothing — resolves a mode | returns `none`/`scoped`/`full` | Reads `test_run_task`/`test_run_story`/`test_run_epic`. Defaults are now `none`/`scoped`/`none` (header table lines 30–32, code lines 179–181). `full` is returned **only** when the key literally holds `"full"`. | **OK.** Live config verified: `none`/`scoped`/`none`. |
| `agents/tester.md` | `scope-test-gate.sh` at `--scope task` (step 6f), `--scope story` (step 6g-s), `--scope epic` (on request) | whatever the policy resolves | **No choice of its own** — it is instructed to call the script and interpret the exit code, never to resolve the policy or pick suites. | **FIXED HERE.** Its *prose* still claimed `test_run_epic` defaults to `full` (2 sites) and that both fallback causes "fall back to the full catalog" (2 sites). Corrected in `b94b3f6d`. |
| `agents/scrum-master.md` | requests the epic gate from the tester; runs nothing itself | — | **No choice of its own**; it explicitly does not run or select suites. | **FIXED HERE.** Same two stale claims (epic default `full`; the full-catalog fallback note). Corrected in `b94b3f6d`. |
| `skills/j-commit/scripts/test-gate-decide.sh` | nothing — pure decision logic | `prompt`, `run scoped`, `run full`, `skip` | **A human, three ways, and nothing else.** Rule 1 (non-interactive wins) returns `action=skip` for `--caller noninteractive`, `--inline`, `JENGA_COMMIT_INLINE=1` or `JENGA_COMMIT_NONINTERACTIVE=1`, *ignoring both `--tests` and the recorded default* — "a flag an agent passes is not a human decision". Otherwise `full` comes from `--tests full` (typed), answer `2`/`full` to the prompt, or `recorded_default: full`. | **OK.** See the one residual risk in §3. |
| `skills/j-commit/scripts/test-gate-run.sh` | `run-suites.sh`, `build-catalog.sh` | `full` and `scoped` are **separate subcommands** | The caller names the subcommand. `scoped` never calls `cmd_full`: a `zero`/`error` plan is **refused** (exit 2, nothing run, no `TEST_GATE_` line). The escalation decision is handed back to the skill, which prompts. | **OK.** No internal escalation. |
| `skills/j-commit/scripts/test-gate-scoped.sh` | `discover-tests.sh`, `build-catalog.sh`, `map-scope.sh` | produces a plan only; runs nothing | Builds the full catalog as the *denominator* for mapping (`CAT_FULL`), then emits a plan. It never runs it. | **OK.** |
| `skills/j-commit/SKILL.md` step 4b | the three scripts above | `scoped`, `full`, `skip` | **A human answering a prompt.** On a `zero`/`error` plan it must say plainly this is *not a pass*, then show `fallback-prompt` and parse the typed answer with `fallback-answer` (blank → `skip`, never `full`). Logged with `--action fallback --caller interactive`. | **OK.** The zero-mapping route to `full` requires a typed `1`. |
| `skills/j-test/SKILL.md` + `run-suites.sh` | the whole runnable catalog by default | `full` by default | **The user, by invoking it.** Deliberate and out of scope per the story. | **OK by design.** |
| `package.json` `"test"` | `bats tests/*.bats` | the top-level bats files in one invocation | **A human or CI.** Not a lifecycle gate; nothing in the board flow calls `npm test`. | **OK.** Human/CI-invoked. |
| `.github/workflows/mirror-staging-gate.yml` job `test` | `npm test` | full (of the *public* checkout) | **CI, on a push to the staging branch.** This is the real full-suite gate — see §2, including a correction to how it is usually described. | **OK.** The sanctioned place for a full run. |
| `scripts/slowness-probe.sh` | — | — | Mentions `run-suites.sh` only in a header comment about `JENGA_NESTED_SUITE_RUN`; it invokes no runner. | **Not a call site.** |
| `skills/j-close-task/`, `skills/j-close-story/`, `skills/j-verify/`, `skills/jenga/`, `skills/j-do/`, `skills/j-dooo/` | **nothing** | — | — | **Not call sites — the proven negative.** Grep 2 found **zero** runner invocations across all six. `j-close-task` only *delegates*: the Tester runs the gate, the Scrum Master rolls up. The other five never mention a runner at all. |
| `hooks/` | **nothing** | — | — | **Not call sites.** Zero hits. `on_preflight_check.sh` runs `checklist.sh check`, never a test runner. |
| `project/.workflows/` | **nothing** | — | — | **Not call sites.** Zero hits; no workflow step shells out to a runner. |
| `.claude/**`, `.agents/**` | generated copies of the above | identical | identical | **Not audited separately, by design.** Per `CLAUDE.md` these are build outputs of `j.self-sync`; they are **resynced, not audited**. Auditing them would double-count every row and invite a hand-edit. |

**Answer to the question the task asks: there is no fourth automatic route.** After `T01`, `T02` and `T06`,
every path that reaches the full catalog is entered either by a human in the moment (`j.test`, `j.commit`
option 2 or its fallback prompt, a typed `--tests full`), by the user's own recorded configuration
(`test_run_* = full`), or by CI on the public mirror. No lifecycle gate — task close, story close, epic
rollup — runs the full suite, and none can.

---

## 2. Where the full suite genuinely runs after this story

Three places, and **no local lifecycle gate is one of them**:

1. **The public CI `test` job on the `jenga-npm` mirror** — `.github/workflows/mirror-staging-gate.yml`,
   job `test`, running `npm test` (`bats tests/*.bats`) against a real checkout of the staging branch.
2. **`j.test`** — user-invoked, full-suite by default.
3. **`j.commit`'s option 2** ("Run j.test (full suite)"), or its zero-mapping fallback prompt option 1 —
   in both cases a human typing the choice.

**A correction to how (1) is usually described, reported rather than repeated.** The story's acceptance
criterion calls it "the public CI test job on the `jenga-npm` mirror **that gates `npm publish`**". Measured
on this tree, that is not quite what the workflow graph says:

- `mirror-staging-gate.yml` triggers on a **push to the staging branch**. Its `promote-main` job declares
  `needs: [test, pack-smoke]` (line 117), so the full suite gates **fast-forwarding the public default
  branch**, not publishing.
- `npm-publish.yml` is **`workflow_dispatch` only**, and its publish job declares `needs: audit` — the
  dependency audit, **not** the test job.

So the full suite gates *what is allowed to become public `main`*, and publish runs from `main`; the
protection is real but **indirect**, and `npm publish` itself is dispatched by hand behind the dependency
audit alone. Anyone relying on "CI tests gate publish" as a literal precondition should read it as "CI
tests gate promotion to the branch publish is dispatched from".

**Two further things that make the indirection looser still** (both found in verification):

- `workflow_dispatch` lets the dispatcher pick **any branch or tag**, so "publish runs from `main`" is a UI
  default, not an enforced property.
- `npm-publish.yml`'s **`stage` job (`:130`) declares no `needs:` at all** — a `mode=stage` dispatch runs
  behind neither the tests nor the dependency audit.

**And "full" there is not this repository's full catalog.** `npm test` is `bats tests/*.bats`: top-level
only, and on the public checkout only the suites that survive `.publicignore`. It is the largest automatic
run that exists, not a superset of a local `j.test` run.

---

## 3. Residual risks — reachable, and reported rather than omitted

**(a) `j.commit --tests full` from an agent that does not declare itself non-interactive.**
`test-gate-decide.sh` rule 1 is the only thing separating an agent-passed flag from a human choice, and it
fires on `--caller noninteractive`, `--inline`, `JENGA_COMMIT_INLINE=1` or `JENGA_COMMIT_NONINTERACTIVE=1`.
An agent that passes `--tests full` while omitting all four would be resolved as a human override and get a
full run. This is **convention-enforced, not structurally enforced** — nothing detects a non-TTY.

*Not fixed here, with a stated reason.* The developer and tester agent definitions both instruct
`--caller noninteractive`, so the convention is documented at every call site; and making the script infer
interactivity (a TTY check) would change the contract of a script whose header is normative for four other
tasks, which is a design change well outside an audit. **Recommendation:** no new board item on its own —
it is worth a line in `test-runner.md`'s `j.commit` section (owed to `T05`, see §6) rather than a task.

**(b) `test_run_* = full` is still reachable by configuration, and that is deliberate.** The story's own
acceptance criterion requires `full` to remain a settable value of all three keys. A project that sets
`test_run_epic: full` gets a full epic gate, and the three declared-hostile mirror suites are then part of
the catalog and **run** — the scope map's `excluded_tests` omissions hold only on the scoped path. That
limit is already recorded in the map's `_comment` and is `E77_S02`'s to close with the
`jenga:manual-only` marker. Recorded here so the audit is not read as "a full run is now impossible".

---

## 4. The config self-mapping gap (folded in 2026-11-02)

### 4.1 The measured baseline

Reproduced on this worktree before any change, with `map-scope.sh --files-from` against the active
`project/configs/test-scope-map.json` (79 rules at the time). **All seven** files returned
`mapped_suites: []` with `warnings: ["No tests found for the changed files"]`:

| File | Suites mapped (before) |
|---|---|
| `project/configs/audit-config.json` | 0 |
| `project/configs/checklists.json` | 0 |
| `project/configs/playbook-config.json` | 0 |
| `project/configs/scope-thresholds.json` | 0 |
| `project/configs/test-config.json` | 0 |
| `project/configs/test-scope-map.json` | 0 |
| `project/configs/workflow.json` | 0 |

No rule covered `project/configs/` at all. **Editing a config file selected zero tests.**

The sharpest instance is the map itself: `tests/project-scope-map.bats` is where this epic's map invariants
are pinned — including the mutation test proving the mirror family's enumerate-and-omit mechanism is
load-bearing, which is the only thing standing between an automatic gate and the three hostile mirror
suites — so **editing the scope map never ran the suite that guards the scope map.** `T07` only exercised it
because that task happened to edit the test file itself, which maps to its own suite by `map-scope.sh`'s
changed-file-is-a-test-file rule, not because the map change selected it.

### 4.2 The masking, recorded explicitly

This gap was invisible before `T02` and real after it:

- **Before `T02`:** a zero-mapping escalated to the full catalog, so editing a config file *did* run its
  asserting suite — as one of 264. The gap was completely hidden by the very escalation `T02` removes.
- **After `T02`:** the same edit runs `T06`'s bounded floor — `smoke-test-skills`, `resolve-root`,
  `events-append`, `scope-test-policy-resolve`, `discover-tests`, `j-test-build-catalog` — which contains
  **none** of the asserting suites below except `resolve-root`.

So the coverage that existed by accident disappeared, and the gap became visible only once it also became
real. That is why the fix lands in the story that creates it, rather than as a follow-up.

### 4.3 The discriminator, and why a raw grep gives the wrong answer

A raw `grep -rl` for a config path over `tests/` inflates uselessly — the same trap `T07` documented for
`.md` paths (177 of 271 suites mention one):

| File | Raw `grep -rl` hits (of 272 suites) |
|---|---|
| `workflow.json` | **95** |
| `test-config.json` | 24 |
| `checklists.json` | 20 |
| `scope-thresholds.json` | 15 |
| `audit-config.json` | 12 |
| `test-scope-map.json` | 10 |
| `playbook-config.json` | 5 |
| **total file-hits** | **181** |

Most of those build a scratch config under `$BATS_TEST_TMPDIR` and assert a *script's* behaviour, so
editing the real file cannot change their result. Two tiers were applied, and **both are recorded**:

- **Tier A (mapped).** The suite reads the real file off the repository root **and** makes at least one
  assertion whose subject is that file's own content. A bad edit changes the result.
- **Tier B (rejected).** The suite reads the real file only as an *input* to exercise something else —
  `cp`/`jq` into a fixture tree, `export JENGA_*_FILE=`, or a content-invariant isolation checksum. Its
  subject is a script's behaviour, not the file's invariants.

### 4.4 Tier A — the rules added

Seven additive rules in `project/configs/test-scope-map.json` **only**. No rule was added to
`templates/test-scope-map.json`: these suites are specific to this repository and the shipped default stays
project-agnostic (the epic's standing constraint).

| Rule source | Tests | Why each qualifies (Tier A evidence) |
|---|---|---|
| `project/configs/*.json` *(the catch-all)* | `tests/config-descriptors.bats` | Lines 117–118 iterate **every** live config (`audit-config`, `workflow`, `scope-thresholds`, `test-config`, `playbook-config`, `checklists`) reading `$REPO_ROOT/project/configs/<f>.json` and asserting every key is covered by its descriptor; lines 255–258 read real values for three more. |
| `project/configs/test-scope-map.json` | `tests/project-scope-map.bats`, `tests/test-scope-map.bats` | `project-scope-map.bats:39` sets `MAP` to the real file and asserts `map_version`, rule keys, the absent `**/*.sh` rule, `_comment` content, `excluded_tests` identity and the mutation invariant. `test-scope-map.bats:142` asserts the project map is **not** byte-identical to the shipped template. |
| `project/configs/test-config.json` | `tests/default-suite-set.bats`, `tests/project-scope-map.bats`, `tests/audit-tester-wiring.bats`, `tests/tools-registry-e2e.bats`, `tests/config-command.bats` | `default-suite-set.bats:42` (`LIVE_CONFIG`) asserts `test_default_suite_set`; `project-scope-map.bats:93` asserts `commit_scope_map_file`; `audit-tester-wiring.bats:38` asserts all seven tool types are present; `tools-registry-e2e.bats:178` asserts `bats`/`unit` is present; `config-command.bats:293–302` asserts the real file round-trips byte-identically through `JSON.stringify(obj, null, 2) + "\n"`. *(The last was added 2026-11-02 — see the scope-thresholds row.)* |
| `project/configs/scope-thresholds.json` | `tests/config-command.bats`, `tests/config-consumer-install.bats` | **Both citations corrected 2026-11-02.** `config-command.bats` rests on **`:293–302`**, which runs `node` over `$REPO_ROOT/project/configs/<f>.json` and asserts the real file round-trips byte-identically through `JSON.stringify(obj, null, 2) + "\n"` — so a hand-edit breaking the 2-space serialisation fails it. It does **not** rest on `:105`, which compares `jenga config get` (reading the **copy** made at `:31`) against the real file: both sides move together, which is the very shape this sweep rejected `config-get-set-e2e.bats` for. Because `:293–302` covers `scope-thresholds`, `playbook-config` **and** `test-config`, that suite is now named by all three rules. `config-consumer-install.bats` rests on **`:144` alone** — a leak guard that fails only if the real `inline_max_files` becomes exactly `11`; thin, but a genuine read of real content. `:172` was dropped: it compares a value `jq`'d out of the real file at `:61` against the real file. |
| `project/configs/playbook-config.json` | `tests/config-command.bats` | **Added 2026-11-02.** `config-command.bats:293–302` covers this file by name, so it is **no longer catch-all-only** as the first sweep recorded. |
| `project/configs/workflow.json` | `tests/resolve-root.bats`, `tests/strategy-path-resolver.bats` | `resolve-root.bats:513–523` asserts the real `.paths` keys equal the resolver's own key set — the strongest of the seven. `strategy-path-resolver.bats:128–130` asserts the real `.paths.strategy`. **Not a contradiction of `T07`**, though it looks like one: the map's `_comment` lists `strategy-path-resolver.bats` among suites rejected as *documentation* suites, which it is — it builds a synthetic doc tree for its `.md` coupling. It is mapped here for a different file and a different assertion, on `workflow.json`'s own content. Stated so a reader does not read the two as conflicting. |
| `project/configs/checklists.json` | `tests/validate-checklists.bats`, `tests/checklist-gating.bats`, `tests/checklist-sh.bats`, `tests/checkin-gate.bats`, `tests/preflight-audit-items.bats`, `tests/audit-end-to-end.bats` | `validate-checklists.bats:107` runs the validator **on the real file** and asserts `PASS`; `checklist-gating.bats:304` asserts the declared situations; `checkin-gate.bats:367,383,407` assert a named item's enforcement and validate it; `preflight-audit-items.bats:121` asserts items of the real instance; `checklist-sh.bats:1661` exports the real registry and asserts it lists cleanly for every situation, so a malformed edit fails it; `audit-end-to-end.bats:219–253` runs `checklist.sh check pre-release` against the real registry and asserts `dependency-audit-before-release`'s `result`, `exit_status`, `reason` and `action`. **Corrected 2026-11-02:** `audit-end-to-end.bats` was wrongly rejected in the first sweep as "export only" and is now mapped; `tests/conventions-no-leak.bats` was wrongly *mapped* and is now removed — see §4.6. |
| `project/configs/audit-config.json` | `tests/init-audit-config.bats` | `init-audit-config.bats:19` (`LIVE`) asserts the real file against the scaffold. |

**`tests/checklist-*.bats` was deliberately *not* used** for `checklists.json`, even though the existing
`templates/checklists.json` rule uses exactly that glob. The glob matches five suites and only two are
Tier A; `checklist-entry`, `checklist-hook` and `checklist-suggest` are fixture-based. Naming the Tier A
ones literally follows this map's own stated principle — shared scripts are named individually rather than
via `scripts/*.sh`, so adding a file does not silently inherit another's test set.

### 4.5 Verified after the change

`map-scope.sh --files-from`, one file at a time, against the edited map. Every file resolves and **no file
returns the `No tests found for the changed files` warning**:

| File | Test files selected | Includes its asserting suite |
|---|---|---|
| `audit-config.json` | 2 | `init-audit-config.bats` |
| `checklists.json` | 7 | `validate-checklists.bats` + 5 |
| `playbook-config.json` | 2 | `config-command.bats` + the catch-all |
| `scope-thresholds.json` | 3 | `config-command.bats`, `config-consumer-install.bats` |
| `test-config.json` | 6 | `default-suite-set.bats` + 4 |
| **`test-scope-map.json`** | **3** | **`tests/project-scope-map.bats`** ← the task's named criterion |
| `workflow.json` | 3 | `resolve-root.bats`, `strategy-path-resolver.bats` |

Selections are 1–7 files out of 272, so every one is a strict subset of the catalog and none can trip
`T03`'s forthcoming `scoped` ≠ `full` invariant. Invariants of the map held, static-checked: `map_version`
still `1`, rule keys still exactly `{source, tests}`, no `**/*.sh` rule, `excluded_tests` byte-identical
(3 entries, same files), **no new rule names any of the three declared files**, the `_comment` still
contains the three strings `tests/project-scope-map.bats` asserts, and a `mirror.sh` change still selects
**exactly the enumerated five**.

**Corrected 2026-11-02 — `playbook-config.json` *does* have a file-specific rule.** The first version of
this document recorded it as covered by the catch-all alone. That rested on the wrong citation for
`tests/config-command.bats` (see §4.4): its real Tier A case, `:293–302`, names `playbook-config` directly.
Its other real-root reader, `config-get-set-e2e.bats:351`, remains Tier B (see §4.6).

**The catch-all is still the general form, and is now pinned as such.** The strongest evidence is that a
config file that *does not exist yet* already resolves through it: `map-scope.sh` on
`project/configs/some-future-config.json` selects `tests/config-descriptors.bats`. That is asserted as a
test case, not just measured here.

### 4.6 Tier B — every candidate examined and rejected, with its reason

| Rejected suite(s) | Config | Why it is not Tier A |
|---|---|---|
| `tests/config-get-set-e2e.bats` | `test-config.json`, `playbook-config.json` | `setup()` copies the real configs into a scratch tree; `cfgval` reads `$CFG/<f>.json` (**the copy**) and the assertions at `:501` and `:351` compare the copy against the original. Both sides move together, so the result is **invariant to the file's content**. (It also carries pre-existing failures unrelated to this task, plus the one from `T01` fixed in §5.3. The story's record says five; the tester measured four on the same branch. **I did not run it, so I assert no count** — and the discrepancy is itself a sign the suite's verdict moves with working-tree state.) |
| `tests/audit-deps.bats` | `audit-config.json` | `:461` checksums the real file **before and after** and asserts it was *not* modified. Editing the file cannot change the result. A textbook content-invariant isolation check. |
| `tests/audit-record.bats`, `tests/audit-notice.bats`, `tests/audit-status.bats`, `tests/audit-end-to-end.bats`, `tests/publish-audit-notice.bats`, `tests/publish-audit-gate.bats`, `tests/config-consumer-install.bats`, `tests/workflow-load-catalog.bats`, `tests/jenga-list-preflight-deferred.bats`, `tests/commit-test-gate-run.bats` | `workflow.json` | All `cp` or `jq` the real `workflow.json` into a fixture root so path resolution works, then assert a **script's** behaviour. These ten are the single largest source of the 95-suite grep inflation. |
| `tests/consumer-path-fallback.bats` | `scope-thresholds.json` | `:98,115,131` copy the real file into a consumer tree; asserts consumer path fallback, not the file's invariants. |
| ~~`tests/audit-end-to-end.bats`~~ | `checklists.json` | **RETRACTED 2026-11-02 — this was a wrong rejection and the suite is now mapped (§4.4).** The stated reason ("`:72` only `export`s the real registry") was incomplete: `:219–253` run `checklist.sh check pre-release` against that real registry and assert the named item `dependency-audit-before-release` by `result`, `exit_status`, `reason` and `action`, so removing, renaming or re-enforcing that item changes the verdict. It is Tier A by the discriminator as written. |
| `tests/conventions-no-leak.bats` | `checklists.json` | **A Tier A FALSE POSITIVE in the first sweep, now removed from the rule.** It reads the real registry only inside its `denylist()` helper (`:38–41`), as an **input** used to build the list of this repository's own identifying values; the subject of its assertions is whether those values leak into *public-facing files*, not the registry's own invariants. Its one case that genuinely asserts a registry — `no-leak 10` at `:174` — reads `templates/checklists.json`, not the project instance. The first sweep cited `:40` as the assertion, which is a `jq` inside the helper. Caught in verification. **See the recorded decision below — this is not a *pure* Tier B, and dropping it gives up a narrow strand of real coverage.** |
| `tests/config-command.bats:105` *(the case, not the suite)* | `scope-thresholds.json` | `jc get` reads the **copy** made at `:31`; comparing it to the real file is value-invariant. The suite is still mapped, but on `:293–302` — see §4.4. |
| `tests/config-consumer-install.bats:172` *(the case, not the suite)* | `scope-thresholds.json` | Compares a value `jq`'d out of the real file at `:61` against the real file; both sides move together. The suite is still mapped, on `:144` alone. |
| `tests/scope-test-policy-resolve.bats` | `test-config.json` | Looks like the asserting suite and is not: it writes its own fixture config under `$CFG_DIR`. Already in `T06`'s bounded floor, so a `test-config.json` edit reaches it by that route regardless. |
| `tests/test-scope-map-errors.bats`, `tests/test-scope-map-mapping.bats` | `test-scope-map.json` | Both anchor on `$REPO_ROOT/templates/test-scope-map.json` (the shipped template) and build fixtures; neither reads the project map. |
| `tests/commit-test-gate-decide.bats`, `tests/conventions-detect.bats`, `tests/discover-tests.bats`, `tests/j-test-e2e.bats`, `tests/scope-test-gate.bats`, `tests/init.bats`, `tests/break-status.bats`, `tests/checkin-liveness.bats`, `tests/conventions-precommit-timing.bats`, `tests/workflow-recorder-active.bats`, and the ~40 further `workflow.json` grep hits | various | Each **writes its own** config JSON into `$BATS_TEST_TMPDIR`, `$PROJ`, `$CFG_DIR` or `$CONSUMER_DIR`. The real file is never read; the grep hit is the *path string*, not an access. |
| ~~`tests/config-command.bats` (for `test-config.json`)~~ | `test-config.json` | **RETRACTED 2026-11-02.** This row claimed the real file is never read, which contradicted §4.4 once that section began mapping the suite to `test-config.json`. `:293–302` iterates `scope-thresholds playbook-config test-config` and runs `node` over `$REPO_ROOT/project/configs/<f>.json` itself. The suite is Tier A for all three and is mapped by all three rules. |

#### Recorded decision — dropping `conventions-no-leak.bats` gives up a narrow strand of real coverage

Raised in verification and recorded here deliberately, so it is a decision rather than a silent
consequence of a reclassification.

`conventions-no-leak.bats` is **not a pure Tier B**. Its `no-leak 4` case builds part of its denylist from
the **real registry's non-default item ids** — `[.items[].id] - [templates'.items[].id]`, which is 10 ids
today, all at least the 6 characters the helper requires — and then scans the five shipped files for any of
them. So if a future `checklists.json` gained an item whose id happened to be a substring present in a
shipped file, that case would go red, and **no rule now reaches it.**

**Dropped anyway, for two reasons.** First, the coupling is incidental rather than asserted: the subject of
every case in that suite is whether this repository's identifying values leak into public-facing files, and
the registry is one of five sources feeding the denylist — it asserts nothing about the registry's own
invariants, which is the whole basis of the Tier A/Tier B split. Second, the specific risk is already
covered from the other side: `templates/checklists.json` maps to `tests/checklist-*.bats` and
`tests/preflight-audit-items.bats`, and the five mapped `checklists.json` suites validate the real
instance's schema, items and enforcement directly.

**The residual risk, stated plainly:** an id collision between a new project registry item and text in a
shipped file would not be caught by a scoped gate on a `checklists.json` edit. It would still be caught by
`j.test`, by `j.commit` option 2, and by the public CI job. If that trade turns out to be wrong, the fix is
one entry, not a redesign.

### 4.7 The known cost of the catch-all, stated not buried

`tests/config-descriptors.bats` is the correct catch-all target — it is the one suite that asserts *every*
live config against its descriptor — and it has **two red cases on `main`** that `E72_S08` explicitly
disclaims (full record: `project/rapports/problems/E72_S07-config-descriptor-drift-unowned.md`):

- **test 9** (`commit_scope_map_file` differs from its descriptor default) — real drift from `E72_S07_T03`.
  **Owner: `E72_S07`.**
- **test 14** (`scope-thresholds.json max_concurrent_developers`) — not drift. It fails **because
  `bump_on_change` worked** (live `8` vs descriptor default `4`), so it asserts a property that any correct
  use of `jenga config set` breaks. **Unowned; needs a decision.** Its result is **working-tree dependent**,
  which is itself the clearest evidence of the defect: it was red when this audit was written and **green**
  when the tester re-ran it hours later on the same branch. A test whose verdict moves with uncommitted
  state is not a usable gate either way.

**Consequence of this change:** a `project/configs/` edit under `test_run_story: scoped` now selects a
currently-red suite, which under the scrum master's Rollup Logic would hold a story open on redness it did
not cause.

**It is mapped anyway.** Withholding the asserting suite to keep the gate green would be hiding the defect,
not fixing it — and would be exactly the "clean table that omits an awkward call site" this task forbids.
**Recommendation: test 14 needs an owner, and `E72_S07` should be asked to close test 9.** The precedent is
already set either way: `templates/config-descriptors/*.json` has mapped to this same suite since
`E72_S07_T03`, so descriptor edits already carry the redness.

---

## 5. The two open findings folded in (Part 3)

### 5.1 The `die 3` "no runnable catalog entry" path has no runtime test — **own item: YES**

Finding 2 of `project/rapports/problems/E72_S08_T02-stale-source-text-assertion-in-scope-gate-narrowing.md`,
the only item still open on that rapport after finding 1 was closed in `963bdfa3`.

**Recommendation: it needs its own board item, outside `E72_S08`.** Reasons:

1. It is **pre-existing** and explicitly not caused by `T02`; the tester recorded it as a live non-blocking
   finding, and the rapport is its only provenance.
2. Closing it properly (the rapport's option 1 — drive the gate into the branch and assert `status` 3 plus
   the runtime stderr) is **a sizeable port, not a one-line fix**. *Corrected 2026-11-02: the first version
   of this section said the three fixture pieces did not exist and had to be built. They do exist —
   `tests/scope-gate-narrowing.bats:71–74` (`elevate()`), `:65–69` (`marked_test()`) and `:44`/`:52` (the
   npm suite) — but in the **wrong suite**.* Porting them into `T03`-owned `tests/scope-test-gate.bats` is
   still substantial, and there is one genuinely new wrinkle: `baseline-permissions.sh:433–451` scans
   `$ROOT/tests/*.bats` only, while the gate fixture's files live under `alpha/`…`delta/`.
3. The rapport itself warns it "should **not** be folded silently into `T05`'s mirror resync", and folding
   it into this audit task would be the same mistake in a different costume.

### 5.2 `T02`'s `run_full` guard has a hole — **own item: NO**

The hole is real and reproduces as described. `tests/scope-test-gate.bats:369` asserts
`grep -cE '^[[:space:]]*run_full$' == 1`, which matches **only a bare call on its own line**. So
`run_full || true`, or `if true; then run_full; fi`, reintroduces the escalation with valid syntax while all
three of that test's assertions stay green: the bare-call count is still `1`, the escalation string count is
still `0`, and the one bare call still precedes the scoped section. *(It is **test 17** of
`tests/scope-test-gate.bats`; the first version of this section called it "test 14", which is a different
case in a different file.)*

**The invariant is nonetheless guarded behaviourally — but by narrower means than the first version of
this section claimed.** *Corrected 2026-11-02 in verification; the conclusion stands, the argument does
not.* The original wording was:

> `run_full`'s **first statement is `EFFECTIVE="full"`**, so *any* call to it reached from a scoped path
> flips `effective_mode` and fails one of those assertions, **however the call is spelled.**

"However the call is spelled" is **false**, in two ways:

1. **Any subshell spelling** — `(run_full)`, `run_full | cat`, `x=$(run_full)`, `run_full &` — sets
   `EFFECTIVE="full"` in a child that never propagates. Worse, `jq_ok` is `jq -e` over `$output`
   (`tests/scope-test-gate.bats:214–219`), and `jq -e` on a **two-object stream** takes its exit status
   from the *last* object, so the `.effective_mode != "full"` assertions would pass anyway. The suite does
   still catch this case — but via `:551`'s single-object (`jq -s 'length' == 1`) assertion and the `marks`
   assertion at `:362`, **not** the assertions originally named here.
2. **A call inserted at either `die 3` site** (`scope-test-gate.sh:804`, `:822` — the old escalation
   sites). `die` never calls `finish` (`:389`), so those paths emit **no JSON at all** and no
   `effective_mode` assertion can fire. Nothing in the suite reaches either branch at runtime — **which is
   §5.1's own open finding.** The two findings therefore interact: §5.1's uncovered `die 3` branch is
   precisely where §5.2's hole is least guarded, which strengthens the case for §5.1's follow-up item
   beyond hygiene.

**Recommendation: still no new board item.** Case 1 is caught, albeit by different assertions than first
claimed, and case 2 is already covered by §5.1's recommended item rather than needing a second one. The
grep remains a weaker, redundant belt beside a working brace.

What is worth doing is **one comment naming the assertions that actually guarantee the invariant**, so a
future reader does not mistake the grep for the guarantee — and it must cover **both** sites, because the
identical grep pair is duplicated: `tests/scope-test-gate.bats:365–378` (which is **test 17** of that file,
not "test 14" as first written here) and `tests/scope-gate-narrowing.bats:296–299`. Both files are `T03`'s
under this story's lane discipline, so **this is reported as owed to `T03`**, not made here.

*Coordination note, by reading `T03`'s task file rather than messaging it:* `T03`'s invariant does **not**
close this hole. `T03` compares the scoped *selection* against the full runnable catalog and refuses when
they are equal — an extra `run_full` call is an extra *execution*, not a wider selection, so the comparison
would not see it. The `effective_mode` assertions are what close it.

### 5.3 `tests/config-get-set-e2e.bats` L517 — **fixed here**

Not one of Part 3's two findings, but the same class of defect and the story named this task as its home.
The story's 2026-11-02 "Known test state" entry records that `T01` made **L517** of that suite red:
`setup()` copies this repository's **live** `project/configs/*.json`, and the case
*"test_run_* keys: get reads the defaults (none, scoped, full)"* asserted `test_run_epic == "full"` — the
policy `T01` legitimately changed to `none`. It was outside `T01`'s three enumerated test files and was left
**unowned**, with the story stating "`T04` is the natural home if it is picked up inside this story, since
`T04` already corrects prose that restates the old policy".

**Fixed**: the assertion now reads `none`, the title is corrected to say *live tiers* rather than
*defaults*, and a comment records that this case reads the live config rather than the descriptor defaults —
which is why a policy re-tier moves it — so the next change to these keys finds the pointer.

**The suite's other failures were deliberately left alone.** They are pre-existing on `main`, no task in
this story owns them, and folding them into an audit task would be scope creep. They still need an owner.
**No count is asserted here**: I did not run the suite, the story's record says five, and the tester
measured four (cases 1, 10, 17 and 33, with L517 green after §5.3's fix). *Corrected 2026-11-02 — this
paragraph still read "the other five failures" after the same count had been removed from §4.6.*

---

## 6. Owed elsewhere

**Owed to `T05`** (`project/documentation/test-runner.md`, `project/configs/README.md`, `CLAUDE.md` and the
mirror resync are all `T05`'s; `test-runner.md` is additionally `T03`'s live file under this task's lane
discipline, so none of it was edited here):

1. **A link to this document** from `project/documentation/test-runner.md`. This task's acceptance criterion
   asks for the link; the file is out of lane, so the link is owed rather than made.
2. The `project/configs/` scope-map rules added here should be mentioned in `test-runner.md`'s
   "A project scope map" section, alongside `T07`'s documentation rules.
3. §3(a) above — that `j.commit`'s protection against an agent-chosen `full` rests on the caller declaring
   `--caller noninteractive`, and is convention- not structurally-enforced — belongs in `test-runner.md`'s
   `j.commit` section.
4. §2's correction: the public CI full-suite job gates **promotion to the public default branch**, not
   `npm publish` directly (which is `workflow_dispatch` behind `needs: audit`). Any doc that says "the CI
   test job gates `npm publish`" should be softened to match the workflow graph.

**Owed to `T03`:** the clarifying comment described in §5.2, at **both** sites that carry the identical
grep pair — `tests/scope-test-gate.bats:365–378` (test 17) and `tests/scope-gate-narrowing.bats:296–299`.
Annotating only the first would leave its twin reading as the guarantee.

**A handoff risk on the one unmet criterion, flagged in verification.** Item 1 above (the `test-runner.md`
link) currently lives **only in this document** — which is itself the deferred artefact. `T05`'s task file
names neither this audit nor the link, and the audit is absent from its `docs:` list. Deferring across a
lane boundary is the right call, but a deferral recorded only inside the thing being deferred can be
dropped unnoticed. **Whoever picks up `T05` should add this document to its `docs:` and the link to its
deliverables**; until then, treat this paragraph as the only pointer.

**Mirror files made stale by this task** (generated artefacts, never hand-edited; resync is `T05`'s):

- `.claude/agents/tester.md`
- `.agents/agents/tester.md`
- `.claude/agents/scrum-master.md`
- `.agents/agents/scrum-master.md`

`project/configs/test-scope-map.json` has **no** mirror copy, so the map change needs no resync.

---

## Appendix A — the recorded greps

Run from the repository root. Root sources only; `.claude/`, `.agents/`, `.git/` and `node_modules/` are
excluded because they are generated or vendored.

**Grep 1 — every reference to a runner or gate script.**

```bash
for pat in scope-test-gate run-suites test-gate-run test-gate-decide test-gate-scoped \
           build-catalog discover-tests; do
  echo "=== $pat ==="
  grep -rl "$pat" skills agents hooks scripts templates lib tests package.json CLAUDE.md \
    project/.workflows project/documentation project/configs 2>/dev/null | sort
done
```

Live (non-historical) hits are exactly the rows of §1. Everything else was a plan or summary under
`project/documentation/plans/` or `project/documentation/summaries/` — a historical record, not a call site.

**Grep 2 — the proven negative over the six closing skills, the hooks and the workflows.**

```bash
grep -rniE 'scope-test-gate|run-suites|test-gate-|bats|j\.test|/j-test|test_run_|full suite|full catalog|test gate' \
  skills/j-close-task skills/j-close-story skills/j-verify skills/jenga skills/j-do skills/j-dooo \
  hooks project/.workflows package.json
```

Returned **no runner invocation** from any of the six skills, from `hooks/` or from `project/.workflows/`.
The only substantive hits were `package.json`'s `"test": "bats tests/*.bats"`, `j-close-task`'s prose
delegating the gate to the Tester, and unrelated uses of the word "catalog" in `skills/jenga/scripts/`.

**Grep 3 — stale policy prose in the agent definitions.**

```bash
grep -n -i 'test_run_epic|scope-test-gate|full suite|full catalog|default .full.|epic scope test gate' \
  agents/scrum-master.md agents/tester.md
```

Found the six stale claims fixed in `b94b3f6d`. Re-running
`grep -n -i 'default .full.|defaults none, scoped, full|fall(s)? back to the full catalog' agents/*.md`
now returns nothing.

**Grep 4 — the Part 2 inflation measurement and the discriminator pass.**

```bash
# the inflation
for n in test-scope-map test-config scope-thresholds workflow checklists audit-config playbook-config; do
  printf '%-22s %s\n' "$n.json" "$(grep -rl "$n.json" tests/*.bats | wc -l)"
done
# the discriminator: a read of the REAL file off the repository root
for n in ...; do grep -rn "REPO_ROOT/project/configs/$n" tests/*.bats; done
```

Counts are in §4.3; the per-candidate classification is in §4.4 and §4.6.

**Measurement — the mapping itself, before and after.**

```bash
for f in project/configs/*.json; do
  printf '%s\n' "$f" > /tmp/one.txt
  bash skills/j-test/scripts/map-scope.sh --root . \
    --map project/configs/test-scope-map.json --files-from /tmp/one.txt \
    | jq -c '{mapped: [.mapped_tests[] | .[]] | length, warnings}'
done
```

`map-scope.sh` is the gate's own mapper and is read-only; **no test suite was executed by this task.**
