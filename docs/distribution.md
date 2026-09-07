# Distribution & Consumer Install

How the Jenga AI framework reaches a consumer project, what lands where, and how upgrades
are reconciled.

Scope: the **consumer** distribution path (`npm install @jenga-ai/agent` → `postinstall`).
For the in-repo development mirror (`j.self-sync`, which mirrors this repo's root
directories into its own `.claude/` and `.agents/`), see `skills/self-sync/SKILL.md` — it
shares the same copy helper but is a different mechanism with different rules.

---

## 1. What ships

The published package contains the framework's root directories. Only two of them are
**discovery-bound** — they have to sit at a fixed path in the consumer's project for an
agent runtime to find them at all:

| Directory | Consumer destination | Why |
|---|---|---|
| `skills/` | `.claude/skills/` **and** `.agents/skills/` | Claude Code reads `.claude/`; non-Claude agents (Copilot, custom) read `.agents/`. |
| `agents/` | `.claude/agents/` **and** `.agents/agents/` | Same split. |

Everything else — `hooks/`, `scripts/`, `templates/`, `mcp/`, `lib/` — stays inside the
installed package and is sourced from `node_modules/@jenga-ai/agent/…` at runtime. It is
never duplicated into the consumer project.

The duplication of `skills/` and `agents/` into *both* roots is deliberate and
unavoidable: each agent ecosystem has its own hardcoded discovery path, and a consumer may
use more than one.

The consumer's own `project/` directory (board, queue, logs, rapports) is never touched by
install.

---

## 2. The install path

`scripts/postinstall.js` runs automatically as an npm `postinstall` hook.

1. **Locate roots.** The package root is derived from the script's own location; the
   consumer root comes from npm's `INIT_CWD`.
2. **Self-install guard.** If `INIT_CWD` resolves to the package root itself, the hook is
   running inside the framework repo during development — it logs and exits without
   copying.
3. **Version gate.** The version last installed is read from `<consumer>/.jenga-version`.
   Files are copied only on a first install (no `.jenga-version`) or a strict semver
   **upgrade**. A same-or-older version short-circuits with "Nothing to do" and performs no
   copy, no cleanup, and no manifest write.
4. **Mirror.** `lib/mirror.js` copies `skills/` and `agents/` into each destination root,
   classifying every file as `added`, `overwritten`, or `skipped` (byte-identical, left
   alone).
5. **Reconcile stale files.** See §3.
6. **Write the manifest.** See §3.
7. **Regenerate `lib/skill-allow-list.json`** by scanning the freshly mirrored
   `.agents/skills`. This runs *after* the cleanup in step 5 so the allow-list reflects the
   post-cleanup tree, not a stale one.
8. **Bootstrap `.github/copilot-instructions.md`** (idempotent; a later `jenga init` refines
   it without duplicating the JENGA block).
9. **Write `.jenga-version`** with the installed version.

Steps 5–8 are all best-effort: a failure there logs a warning but never fails the install.

---

## 3. Upgrade cleanup — manifest-based delete reconciliation

### The problem

The mirror is **additive-only**. Until this mechanism existed, nothing ever deleted from a
consumer's mirror roots. That was harmless while skills were only ever added — but a
release that **renames, removes, or excludes** a skill leaves the previously installed copy
sitting in `.claude/skills/` and `.agents/skills/` indefinitely, next to its replacement.
Both keep loading.

This was confirmed live upgrading to `@jenga-ai/agent@3.0.0`: `E50_S06` excluded certain
`j-<name>` twin directories from what the package ships, and `E50_S07` renamed skill
frontmatter separators (`j:` → `j.`). `node_modules/` got the new files, but the mirrored
discovery-path copies — where agents actually read from — were never cleaned up.

### Why not just enable `reconcileDeletes`

`lib/mirror.js` already has a `reconcileDeletes` flag, and it is used by `j.self-sync`. It
is **deliberately left `false`** on the consumer call site, and this mechanism exists
specifically so it can stay that way.

That flag's delete logic works by diffing the destination's *current directory contents*
against the source tree. It has no notion of **who wrote a given file**. Inside this repo
that is fine — everything in the mirror came from the repo. On a consumer's machine it is
not: a consumer's own hand-authored custom skill in `.agents/skills/` is, to that diff,
indistinguishable from an orphan, and would be deleted. The additive-only default was
introduced by `E27_S01_T01` precisely so accidental callers could not delete files.

So the consumer path gets a narrower, **provenance-aware** mechanism instead.

### The manifest

Each run records exactly what it wrote. One manifest per destination root, stored **inside
that root**:

