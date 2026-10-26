# Public-Mirror Content Parity

How to verify that the `skills/j-<name>/` twins the public mirror ships carry the same
content as their `skills/<name>/` sources — and why a check run against the private
repo alone cannot tell you that.

Established by `E50_S19` (2026-09-10). Companion to `project/documentation/skill-authoring.md`'s
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

34, not 39: five skills are blocklisted in **both** forms and ship in neither
(`mirror-public`, `self-sync`, `train`, `strategy`, `convert`). A drift in
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

### Now machine-enforced (`E28_S16`)

Choosing neither option above is no longer caught only downstream. `check_test_subject_invariant`
in `skills/j-mirror-public/scripts/mirror.sh` runs before every real push (alongside the existing
publish-config and permission-level invariants), materialises the computed ship set into a temp
tree, and runs the shipping `.bats` suite there. Any shipping test that fails — because its subject
was blocklisted without following either sanctioned option, or for any other reason — refuses the
push and names the failing file. It is skipped by `--dry-run` and `--inventory`, matching the other
two pre-push invariants, and a missing `bats` binary is a logged skip rather than a hard failure.

**Why this reproduces the failure instead of predicting it.** A measured probe (2026-09-25) tried
static reference-scanning first — grepping each test for repo-relative paths and classifying them via
`scripts/check-publicignore-match.sh` — and rejected it on the evidence: 5 raw hits across 4 files, of
which only 1 was real. The other 3 were a fixture name written into a sandbox `.publicignore`, a
prose comment citing a script for precedent, and comments citing line numbers — a static checker
cannot tell an executed reference from a fixture string or a comment, and a 3-in-4 false-positive
rate gets a gate ignored within a release or two. The shipped implementation instead runs the real
suite in a mirror-shaped tree, which has zero false positives by construction because it reproduces
the actual failure rather than guessing at it. Regression coverage: `tests/mirror-test-subject-invariant.bats`
(`E28_S16_T02`), modeled on `tests/mirror-permission-level-invariant.bats`.

The two sanctioned resolutions above are unchanged and still the correct authoring guidance — this
gate is what happens when neither was followed, not a replacement for choosing one.

**Enforced twice as of `E28_S17`.** The rule is now checked at two independent points, not one:

1. **Pre-push, privately.** `check_test_subject_invariant` (above) — unconditional, runs before every
   real `/mirror-public` push, and cannot be bypassed by using `mirror.sh` normally.
2. **In CI, on the public repo.** `.github/workflows/mirror-staging-gate.yml`'s `test` job runs the
   real `npm test` against the real staged checkout. It is not a second implementation of the private
   guard — `check_test_subject_invariant` lives in `mirror.sh`, which is permanently private and never
   ships publicly, so there is nothing there to re-invoke. What the private guard *simulates* (a
   materialised temp tree running the shipping suite) the CI checkout simply *is*, so a real `npm test`
   run against it serves the same role without reimplementing anything. See that workflow file's own
   header comment for the full reasoning, including why a second static-parsing step was rejected on
   the same false-positive evidence as Approach A above.

Layer 1 is what stops a stranded test from ever reaching the mirror in the first place; layer 2 is
what would catch it if layer 1 were ever bypassed (e.g. a direct push to the staging branch outside
`mirror.sh`). Neither replaces the other.

**Which skills are never public.** Five are blocklisted in *both* their bare and `j-` form, so they
ship in neither and no naming change can make them available: `convert`, `mirror-public`,
`self-sync`, `strategy`, `train`. Plus `mcp/router/`. A test touching any of these must take option 1
or 2. The other 34 blocklisted skills ship under their `j-<name>` twin and are publicly available —
referencing *those* by twin name is fine.

**Audit command.** For each `tests/*.bats` and `tests/helpers/*` that
`scripts/check-publicignore-match.sh` classifies `PUBLIC`, grep for references to the five
never-public subjects above. As of 2026-09-10 this reports no violations. This was originally **manual
and unwired** — the same weakness `E50_S19`'s rapport recorded about the `--min-pairs` floor — with no
natural host after the twin-parity gate it was once meant to fold into was retired. `E28_S16`'s
`check_test_subject_invariant` (see "Now machine-enforced" above) is not that same static grep — it
runs the real suite instead — but it closes the same gap this audit command existed to catch by hand,
and does so automatically on every real push. This audit command remains useful as a targeted,
faster manual spot-check; it is no longer the only thing standing between a violation and a push.

