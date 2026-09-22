# Public-Mirror Content Parity

How to verify that the `skills/j-<name>/` twins the public mirror ships carry the same
content as their `skills/<name>/` sources — and why a check run against the private
repo alone cannot tell you that.

Established by `E50_S19` (2026-09-10). Companion to `docs/skill-authoring.md`'s
"The Canonical Naming Contract".

> **Status: the gate this document was built around is retired (2026-09-20, `E42_S07_T01`).** The
> twin-parity gate — its `npm run` entry point, the twin-divergence audit script beneath it, and both
> of their bats suites — has been deleted, because `E50_S15` removed every bare-name skill directory
> and with it every pair the audit existed to compare. The verification procedure below is kept as a
> record of what was checked and what each check proved; runs A, C, and D are no longer runnable as
> written. Full account in "Retired: the twin-parity gate" below. Everything else in this document —
> the failure mode, the "a test may never outlive its subject" rule, and the `.publicignore` policy
> sections — is unaffected and still current.

---

## The failure this exists to catch

`.publicignore` blocklists the bare-name skill directories, so the public mirror
(`https://github.com/samwelmunga/jenga-npm`) ships **only** the `j-<name>` twins. A fix
that lands in a bare directory and never reaches its twin is therefore invisible to
every downstream consumer — while looking completely healthy in this repo, because here
the bare directory still exists and any bare path still resolves.

The two-line demonstration, which is the whole problem in miniature:

```console
$ bash scripts/check-publicignore-match.sh \
    skills/j-publish/scripts/npm_stage_pipeline.sh \
    skills/publish/scripts/npm_stage_pipeline.sh
PUBLIC	skills/j-publish/scripts/npm_stage_pipeline.sh
BLOCKED	skills/publish/scripts/npm_stage_pipeline.sh
```

The file a contributor edits is the one that does not ship.

**Worked example.** `E22_S09_T07` added `parse_stage_id_from_text()` and a CI-log
stage-id capture block to `skills/publish/` at commit `f3daaa8` on 2026-09-09. Neither
reached `skills/j-publish/`. On 2026-09-10 a public-mirror consumer reported
"`E22_S09_T07` has not been addressed", while the board read `Merged`. Both were
correct. Back-filled by `E50_S19_T02`.

---

## The verification procedure