```
<consumer>/.agents/.jenga-postinstall-manifest.json
<consumer>/.claude/.jenga-postinstall-manifest.json
```

Keeping it inside the root it describes means it travels with that mirror — moving or
renaming the consumer project cannot desynchronise it, and deleting one mirror root but not
the other cannot leave a stale record of the deleted one behind.

```json
{
  "manifest_version": 1,
  "package": "@jenga-ai/agent",
  "package_version": "3.0.1",
  "generated_at": "2026-09-07T00:00:00.000Z",
  "dest_root": ".agents",
  "paths": [
    "agents/developer.md",
    "skills/do/SKILL.md"
  ]
}
```

- `paths` are relative to the destination root, POSIX-separated, deduped and sorted —
  portable across platforms and independent of the consumer's absolute project path.
- `paths` records **regular files only, never directories**. Directory removal is derived
  by pruning parents that become empty. This is the key safety property, not an
  optimisation: a directory that still holds any consumer file is not empty, so it is never
  pruned.
- `paths` includes files that were byte-identical and therefore **skipped** by the copy
  step. A skipped file is still a package-owned path; omitting it would make the very next
  run classify it as stale and delete it.
- `manifest_version` lets a future format change be detected. An unrecognised version is
  treated as "no manifest".

### The rule

> A path is deleted only if a manifest **previously written by this package's own
> postinstall** lists it, **and** the current run did not write it.

Concretely, on each run: mirror additively, compute the set of paths just written, subtract
it from the previous manifest's path list, delete the remainder, prune directories left
empty, then write the fresh manifest.

### Safety invariants

Four independent layers, each sufficient on its own to prevent the failure mode this
mechanism is most at risk of — deleting a consumer's own files:

1. **No prior manifest ⇒ seed from known-shipped paths, then reconcile** (revised by
   `E26_S08_T03` — see §4 below). A genuine first-ever install is still additive-only, since
   there is nothing on disk yet to seed from. But "we don't know what we wrote before" no
   longer means "never delete anything, ever" for a consumer who was already installed
   before this manifest mechanism existed: their first run of a fixed version now seeds a
   synthetic prior-path list from `lib/legacy-shipped-paths.json` — paths known to have
   shipped in some real prior published version — intersected with what is actually on disk,
   and reconciles against it in that same run. "We don't know what THIS INSTALL wrote before"
   is never treated as "delete everything we didn't just write" — the seed is scoped strictly
   to paths with real publish provenance, never a blanket assumption.
2. **Provenance required.** A file the package never wrote was never in a manifest, so it
   is never a deletion candidate — regardless of whether it sits inside `.agents/skills/`
   alongside package-owned files.
3. **Bounded and type-checked.** Every candidate must resolve strictly inside its
   destination root (rejecting `..` traversal and absolute overrides) and must be a regular
   file — checked with `lstat`, so a symlink is refused rather than followed. Directories
   are never deleted directly, only pruned when genuinely empty.
4. **Fail toward doing nothing.** A missing, unreadable, corrupt, wrong-shaped, or
   unknown-version manifest disables the delete pass rather than guessing. A single
   unlinkable file is skipped with a warning rather than aborting an unattended install.
5. **Identity backstop.** A candidate whose filesystem identity (`dev`+`ino`) matches a
   file the current run wrote is never deleted, even if its recorded path string differs.
   Path strings alone are not enough on a case-insensitive filesystem (macOS APFS, Windows
   NTFS): after a case-only rename (`skill.md` → `SKILL.md`) the old and new strings differ
   while both resolve to the *same file*, so a string-only diff would delete the very file
   just written. Comparing inodes closes that whole class — case, Unicode normalisation,
   hardlinks — rather than special-casing letter case.

Additionally, if any `copySet` entry is **missing from the package** (a packaging
regression), both the delete pass and the manifest write are skipped for that run. The copy
step silently skips a missing source, so the run would under-report what it wrote and read
the entire mirrored subtree as stale — turning one bad publish into mass deletion on every
consumer. The previous manifest is deliberately left in place: it still accurately describes
what is on disk, so a later healthy release reconciles correctly against it.

Refusals are logged (`left in place (<reason>)`) rather than silently swallowed, and are
selective: a hostile manifest entry being refused does not stop genuinely stale entries in
the same manifest from being cleaned up.

### What a consumer sees

```
  ✓ .agents/skills/ — 12 file(s) copied
  ✓ .agents/ — 3 stale file(s) removed, 1 empty dir(s) pruned
```

or, on a first install:

```
  ℹ  .agents/ — no previous install manifest; additive copy only (no deletes)
```

### Consumer-facing notes

