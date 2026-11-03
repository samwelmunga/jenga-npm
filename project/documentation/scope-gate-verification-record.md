# Scope gate verification record — `E72_S07_T04`

**Status:** **story gate run and recorded (§2.4); the epic gate is still unrun (§7, AC2)**
**Compiled by:** developer, session `do-20261101T150733Z`, 2026-11-01. **Amended 2026-11-01, fix round 4**: §2.3
corrected (mirror parity is clean; the original finding retained as dated history) and §2.4 added (the blocker-1
range decision and the story gate result it belongs to).
**Tree:** worktree `bundle-E72_S07`, branched from `main` at `450339d2`
**Who measured what.** Everything written here by the developer is read-only: `cmp`, `jq`, `bats --count`, and
read-only `map-scope.sh` invocations. **The developer executed no suite and ran no gate**, changed no permission
level and ran no `j.self-sync`. Every pass/fail count and the §2.4 gate result are the **tester's** measurements,
attributed as such where they appear. No score in this document is a developer reading, and no score is carried
forward from an earlier round.

---

## 1. Read this first: the task is not finished

`E72_S07_T04` is `assigned_to: tester` and its substance is *"run two real gates and record what happened"*. The
developer never runs tests, so the runs are not the developer's. This document records everything that is
determinable without running a suite — which is more than it sounds, and it changes what the tester should expect —
and then hands over the rest explicitly.

**Four things found here are blockers the tester will otherwise hit cold.** They are in §2.

**What has since been settled (fix round 4, 2026-11-01).** Two of the four are closed and one is half closed:

| § | Then | Now |
|---|---|---|
| 2.1 AC1 not satisfiable as written | open | still open — needs the user's or scrum master's agreement; AC1/AC1a were amended on the task |
| 2.2 the scoped gate selects the 2-hour invariant suite | open | **decided** — option 1 (reduced range) was taken; recorded in §2.4 |
| 2.3 mirror parity broken | open | **closed** — three `chore(self-sync)` commits landed; parity re-measured clean |
| 2.4 blocker-1 decision unrecorded (AC9) | not yet raised | **recorded**, with the story gate result it belongs to |

