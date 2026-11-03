# Narrowing un-folds the npm alias: the narrowed selection runs twice, and in one variant the exclusion is defeated

**Status: RESOLVED — the user chose C + B, and both are implemented.** Sections 1-5 are the investigation as it was
written before any code changed and are left untouched; section 7 records what was built and how it was verified.

**Date:** 2026-11-01 (UTC)
**Agent:** developer
**Session:** `do-20261101T150733Z`
**Origin:** finding 3 of `project/rapports/problems/E72_S07_T02-glob-defs-fixture-gap-and-two-gate-defects.md`
**Related:** `E72_S07_T02`, `E72_S07_T01`'s decision document `project/documentation/scope-gate-fix-decision.md` (Q2, lines 100-116)

---

## 1. Verdict: the tester's reproduction is CONFIRMED

Confirmed, and the investigation found **a second failure mode the rapport did not describe**, which is worse than
the one it did: in one configuration the npm suite does not merely duplicate the run, it **executes the very test
files the exclusion just removed**, while the gate's output still reports them as excluded.

The rapport's claim that the scoped path is also affected could not be reproduced and is **refuted**: the scoped
path is immune, for a structural reason given in section 4.

---

## 2. Root cause, exactly

Two scripts key the same suite on two different strings.

**`build-catalog.sh:174-180`** — the fold key. For every suite the key is its `command`, *except* that for a suite
with `ecosystem == "npm"` and an id beginning `npm:` the key is the **body of that npm script read from
`package.json`**:

```jq
| ($all | map(select(.command != "")
    | . + {key: (
        if .ecosystem == "npm" and (.id | startswith("npm:"))
        then (($scripts[.id | ltrimstr("npm:")] // "") as $b
              | if ($b | type) == "string" and $b != "" then $b else .command end)
        else .command end)})) as $run
```

That rule is deliberate and load-bearing. Here `scripts.test` is `bats tests/*.bats`, byte-equal to `bats:tests`'s
discovered command, so `npm:test`, `bats:tests` and `config:bats:integration` share a key and fold into **one**
runnable entry. `build-catalog.sh`'s own header states the stake: *"without this a run-all would run the hour-long
bats suite twice."*

**`narrow-suites.sh:390-397`** — the npm-twin rule, added by `E72_S07_T02`. It knows about the fold and tries to
preserve it: when an npm suite's script body is byte-equal to a bats suite's **pre-rewrite** command, it rewrites
that npm suite's `command` to the same narrowed string.

```jq
elif ($s.ecosystem == "npm")
     and ($npmBody | has($s.id))
     and ($byOrigCommand | has($npmBody[$s.id]))
  then (.command = $byOrigCommand[$npmBody[$s.id]])
```

**The rule cannot work as written.** It rewrites `command`, but the npm suite's fold key is not its `command` — it
is the `package.json` script body, which narrowing neither rewrites nor could rewrite (rewriting a project's
`package.json` from a test gate is not on the table). So:

| | fold key before narrowing | fold key after narrowing |
|---|---|---|
| `bats:tests` | `bats tests/*.bats` | `bats 'tests/a.bats' 'tests/b.bats'` *(narrowed)* |
| `config:bats:integration` | `bats tests/*.bats` | `bats 'tests/a.bats' 'tests/b.bats'` *(narrowed)* |
| `npm:test` | `bats tests/*.bats` *(package.json body)* | `bats tests/*.bats` *(package.json body — **unchanged**)* |

Before narrowing all three keys agree and fold. After narrowing the two bats keys move and the npm key does not,
so the group splits in two. The npm-twin rule's only actual effect is to decide **what the duplicate runs**, not
whether it exists — which is exactly the difference between the two variants in section 3.

`narrow-suites.sh`'s report compounds the confusion: it lists `npm:test` under `not_narrowable` in **both**
variants, including the one where its command *was* rewritten. The report tells a reader the npm suite was left
alone when it was not.

---

## 3. Reproduction — exactly how it was tested

**Method.** Read-only, against throwaway fixture roots under `/tmp`; the repository's own gate was never run and
no test suite was executed (the developer never runs tests). Each fixture is a complete miniature project: the real
`skills/j-test/scripts/*.sh` plus `scripts/lib/glob-defs.jq`, `scripts/resolve-root.sh`,
`templates/permission-levels/level-2-guarded.json`, a `package.json` with a `scripts.test`, three `tests/*.bats`
files one of which carries `# jenga:requires-baseline-permissions:`, and its own `git init` + initial commit. Two
such trees were built, identical except for `.claude/settings.json`:

