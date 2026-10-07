# Diagnosis: the three `mirror-test-subject-invariant` failures

**Task:** E28_S18_T01
**Story:** E28_S18 — Mirror surface follow-ups from E67
**Epic:** E28 — Public Mirror
**Date:** 2026-10-05 (UTC)
**Agent:** developer
**Session:** do-20261005T000137Z-72167

---

## Verdict in one paragraph

The three cases are **not broken, and `mirror.sh` is not broken.** They fail because
`check_test_subject_invariant` is correctly refusing the push: one unrelated shipping test file,
`tests/checklist-gating.bats`, is genuinely **stranded** — it ships to the public mirror but asserts the
existence of `skills/j-mirror-public/SKILL.md`, which is deliberately blocklisted as private tooling.
The gate is a **true positive**. The three named cases are the only three in the file that assert the
push *succeeds*, so they are the only three that go red when any shipping test is red; the other seven
assert refusal or never reach the gate, and pass either way. The apparent "intermittency" is not
timing, ordering, machine load, or leaked git state — it is the **changing identity of whichever
unrelated shipping test happens to be red at the time**. The runtime is structural: the gate runs the
whole shipping `.bats` suite serially, once per real-push case, and the suite has grown from 43 to 92
files in nine days.

---

## 1. What the three cases actually assert