The one thing §2 still hands over unrun is the **epic gate** (AC2): `test_run_epic` is `full`, a `full` run is the
whole catalog, and the whole catalog contains three suites no approval exists to run (§2.4, and "Suites not run" in
the tester's rapport). That is a standing blocker on the story's Definition of Done item 4, not a defect in the
implementation, and it needs a user decision — approve the three suites, or amend AC2/DoD item 4 to accept a `full`
epic gate measured over a catalog with the three excluded, with the substitution stated.

---

## 2. Four findings that change what a story gate will do

### 2.1 AC1 is not satisfiable as written

> *"A real story-closing gate run passes end-to-end in this working tree with `session_level` still 5, with the
> permission level unchanged and `j.self-sync` not run."*

Measured today in both the main checkout and this worktree:

```text
.claude/settings.json : permissions.deny match=YES  autoMode.allow match=YES
.agents/settings.json : permissions.deny match=YES  autoMode.allow match=YES
.jenga-permission-level.json : {"session_level":2}
git status for all three : clean
```

**The user restored level 2 at some point after 2026-10-22.** The elevated-session condition the story's evidence
rests on is gone. The only ways to satisfy AC1 literally are to elevate the session — which the story explicitly
forbids and reserves to the user — or to misreport a level-2 run as a level-5 one.

**Recommendation:** record AC1 as *not satisfiable, condition absent*, and treat the underlying property as verified
by the fixture-driven coverage `E72_S07_T02` added instead (`tests/baseline-permissions.bats`,
`tests/scope-gate-narrowing.bats`), which reaches the unsatisfied branch deterministically through `--root` rather
than depending on ambient session state. That is better evidence than a one-off observation would have been, and it
does not require the user's session to be in a particular state. This needs the user's or scrum master's agreement,
not the developer's — it is an acceptance-criteria change.

### 2.2 This story's own scoped gate selects the 2-hour invariant suite

`E72_S07`'s change set is 23 files, 7 of them under `tests/`. `map-scope.sh` resolves *"a changed file that is itself
a test file"* to its own suite — editing a test runs it — and `E72_S07_T02` **edited**
`tests/mirror-test-subject-invariant.bats` to add its marker and skip guard. So that file is in the change set, and a
scoped gate for this story selects it:

```text
26 test files selected, including tests/mirror-test-subject-invariant.bats
```

This is **exactly the gap `E72_S07_T03` documented** — a map cannot exclude a file that the change set names
directly, and `map_version: 1` has no negation. It is the first concrete instance of it, and it lands on this story's
own closing gate: a naive run would sit for hours and would mutate the real `.publicignore`.

**Mitigation available to the tester now:** the file carries
`# jenga:requires-baseline-permissions:` and its `setup()` calls `require_baseline_permissions` **before**
`.publicignore` is touched, so on an off-baseline tree it skips cleanly with no side effect. On *this* tree the
baseline holds, so it will not skip — it will run. Options, in preference order:

1. Run the story gate with `--range` or `--rev` narrowed to the non-test commits, and verify the edited test files
   separately by running them directly. The gate supports this; it is not a workaround to its contract.
2. Run the gate and accept the runtime.
3. Record the story gate as blocked on `E77_S02`'s manual-only marker, which is the mechanism that would exclude this
   file regardless of the map, and which is **not on `main`** (see §4).

Option 1 is recommended. Whichever is chosen must be recorded, because it is the difference between "the gate passed"
and "the gate passed over a reduced range".

**Decided (2026-11-01, fix round 4): option 1 was taken, over `--range 282801a5..1b2f483e`. The decision and the
gate result it belongs to are recorded in §2.4, which AC9 requires.** Two corrections to this section's framing
belong with it: the selection contains **three** barred suites, not the one named here, and a range that avoids all
three **does** exist. Both are measured in §2.4.

### 2.3 Mirror parity — corrected 2026-11-01 (fix round 4): parity is **clean**, nothing is owed here

**Superseded finding — the parity break this section reported is closed.** Re-measured 2026-11-01 in worktree
`bundle-E72_S07` at `c47d7762`, independently by the tester and again by the developer: **all 11 files** under
`skills/j-test/` are byte-identical to their `.claude/` and `.agents/` copies. The developer's sweep was 22 `cmp`
comparisons (11 files x 2 mirrors): **22 identical, 0 differing, 0 missing**, including every file the table below
had reported as `missing` or `differs`.

| File under `skills/j-test/` | §2.3 as written | measured at `c47d7762` (`.claude/` and `.agents/`) |
|---|---|---|
| `scripts/baseline-permissions.sh` | missing | **byte-identical** |
| `scripts/lib/glob-defs.jq` | missing | **byte-identical** |
| `scripts/narrow-suites.sh` | missing | **byte-identical** |
| `scripts/map-scope.sh` | differs | **byte-identical** |
| `scripts/scope-test-gate.sh` | differs | **byte-identical** |
| the other 6 (`SKILL.md`, `build-catalog.sh`, `discover-tests.sh`, `parse-selection.sh`, `run-suites.sh`, `scope-policy.sh`) | not tabulated | **byte-identical** |

**What closed it.** Three `chore(self-sync)` commits, all ancestors of `c47d7762` on this branch (verified with
`git merge-base --is-ancestor`):

| Commit | What it mirrored |
|---|---|
| `ea7ee046` | the five `E72_S07_T02`/`T03` j-test scripts |
| `1dd5fe78` | the five j-test scripts changed by fix rounds 1-2 |
| `1b2f483e` | the two scripts changed by fix round 3 |

**So this section's conclusion is withdrawn.** *"The story gate will fail on mirror parity until a `j.self-sync`
runs"* is **false as of `1b2f483e`**: the sync has run, three times, and the assertion that was going to fail is
green. `tests/j-test-skill.bats` — whose case *"the `.claude/` and `.agents/` mirrors of `skills/j-test/` are
byte-identical to the root"* this section cited as the thing that would fail — carries **16 cases** (`bats --count`,
developer) and was measured **16/16 passing** by the tester this round. The developer runs no suites, so that score
is the tester's measurement, not the developer's.

**Consequences for the handover.** §6 step 1 ("resync the mirrors first") is **already done and must not be
repeated** — `j.self-sync` remains reserved to the user, and there is nothing left for it to do here. A reader of
the earlier text would have run a sync that was already landed and would have believed this story's gate could not
be judged when it could.