- **`on`** — `.claude/settings.json` and `.agents/settings.json` both copied from `level-2-guarded.json`, so
  `baseline-permissions.sh check` exits 0 (**satisfied**, no exclusion).
- **`off`** — `.claude/settings.json` copied from `level-5-unrestricted.json`, so `check` exits 1
  (**unsatisfied**, exclusion active).

The discovery document was handed over as a literal file (no real discovery ran) with three suites:
`bats:tests` (`bats tests/*.bats`, `paths: ["tests/*.bats"]`), `config:bats:integration` (same command and paths)
and `npm:test` (`ecosystem: "npm"`, `command: "npm test"`, `paths: []` — what `discover-tests.sh:311` always
produces for an npm suite). Each tree was then run through its own
`narrow-suites.sh --root <tree> --suites <discovery> --report <report>` and the result piped into
`build-catalog.sh --root <tree> --discovery-file <narrowed>`, which is the gate's own FULL-path sequence
(`scope-test-gate.sh:47`).

### Variant 1 — `scripts.test` byte-equal to the bats command (this repository today): DOUBLE EXECUTION

`package.json` → `{"scripts":{"test":"bats tests/*.bats"}}`, which is what this repository actually has.

```
=== on-baseline tree ===
precondition: SATISFIED
narrow report: {"precondition":"satisfied","excluded":[],"narrowed":[],"not_narrowable":["npm:test"]}
catalog: runnable entries: 1
  n=1 npm:test  also=[bats:tests,config:bats:integration]   cmd= npm test

=== off-baseline tree ===
precondition: UNSATISFIED (exit 1)
narrow report: {"precondition":"unsatisfied","excluded":["tests/marked-mirror.bats"],
                "narrowed":[{"id":"bats:tests","available":3,"selected":2},
                            {"id":"config:bats:integration","available":3,"selected":2}],
                "not_narrowable":["npm:test"]}
catalog: runnable entries: 2
  n=1 bats:tests  also=[config:bats:integration]   cmd= bats 'tests/plain-a.bats' 'tests/plain-b.bats'
  n=2 npm:test    also=[]                          cmd= bats 'tests/plain-a.bats' 'tests/plain-b.bats'
```

Two runnable entries, **byte-identical commands**, `also=` empty on the second. `run-suites.sh` executes each
selected `runnable[]` entry by its number and never compares commands, so a `full` policy — which selects every
entry — runs the whole narrowed selection twice. This reproduces the tester's measurement exactly.

### Variant 2 — `scripts.test` NOT byte-equal: THE EXCLUSION IS DEFEATED (new; not in the rapport)

Same `off` tree, `package.json` changed to `{"scripts":{"test":"bats --tap tests/*.bats"}}` — enough to make the
body differ from `bats:tests`'s command, so `narrow-suites.sh`'s twin rule declines to rewrite it.

```
narrow report: {"precondition":"unsatisfied","excluded":["tests/marked-mirror.bats"], ...}
narrowed commands:
   bats:tests:               bats 'tests/plain-a.bats' 'tests/plain-b.bats'
   config:bats:integration:  bats 'tests/plain-a.bats' 'tests/plain-b.bats'
   npm:test:                 npm test          <- untouched
catalog: runnable entries: 2
  n=1 bats:tests  also=[config:bats:integration]   cmd= bats 'tests/plain-a.bats' 'tests/plain-b.bats'
  n=2 npm:test    also=[]                          cmd= npm test
```

Entry 2 still runs `npm test`, which expands to `bats --tap tests/*.bats` — **the whole `tests/` directory,
including `tests/marked-mirror.bats`, the file the exclusion removed**. Meanwhile the gate's own output and its
`excluded_test_files` key both report that file as excluded and not verified.

This is strictly worse than variant 1. It is not a runtime regression, it is a **correctness** one, and it breaks
`E72_S07`'s central invariant from the direction the story did not guard: not "a skip read as a pass", but "a file
the gate says it skipped was in fact executed, and its failure will be attributed to a suite the reader was told
had been narrowed". Every excluded suite is excluded precisely because it *cannot* pass off-baseline, so the run
does not merely waste time — it fails, for the reason the exclusion exists to avoid.

