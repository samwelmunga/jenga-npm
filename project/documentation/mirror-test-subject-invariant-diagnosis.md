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

**And the mechanical reason this went undiagnosed for nine days across six tasks:** the failing case
asserts on `$status` alone, while `run` swallows the one line that names the culprit
(`test-subject-invariant: FAIL tests/checklist-gating.bats — not ok 8 ...`) into `$output`, where it is
never printed. Nine minutes of runtime that ends by withholding the only pointer to the real fault, and
pointing at itself instead. Six consecutive tasks chose the "known baseline failure" label over
investigating, and on this evidence that was the rational response to what the suite actually told them.
See section 3 and **E28_S18_T05**.

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

### The project has already ruled on this exact class

This classification does not need deriving from first principles — there is settled precedent in the
repo. `.publicignore` already blocklists `tests/train-cli-root-climb.bats` for the identical reason, and
its comment (lines 289–291) says so outright:

> Same reasoning as the four entries directly above. Caught by `check_test_subject_invariant` (E28_S16)
> on the 2026-09-28 run, before it ever reached the mirror — which is precisely what that gate exists to
> do.

So a shipping test that fails in the mirror because its subject is blocklisted has previously been
treated as *the gate working correctly*, and the resolution was to blocklist the test alongside its
subject — which is option 2 of the two offered in `E28_S18_T03`. Three of the four entries that comment
refers to are the other `tests/mirror-*.bats` files, handled the same way.