**Non-test audit.** `scripts/check-public-references.sh` covers the shipped skill definitions and scripts
(`skills/*/SKILL.md`, `skills/*/scripts/`, `scripts/`, `hooks/`). It keeps only the files that
`scripts/check-publicignore-match.sh` classifies `PUBLIC`, then reports every line that names or paths into
a never-public subject, and exits 1 when there is any. It is report-only and not wired into a gate.

Since `E28_S19_T06` it derives nothing itself: the set, the three regexes and the severity all come from
[`scripts/never-public-refs.sh`](../../scripts/never-public-refs.sh), called with `strict=1` so its verdict
matches what a real push would refuse rather than check 6's consumer-side view. As of 2026-10-21 it reported
**42 critical and 48 minor across 260 public files**; after `E28_S21_T01` widened the comment rule (see "What
counts as a comment line" below) it reports **40 critical and 50 minor across 262 public files**. That supersedes the 59 lines reported on 2026-10-17,
when it still used a hardcoded five-name list: the set is now six names, so `j-dev-done` is audited for the
first time (20 hits), and bare `j-<name>` tokens are matched as the push gate matches them. The new output is
a strict superset of the old — 65 distinct `file:line` before, 90 after, with none lost.

Most minors are comments. Some hits are deliberate maintainer-only paths, such as
`scripts/compute-deploy-reconcile.sh` reading the mirror config, which is absent in a consumer install and
skipped there. Each hit still needs a triage decision before the audit can be a gate. `mcp/router/` is
audited too, by a pattern kept deliberately separate from the shared skill set, because it is blocklisted
private tooling and not a skill. The consumer-side equivalent is check 6 of
`skills/j-smoke-test/scripts/smoke-test-skills.sh`, which judges only what a consumer install receives.

## Rule: a shipped file may not reference a skill that stays private

**The sibling of the rule above (`E28_S19`).** A test may not outlive its subject; likewise no file
that ships may point at a skill that `.publicignore` keeps private. A consumer who receives such a
file gets an instruction (`/j-mirror-public`, `skills/j-mirror-public/...`) that resolves to nothing
in their install.

**What is "never-public".** A skill whose canonical `skills/j-<name>/` directory is blocked by a
`^skills/j-<name>/$` line in `.publicignore`. The set is read from `.publicignore` at run time, never
hardcoded, so unblocking a skill there removes it from the rule automatically.

**What is scanned (name scope narrowed by `E28_S19_T07`, path scope widened by `E28_S21_T05`).** Two scopes,
deliberately asymmetric; the full statement and the reasons are under "Final scope" below.

- **Name hits** (`/j-<name>`, `j.<name>`, bare `j-<name>`): **instruction files only**, the files a consumer would
  actually follow: `skills/*/SKILL.md`, `agents/*.md`, `.github/agents/*.md`, `hooks/*`, and the `.claude/` and
  `.agents/` mirrors of those (`scope_re` in the guard).
- **Path hits** (`skills/j-<name>/...`): **every shipped file an npm consumer receives**, that is the computed ship
  set intersected with `scripts/npm-reach-files.sh` (`npm pack --dry-run`). `scope_re` does not gate them.

Shipped files that never reach npm (`tests/`, `project/`, the `.claude/` and `.agents/` trees) are not path-scanned,
and a reference in them is not reported.

**Failing versus reported.** The classification is recorded in the header of
[`scripts/never-public-refs.sh`](../../scripts/never-public-refs.sh). The mirror guard calls it with
`strict=0` for markdown and `strict=1` for everything else:

| File kind | path hit | name / bare `j-<name>` hit, non-comment | comment line (`#`, `//`, `/*`, `*`) |
|---|---|---|---|
| markdown (`*.md`) | **critical, fails the run** | minor, reported only | n/a — a leading `#` is a heading |
| anything else | **critical, fails the run** | **critical, fails the run** | minor, reported only |

A path stays critical in markdown because `never_public_severity` short-circuits on the hit kind before
it consults `strict`. In check 6 of `j.smoke-test` (always non-strict) every name hit is minor and bare
`j-<name>` tokens are not scanned; that mode is kept so name-hit severity does not change.
`.publicignore` itself defines the set and so necessarily names every member; how that is handled is
stated once, under "Declared exemptions" below.

**What counts as a comment line (widened by `E28_S21_T01`).** A line whose first non-blank characters are
`#`, `//`, `/*` or `*` (the last also covers `*/`, so a ` * text` JSDoc or C-style block-comment continuation
line is a comment). Only a *leading* marker counts: a `*` elsewhere on the line, such as the glob in
`skills/*/SKILL.md`, does not make it one. The test is lexical and does not track whether a `/*` block is open,
so a code line that merely begins with `*` (a shell case arm such as `*.md)`) is also read as a comment; a
path hit on such a line would be reported minor instead of critical. Markdown stays exempt (`own_md=1`): there
a leading `#` is a heading and a leading `*` is a bullet, so no markdown line is a comment.

*Why it was widened.* The old `#`/`//` rule classified a path inside a JSDoc block as executable
(critical), and `E28_S19`'s verification then described `lib/generate-skill-allow-list.js:41`, a JSDoc
continuation line, as "executable logic composing a path". The measured scale of the gap: 12 path-hit
lines across the public set are block-comment continuations, which is 4 distinct lines in `lib/` repeated
across the root, `.claude/` and `.agents/` copies. **None of them is in scope of any of the three
consumers** (`lib/` is outside the mirror guard's instruction-file scope, check 6's `SKILL.md` +
`scripts/` scope, and `check-public-references.sh`'s scope), so the change moves no existing verdict for
those 12.

*Measured effect on the three consumers* (committed `HEAD` `fb722671`, before versus after):

| Consumer | Before | After | Hits reclassified critical to minor |
|---|---|---|---|
| Check 6 of `j.smoke-test` | 0 critical, 37 minor | 0 critical, 37 minor, output byte-identical | **0** |
| Mirror guard (`check_never_public_refs_invariant`) | 0 critical, 70 minor | 0 critical, 70 minor, same lines | **0** |
| `scripts/check-public-references.sh` | 42 critical, 48 minor | 40 critical, 50 minor | **2** |

The two reclassified lines are `scripts/postinstall.js:26` (a name hit for `j-self-sync` in the JSDoc line "single source of truth shared with the in-repo
`/self-sync` skill") and `skills/jenga/scripts/load-nl-catalog.js:85`
(an `mcp/router/` path hit in a JSDoc continuation). Both are genuine block-comment continuation lines. The
full before/after listings are in `project/documentation/summaries/E28_S21_T01-findings-delta.txt`.
`E28_S19_T01`'s freeze of check 6's findings is amended to record this change; check 6's actual findings did
not change.

**Why markdown name hits do not fail.** The shared rule's own header states the limit: "a name mention
cannot be told from prose by a regex." `E28_S19_T02` shipped `strict=1` over the whole ship set, which
measured **598 critical hits across 131 shipped files** and so refused *every* real push — a gate that
is permanently red enforces nothing, and no board item tracked the remediation. All 67 in-scope name
hits turned out to be prose: a quoted ticket title, a described condition, a list of sibling skills. Not
one was an instruction. Remeasured under the matrix above, this scope yields **0 critical**.

This also brings the code into line with story `E28_S19`'s own AC4 — "prose and comment references are
reported without failing the run, matching check 6" — which `strict=1` contradicted.

**Accepted weakening, recorded so nobody has to rediscover it:** a genuine `/j-mirror-public`
*invocation* in a shipped `SKILL.md` is now advisory rather than blocking. The path form
(`skills/j-mirror-public/...`), which is what actually dangles in a consumer install, stays critical
everywhere.

### Final scope (`E28_S21_T05`)

| Hit kind | Scanned in | Gated by | Severity |
|---|---|---|---|
| **path** | every file in the ship set that is also in the npm-reach list (all file kinds) | `scripts/npm-reach-files.sh` | critical on a non-comment line, minor on a comment line (markdown has no comment lines) |
| **name** and bare `j-<name>` | instruction files only (list above) | `scope_re` in the guard | markdown: minor (`strict=0`); anything else: critical on a non-comment line |

*The asymmetry.* A path hit carries none of the prose-versus-invocation ambiguity that made whole-tree name scanning
unenforceable (`E28_S19_T02` measured 598 criticals and refused every push). A path either exists in a consumer
install or it does not. A name mention cannot be told from prose by a regex, so name hits stay where a consumer
follows them. The code states the asymmetry where it is applied: `scope_re` in `check_never_public_refs_invariant`
gates name hits only, and `SCOPE_RE` in `scripts/check-public-references.sh` is kept for name hits only.

*How reach is computed.* `scripts/npm-reach-files.sh` runs `npm pack --dry-run --json --ignore-scripts` and prints the
file list root-relative and sorted under `LC_ALL=C`, so the same tree always gives byte-identical output.
`package.json` `files` and `.npmignore` stay the single source of truth: there is no second list to drift, and a
directory added to `files` is scanned automatically. It **fails closed**: if `npm` or `node` is missing, the JSON does
not parse, `npm pack` fails, or the list is empty, it exits non-zero with a message on stderr and nothing on stdout,
and both consumers (the mirror guard and `scripts/check-public-references.sh`) then stop rather than treat the
failure as an empty, green scan. The list is the private repository's, so it slightly over-states what ships (the
mirror strips blocked files); intersecting with the ship set removes those, and any over-statement errs toward
scanning more. The `.claude/` and `.agents/` trees never reach npm (`.npmignore`), so they fall out by construction;
their copies are covered through the root file they are generated from.

*Measured* (base `23bef16d`, this repository): the reach list is 485 files; the guard path-scans 442 of them and
name-scans 192 instruction files; 45 path hits are exempted by `scripts/never-public-exemptions.conf`; **0 critical**,
and a `--dry-run` against a local bare remote exits 0. Runtime: `npm pack --dry-run` alone about 0.6 s; the whole
`--dry-run` takes about 4.0 s against about 5.4 s on the pre-change tree, because the per-file scope test that used
to fork a `grep` for every one of ~1700 ship-set files is now one `awk` pass. The broadened scan did not slow the
mirror run.

*The accepted limit.* Files that never reach an npm consumer are not path-scanned: `project/` and `tests/` in the
mirrored tree, and therefore what a reader of the public GitHub repository sees there. If the maintainers later decide
those readers count as consumers, the answer is a directory-level exemption design (option (b) below), as a new story,
not an extension of this one. `tests/` is additionally covered by the behavioural `check_test_subject_invariant`.
The `.claude/` and `.agents/` mirrors are no longer path-scanned directly (they are still name-scanned), which is
sound only while they are generated from the root files that are scanned.

*Option (b), the whole public ship set for path hits: considered and not chosen.* `E28_S19`'s tester proposed it. It
would have added `project/` (15 files, 59 hits) and `tests/` (5 files, 19 hits). The `E28_S21_T02` triage found 210 of
the 225 path hits (**93 percent**) legitimate by purpose, so under that scope the exemption file would carry the gate:
the scan would meaningfully test 7 percent of what it reads, and both directories would need directory-level
exemption entries (every new design note naming the mirror skill would otherwise break the gate). Under npm reach, 6
exemption entries cover the legitimate hits and the 5 defect lines (reworded by `E28_S21_T04`) are the live signal,
which is a proportionate gate. The exemption file therefore holds no entry for `project/` or `tests/`, and a test
asserts it. User decision, 2026-10-22.

### Declared exemptions (`E28_S21_T03`)

A few files legitimately name a blocked skill's path **as their purpose**. They are declared in
[`scripts/never-public-exemptions.conf`](../../scripts/never-public-exemptions.conf) and honoured by the one shared
rule, so the three consumers cannot disagree.

**Format** (line based; nothing else is accepted):

```
[lib/legacy-shipped-paths.json]      one entry per file, keyed on the ROOT path
reason = <one self-contained line>   mandatory
match = <literal substring>          optional: only a hit on a line containing it is exempt
```

- **Granularity is per file.** A leading `.claude/` or `.agents/` is folded off before the lookup, so one root
  key covers a file and both generated copies of it. A key written with that prefix is rejected.
- **Path hits only.** `never_public_path_exempt` is called for path hits and nothing else. A line that still carries
  a name or bare `j-<name>` hit once its path hits are blanked is **not** exempt (it stays reported; it is then
  classified as a path hit, which is the stricter reading). The router MCP directory, which
  `scripts/check-public-references.sh` audits as private tooling, is never exempted.
- **Narrowing** is a literal substring (no pattern language). It is used on the three single-hit files, so a later
  second reference to a blocked skill in the same file is not silently inherited. A narrowed entry can also cover a
  comment line carrying the same text: `scripts/compute-deploy-reconcile.sh:18` (a minor hit) is covered by the
  same `/assets/config.json` narrowing as line 146.
- **No** glob, directory or per-line entries.
- **Fail closed.** A missing or empty `reason`, an empty `match`, a duplicate entry or field, a glob, directory,
  absolute or prefixed key, an unknown field, or any unparseable line makes the file malformed. The loader then
  loads *nothing* and sets `NEVER_PUBLIC_EXEMPT_ERROR`, a message naming the entry (and line where there is one); the
  mirror guard dies before any rsync write, commit or push, check 6 exits 2, and the reference audit exits 2. An
  **absent** file means no exemptions, which is the stricter reading.
- **Visible at push time.** The mirror guard logs every exemption it applies, with its reason
  (`never-public-refs-invariant: exempt (path) <file>:<line> ... - <reason>`), and the OK line carries the count.
  The reference audit prints the count on stderr and leaves its last line unchanged.

**The bar for an entry.** *Naming the path is the file's purpose*: a registry of paths that really shipped, a
tool that rewrites those paths, a permission rule for a maintainer-only command. A reference a consumer would
follow to a path that does not exist is a **defect to reword** (`E28_S21_T04`), never an entry. The file is a
security-relevant allow list: review the entries and their reasons, not only the diff. Every entry must still
name an existing file (a bats case guards against a typo that would exempt nothing).

**Seed entries (6, provisional on the maintainer for five of them).** Hit counts are root hits from the
`E28_S21_T02` triage (`project/documentation/path-reference-triage-E28_S21.md`), which cover 44 of the 49
npm-reachable path hits (132 of 147 counting the mirror copies):

| Entry | Hits | Narrowing | Why |
|---|---|---|---|
| `lib/legacy-shipped-paths.json` | 28 | none | Generated registry of paths that shipped in earlier npm versions; the strings are the data |
| `scripts/compute-deploy-reconcile.sh` | 1 | `/assets/config.json` | Reads the mirror skill's maintainer-only config |
| `scripts/repoint-dead-bare-path-prose.py` | 3 | none | Spent `E50_S22_T03` migration tool; the paths are its targets |
| `scripts/rewrite-stale-skill-preambles.py` | 10 | none | Spent `E50_S22_T02` migration tool; the paths are its data |
| `templates/permission-levels/level-4-elevated.json` | 1 | `/scripts/mirror.sh*)` | Allow rule for the mirror script; functional for the maintainer, inert in a consumer install |
| `templates/permission-levels/level-5-unrestricted.json` | 1 | `/scripts/mirror.sh*)` | As level 4 |

The two migration scripts, `compute-deploy-reconcile.sh` and the two level files are judgement calls (the triage
marked them ambiguous). **Open question for the maintainer:** retire the two spent migration tools instead of
exempting them? That would leave 4 entries and exempt 13 fewer root hits (39 with mirrors). Nothing was deleted here.

**The file adds no hits of its own.** A wide scan (the audit with its scope filter set to the whole tree) reports 225
critical skill-path hits with the file in the tree, the same total as the `E28_S21_T02` baseline without it; the
file itself contributes 0 path hits and 0 name hits (reasons and narrowing texts refer to a skill's directory in
words, never as a path). With the exemptions applied the same scan reports 93 critical path hits (135 exempted:
132 critical plus the 3 minor `compute-deploy-reconcile.sh:18` copies); the 5 defect lines in two templates
remain. **It does ship to npm**: `scripts/` is in the `files` whitelist and `npm pack --dry-run` lists
`scripts/never-public-exemptions.conf` (as it lists `scripts/never-public-refs.sh`, which check 6 needs in an
install).

**`.publicignore`: left outside the mechanism.** The files `npm pack` lists (the path scope `E28_S21_T05` implemented)
do not include `.publicignore` (verified with `npm pack --dry-run --json`: 483 files, none of them it). It is
therefore unreachable and gets no exemption entry. The existing handling stands: neither of the mirror guard's
scopes reaches it (`b62e3e14` removed the explicit exemption as dead), and
`scripts/check-public-references.sh` skips it by name. If a future scope reaches it, express the handling as an
entry here rather than a second ad-hoc check. The bats case for the audit's skip runs the audit widened to the
repo root with and without the skip line, so deleting the handling turns it red.

**Where it runs.**

1. `check_never_public_refs_invariant` in [`skills/j-mirror-public/scripts/mirror.sh`](../../skills/j-mirror-public/scripts/mirror.sh)
   scans the instruction files within the computed ship set before any rsync write, commit or push, and
   also under `--dry-run`,
   so a dry run reports the verdict a real push would. Under bats it is skipped unless
   `MIRROR_NEVER_PUBLIC_REFS_GATE=1` is set.
2. Check 6 of `j.smoke-test` ([`skills/j-smoke-test/scripts/smoke-test-skills.sh`](../../skills/j-smoke-test/scripts/smoke-test-skills.sh)).
3. `scripts/check-public-references.sh` (maintainer-side audit, report only).

All three source the one shared rule, [`scripts/never-public-refs.sh`](../../scripts/never-public-refs.sh).
Do not duplicate its regexes or severity logic anywhere else.

**Fixing a hit.** Either remove or reword the reference so the shipped file no longer names the private
skill, or stop blocking the skill in `.publicignore` (a deliberate publishing decision, never a way to
silence the guard). Do not exempt a file from the scan, except through a declared entry that meets the bar
under "Declared exemptions" above.

---

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

The rationale is in `project/documentation/skill-authoring.md`'s "Public Playbooks Terminate at `j-commit`" section:
most users would not want a playbook that publishes or pushes to a public destination on their
behalf, so publishing stays an explicit, separately invoked act. Consequences for this document:

- **Its three `.publicignore` entries are permanent.** Do not "fix" them. No step-name cutover,
  skill rename, or parity-audit improvement is meant to make this playbook public, and a future
  audit finding it absent from the mirror has found the intended state, not a defect.
- **It is out of the parity population by construction**, for the same reason the five
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

## Project-local workflows are private: `project/.workflows/` (`E80_S01`)

Workflow definitions follow the same two-source shape as playbooks (`E80_S01`): the framework-owned
BUILTIN source `templates/workflows/`, and the project-owned PROJECT source `project/.workflows/`.
Only the first is framework content. Exactly as for `project/.playbooks/` above, the second is
blocklisted in full (`E80_S01_T08`):

```
project/.workflows/
```

**Why.** Project-local workflows are per-project by definition. Ours are not framework content, and a
consumer's are not ours to overwrite. Shipping our own would push private workflow tooling downstream
as though it were part of the framework, and would land in the same directory a consumer uses for
their own workflows.

**What still ships.** The `templates/workflows/` builtins DO ship. They are framework content, the
workflow counterpart of `skills/jenga/playbooks/`, and the blocklist entry deliberately names only the
project-local directory so it cannot catch them.

**This is an exclusion, not a deletion.** Anything in `project/.workflows/` stays on disk and keeps
working in the private repo; it simply stops shipping.

**No test is stranded by it** (per the "a test may never outlive its subject" rule above):
`load-workflows.sh` treats a missing `project/.workflows/` as a **silent no-op** (no warning, no
error), so the mirror simply has no PROJECT workflow source. The entry needs neither of the rule's two
sanctioned mitigations.

**No `.claude/` or `.agents/` parallel lines.** Like the `project/.playbooks/` entry, and unlike the
private-tooling playbook entries, the blocklist line is a single root-relative path; the generated
mirrors do not carry the project-local directory.

`tests/workflow-publicignore.bats` asserts the exact `.publicignore` line and that this document
mentions `project/.workflows/`.

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