- **Do not hand-edit or delete the manifest.** Deleting it does not cause data loss — it
  just disables cleanup on the next upgrade (invariant 1), leaving stale files behind until
  a manifest is re-established.
- **Your own files are safe anywhere**, including inside package-owned skill directories.
  If the package removes a directory you have added a file to, the package's files go and
  yours stays, along with the directory.
- **Do not hand-edit package-owned skill files** in the mirror roots. They are not deleted
  (they are still in the current copy set), but they *will* be overwritten by the next
  upgrade. Put customisations in your own directories.

---

## 4. Legacy-path seeding — first-manifest orphan cleanup

### The gap it closes

§3's manifest mechanism, as `E26_S08_T01` originally built it, is purely forward-looking.
Deletion candidates are computed as `prior_manifest.paths − currentPaths`. For a consumer
already installed *before* this feature existed, the first run of any fixed version takes the
`no-prior-manifest` branch — additive copy only — and then writes a first manifest containing
only what *that run* mirrored. Pre-existing orphans were never in `currentPaths`, so they never
enter any manifest, so they could never become deletion candidates on any *future* upgrade
either. Confirmed empirically against a throwaway fixture, not merely reasoned about: a consumer
carrying an orphaned `j-<name>` twin (removed by `E50_S06`) survived two upgrades, the second
with an active delete pass and a valid manifest present, appearing 0 times in either manifest.

### The fix — seed, then reconcile, in the same run

On the `no-prior-manifest` branch, postinstall now additionally seeds a **synthetic** prior-path
list from `lib/legacy-shipped-paths.json` — a static, package-shipped list of paths known to have
shipped in some real prior published version (see below) — intersected with what is **actually a
regular file on disk** in that mirror root right now (`seedFromLegacyPaths` in
`lib/postinstall-manifest.js`; never seeds a path that isn't really there). If anything seeds, it
is reconciled against this run's own copy set immediately — **adopt-then-reconcile in one pass**,
so the cleanup lands on the upgrade that introduces this feature rather than one cycle later. The
seeded reconciliation reuses the exact same boundary/type-checked delete engine as the
manifest-backed path (invariants 3, 4, and 5 above apply unchanged over seeded candidates), and
writes a fresh, accurate manifest afterward exactly as §3 already does.

**Provenance stays the entire compensating control**, unchanged from §3's invariant 2: a path
absent from every published version's file list is never in `lib/legacy-shipped-paths.json`, so
it can never be seeded, regardless of where it sits in the mirror root. A consumer's hand-authored
file was never in any published version and stays exactly as untouchable as before — seeding only
ever narrows *which* paths are eligible for consideration, it never relaxes *how* a candidate is
validated once under consideration.

A genuine first-ever install has nothing on disk to intersect with, so the seed set is naturally
empty and the run falls straight through to the additive-only behaviour — no separate "is this a
first install" branch is needed for that to hold, and no regression in that case is possible by
construction.

### Where the legacy path list comes from

`scripts/generate-legacy-shipped-paths.js` produces `lib/legacy-shipped-paths.json`, which ships
with the package like any other file under `lib/`. Two modes:

- **`--bootstrap`** (manual, rare — a one-off backfill or occasional resync): queries the real
  npm registry (`npm view <package> versions --json`), `npm pack`s every currently-listed
  published version into a throwaway temp dir, and unions the `skills/`+`agents/` entries found
  in every tarball. Network-dependent, and deliberately **not** part of the automatic publish
  flow. The artifact currently shipped was generated this way, against the real registry — its
  `source` field reads `bootstrap-from-registry+incremental` and it correctly includes
  `skills/do/SKILL.md` (shipped in the published `2.0.0`, absent from `3.0.0`).
- **Default / incremental (no network):** reads whatever is already at the output path and unions
  it with the paths **currently on disk** under this repo's own `skills/` and `agents/`
  directories — i.e. "what this release is about to ship" folds into the running cumulative
  record. This is the mode wired into the publish pipeline (`npm run generate:legacy-paths`,
  called from `skills/publish/scripts/npm_pipeline.sh` before `npm publish`, and from the
  generated CI workflow in `npm_ci_pipeline.sh`), so the list is **regenerated automatically on
  every publish** and cannot silently go stale — it is not hand-maintained. Incremental mode's
  first-ever run (before any artifact exists) is NOT a substitute for `--bootstrap`: it would only
  union "what's on disk in this repo's tree right now," which happens to currently equal the real
  historical union but is a coincidence of this repo's current state, not a guarantee — which is
  why the artifact actually shipped was seeded via `--bootstrap` against the real registry first.

Why not derive the list from git tags, the task's other allowed option: checked and rejected for
this repo specifically. This repo's local tags (`v0.0.1`, `v55.0.1`, `last-self-sync`) do not
correspond to the real npm publish history at all — `npm view @jenga-ai/agent versions --json`
shows an entirely disconnected real sequence. Reconstructing shipped paths from local git tags
here would silently produce a list bearing no relation to what was actually published.

### Explicitly out of scope

**Reading the *old* package tree at postinstall time to derive what was previously installed.**
By the time postinstall runs, npm has already swapped `node_modules` — the old version's file
list is simply gone. Recorded here so a future implementer does not re-propose it.

---

## 5. Manual cleanup — `jenga doctor` / `jenga clean`

### The gap it closes

The manifest mechanism in §3 is purely forward-looking: a consumer already installed *before*
any manifest existed takes the `no-prior-manifest` branch on their first run of a fixed version,
and the manifest that run writes records only what that one run mirrored. Pre-existing orphans —
for example the `j:`-separator-form skill files retired by `E50_S07`, or the `j-<name>` twins
excluded by `E50_S06` — were never in that first manifest, so they can never become deletion
candidates on any future upgrade through the manifest path alone (§4 above closes this
automatically for future releases). `jenga doctor` is the manual remedy that works *today*, for
any consumer already stuck with orphans on a version older than §4's fix, and for any other cause
of mirror drift — a hand-copied file, an interrupted install, a manually deleted manifest.

### What it scans

Run from the consumer project root:

```bash
jenga doctor              # scan and, on confirmation, clean up
jenga doctor --dry-run    # preview only, never prompts or deletes
jenga clean                # identical command, alternate name
```

For each of `.agents/` and `.claude/` present in the project, it looks for files that **look
package-owned** but are absent from **both** the currently-installed package's own `skills/` /
`agents/` tree **and** that root's `.jenga-postinstall-manifest.json` (manifest-listed paths
already self-heal through the normal postinstall path, so they are deliberately excluded here to
avoid surfacing the same file through two different mechanisms).