Citation added during verification at the suggestion of the `test-E28_S18_T01-verify` tester session
(not the re-verification session that later confirmed it — the two are distinct, an artifact of a
duplicate tester dispatch recorded in this task's remarks). It is a better-grounded argument than
re-deriving the conclusion, and it predates this task by a week.

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

### Why nobody diagnosed it for nine days: the cases emit no attribution

This is the single most actionable finding in this document. When case 5 fails, its entire output is:

```
not ok 1 real push proceeds normally when the shipping suite is clean
# (in test file tests/mirror-test-subject-invariant.bats, line 170)
#   `[ "$status" -eq 0 ]' failed
```

That is all. `mirror.sh` *does* print the culprit —
`test-subject-invariant: FAIL tests/checklist-gating.bats — not ok 8 ...` — but the case captures it into
`$output` via `run` and then asserts on `$status` alone, so the diagnostic line is never printed. The
reader is told only that a status was not zero, after a nine-minute wait, with no indication that the
real problem is in a completely different file.

So the three cases were the only visible symptom of a defect they do not contain, while actively
withholding the one line that names it. That combination — expensive, unattributed, and pointing away
from the actual fault — is a sufficient explanation for why six consecutive tasks chose to label them
"known baseline failures" rather than investigate. A one-line `echo "$output" >&3` on failure would have
collapsed this diagnosis to about thirty seconds of work.

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
- **Leaked fixture:** ruled out **as the cause of these three failures**, but *not* ruled out as a real
  hazard — see the correction immediately below. `.publicignore` is snapshotted in `setup()` and
  restored in `teardown()`, and each case gets a brand-new bare remote and its own scratch worktree
  under `$BATS_TEST_TMPDIR`. On any normal pass or fail, restoration is byte-for-byte and nothing
  survives the run.

### Correction, observed twice in this session: the fixture DOES leak when the run is interrupted

My initial claim that `.publicignore` is restored "regardless of outcome" was too strong, and I was
wrong about it. `teardown()` runs on pass and on fail — but **not** when the process is killed. This
session's full-file run was terminated externally twice, and each time it left the working tree with:

```
-tests/mirror-permission-level-invariant.bats
```

i.e. `strand_permission_level_test()`'s deliberate mutation still in place, silently **un-blocklisting a
private test file** from the public mirror's ship set. I detected it only because `git diff main --stat`
showed an unexpected `.publicignore | 1 -` while I was verifying something else, and it had already
corrupted one in-flight measurement run before I noticed (that run was discarded and redone against a
restored fixture).

Why this matters more than a normal fixture leak:

- `.publicignore` is **load-bearing for what ships to the public repo.** A silent mutation of it is a
  content-parity hazard, not untidiness.
- **Interruption is the expected case, not the edge case.** This file takes ~64 minutes. Anyone running
  it will plausibly `Ctrl-C` it, and I hit this twice in a single session without trying to.
- It is **durable and invisible**: it survives in the working tree with no warning, and a subsequent
  `git add -A` would commit it.
- The one mitigating factor: on the next real push the gate itself would catch the now-stranded test
  and refuse — the invariant protects against its own test file's leak. But `--dry-run` and
  `--inventory` would report a wrong ship set in the meantime, with no indication why.

Filed as **E28_S18_T06**. Note this is a defect in the **test file's fixture handling**, not in
`mirror.sh`, and it is *not* the cause of the three named failures — those reproduce from a pristine
`.publicignore`, as section 2's direct gate run (done before any interruption occurred) shows.
- **Timing / machine load:** ruled out as a *cause of failure*. Load changes how long the run takes, not
  whether an unrelated test file is red. It is entirely a runtime story (section 6), not a pass/fail one.

---

## 5. Isolation versus suite order

Each named case was run alone via `bats -f "<name>"`, then the whole file was run in suite order, then
the three named cases were run together in one invocation. All on an otherwise idle machine, all against
a pristine `.publicignore`.

| # | Case | Isolation | Full file, suite order | Grouped 3-case run |
|---|---|---|---|---|
| 1 | real push is refused when a shipping test's subject is blocklisted | — | **pass** | — |
| 2 | refusal names the offending stranded test file | — | **pass** | — |
| 3 | refusal leaves the bare remote with zero refs | — | **pass** | — |
| 4 | refusal leaves no committed marker in the scratch worktree | — | **pass** | — |
| **5** | **real push proceeds normally when the shipping suite is clean** | **FAIL** (540 s) | **FAIL** | **FAIL** |
| **6** | **a clean push actually lands a commit on the bare remote** | **FAIL** (542 s) | **FAIL** | **FAIL** |
| **7** | **a deliberately blocklisted test file causes no failure, only its ship-list absence** | **FAIL** (548 s) | not reached | **FAIL** |

Wall clock: the three isolation runs took **540 s / 542 s / 548 s**; the grouped run took **1634 s** for
three cases (**544.7 s** per case). Every one of these is a single gate pass, and all six measurements
agree with the independently-taken 549 s figure from section 6 to within 1.6%.

**Verdict: isolation and suite order agree on every case measured, without exception.** No case changes
outcome based on how it is invoked. This is the empirical test of the mechanism in section 4, and it
comes out exactly as that mechanism predicts: the predicate is "is any shipping test red right now",
which no amount of ordering, grouping or isolation can influence. Had any of the three passed in
isolation while failing in suite order (or vice versa), the mechanism would have been refuted and would
have had to be rewritten around ordering or leaked state instead. It was not.

**Is the grouped run an adequate substitute for case 7's full-file cell? Yes — stated explicitly so no
reader has to wonder whether it was simply skipped.**

The only hypothesis that cell could test is *"does case 7 behave differently when it runs alongside
other cases than when it runs alone?"* The grouped run answers exactly that question: case 7 ran
**third**, in the same `bats` process, after two other gate-running cases, sharing all file-level state
with them — and failed identically to its isolated run. What the grouped run does not reproduce is
running after cases 1–4 specifically, i.e. after four cases that each mutate `.publicignore` via
`strand_permission_level_test()` and restore it in `teardown()`.

Three reasons that residual gap cannot change the conclusion:

1. **Cross-case influence is architecturally impossible here.** `setup()` creates a brand-new bare
   remote and a fresh scratch worktree under `$BATS_TEST_TMPDIR` for every single case, and the gate
   materialises a fresh temp tree per invocation. There is no shared mutable state between cases except
   `.publicignore`, which is snapshotted and restored per case.
2. **That one shared file was directly verified clean.** After the grouped run completed normally,
   `git diff main -- .publicignore` was empty in both the worktree and the primary checkout, with the
   blocklist line intact at line 272 — so the restore path cases 1–4 depend on demonstrably works.
3. **Mode has no demonstrated effect on anything.** Cases 5 and 6 were measured in all three modes and
   produced the same result in all three. Case 7 was measured in two and produced the same result in
   both.

**What would actually close it**, for the record: a full-file run that reaches case 7. That needs either
E28_S18_T04's early exit (which would cut the run to minutes) or a budget above ~64 minutes. The
observed non-completion rate for the full file is **2 of 2 attempts**, so this is not a cheap datum to
obtain and it would test a hypothesis already refuted twice over. I judged it not worth a third hour;
a reader who disagrees now knows precisely what is missing and what it would cost.

**Caveat on the "not reached" cell.** The full-file run was terminated externally **twice** by the
harness manager, at ~55–60 minutes each time, before reaching case 7. The first attempt yielded cases
1–3, the second cases 1–6; bats writes TAP incrementally, so completed cases survived both kills. Case
7's suite-order cell is therefore filled from the grouped run, where it ran third in a multi-case
invocation rather than alone — not literally full-file order. Given that cases 5 and 6 produce the same
result in all three modes, and that case 7 fails in both the modes it was measured in, the gap is not
material to the conclusion; it is flagged rather than papered over. It is also, independently, a
data point about this file: **a test file that cannot be run to completion inside a one-hour budget is
not a usable regression suite**, which is the substance of E28_S18_T04.

Note also that these runs are the reason the fixture leak in section 4 was discovered — two
interrupted runs, two leaked `.publicignore` mutations. After the grouped run completed *normally*,
`git diff main -- .publicignore` was empty, confirming `teardown()` restores correctly on a clean
pass/fail and that the leak is specific to interruption.

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

### The >22-minute observation: reproduced, and comfortably exceeded

Six independent single-pass measurements (549 s direct, 540/542/548 s isolation, 1634 s for three
grouped cases = 544.7 s each) agree to within 1.6%. Taking 545 s as the per-pass cost:

| Quantity | Value |
|---|---|
| Gate passes per full run of the file | 7 |
| Predicted full-file wall clock | **7 x 545 s = 3815 s ≈ 64 min** |
| Observed | full-file run terminated externally **twice**, at ~55–60 min, having reached cases 1–3 and 1–6 respectively |

So the ">22 minutes" is not merely reproduced — it is exceeded by roughly 3x, and the file did not
complete at all within the one-hour budget available to it on either attempt. Two independent runs
failing to finish is itself the strongest available statement of the problem: **this file is currently
not runnable to completion in a normal working session.** That is what makes the "known baseline
failures" habit so predictable — the cheapest way to learn the suite's verdict was to not run it.

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

It executes **zero** tests. It does at least exit **1**, so it **fails closed**: the gate keys on bats'
real exit status, so a `-j` that ran nothing would make the gate *refuse* the push rather than falsely
clear it. A naive `-j` adoption is therefore loud — a confusing universal refusal, plus a new hard
dependency (GNU parallel) in a pre-push gate.

The real hazard is one step further on. The failure presents as `Executed 0 instead of expected 17
tests` next to a non-zero exit, so the tempting cleanup is to treat that warning as benign and make the
invocation tolerant of it. **That converts a loud refusal into a silent zero-test pass** — the gate
reporting `OK` having verified nothing — which is exactly the false-clear mode the function's header
comment already warns about from the `tail -40` incident. `bats -j` is thus a correctness trap only if
someone "fixes" its exit code, but that fix is the natural next move for anyone who hits it. If `-j` is
ever adopted, assert a non-zero executed-test count and never suppress a non-zero bats exit.

An early exit (E28_S18_T04) is the cheaper and safer win, and needs no new dependency.

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
3. **E28_S18_T05 — make the real-push cases emit attribution on failure.** The highest-leverage of the
   three filed items: today a failure prints only `[ "$status" -eq 0 ]' failed` after nine minutes,
   while the line naming the culprit sits unprinted in `$output`. This is why the diagnosis took nine
   days instead of thirty seconds. The same item carries the *secondary*, judgment-call question of
   whether to make cases 5–7 hermetic (they currently depend on all 83 shipping files being green, so
   unrelated breakage is mis-attributed to this file forever) — flagged there rather than decided
   here, because the options trade away coverage.
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