**Still owed on the board (not the developer's to write).** The same superseded claim is mirrored in two places in
`project/board/stories/E72_S07_make-the-scope-test-gate-passable.md`, which only the scrum master may correct:
`## Known Gate Blockers` blocker 2 (the whole blocker, including its five-row table) and the Definition of Done
item 5 parenthetical (*"Five `skills/j-test/` files are currently out of parity in each mirror."*). Both are
reported as owed; neither is edited from this session.

#### Original finding (2026-11-01, earlier the same day) — superseded, retained as what was measured and when

Retained verbatim in substance, because the record's value is that it shows what was found and when. It was accurate
when written: at that point the implementing session had been instructed not to run `j.self-sync`, `E72_S07_T02` had
changed `skills/j-test/` at the root only, and the generated mirrors were genuinely behind:

> **2.3 Mirror parity is broken by this story, by design of the brief**
>
> This session was instructed not to run `j.self-sync`. `E72_S07_T02` changed `skills/j-test/` at the root only, so
> the generated mirrors are behind:
>
> | File | `.claude/` | `.agents/` |
> |---|---|---|
> | `skills/j-test/scripts/baseline-permissions.sh` | missing | missing |
> | `skills/j-test/scripts/lib/glob-defs.jq` | missing | missing |
> | `skills/j-test/scripts/narrow-suites.sh` | missing | missing |
> | `skills/j-test/scripts/map-scope.sh` | differs | differs |
> | `skills/j-test/scripts/scope-test-gate.sh` | differs | differs |
>
> `tests/j-test-skill.bats`'s case *"the `.claude/` and `.agents/` mirrors of `skills/j-test/` are byte-identical to
> the root"* asserts exactly this, and that file **is** in this story's scoped selection. **So the story gate will
> fail on mirror parity until a `j.self-sync` runs.** This is foreseeable and foreseen, not a defect in the
> implementation: the brief forbade the sync, and `E72_S07_T02`'s corresponding acceptance criterion is reported
> unmet for the same reason. A `j.self-sync` plus its `chore(self-sync)` commit is the fix, and it is the first thing
> to do before judging this story's gate.

The prediction it made was correct and the fix it named is the one that was applied. Only its present tense expired.

### 2.4 The blocker-1 range decision, recorded alongside the gate result (AC9)

`E72_S07_T04`'s AC9 requires that the decision taken about `## Known Gate Blockers` blocker 1 — how the story gate
handled its own selection of `tests/mirror-test-subject-invariant.bats` — be recorded **alongside the gate result,
including whether the gate was run over a reduced `--range`/`--rev`**, and states that a gate result reported without
this statement does not satisfy AC1. This section is that record. Added 2026-11-01, fix round 4.

**The decision: §2.2 option 1 — a reduced range.** The story gate was run over `--range 282801a5..1b2f483e`, not
over the story's full change set. That range is the fix-round-3 delta, i.e. exactly the work that was under
re-verification when the gate was run.

**Why the full range could not be used, and that it is worse than blocker 1 says.** Measured read-only by the
developer with `map-scope.sh --root . --range <r>`, and matching the tester's own measurement:

| Range | Test files selected | Barred suites in the selection |
|---|---|---|
| `450339d2..c47d7762` (the story's full delta) | **26** | **all three** — `mirror-test-subject-invariant`, `mirror-permission-level-invariant`, `mirror-staging-branch-push` |
| `450339d2..HEAD` | **26** | all three |
| **`282801a5..1b2f483e`** (used) | **23** | **none** |
| `411c2f71..1b2f483e` | **23** | **none** |

Blocker 1 names only `tests/mirror-test-subject-invariant.bats`. The real selection is **three** barred suites, not
one: commit `411c2f71` added the `# jenga:requires-baseline-permissions:` marker to all three, and `map-scope.sh`
resolves a changed file that is itself a test file to its own suite ("editing a test runs it"), so each of the three
pulls itself in. The other two drive **real pushes to the public mirror**, which is a different and sharper hazard
than the first one's runtime. Blocker 1 therefore understates its own scope by two suites, and that is owed to the
scrum master as a board correction.

**Correction to the related claim that no range avoids them.** `project/data/baselines.json` →
`scope_gate_selection.E72_S07` asserted *"No range avoids them."* **That is false.** Both `282801a5..1b2f483e` and
`411c2f71..1b2f483e` select 23 test files with **zero** barred suites, because neither range contains `411c2f71`
itself and no later commit on this branch touches those three test files. The tester disproved it and corrected
`baselines.json` this round; this record is corrected here, and the same superseded framing survives in the story's
blocker 1 (board, scrum master's to fix) and in
`project/rapports/problems/E72_S07_T02-baseline-root-resolution-regression-and-exclusion-misreport.md` (a rapport,
left as dated history by design).

**The gate result this decision belongs to.** Run for real by the tester over the range above; the developer runs no
suites, so every figure in this table is the tester's measurement, attributed, not a developer reading:

| | |
|---|---|
| Command scope | `--scope story --id E72_S07`, over `--range 282801a5..1b2f483e` |
| Exit code | **0** |
| `mode` / `effective_mode` | `scoped` |
| `fallback_reason` | `null` — the map resolved suites; the full catalog was never reached |
| Test files in the executed command | **23** |
| Cases | **853 passed / 853** |
| Wall time | **10m06s**, at 45% CPU |
| Ambient `session_level` | **2** (unchanged; the permission level was not touched) |
| Baseline check | exit **0** |
| Barred suites executed | **none** — zero in the selection, so nothing was suppressed and nothing was skipped to get the pass |

**What the reduced range does not cover, stated so the pass is not read as wider than it is.** The range excludes
`411c2f71`, so it excludes the three edited test files, so the gate verified **none** of the three. All three remain
recorded as **unverified — never as passed** (see the handover's §6 and `E72_S07_T03`'s `excluded_tests`
declarations, which now name all three). This is the difference between *"the gate passed"* and *"the gate passed
over a reduced range"*, and it is why AC9 exists.

The edited test files are verified separately by running them directly, per §6 steps 2-4 — which is the supported
use of the gate's contract that §2.2 option 1 names, not a workaround to it. The tester's measurements for the
suites it could run this round: `tests/scope-test-gate.bats` **57/57**, `tests/baseline-permissions.bats` **33/33**,
`tests/j-test-skill.bats` **16/16**, `tests/commit-test-gate-mirror.bats` **5/5**,
`tests/external-refs-absent-safe.bats` **12/12**, and a whole-catalog figure of **895/897 over 25 suites** whose two
failures are the pre-existing `tests/perceived-branch.bats` pair (cases 20 and 24), owned by `E78` and untouched by
this story.
---

**Re-verification run, 2026-11-02 (tester, session `do-20261101T150733Z`) — the run this story's verdict rests on.**
The gate result tabulated above was measured over `282801a5..1b2f483e`. Fix round 4 then added commits
(`7ef09bda`, `027a5896`, `b6d0d3e2`, `b9272961`), **one of which changed a test file**
(`tests/project-scope-map.bats`), so that result no longer covered the tree being judged. The gate was therefore
re-run over the **same reduced-range decision, extended to the current HEAD**. The decision is unchanged: §2.2
option 1, a reduced range; the barred suites are kept out by the range plus the map's enumerate-and-omit, **not** by
any exclusion mechanism.

| | |
|---|---|
| Command scope | `--scope story --id E72_S07`, over `--range 282801a5..HEAD` (HEAD `b9272961`) |
| Exit code | **0** |
| `mode` / `effective_mode` | `scoped` / `scoped` |
| `fallback_reason` | `null` — the map resolved suites; the full catalog was never reached |
| Test files | **23 run / 23 available**, zero barred |
| Cases | **853 passed / 853**, 0 failed |
| Wall time | **12m06s** (prior round 10m06s; the gate's own slowness probe flagged the machine slow, so wall time is not a measure of the tests) |
| Ambient `session_level` | **2** (unchanged; the permission level was not touched, and `j.self-sync` was not run) |
| Settings baseline | both `.claude/settings.json` and `.agents/settings.json` match `level-2-guarded` on `permissions.deny` and `autoMode.allow`. Both files are *dirty* in git, but only by 11 added lines registering an unrelated `UserPromptSubmit` recording hook, which touches neither field |
| `excluded_test_files` / `exclusion_reason` | **`[]` / `null`** |
| `map_exclusion_conflicts` | **`[]`** |
| `map_excluded_test_files` | **3** — all three barred suites, reported as "NOT verified, and NOT a pass" |

**The exclusion mechanism did nothing, and that is the point.** `narrow-report.json` for this run reads
`"precondition":"satisfied"` with `"excluded":[]`. Per `scope-test-gate.sh`'s own EXCLUSION contract — *"**While the
precondition is unmet**, those files are removed from the run"* — the precondition is **met** on this tree
(`baseline-permissions.sh check` exits 0 in both the worktree and the main checkout), so the baseline-permissions
exclusion is a **no-op here** and removed zero files. Any reading that the exclusion keeps the barred suites out of a
run on this tree is wrong.

**Pre-fix versus post-fix selection, measured at the same range on the same commit (AC7).** With the pre-fix shipped
map (`templates/test-scope-map.json`) over `282801a5..HEAD` at `b9272961`: **264 test files — the entire live
catalog — including all three barred suites.** With the project map: **23 files, zero barred.** The live catalog at
that commit is **264 files / 5770 `@test` cases** (main checkout at `e548cb23`: 266 / 5815). Selection counts stand
in for a pre-fix runtime, which was never measured to completion; the substitution is stated here as AC7 requires.

**One invalidated run, recorded so it is not mistaken for a result.** A first attempt over the same range returned
`exit_code: 1` with **zero** failing assertions. Its bats scratch directory was destroyed mid-run
(`bats-run-1N6zxK/17-scope-test-gate.bats.src: No such file or directory`, `test_list_file.txt: No such file or
directory`, `rm: ... Permission denied`) while three sibling agents ran gates concurrently against a shared
`TMPDIR`. Nothing was verified by it, so it is neither a pass nor a failure of this story's work; it was discarded
and re-run under an isolated `TMPDIR`. **Operational note for future closing gates: run them with a private
`TMPDIR` when other agents may be running suites concurrently.**

---

## 3. The 4 pre-existing non-cluster failures (AC4, AC5)

From the 2026-10-22 run. **Re-checked today where inspection can settle it; no suite was run, so no entry here is a
claim that a test passes.**

| Suite | The 2026-10-22 failure | Re-checked today | Selected by a **scoped** gate? | Selected by an **epic** gate (`full`)? | Likely owner |
|---|---|---|---|---|---|
| `tests/commit-test-gate-mirror.bats` (assertion 661) | mirror drift under `skills/j-commit/` | **Parity is clean now.** All five cases' subjects — every file under `skills/j-commit/`, `skills/j-lgtm/`, `skills/j-dev-done/`, `agents/developer.md`, and the three `test-gate-*.sh` scripts — compare byte-identical across root, `.claude/` and `.agents/` by `cmp`. The drift appears to have been fixed since, independently of this story. | **Yes** — mapped from `skills/j-test/**/*.sh` → `tests/commit-test-gate-*.bats`, and from `skills/j-commit/**/*.sh` | Yes | `E72` (the commit gate's own story) if it recurs |
| `tests/external-refs-absent-safe.bats` (assertion 1582) | parity, `check-privatized.sh` ticket handling | **Not checkable by inspection** — it is behavioural, not a file comparison. Unverified; treat the 2026-10-22 result as still standing until run. | **No** for this story. Mapped only from `.publicignore` and `scripts/check-privatized.sh`, neither of which this story touches | Yes | `E28` (public-mirror parity) |
| `tests/perceived-branch.bats` (assertion 2229) | session-state hooks | **Not checkable by inspection.** Unverified. | **No** for this story. Mapped from `scripts/perceived-branch.sh` and `scripts/create-task-worktree.sh` | Yes | `E78` (`j.checkout` / perceived branch) |
| `tests/perceived-branch.bats` (assertion 2233) | session-state hooks | as above | as above | Yes | `E78` |

**AC5 — did any of the 4 merely stop being *selected* rather than being fixed? Yes, three of them.**
`external-refs-absent-safe.bats` and both `perceived-branch.bats` assertions are **no longer selected by this
story's scoped gate**, because the new project map maps them only from source files this story does not touch. That
is legitimate behaviour for a scoped gate — a story is not responsible for suites unrelated to its change — but it is
**not a fix**. All three will still be selected by `test_run_epic: full` and, on the 2026-10-22 evidence, will still
fail an epic gate.

`commit-test-gate-mirror.bats` is the exception: it *is* still selected, and inspection suggests it is no longer red.
That needs a run to confirm.

**AC8 — no unattributed red.** Every row above names an owner. None is left as a bare assertion number.

---

## 4. The elevated-session cluster (AC6)

**Confirmed as a mechanism, not as an observed run** — the condition is absent on this tree (§2.1), so the cluster
cannot be observed failing or skipping here.

What is in place:

- All three baseline-sensitive suites carry `# jenga:requires-baseline-permissions: <reason>`, and
  `baseline-permissions.sh list` returns all three with their reasons (verified).
- `tests/mirror-permission-level-invariant.bats`: the **4 ambient-dependent cases** are guarded; the **8 self-fixtured
  refusal cases are deliberately not**, because they build their own elevated state and are the coverage proving the
  guard refuses a bad push. Case count unchanged at 12.
- `tests/mirror-staging-branch-push.bats` (12 cases) and `tests/mirror-test-subject-invariant.bats` (10 cases) guard
  in `setup()`, since no case in either builds its own fixture.
- The gate excludes marked files itself and reports them in `excluded_test_files` with `exclusion_reason`; an
  all-excluded selection exits **3**, and a scoped run does **not** fall back to full in that case.

**It is not silently counted as passed**, by three independent means: the gate's exclusion happens before the run, so
an excluded file never reaches `run-suites.sh`'s tally; the file is named in stdout and JSON; and an emptied suite
gets an empty command, which `build-catalog.sh` classes `not_runnable` (verified: 0 runnable entries).

**Blocking dependency worth flagging:** `E77_S02`'s manual-only mechanism — the thing that would exclude
`tests/mirror-test-subject-invariant.bats` from *every* run including the self-edit case in §2.2 — **does not exist on
`main`.** `E77_S02_T01` is marked `Passed`, but `skills/j-test/scripts/manual-only.sh` is absent from `main` and its
commit `d11a226b4` is not an ancestor of HEAD (it lives on `E77_S02_T01-manual-only-marker` and `bundle-E77_S06`). No
test file carries a `jenga:manual-only` marker, and `E77_S02_T02`–`T09` are all `Pending`. This is a board-versus-git
discrepancy worth a `j.reconcile` pass in its own right.

---

## 5. Selection counts (what AC7's runtime will follow from)

Runtime is not measurable without running the gate. The selection counts that drive it are:

| Scope | Selection | Test files in the executed command |
|---|---|---|
| `E28_S19` story, shipped default map (the 2026-10-22 configuration) | 1 suite | **261** (5666 cases) |
| `E28_S19` story, project map (now) | 1 suite | **14** |
| `E72_S07` story, project map (now), full delta `450339d2..HEAD` | 1 suite | **26** (includes all three barred suites) |
| `E72_S07` story, project map (now), **reduced range `282801a5..1b2f483e`** — the range the gate was run over | 1 suite | **23** (no barred suite) |
| Any epic, `full` | whole catalog | **261** |

The headline: a scoped story gate went from the entire catalog to 14–26 files, a 90–95% reduction in what executes.
An epic gate is unchanged at 261 by definition — `full` means everything — which is why `E72_S07_T01` concluded both
fixes were needed and why exclusion, not narrowing, is what helps an epic gate.

**Runtime, now that one gate has actually been run (fix round 4).** The tester measured the 23-file scoped run at
**10m06s** wall, at 45% CPU, for **853 cases**; see §2.4. There is no measured "before" figure for the same scope to
subtract it from — before the fix, a scoped run executed the whole catalog, which is the 261-file / 5666-case
configuration nobody timed to completion on this tree. So AC7's before/after pair is still **not** closed by
measurement; what is recorded is the selection reduction above plus one real after-figure.

---

## 6. Handover: what the tester must run

In this order. Commands are relative to the worktree root.

1. ~~**Resync the mirrors first** (`j.self-sync`, then its `chore(self-sync)` commit). Without this, §2.3 fails the
   story gate for a reason unrelated to the implementation.~~
   **Done — do not repeat (2026-11-01, fix round 4).** Three `chore(self-sync)` commits landed on this branch
   (`ea7ee046`, `1dd5fe78`, `1b2f483e`) and parity re-measured byte-identical across all 11 `skills/j-test/` files in
   both mirrors; see the corrected §2.3. `j.self-sync` is reserved to the user and has nothing left to do here.

2. **Run the three new/unexecuted suites.** They have never been run — only `bats --count`-parsed.
   ```bash
   bats tests/baseline-permissions.bats      # 27 cases
   bats tests/scope-gate-narrowing.bats      # 22 cases
   bats tests/project-scope-map.bats         # 18 cases
   ```
   A bug in these is the most likely defect in this story's diff.

3. **Run the suites this story edited**, checking the 8 self-fixtured refusal cases in
   `tests/mirror-permission-level-invariant.bats` **run rather than skip** (the baseline holds on this tree, so any
   skip there is a defect in guard placement).
   ```bash
   bats tests/mirror-permission-level-invariant.bats   # expect 12 cases, none skipped
   bats tests/mirror-staging-branch-push.bats          # expect 12 cases, none skipped
   ```

4. **Run the glob-extraction regression surface**: `bats tests/test-scope-map*.bats`.

5. **The story gate**, with §2.2's range decision made and recorded:
   ```bash
   bash skills/j-test/scripts/scope-test-gate.sh --scope story --id E72_S07 --root . --json
   ```
   **Done (2026-11-01, fix round 4)** over `--range 282801a5..1b2f483e`: exit 0, `scoped`, `fallback_reason` null,
   23 test files, 853/853. The decision and the full result are recorded in §2.4, which is what AC9 asks for.

6. **The epic gate**, and record the outcome pass or fail:
   ```bash
   bash skills/j-test/scripts/scope-test-gate.sh --scope epic --id E72 --root . --json
   ```
   On the §3 evidence, expect it to **fail** on `external-refs-absent-safe.bats` and `perceived-branch.bats`. If it
   does, `E72_S07` closes with a known-failing epic gate owned by `E28` and `E78` respectively — which is a statement
   the story's Definition of Done explicitly allows, provided it is made.

7. **The deliberate-defect demonstration** (`E72_S07_T02`'s outstanding criterion, which proves narrowing did not
   disarm the gate). The cheapest form is a pair:
   - break an assertion in a file this story's change set **maps to** (e.g. `tests/discover-tests.bats`) → the scoped
     gate must exit 1;
   - break one in a file it does **not** map to (e.g. `tests/break-signal.bats`) → the scoped gate must still exit 0
     while a `full` gate exits 1.

   Revert both. That pair is the real proof, and it is the single most important check in this story.

8. **Do not** run `tests/mirror-test-subject-invariant.bats` as part of routine verification. Its exclusion is the
   point of `E72_S07_T03`; run it deliberately only if you intend to spend the hours.

---

## 7. Criteria status, stated without rounding up

| AC | Status |
|---|---|
| 1. Story gate passes with `session_level` 5 | **Not satisfiable as originally written** — condition absent (§2.1); amended on the task. A real story gate was since run and passed over a reduced range at ambient `session_level` 2, with the range decision recorded as AC9 requires — evidence in §2.4. Whether that satisfies the amended AC1 is the tester's judgment, not this document's claim. |
| 2. Real epic gate run and outcome recorded | **Still unrun.** A `full` epic gate is the whole catalog, which contains three suites no approval exists to run (§2.4). Needs a user decision: approve them, or amend AC2 to accept the catalog with the three excluded. |
| 3. If the epic gate fails, reason attributed per suite | **Prepared** (§3) — the attribution table is ready; the run is the tester's. |
| 4. Each of the 4 recorded with suite, owner, and what it blocks | **Met** (§3). |
| 5. Stated whether any merely stopped being selected | **Met** — three of four did; named explicitly as not a fix (§3). |
| 6. Cluster confirmed skipped-or-excluded, not counted as passed | **Met as mechanism**, not as an observed run (§4). |
| 7. Total gate runtime before and after | **Partly met** — one real "after" figure now exists (10m06s / 853 cases over 23 files, §2.4). No comparable "before" figure for the same scope was ever measured to completion, so the pair is incomplete; selection counts stand in for it (§5). |
| 8. Every still-failing suite has a board item or named owner | **Met** (§3). |
| 9. Blocker-1 decision recorded alongside the gate result, including whether a reduced `--range`/`--rev` was used | **Met** (§2.4) — option 1, `--range 282801a5..1b2f483e`, stated as a reduced-range pass with what it does not cover. |