### The "looks package-owned" heuristic — and its false-positive posture

Unlike §3's manifest diff, there is no provenance guarantee to lean on here — this command exists
specifically for paths a manifest never recorded. Eligibility is therefore decided by a heuristic:

- A top-level directory under `skills/` is a candidate only if it is **not** one of the
  currently-installed package's own skill directories, **and** its `SKILL.md` (if present) has
  frontmatter whose `name:` matches `/^j[.:]/i` — the same anti-masquerading prefix regex
  `lib/generate-skill-allow-list.js` already uses to recognise a genuine Jenga skill identifier.
  Every regular file inside a confirmed candidate directory is swept together as one group.
- A top-level `.md` file directly under `agents/` is a candidate if its name does not match one
  of the currently-installed package's own agent files.
- A directory the package currently ships is **never** inspected file-by-file — this is what lets
  a consumer's own extra file living inside an otherwise-current package skill directory survive
  untouched, without a separate special case.

**Known false positives, accepted deliberately:** a consumer's own `SKILL.md` that happens to
declare `name: j.<something>` frontmatter, or a consumer's own hand-dropped `.md` file placed
directly under `agents/`, would be misclassified as package-owned. This is why the confirmation
step below is load-bearing, not a convenience.

### Preview, confirm, and the non-interactive rule

The candidate list — grouped by mirror root, with a total count — is always printed before any
action. Nothing is ever deleted without an explicit interactive "yes":

- `--dry-run` prints the candidate list and exits without prompting or deleting.
- If stdin is not a TTY (e.g. piped input, a CI job, an agent-driven non-interactive session),
  the command prints the candidate list and exits **without prompting or deleting**, even if the
  piped input would otherwise read as an affirmative answer. It directs the user to re-run
  interactively.
- Declining the interactive prompt deletes nothing.
- Deletion re-uses the exact boundary and type checks §3's delete pass uses: every candidate must
  resolve strictly inside its mirror root, must be a regular file (`lstat`, symlinks refused, not
  followed), and directories are only ever pruned once genuinely empty — never deleted directly.
- After a successful clean, the manifest is left untouched: nothing this command removes was ever
  a manifest entry to begin with (manifest-listed paths are excluded from candidates), so there is
  nothing stale left behind in it.

---

## 6. Verification

`scripts/verify-postinstall-reconcile.sh` rehearses the whole §2–§3 path against a throwaway
fixture consumer project. It creates its own fixture root via `mktemp -d`, takes no path
argument, and reads/writes/deletes only inside it — it cannot touch a real project.

```bash
bash scripts/verify-postinstall-reconcile.sh      # KEEP_FIXTURE=1 to inspect afterwards
```