This repository is on variant 1 today. Variant 2 is reachable by any consumer project — Jenga ships through npm —
whose `scripts.test` is anything other than a byte-for-byte copy of its discovered bats command: `npm run test:all`,
`bats --tap tests/*.bats`, `bats -r tests`, or a `scripts/test.sh` wrapper all land there.

---

## 4. Blast radius

### Conditions, precisely

All four must hold simultaneously:

1. The run is on the **FULL path** — `test_run_epic: full`, `test_run_story: full`, `j.test` answered blank/`all`,
   or a scoped policy that fell back to the full catalog. (The default policies are none / scoped / full, so the
   **epic** gate is full by default.)
2. The precondition is **unsatisfied** — `baseline-permissions.sh check` exits 1, i.e. `.claude/settings.json` or
   `.agents/settings.json` diverges from `level-2-guarded.json` on `permissions.deny` / `autoMode.allow`. In
   practice: the session is at permission level 3, 4 or 5.
3. At least one **marked** file is in a narrowable suite's candidate set, so an exclusion actually fires. Today the
   marked files are `tests/mirror-permission-level-invariant.bats`, `tests/mirror-staging-branch-push.bats` and
   `tests/mirror-test-subject-invariant.bats`.
4. The discovery contains an **npm suite** (`npm:<key>`) at all.

When the precondition is satisfied, `narrow-suites.sh`'s identity property holds: nothing is excluded, no command
is rewritten, stdout is the input discovery unchanged, and the fold is exactly as it always was (measured above as
`runnable entries: 1`). So the defect is **latent on this tree right now** only because the session sits at
level 2 — not because it is rare.

### The scoped path is NOT affected (the rapport's claim here is refuted)

`scope-test-gate.sh:772-776` filters the discovery down to `.mapped_suites` **before** calling `narrow`. An npm
suite can never be in `mapped_suites`: `discover-tests.sh:311` adds an npm suite with no `paths` argument, so its
`paths` is always `[]`, and `map-scope.sh` builds `mapped_suites` from the test-file → suite resolution table
driven by those `paths` globs. With no globs, no test file ever resolves to the npm suite. Verified by replaying
the gate's real sequence — filter to the mapped suites first, then narrow, then build the catalog — on both trees:
`runnable entries: 1` in each case, on-baseline and off.

An earlier run that narrowed *without* the filter did produce two entries, which is how the rapport's broader claim
most likely arose; it is an artefact of calling `narrow-suites.sh` directly rather than how the gate calls it.

### Cost

- **Variant 1 (this repository).** A full gate off-baseline runs `264 − 3 = 261` test files twice. The documented
  figure for one pass of the shipping bats suite is **"the hour-long bats suite"**
  (`build-catalog.sh` header, quoted in `scope-gate-fix-decision.md:109`) and *"the suite takes over an hour"*
  (`project/documentation/test-runner.md:736`), so the overhead is **roughly one extra hour per gated epic
  close**, plus a second `shellcheck:all`-free pass of everything else in the selection. Exact wall-clock was not
  measured: doing so would mean running the suite, which is the tester's job, and on this machine wall time is
  known to be unreliable (`project/rapports/problems/E77_S06_T11-wall-clock-timings-inflated-by-first-exec-latency.md`).
- **Variant 2 (consumer projects).** The cost is not time, it is a **wrong verdict**: the gate runs the excluded
  mirror suites it promised not to run, they fail for the baseline reason, and the epic gate blocks — which is
  precisely the 2026-10-22 unpassable-gate condition `E72_S07` exists to remove.
- **`j.test` interactive.** Off-baseline the numbered picker shows two entries that do the same thing, the second
  without the `[also covers: ...]` annotation that would hint at it. Duplication is visible but unlabelled.

### Why this matters beyond the bug

`E72_S07_T01`'s decision document cited this exact hazard as *"the single strongest argument against the catalog
split"* (Q2, line 103) and rejected per-file suites over it: *"every test twice, and the one thing
`build-catalog.sh` was explicitly written to prevent"* (line 113). `T02` then rewrote commands in place instead of
splitting the catalog, specifically to avoid that outcome — and reintroduced it through a different route, because
rewriting `command` does not move the npm suite's fold key. The decision document's reasoning was right; the
mitigation aimed at the wrong string.