**Historical, as of 2026-09-20.** Runs A, C, and D invoked the twin-divergence audit script, which
was deleted when the gate was retired — so they cannot be run as written. They are kept because the
*questions* they asked, and the trap run C exposes, are the substance of this document and outlive
the tool that answered them. The exact commands, flags, and real output are in git history
(`E50_S19` built them; `E42_S07_T01`'s parent commit is the last state in which they ran). Run B
depends on no deleted tooling and still works today.

Four runs. Each answered a different question, and the ordering mattered — run A alone
is what previously looked sufficient and was not.

### A. Private repo — is every twin in sync with its source?

The audit walked `./skills`, paired each `skills/j-<name>/` twin with its `skills/<name>/` bare
source, and reported every difference between the two that the generator's own transforms did not
explain. It was always invoked with a `--min-pairs 40` floor, asserting it had actually found all 40
pairs rather than quietly finding none. That floor was not decoration — see run C.

**Wired 2026-09-19 (`E50_S19_T04`), retired 2026-09-20 (`E42_S07_T01`).** It ran as an `npm run`
entry point and was deliberately never folded into `npm test`. Both decisions, and the retirement,
are recorded in "Retired: the twin-parity gate" below.

> **Known caveat as it stood at `E50_S19_T04` — retained for the record, and part of why retirement
> beat repair.** A real run of run A exited 1, not 0. That was **not** a content-parity defect:
> `E50_S11`/`E50_S12`/`E50_S14` (merged the same day, concurrently with that fix) settled the naming
> contract in the opposite direction the audit still assumed — `skills/j-<name>/` became the
> canonically hand-edited source and `skills/<name>/` a frozen, soon-to-be-deleted (`E50_S15`) stub —
> and the script's classification engine was never updated to match. The 5 `__pycache__`/`*.pyc`
> false positives `E50_S19_T04` fixed were gone; ~61 `SKILL_DRIFT`/`CONTENT_DRIFT` findings remained,
> all attributable to the same stale-model cause, not to any actual content at risk of being lost.
> Full account and evidence in
> `project/rapports/problems/E50_S19_T04-audit-classification-stale-post-contract-flip.md`.

### B. Mirror-shaped tree — reproduce the condition the defect appears under

Build a tree with the blocklist applied, using the same rsync semantics as
`skills/j-mirror-public/scripts/mirror.sh`'s sync step. This needs no network and does
not touch the public repo:

```console
$ MIRROR=$(mktemp -d)
$ rsync -a --delete --delete-excluded --filter='protect .git/' \
    --exclude-from=.publicignore --exclude=".git" ./ "$MIRROR/"
$ ls "$MIRROR/skills" | grep -v '^j-'
index
jenga
jenga-permission-level
```

Only the three permanent exceptions survive under a bare name; `skills/publish/` is
gone. That is the downstream condition. Now confirm the reported regression is actually
reachable there:

```console
$ grep -c 'parse_stage_id_from_text' "$MIRROR/skills/j-publish/scripts/npm_stage_pipeline.sh"
3
$ grep -c "Stage-id capture reads the CI run's own log" "$MIRROR/skills/j-publish/adapters/npm-ci.md"
1
```

### C. The trap — why a clean audit of the mirror tree means nothing

Pointed at `$MIRROR`, the audit reported **exit 0 over zero pairs**: `audited 0 twinned pair(s)`,
followed by `no unexpected divergence`.

**Exit 0, and worthless.** The audit compared each twin against its bare source; in a
mirror-shaped tree the sources have been stripped, so there were no pairs, nothing was
compared, and success was reported. Anyone reading only the exit code would take this as
proof of parity.

The `--min-pairs` floor existed to make that failure loud. The same run with `--min-pairs 1` exited
2 instead: `only 0 twinned pair(s) were audited, but --min-pairs 1 was required. A clean result over
too small a population is not a pass — check the tree actually contains the pairs you expected.`

**This is the lesson that outlives the tool.** A parity check whose population can silently fall to
zero reports success most confidently exactly when it is measuring nothing, so any such check needs a
floor asserting the population it expected. It is also, read forward, precisely how this gate ended:
`E50_S15` took the real population to zero permanently, the floor did its job and refused to pass,
and there was nothing left for a passing run to mean. Any future audit of this shape — `E61_S04`'s
master-vs-mirror drift audit is the live candidate — should carry the same floor, and should be
retired the same way if its population ever goes to zero for good.

### D. The real question — do the twins that *ship* carry the sources' content?

Overlay the private repo's bare sources onto the twins that survived the blocklist, and
audit that. This was the only one of the four runs that was both non-vacuous and scoped
to what consumers actually receive: copy `$MIRROR/skills/` into a fresh `$HYBRID`, then for each
`j-<name>` twin there, copy the private `skills/<name>/` source back in beside it, and run the audit
over `$HYBRID` with a `--min-pairs 34` floor. It reported `audited 34 twinned pair(s)` and
`no unexpected divergence`, exit 0.

34, not 40: six skills are blocklisted in **both** forms and ship in neither
(`mirror-public`, `self-sync`, `train`, `strategy`, `convert`, `route`). A drift in
those twins is real but has no downstream consumer, so it is out of this run's
population by construction.

---

## Rule: a test may never outlive its subject in the mirror

**Stated by the user, 2026-09-10, after `E50_S13`:** *if a test utilizes skills not available in
public then that test should either not be shipped, or it should somehow be conditioned not to run in
the public repo.*

This is the general form of a defect this repo has now hit twice. `load-playbooks.sh` requires every
playbook step's `skills/<dir>/SKILL.md` to exist; `.publicignore` strips private skills; a test
asserting the playbook loads therefore passes privately and fails in the mirror, where it is
discovered by a stage-deploy gate rather than by anyone running tests. `E50_S07_T11` hit the same
shape earlier with `mcp/router/` and `skills/mirror-public/`.

**Two sanctioned resolutions — pick one, never neither:**

1. **Don't ship the test.** Blocklist it alongside its subject in `.publicignore`, with a comment
   naming the subject and the dependency. This is the established form; see the
   `Private-tooling tests (E50_S07_T11)` and `Private-tooling playbooks and their tests (E50_S13)`
   blocks in that file.
2. **Ship it, conditioned to skip.** The test detects its subject's absence at runtime and skips
   rather than fails. Preferred when the test has assertions that remain meaningful publicly and only
   *some* cases depend on the private subject — blocklisting the whole file would lose the public
   coverage too.

Choosing neither is what produces a mirror-only failure. Note the two options differ in what the
public suite reports: option 1 makes the test invisible, option 2 makes it visibly skipped. Option 2
is the more honest signal and should be preferred where the test can be split; option 1 is correct
when the entire file depends on a private subject, as both current cases do.

**Which skills are never public.** Six are blocklisted in *both* their bare and `j-` form, so they
ship in neither and no naming change can make them available: `convert`, `mirror-public`, `route`,
`self-sync`, `strategy`, `train`. Plus `mcp/router/`. A test touching any of these must take option 1
or 2. The other 34 blocklisted skills ship under their `j-<name>` twin and are publicly available —
referencing *those* by twin name is fine.

**Audit command.** For each `tests/*.bats` and `tests/helpers/*` that
`scripts/check-publicignore-match.sh` classifies `PUBLIC`, grep for references to the seven
never-public subjects above. As of 2026-09-10 this reports no violations. This check is **manual and
unwired** — the same weakness `E50_S19`'s rapport recorded about the `--min-pairs` floor. It was once
the natural candidate to fold into the twin-parity gate; with that gate retired (see below) it has no
host, and wiring it is still open.

## Permanently private *by policy*: `brainstorm-to-mirror`

Every other exclusion recorded in this document is **mechanical**: a thing is out of the mirror
because shipping it would break something — a test whose subject is private (above), a twin whose
source never ships, a skill that depends on private tooling. Fix the dependency and the exclusion
could in principle go away.

`skills/jenga/playbooks/brainstorm-to-mirror.json` is **not** in that category, and should not be
read alongside the lists above as though it were. It is excluded by a standing product decision
(user, 2026-09-17, `E53_S10`):

> **No public playbook may contain a publishing or mirroring step; public build chains terminate at
> `j-commit`.**

The rationale is in `docs/skill-authoring.md`'s "Public Playbooks Terminate at `j-commit`" section:
most users would not want a playbook that publishes or pushes to a public destination on their
behalf, so publishing stays an explicit, separately invoked act. Consequences for this document:

- **Its three `.publicignore` entries are permanent.** Do not "fix" them. No step-name cutover,
  skill rename, or parity-audit improvement is meant to make this playbook public, and a future
  audit finding it absent from the mirror has found the intended state, not a defect.
- **It is out of the parity population by construction**, for the same reason the six
  never-public skills are out of run D's 34 pairs — no downstream consumer exists for it.
- **`understand-then-ship` was never in this category and is no longer here at all.** It was
  blocklisted only as collateral of composing `brainstorm-to-mirror`; it had no private step of its
  own. `E53_S10_T01` repointed it at `idea-to-committed`, renamed it `understand-then-commit`, and
  removed all three of its entries — it now ships.
- **Blocklist membership is not what enforces the policy.** `j-publish` ships publicly, so a
  playbook chaining it would pass `scripts/check-public-playbook-steps.sh` clean while violating the
  policy. The enforcing deny-list landed in `E28_S14_T02` — see the section below.

## Project-local playbooks are private: `project/.playbooks/` (`E28_S14`)

`skills/jenga/scripts/load-playbooks.sh` scans two playbook sources (`E53_S09_T01`): the
framework-owned BUILTIN source `skills/jenga/playbooks/`, and the project-owned PROJECT source
`project/.playbooks/`. Only the first is framework content. As of `E28_S14_T01`
(user decision 2026-09-17) the second is blocklisted in full:

```
project/.playbooks/
```

**Why.** Project-local playbooks are per-project by definition. Ours are not framework content, and
a consumer's are not ours to overwrite. Shipping our own would push private workflow tooling
downstream as though it were part of the framework, and would land in the same directory a consumer
uses for their own playbooks.

**The asymmetry this closes.** `project/.playbooks/improve-to-commit.json` was tracked in the public
mirror while being **absent from `package.json`'s `files` array**. The two delivery channels
therefore disagreed: someone cloning the public GitHub repo received the file, and npm consumers
never did. That split was unintentional — the file was neither a deliberate worked example nor
properly private. `E28_S14_T01` closes it in the private direction, so both channels now agree that
project-local playbooks do not ship. The already-present mirror copy is purged by rsync `--delete`
on the next `/j-mirror-public` run (`E28_S04`).

**This is an exclusion, not a deletion.** `improve-to-commit` is untouched on disk and still loads
in the private repo — `load-playbooks.sh` continues to list it with `source: "project"`. It simply
stops shipping.

**No test is stranded by it** (per the "a test may never outlive its subject" rule above; re-verified
at implementation time, 2026-09-19):

- `tests/load-playbooks-project-source.bats` and `tests/load-playbooks-resolve-lookup.bats` build
  every fixture under `$BATS_TEST_TMPDIR` and point the loader at it via `JENGA_PLAYBOOKS_TEST_ROOT`.
  Neither reads the real `project/.playbooks/`.
- No file under `tests/`, `scripts/` or `skills/` references `improve-to-commit` by name. Outside
  the private `project/` tree, the only mentions anywhere are the explanatory prose in this section
  and the matching comment block in `.publicignore` — inert text that records *why* the file is
  absent, depends on nothing, and strands no test. Deliberately worded this way: the original
  phrasing included `docs/`, which the very commit recording it falsified (`E28_S14_T01` rapport,
  `project/rapports/problems/E28_S14_T01-self-falsifying-no-reference-claim.md`).
- `load-playbooks.sh` treats a missing `project/.playbooks/` as a **silent no-op** — no warning, no
  error — asserted by `tests/load-playbooks-project-source.bats` Case 3. The mirror simply has no
  PROJECT playbook source.

So this exclusion needed neither of the rule's two sanctioned mitigations: there was no test to
blocklist alongside its subject and none to condition on the subject's absence.

**The guard covers the directory mechanically, not by policy.**
`scripts/check-public-playbook-steps.sh` scans `project/.playbooks/*.json` as a second source
(`E28_S14_T02`), classifying each entry through `scripts/check-publicignore-match.sh` exactly as it
classifies builtin playbooks. With this blocklist entry in place every project-local playbook
classifies BLOCKED and is counted as private/skipped — the expected steady state. The point is that
if anyone unblocks the directory later, the guard covers it automatically rather than the invariant
resting on the blocklist staying as it is. A missing `project/.playbooks/` is a no-op there too,
matching the loader.

## Retired: the twin-parity gate

**Wired 2026-09-19 (`E50_S19_T04`). Retired 2026-09-20 (`E42_S07_T01`).** Recorded here rather than
deleted silently, so the lifecycle end is as traceable as the build-out was.

### What it was, and why it existed

`E50_S19_T04` closed the gap the original rapport
(`project/rapports/problems/E50_S19-parity-gate-is-manual-only.md`, Finding 1) flagged: `--min-pairs`
was documented as "the thing to always pass when using this as a gate" but nothing actually invoked
it. An `npm run` entry point was added that ran exactly run A's command — the audit over `./skills`
with a floor of 40 pairs — making it reachable from the project's normal `npm run` surface. A
dedicated bats file covered the wiring itself and proved the gate's fault-injection correctness
against synthetic sandboxes rather than the live repo: a genuine divergence tripped it, clearing that
divergence cleared it, and a gitignored build artifact did neither.

It was deliberately **not** folded into `npm test` (`bats tests/*.bats`). Coupling the bats suite's
pass/fail to real-tree state was a design question the original rapport raised and explicitly
declined to resolve in place — "wiring this into `npm test` or CI... would make the suite depend on
real-tree state, which the suite currently avoids by design." The gate was therefore a separate,
explicitly-invoked surface rather than an implicit addition to every contributor's `npm test` run.

### Why it was retired

**Its entire input population went permanently to zero.** `E50_S15_T04` deleted every bare-name
`skills/<name>/` directory on 2026-09-19, the final step of the sole-canonical-form cutover
(`E50_S10`–`E50_S15`). The gate audited drift between a bare source and its `j-` twin; with no bare
source left anywhere in `skills/`, there is not now and never will be a pair to compare. It could
only ever report zero pairs audited and hard-fail its own 40-pair floor.

That was not a theoretical cost. It surfaced twice:

- `project/rapports/problems/E50_S15_T05-crucial-escalation-twin-parity-gate-obsoleted.md` — the
  originating `crucial_escalation`, raised the moment the cutover landed.
- `project/rapports/problems/E62_S01_T06-twin-parity-gate-min-pairs-unsatisfiable.md` — the gate
  reappearing a day later as the sole red test on `main`, hit by an unrelated task's smoke gate.
  That is the concrete price of leaving an unsatisfiable check standing: it bills its failure to
  whoever runs the suite next, who did not cause it and cannot locally fix it.

**Two alternatives were considered and rejected** (scrum-master, 2026-09-19; full reasoning in
`project/board/stories/E42_S07_retire-gate-twin-parity-mechanism.md`):

- **Repurpose the script.** Its classification engine was a byte-for-byte port of the also-deleted
  `scripts/generate-j-alias.sh`'s bare→twin transforms (`E50_S14_T01`). With no bare source left to
  reconstruct a twin from, it has no meaningful function; aiming it at an unrelated invariant would
  mean rewriting it from scratch — out of proportion to any currently identified need.
- **Leave the floor standing as a deliberate always-fails trip-wire.** Rejected as needless noise for
  anyone invoking the gate directly, with no corresponding benefit, and — per the `E62_S01_T06`
  rapport above — noise that lands on unrelated work.

The redesign the classification engine needed (it could detect whole-file absence but not reliably
detect same-file content drift — see
`project/rapports/problems/E50_S19_T04-audit-classification-stale-post-contract-flip.md`) existed
only to protect the `E50_S15` cutover from silent content loss. That cutover is complete, and the one
concrete drift instance those rapports found — `skills/status/SKILL.md`'s `E51_S05` deploy-reconcile
step — was independently confirmed backfilled into `skills/j-status/SKILL.md` by `E50_S19_T07`
(commit `6f353ec5`) and re-verified before `E50_S15_T04` ran. No content was lost, and there is no
future pair for a redesigned engine to compare.

### What was removed, and what did not change

Removed: the `npm run` entry (one line out of `package.json`'s `scripts` block), the audit shell
script under `scripts/`, and both bats files — the script's own classification-logic suite and the
gate's wiring suite. Exact paths and the full diff are in `E42_S07_T01`'s commits, and the board
files (`project/board/stories/E42_S07_*`, `project/board/tasks/E42_S07_T01_*`) name them explicitly.

Unchanged: `npm test` (`bats tests/*.bats`). The gate was never part of the default run, so its
removal changes no default-run behavior — verified green before and after.

One cross-reference worth keeping in view: `tests/load-nl-catalog-twin-resolution.bats` used to
cross-check `load-nl-catalog.js`'s permanent-exception set against the audit script's own copy of
that list. Rather than lose the drift guard with the gate, `E42_S07_T01` repointed it at
`scripts/repoint-skill-refs.sh`'s `REPOINT_SKILL_REFS_EXCEPTIONS` — a surviving list that file labels
its "Single named source".

## Known limitation

This procedure verifies content parity, not the mirror's push path. It builds the
mirror-shaped tree locally with the same blocklist engine `mirror.sh` uses, but it does
not clone the public repo or run `/mirror-public --dry-run` against the live remote, so
it cannot detect a divergence introduced by the push/squash step itself or by
public-side commits that never came from here. For that, run
`/mirror-public --dry-run` directly.

---

## Recorded ambiguity: `Merged` over-promises

`E22_S09_T07` read `status: Merged` for a full day while its fix was unreachable from
the public mirror. Both the board and the consumer's "not addressed" report were
accurate, because they were claims about different trees.

**`Merged` currently means "merged into `main` in this private repo."** It carries no
claim that the change reached the public mirror, is present in any shipped artefact, or
is reachable by a consumer — and every one of those is a reasonable thing for a reader
to infer from the word. There is no board status that distinguishes "landed here" from
"shipped downstream", so a change blocked by `.publicignore` can sit at the board's
strongest terminal status indefinitely while being absent from everything a user can
install.

`E50_S19` closes the specific content gaps and adds the audit above, which makes the
condition *detectable*. It does not change what `Merged` means — changing the status
semantics repo-wide was explicitly out of scope. This is recorded here so the ambiguity
is not rediscovered from first principles the next time a consumer report and the board
appear to contradict each other.

If it is ever revisited, the question to answer is narrow: should the board distinguish
merged-to-`main` from shipped-to-mirror, or should the mirror gap simply never be
allowed to exist? `E50_S15` (deleting the bare-name directories, so there is exactly one
copy of every skill and nothing to strand) points at the second answer, and would make
the first unnecessary.