It asserts, across four scenarios: first install performs no deletes and preserves
pre-existing consumer files; an upgrade across a rename plus a twin exclusion removes stale
files from both mirror roots while a consumer's custom skill and a consumer note planted
inside an otherwise-emptied package directory both survive; a file common to both versions
keeps its inode and mtime (not needlessly deleted and recopied); a same-version re-run
short-circuits; and adversarial manifests (traversal, symlink, directory-where-file-expected,
corrupt JSON, unknown version) are all refused without preventing legitimate cleanup.

`scripts/verify-legacy-seed-reconcile.sh` rehearses §4's legacy-path seeding the same way, kept
as a separate script so the harness above stays untouched:

```bash
bash scripts/verify-legacy-seed-reconcile.sh      # KEEP_FIXTURE=1 to inspect afterwards
```

It asserts: a pre-manifest orphan is cleaned up on the very first run (adopt-then-reconcile) while
a consumer-authored sibling and its directory survive; a genuine first-ever install stays purely
additive regardless of what the legacy list contains; a legacy-listed path still currently shipped
is never touched; a legacy-listed path absent from disk is never phantom-seeded; a traversal entry
and a symlink entry in the legacy list are refused exactly like a manifest-based candidate; and a
consumer with a real prior manifest reconciles via the normal §3 path, unaffected by seeding.

`tests/postinstall-doctor-cleanup.bats` covers §5's `jenga doctor` / `jenga clean` command
directly: candidate detection (orphan found, current package files and consumer files spared),
`--dry-run`, the real non-TTY refusal via the actual CLI, confirmed deletion with directory
pruning, decline, the empty-candidate-list path, and symlink refusal — against a throwaway
`$BATS_TEST_TMPDIR` fixture, never this repository's own `.agents`/`.claude`.

`tests/postinstall-legacy-seed.bats` drives `scripts/verify-legacy-seed-reconcile.sh` the same way
`tests/postinstall-delete-reconciliation.bats` drives §3's harness, asserting each named check
individually.

A separate, one-off hybrid-tree rehearsal (not part of the repeatable bats suite, performed once
during this task's own manual verification) built a real `@jenga-ai/agent@3.0.0` tarball pulled
via `npm pack`, overlaid this task's modified files on top of the *extracted tarball tree* — not
this repo's own working checkout, which still carries `skills/do/` as private pre-mirror source
and would mask the exact bug this mechanism fixes — and ran the overlaid `postinstall.js` against
a fixture consumer seeded with a `2.0.0`-era `.jenga-version` and a real orphan
(`.agents/skills/do/SKILL.md`). Confirmed the orphan was removed and a planted consumer file
survived. See `project/documentation/summaries/E26_S08_T03-summary.md` for the transcript.

---

## Reference

| Path | Role |
|---|---|
| `scripts/postinstall.js` | Consumer install hook; version gate, mirror, cleanup, manifest, seeding. |
| `lib/mirror.js` | Shared copy helper. `reconcileDeletes` stays `false` on the consumer path. |
| `lib/postinstall-manifest.js` | Manifest read/write, provenance-scoped delete pass, legacy-path seeding. |
| `scripts/generate-legacy-shipped-paths.js` | Generates `lib/legacy-shipped-paths.json` (bootstrap + incremental). |
| `lib/legacy-shipped-paths.json` | Static list of paths known to have shipped in a prior published version. |
| `lib/commands/doctor.js` | `jenga doctor` / `jenga clean` — manual, interactive orphan cleanup. |
| `scripts/verify-postinstall-reconcile.sh` | Fixture rehearsal harness (manifest-based path, §3). |
| `scripts/verify-legacy-seed-reconcile.sh` | Fixture rehearsal harness (legacy-path seeding, §4). |
| `tests/postinstall-doctor-cleanup.bats` | Automated coverage for `jenga doctor` / `jenga clean`. |
| `tests/postinstall-legacy-seed.bats` | Automated coverage for legacy-path seeding. |
| `<consumer>/.jenga-version` | Last installed version; drives the upgrade gate. |
| `<consumer>/.{agents,claude}/.jenga-postinstall-manifest.json` | Per-root provenance record. |

Board provenance: `E26` (NPM-Compatible Distribution) owns the consumer install path;
`E26_S08` / `E26_S08_T01` added the manifest mechanism, `E26_S08_T02` added `jenga doctor` as the
manual stopgap for pre-manifest and other drift, `E26_S08_T03` added legacy-path seeding as the
permanent automatic fix for the same pre-manifest gap. `E27` owns `j.self-sync` and explicitly
scopes out consumer install behaviour.
