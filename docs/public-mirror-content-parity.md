# Public-Mirror Content Parity

How to verify that the `skills/j-<name>/` twins the public mirror ships carry the same
content as their `skills/<name>/` sources — and why a check run against the private
repo alone cannot tell you that.

Established by `E50_S19` (2026-09-10). Companion to `docs/skill-authoring.md`'s
"The Canonical Naming Contract".

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

Four runs. Each answers a different question, and the ordering matters — run A alone
is what previously looked sufficient and was not.

### A. Private repo — is every twin in sync with its source?

```console
$ bash scripts/audit-twin-divergence.sh . --min-pairs 40
audit-twin-divergence.sh: audited 40 twinned pair(s) under ./skills
audit-twin-divergence.sh: no unexpected divergence — every difference between each source and its twin is explained by the generator's transforms.
$ echo $?
0
```

`--min-pairs 40` is not decoration. See run C.

**Wired, 2026-09-19 (`E50_S19_T04`):** `npm run gate:twin-parity` runs exactly the command above.
It is deliberately **not** folded into `npm test` — see "The gate is wired, but not into `npm test`"
below for why.

> **Known caveat as of `E50_S19_T04`.** A real run of run A above currently exits 1, not 0. This is
> **not** a content-parity defect: `E50_S11`/`E50_S12`/`E50_S14` (merged the same day, concurrently
> with this fix) settled the naming contract in the opposite direction this audit still assumes —
> `skills/j-<name>/` is now the canonically hand-edited source, `skills/<name>/` is a frozen,
> soon-to-be-deleted (`E50_S15`) stub — and this script's classification engine has not yet been
> updated to match. The 5 `__pycache__`/`*.pyc` false positives this task fixes are gone; ~61
> `SKILL_DRIFT`/`CONTENT_DRIFT` findings remain, all attributable to the same stale-model cause, not
> to any actual content at risk of being lost. Full account, evidence, and recommended next step in
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

```console
$ bash scripts/audit-twin-divergence.sh "$MIRROR"
audit-twin-divergence.sh: audited 0 twinned pair(s) under /tmp/…/skills
audit-twin-divergence.sh: no unexpected divergence — …
$ echo $?
0
```

**Exit 0, and worthless.** The audit compares each twin against its bare source; in a
mirror-shaped tree the sources have been stripped, so there are no pairs, nothing is
compared, and success is reported. Anyone reading only the exit code would take this as
proof of parity.

`--min-pairs` exists to make that failure loud:

```console
$ bash scripts/audit-twin-divergence.sh "$MIRROR" --min-pairs 1
audit-twin-divergence.sh: error: only 0 twinned pair(s) were audited, but --min-pairs 1 was required. A clean result over too small a population is not a pass — check the tree actually contains the pairs you expected.
$ echo $?
2
```

**Always pass `--min-pairs` when using this script as a gate.** As of `E50_S19_T04`, that means
`npm run gate:twin-parity` — see "The gate is wired, but not into `npm test`" below.

### D. The real question — do the twins that *ship* carry the sources' content?

Overlay the private repo's bare sources onto the twins that survived the blocklist, and
audit that. This is the only one of the four runs that is both non-vacuous and scoped
to what consumers actually receive:

```console
$ HYBRID=$(mktemp -d); mkdir -p "$HYBRID/skills"
$ cp -R "$MIRROR/skills/." "$HYBRID/skills/"
$ for d in "$HYBRID"/skills/j-*/; do
    bare="$(basename "$d")"; bare="${bare#j-}"
    [ -d "skills/$bare" ] && cp -R "skills/$bare" "$HYBRID/skills/$bare"
  done
$ bash scripts/audit-twin-divergence.sh "$HYBRID" --min-pairs 34
audit-twin-divergence.sh: audited 34 twinned pair(s) under /tmp/…/skills
audit-twin-divergence.sh: no unexpected divergence — …
$ echo $?
0
```

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
unwired** — the same weakness recorded in `E50_S19`'s rapport about `--min-pairs`, and a natural
candidate to wire into the same gate.

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

## The gate is wired, but not into `npm test`

`E50_S19_T04` (2026-09-19) closed the gap the original rapport
(`project/rapports/problems/E50_S19-parity-gate-is-manual-only.md`, Finding 1) flagged: `--min-pairs`
was documented as "the thing to always pass when using this as a gate" but nothing actually invoked
it. `npm run gate:twin-parity` (`package.json`) now does — it is exactly
`bash scripts/audit-twin-divergence.sh . --min-pairs 40`, the run A command above, reachable from the
project's normal `npm run` surface.

**Deliberately not folded into `npm test` (`bats tests/*.bats`).** Two reasons, one permanent and one
transitional:

- **Permanent.** Coupling the bats suite's pass/fail to real-tree state was a design question the
  original rapport raised and explicitly declined to resolve in place — "wiring this into `npm test`
  or CI... would make the suite depend on real-tree state, which the suite currently avoids by
  design." `gate:twin-parity` is intentionally a separate, explicitly-invoked surface rather than an
  implicit addition to every contributor's `npm test` run.
- **Transitional, and the sharper reason right now.** Per the "Known caveat" note under run A above,
  a real invocation of this gate currently fails for a cause unrelated to content parity (the
  audit's classification engine predates the `E50_S10`/`E50_S11`/`E50_S12`/`E50_S14` contract
  reversal). Folding a known-red check into `npm test` today would make the whole suite fail for
  everyone, for a reason no ordinary contributor caused or can fix locally — precisely the "a gate
  that cries wolf gets disabled" failure mode `E50_S19_T04`'s own task file warns against, just
  arriving from an unanticipated direction. `gate:twin-parity` stays runnable and honest
  (`npm run gate:twin-parity`) without holding the rest of the suite hostage to a fix that is out of
  this task's scope; see the rapport referenced above for the recommended next step.

`tests/gate-twin-parity.bats` covers the wiring itself and proves the gate's fault-injection
correctness — that a genuine divergence trips it and clearing it clears the gate, and that a
gitignored build artifact does neither — against synthetic sandboxes, not the live repo, for the same
reason.

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