---

## 5. Options

Each entry states what it fixes, what it does not, and its cost. None has been implemented.

### Option A — `build-catalog.sh` keys an npm suite on its command once that command has been rewritten

Teach the fold that a rewritten npm suite is no longer opaque. Requires a signal from `narrow-suites.sh`, e.g. an
additive `"command_rewritten": true` key on the suite (the discovery contract is extended by appending keys, which
`discover-tests.sh:43` already declares as its versioning rule), and a `build-catalog.sh` key rule of "body unless
`command_rewritten`".

- **Fixes:** variant 1 — the two keys agree again and the three suites re-fold to one entry.
- **Does not fix:** variant 2. There the command was never rewritten, so nothing changes and the exclusion is still
  defeated.
- **Cost:** two scripts change, including the deduplicator whose header warns against being touched. A new
  cross-script contract key. `build-catalog.sh` has its own suites (`tests/test-catalog-*.bats`) that would need
  cases for both key rules.

### Option B — `narrow-suites.sh` marks an un-narrowable npm twin NOT RUNNABLE whenever narrowing actually changed something

Leave the npm suite's command alone and set it to `""`. `discover-tests.sh`'s contract already defines an empty
command as not runnable, and `build-catalog.sh` already moves such a suite to `not_runnable` — never numbered,
never executed, never counted as a pass or a fail. This is the same mechanism `T02` already uses for an *emptied*
suite, so it introduces no new concept. The report would name it, so it is not a silent drop.

- **Fixes:** **both** variants. An opaque suite that cannot be narrowed is never run while a narrowing is in force,
  so it can neither duplicate the selection nor resurrect an excluded file.
- **Does not fix:** nothing outstanding, but note the consequence below.
- **Cost:** the npm entry disappears from the picker while narrowing is active, so a reader loses the `npm test`
  label (its coverage is not lost — the bats twin runs the same files). And if an npm suite is the **only** suite a
  project has, an active exclusion empties the catalog and the gate exits 3, "nothing was verified". That is
  arguably the correct answer — an opaque `npm test` genuinely cannot honour a file-level exclusion — but it turns
  a passing gate into a blocked one for such a project, so it is a real decision and not a free win.

### Option C — `build-catalog.sh` adds a second fold pass on the final command

Keep the body-keyed pass exactly as it is, then group the surviving entries once more by their literal `command`
and fold identical ones, preferring the npm survivor as the existing rule already does. A small, local jq change
confined to one script.

- **Fixes:** variant 1, and it does so without any new cross-script contract — two entries with byte-identical
  commands can never both be numbered again, whatever produced them.
- **Does not fix:** variant 2 (`npm test` and the narrowed `bats ...` are different strings, so there is nothing to
  fold).
- **Cost:** lowest of the four. One script, no new keys, no behaviour change when no two commands coincide.

### Option D — do not narrow at all when an un-narrowable npm twin is present

