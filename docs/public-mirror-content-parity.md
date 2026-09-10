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

**Always pass `--min-pairs` when using this script as a gate.**

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