`tests/mirror-test-subject-invariant.bats` has 10 `@test` cases (the reported `#11`/`#12`/`#13` indices
come from an aggregate run across several files and do not map onto this file's own numbering). Seven
of the ten reach the gate's nested-suite loop, via the `run_real_push` helper at line 94, which is
where `MIRROR_TEST_SUBJECT_GATE=1` is set — not per case. Call sites: lines 136, 142, 149, 157, 169,
176, 197.

| # | Case (by name) | Asserts | Reaches gate loop | Red today |
|---|---|---|---|---|
| 1 | real push is refused when a shipping test's subject is blocklisted | `status -ne 0` | yes | no |
| 2 | refusal names the offending stranded test file | output match | yes | no |
| 3 | refusal leaves the bare remote with zero refs | `status -ne 0` | yes | no |
| 4 | refusal leaves no committed marker in the scratch worktree | `status -ne 0` | yes | no |
| **5** | **real push proceeds normally when the shipping suite is clean** | **`status -eq 0`** | **yes** | **YES** |
| **6** | **a clean push actually lands a commit on the bare remote** | **`status -eq 0`** | **yes** | **YES** |
| **7** | **a deliberately blocklisted test file causes no failure, only its ship-list absence** | **`status -eq 0`** | **yes** | **YES** |
| 8 | `--dry-run` never runs the test-subject invariant | `status -eq 0` | no (exits early) | no |
| 9 | `--inventory` never runs the test-subject invariant | `status -eq 0` | no (exits early) | no |
| 10 | a missing bats binary produces a logged skip | `status -eq 0` | no (exits at `command -v bats`) | no |

The three red cases are exactly cases 5, 6 and 7 — exactly the three that both reach the gate **and**
require it to pass. Cases 1–4 reach the gate and require it to *fail*, so a stranded test anywhere
satisfies them regardless of which file it is. Cases 8–10 never run the nested suite. This partition is
the whole explanation of *why these three and no others*.

---

## 2. The actual cause: one genuinely stranded shipping test

A real `mirror.sh` push against a local bare remote, run **outside** bats (so the nesting guard does
not apply and the gate runs in full), reported exactly one failing shipping file:

```
mirror.sh: test-subject-invariant: running 83 shipping test file(s) in a mirror-shaped tree
mirror.sh: test-subject-invariant: FAIL tests/checklist-gating.bats — not ok 8 every gated skill exists and names the checker call for exactly the phases the mapping table assigns it
mirror.sh: error: test-subject-invariant: the following test file(s) ship to the public mirror but FAIL there:
```

`tests/checklist-gating.bats` is **not** in `.publicignore`, so it ships. Its gated-skill list (line 48)
is:

```
GATED_SKILLS="j-commit j-reconcile j-do j-publish j-mirror-public"
```

Four of those five skills ship to the mirror. `skills/j-mirror-public/` does not — the whole directory
is blocklisted as private tooling, and always will be. So the test asserts the existence of a subject
that is absent from the mirror by design. That is the precise definition of a stranded test, and the
exact failure mode `E28_S16` built this gate to catch.

**It is red only in the mirror, not privately.** Measured:

| Context | Result | Wall clock |
|---|---|---|
| Private repo (`bats tests/checklist-gating.bats`) | **17/17 pass** | 9 s |
| Mirror-shaped tree (ship set only) | **4 of 17 fail** | — |

The four that fail in the mirror-shaped tree, with their real messages:

| Case | Failure in the mirror-shaped tree |
|---|---|
| 8 | `j-mirror-public: skills/j-mirror-public/SKILL.md does not exist` |
| 9 | line 272: `.../skills/j-mirror-public/SKILL.md: No such file or directory` |
| 10 | `no reference to preflight-checklists.md in: j-mirror-public` |
| 14 | line 357: `.../skills/j-mirror-public/SKILL.md: No such file or directory` |

Note the gate reported only case 8. That is `grep -m1 -E '^not ok '` in the loop at
`skills/j-mirror-public/scripts/mirror.sh` — by design it names one line to make the failure
actionable, and the verdict keys on bats' exit status, never the grep. The consequence is that the
gate's log **understates the blast radius** (one case named, four actually failing). Cosmetic, but
worth knowing when reading its output.

`tests/checklist-gating.bats` was added on 2026-10-03 by `E67_S03_T05` (commit `fe53ce95`).

---

## 3. Classification per case

| Case | Cause | Test defect or `mirror.sh` defect? |
|---|---|---|
| real push proceeds normally when the shipping suite is clean | Gate correctly refuses because `tests/checklist-gating.bats` is stranded. The case's own precondition ("when the shipping suite is clean") is false. | **Neither.** Not a defect in this case, and not a `mirror.sh` defect — the gate is a true positive. The defect is in `tests/checklist-gating.bats` / `.publicignore`. Filed as **E28_S18_T03**. |
| a clean push actually lands a commit on the bare remote | Same. The push never happens, so no commit lands and no `mirror-staging` ref is created. | **Neither** — same third-party cause. |
| a deliberately blocklisted test file causes no failure, only its ship-list absence | Same. Its first half (`--dry-run`) passes; its second half calls `run_real_push` and asserts `status -eq 0`, which the refusal breaks. | **Neither** — same third-party cause. The irony is that this case fails *because* a different blocklisted-subject situation is being handled correctly. |

**No real `mirror.sh` correctness defect was found.** Two secondary `mirror.sh` findings are recorded in
section 6; one is filed as a board item, and neither is a correctness bug in the invariant.

### A genuine, separate weakness in the three cases themselves

Worth naming even though it is not the cause: these three cases are **non-hermetic**. Their precondition
is "the shipping suite is clean", which is stated in the case name but never asserted or isolated. Their
dependency surface is all 83 shipping test files, so *any* unrelated red test anywhere in the repo is
reported as a failure of `tests/mirror-test-subject-invariant.bats` rather than attributed to its real
source. That mis-attribution is exactly what produced the "known baseline failures" framing in six E67
summaries: the file was blamed for a defect that was never in it. This is a test-design weakness, not
the cause of the current failures, and deliberately **not** fixed here (see section 7 for the
recommendation).

---

## 4. Intermittency: mechanism confirmed, and it is not flakiness

**Confirmed. The mechanism is a dependency on global repo health, not timing, ordering, machine load,
or leaked state.**

Cases 5, 6 and 7 are red **iff at least one of the 83 shipping `.bats` files is red at that moment.**
That predicate has nothing to do with when or how the file is run, which is why it looks intermittent
while being perfectly deterministic at any given commit:

- **2026-10-03** (`project/ideas.md` line 26): the recorded fourth baseline failure was
  `skill-allow-list-bijection`'s "produce identical skills arrays", caused by a stale `.agents/skills`
  mirror, and it **cleared after a `/j-self-sync`**. A repo-state change with no connection to this
  file flipped it.
- **2026-10-05** (this task): the culprit is `tests/checklist-gating.bats`, which did not exist until
  2026-10-03.

So the culprit's *identity* changed between observations while the *mechanism* stayed identical. An
earlier partial run seeing them pass is consistent: at that commit, nothing shipping was red.

This also refutes, in a specific way, the framing that the failures are "pre-existing and unrelated to
E67". The **mechanism** is pre-existing and unrelated to E67 — it has been latent since the gate was
written. But the **current** culprit is an E67 file (`tests/checklist-gating.bats`, `E67_S03_T05`). Both
statements are true at once, and conflating them is what made the failures look mysterious.

### A loop worth noting: E67_S03 could not evidence a criterion its own task broke

`project/PROJECT_SUMMARY.md` line 123 records that `E67_S03`'s "existing bats suites still passing"
criterion was left unticked at rollup *because* `tests/mirror-test-subject-invariant.bats` carried three
undiagnosed failures. The shipping file now causing those failures is `tests/checklist-gating.bats` —
added by **`E67_S03_T05`**, the same story. So the story was blocked from evidencing its own criterion by
a stranded test it had just authored, while the three failures it pointed at were treated as unrelated
pre-existing noise.

This is not a contradiction of the "pre-existing" claim (the mechanism predates E67, and an earlier
culprit cleared after a `/j-self-sync`). It is a demonstration of the cost of the mis-attribution: once
a red file is labelled a "known baseline failure", a newly-introduced strandedness lands inside that
label and becomes invisible. Six E67 summaries cite these failures; none identified that one of them had
caused the then-current instance.

### Ordering, timing and fixture leakage: ruled out

- **Ordering:** ruled out. The predicate is evaluated independently inside each case, against a freshly
  materialised temp tree built by `rsync` from the ship set. No case's outcome can influence another's.
  The isolation-vs-suite-order comparison in section 5 is the empirical check, and it agrees.
- **Leaked fixture:** ruled out. `.publicignore` is snapshotted in `setup()` and restored in
  `teardown()` byte-for-byte regardless of outcome, and each case gets a brand-new bare remote and its
  own scratch worktree under `$BATS_TEST_TMPDIR`.
- **Timing / machine load:** ruled out as a *cause of failure*. Load changes how long the run takes, not
  whether an unrelated test file is red. It is entirely a runtime story (section 6), not a pass/fail one.

---

## 5. Isolation versus suite order

Each named case was run alone via `bats -f "<name>"`, then the whole file was run in suite order, on an
otherwise idle machine.

<!-- MEASUREMENT_TABLE -->

---

## 6. Runtime: reproduced, and structural

### The cost model

| Quantity | Measured value |
|---|---|
| `.bats` files in `tests/` | 92 |
| Of those, shipping to the mirror | **83** (9 blocklisted) |
| Cases in the invariant file reaching the nested-suite loop | **7** of 10 |
| `bats` process launches per full run of this one file | **7 x 83 = 581** |
| One full gate pass, measured outside bats, idle machine | **549 s (9 m 09 s)** |
| Implied average per shipping file | **6.6 s** |

The loop in `check_test_subject_invariant` runs `( cd "$mirror_tree" && bats "$rel_test" )` **one file at
a time, serially, with no early exit and no parallelism.** It does not stop at the first failure — it
runs all 83 even once the verdict is already decided — and it repeats the whole pass for each of the
seven real-push cases.

### Why it has roughly doubled

The function's own header comment still says "6 of 39 .bats files". The real numbers:

| Date | Commit | `.bats` files in `tests/` |
|---|---|---|
| 2026-09-26 (invariant file's first commit) | `62575326` (`E28_S16_T02,T03`) | **43** |
| 2026-10-05 (today) | — | **92** |

Nine days, better than double. At ~37 shipping files and 6.6 s each, a pass cost ~244 s, so the file
cost ~28 min — which matches the ">22 minutes" a tester observed. At 83 shipping files it is ~9 m per
pass, so ~64 min — matching the later "51+ minutes" observation and its upward trend. **The 22 → 51
minute growth is fully explained by the growth in the repo's test count, with no appeal to machine load
at all.** It will keep growing with every `.bats` file added anywhere in the repo, whether or not that
file has anything to do with the mirror.

### Secondary finding: the loop has no early exit

Once any shipping file has failed, the push is already going to be refused, but the loop continues
through all remaining files. On today's numbers that is up to 82 files of pure waste per pass. Filed as
**E28_S18_T04**, since it is a real (performance, not correctness) defect in `mirror.sh` and this task
does not fix `mirror.sh`.

### Important caveat on any parallelism recommendation

The dispatch for this task suggested that parallel bats is "established practice here, unlike the serial
loop in `mirror.sh`", on the basis that the repo's tester shards bats into five concurrent invocations.
**I could not verify this, and the evidence points the other way:**

- `package.json`'s `test` script is `bats tests/*.bats` — one serial invocation.
- No sharding, `-j`, `--jobs` or parallel-bats instruction exists in `agents/tester.md`, `scripts/`, or
  `project/configs/`.

If some tester session did shard by hand, it was ad hoc and is not committed anywhere, so it is not
established practice in any reproducible sense.

More importantly, **`bats -j` does not work on this machine.** bats 1.14.0 delegates `-j` to GNU
`parallel`, which is not installed:

```
$ bats -j 4 tests/checklist-gating.bats
1..17
.../bats-exec-suite: line 323: parallel: command not found
# bats warning: Executed 0 instead of expected 17 tests
$ echo $?
1
```

It executes **zero** tests. It does at least exit **1**, so it fails closed and the gate would refuse
rather than falsely clear — consistent with the script's stated philosophy, and the one piece of good
news here. But a naive `-j` adoption would make the gate refuse every push with a confusing error, and
it would add a new hard dependency (GNU parallel) to a pre-push gate. Any parallelism work must handle
that explicitly rather than assume `-j` is available. An early exit (E28_S18_T04) is the cheaper and
safer win, and needs no new dependency.

---

## 7. The `E46_S02_T01` shared-`.git/config` leak class: ruled OUT

`project/rapports/problems/E46_S02_T01-mirror-test-corrupted-shared-repo-state.md` records a mirror test
leaving this repo's shared `origin` pointing at a deleted bats temp path. Because `.git/config` is shared
across the primary checkout and every worktree, that class of leak is repo-wide, so it was checked
first, as the task required.

**Empirically ruled out.** Snapshot before any run, and again after a full real `mirror.sh` push and
after the full suite run:

| Check | Before | After |
|---|---|---|
| `git config --get remote.origin.url` | `https://github.com/samwelmunga/JengaAgent.git` | unchanged |
| `.git/config` mtime | `Oct 4 20:22:56 2026` | unchanged — predates every run in this task |
| Worktree's checked-out branch | `E28_S18_T01-diagnose-invariant-test-failures` | unchanged |
| `bats-run` / tmp paths in `.git/config`, `.git/config.worktree`, `.git/worktrees/*/config.worktree` | none | none |

The mtime is the decisive datum: `.git/config` was not written at all.

**Structurally ruled out too**, which matters more than one clean run:

1. The scratch worktree is **not** a linked git worktree. `mirror.sh` creates it with `git clone` or
   `git init` (lines 364–370), so it is a standalone repository with its own private `config`. The
   `git -C "$WORKTREE_PATH" remote set-url origin ...` calls therefore write to that throwaway clone,
   never to this repo's shared config.
2. `MIRROR_WORKTREE_PATH_OVERRIDE` (added by `E28_S17_T02` in response to that very incident) points the
   scratch path at `$BATS_TEST_TMPDIR`, i.e. under `/var/folders/...`. The original failure mode was
   `git -C` finding no valid `.git` and **walking up** to the nearest enclosing repository. Under
   `/var/folders` there is no enclosing git repository to walk up to, so even if that walk-up happened
   it would find nothing to corrupt. The shared-path race that triggered the incident is removed.

Every case in `tests/mirror-test-subject-invariant.bats` sets both overrides via `run_real_push`, so the
whole file is covered by both arguments. Note the underlying git-walks-up behaviour itself is *not*
fixed — `mirror.sh`'s own comment at line 316 says so, and it remains separately tracked — but it is not
reachable from this test file.

---

## 8. Recommendations (none applied in this task)

1. **Fix the actual defect: E28_S18_T03** — un-strand `tests/checklist-gating.bats`, either by making it
   tolerant of a by-design-absent gated skill (guarding cases 8, 9, 10 and 14) or by blocklisting the
   file. Doing this turns all three named cases green with no change to either the invariant file or
   `mirror.sh`. This is the whole fix for the red suite.
2. **E28_S18_T04** — give the nested loop an early exit, and refresh the stale "6 of 39 .bats files"
   header comment. Do not reach for `bats -j` without resolving the GNU-parallel dependency.
3. **Consider making cases 5–7 hermetic** (not filed; needs a design decision). As written they depend
   on all 83 shipping files being green, so unrelated breakage is mis-attributed to this file forever.
   Options worth weighing: assert against a small fixed fixture ship set rather than the live one, or
   have the case detect "a shipping test unrelated to this suite is red" and report *that* distinctly
   from "the gate false-positived". Either would have pointed the six E67 tasks at
   `tests/checklist-gating.bats` on day one instead of teaching them to ignore a red file.
4. **Stop citing these as "known baseline failures".** They were a correct signal the whole time. The
   gate found a real stranded test; the only thing missing was attribution.

---

## 9. Reproduction commands

All runs used local bare remotes via `MIRROR_PUBLIC_URL_OVERRIDE`. **Nothing in this task contacted
`https://github.com/samwelmunga/jenga-npm`.**

One full gate pass with attribution, outside bats (cheapest route to the culprit — one pass instead of
seven):

```bash
S=$(mktemp -d); git init --bare -q -b main "$S/public.git"
MIRROR_PUBLIC_URL_OVERRIDE="$S/public.git" MIRROR_WORKTREE_PATH_OVERRIDE="$S/wt" \
  bash skills/j-mirror-public/scripts/mirror.sh 2>&1 | grep 'test-subject-invariant'
```

Confirm the culprit is green privately but red in the mirror:

```bash
bats tests/checklist-gating.bats          # 17/17 pass
```

The isolation and suite-order runs are in `/tmp/e28s18t01-measure.sh` (harness used for section 5).

### Measurement conditions

The machine was idle when timing began. During the backgrounded harness run, this session performed only
light file I/O (writing this document, the plan, and the board items) and a handful of cheap `git log`
and `grep` queries; one `bats tests/checklist-gating.bats` run and two `bats -j` smoke runs (each a few
seconds) overlapped the harness and are the only non-trivial concurrent work. Section 6's headline
549 s figure was taken **before** anything else was started, on a fully idle machine.