On the full path, if the discovery holds an npm suite whose body matches a narrowable suite, skip the narrowing and
report that the exclusion could not be applied (exit 3, "nothing was verified", per the story's own invariant).

- **Fixes:** both variants, by declining to act.
- **Does not fix:** it gives up the story's deliverable in exactly the scenario the story targets — an off-baseline
  epic gate — so the gate stays unpassable there.
- **Cost:** the story's benefit is lost on the full path. Cheapest to reason about, most expensive in capability.

### Combinations

**C + B** is the only pairing that covers both variants with each change staying inside one script: C makes any two
identical commands impossible to double-run regardless of origin, and B stops an opaque npm suite from running
alongside a narrowing it cannot honour. **A** is the option that keeps the npm entry visible in the picker, at the
price of a new cross-script contract and still leaving variant 2 open.

---

## 6. What was explicitly NOT decided in the investigation

Which option to take. This is an architectural change to the deduplicator that `E72_S07_T01` already weighed and
ruled on once, and the orchestrator reserved it to the user. At the time this section was written,
`build-catalog.sh` and `narrow-suites.sh`'s npm-twin rule were unchanged on this branch.

Whatever is chosen, `tests/scope-gate-narrowing.bats` case 10 — `T02`'s own, then unexecuted — must go green,
and variant 2 needs a case of its own: there is no coverage anywhere today for an npm script body that differs from
the bats command, which is why the worse of the two failure modes was never caught.

---

## 7. Decision and implementation (2026-11-01, fix round 2)

The user chose **C + B**, on this document's own recommendation: it is the only pairing that covers both variants with
each change confined to a single script, and it adds no new cross-script contract key.

### C — `build-catalog.sh` dedup **rule 5**: a second fold pass on the final command

The survivors of rules 1-3 are grouped once more by their literal `command` and folded again under the *same*
survivor rule (first `npm`, else first non-`config`, else first `config`), with the two `also` lists merged,
deduplicated by id and re-sorted. Documented as rule 5 in the script's own DEDUPLICATION contract.

- Fixes **variant 1**: the narrowed bats command and the twin-rewritten npm command are byte-identical, so they fold
  back to one entry. The npm entry survives, so the picker keeps the `npm test` label and its
  `[also covers: ...]` annotation.
- **Identity when nothing coincides.** Verified by byte-comparing the catalog of the pre-change script against the
  post-change one over all five committed fixtures (`already-clean`, `dup-command`, `empty-command`, `zero-suites`,
  `npm-alias`): identical in every case, `--render` output included.

### B — `narrow-suites.sh` disables an npm suite that cannot honour an exclusion

When **at least one marked file was actually dropped**, an npm suite whose command the twin rule could not rewrite has
its `command` set to `""` — the mechanism an emptied suite already uses, which `build-catalog.sh` routes to
`not_runnable`: never numbered, never executed, never counted as a pass or a fail. The report names it under a new
additive `disabled` key with the reason, and `scope-test-gate.sh` prints it on stdout
(`not run (NOT verified) because the suite cannot honour the exclusion:`) and in `--json` under `disabled_suites`.

- Fixes **variant 2**: `npm test` can no longer expand to the whole test directory and execute the very file the
  report says was excluded.
- **Keyed on an exclusion firing, not on narrowing.** A pure scoped narrowing claims nothing about files it did not
  exclude, so an opaque suite that runs *more* than the narrowed set is wasteful, not wrong. Keying it on narrowing
  instead would drop the project's own entry point from every scoped run for no correctness gain. This is narrower
  than option B's original wording ("whenever narrowing actually changed something") and deliberately so.
- **Scoped path consequence.** A mapped selection made only of such a suite now yields an empty catalog. The scoped
  path previously fell through to the full catalog there, which would have printed "no suite maps to the changed
  files" (false) and run everything the exclusion had just removed; it now exits 3, exactly as the all-emptied branch
  beside it already did.

### Why C alone and B alone are both required

Measured on throwaway `/tmp` fixture trees (never the repository's own gate, and no suite was run):

| | C only (new narrow + pre-change catalog) | B only (pre-change narrow + new catalog) | C + B |
|---|---|---|---|
| variant 1 | **2 entries, byte-identical commands** | 1 entry | 1 entry |
| variant 2 | npm disabled, 1 entry | **`npm test` runnable — exclusion defeated** | npm disabled, 1 entry |

### Coverage added

- `tests/scope-gate-narrowing.bats` — `variant 1: the narrowed selection is numbered ONCE, not twice` (red if rule 5
  is removed); `variant 2: an npm twin that cannot be narrowed is disabled, never left running the glob` (red if B is
  removed); `nothing is disabled when no exclusion fired`; and a case pinning the gate's refusal to fall back.
  `disabled_suites` added to the enumerated `--json` key list.
- `tests/j-test-build-catalog.bats` — four cases for rule 5 on its own terms, including the no-two-identical-commands
  invariant stated without reference to npm, and the identity property.

Variant 2 had **no coverage anywhere** before this round, which is why the worse failure mode went unnoticed in
`T02`. `tests/scope-gate-narrowing.bats` case 10 — finding 3's own case, red before this round — goes green under the
fix: verified by replicating its fixture read-only (`npm:test` and `bats:tests` commands equal, catalog
`runnable | length == 1`).

### What was deliberately NOT changed

`not_narrowable` still lists an npm twin even when the twin rule gave it a narrowed command, which section 2 called
out as confusing. Changing it is a report contract change outside the five items of this round; instead its documented
meaning is sharpened ("ids whose OWN command is not a bare `bats` invocation") and it is cross-referenced to
`disabled`. Worth revisiting if the report is ever revised for another reason.
