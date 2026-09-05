---
name: j:j-mirror-public
description: Polyfill alias of the mirror-public skill under a collision-safe directory name. Identical behavior to /mirror-public — Mirror this private repo one-way to its public counterpart (`https://github.com/samwelmunga/jenga-npm`), applying a `.publicignore` blocklist and producing a single squash commit per run so private board, queue, log, and rapport artefacts never leak downstream. Use when the bare /mirror-public form is shadowed by another tool's own built-in command of the same name.
keywords:
  - mirror public
  - public mirror
  - jenga-npm
  - one-way sync
  - publicignore
  - squash mirror
  - j-mirror-public
  - polyfill
examples:
  - "/mirror-public --dry-run"
  - "/mirror-public"
  - "/mirror-public --force"
  - "preview what would ship to the public repo"
  - "sync the public mirror"
  - "j-mirror-public"
---

# Mirror-Public

This skill is a literal-directory-name duplicate of `skills/mirror-public/`. It exists so that `/j-mirror-public` (and `j:j-mirror-public`) give a guaranteed-unshadowed way to reach the same flow as `/mirror-public`, even if a host tool's own built-in command of the same name would otherwise shadow or override the bare `/mirror-public` alias (Claude Code's native skill resolution is a literal-string, directory-name-based match — see `docs/skill-authoring.md`'s "Invocation Convention").

This file is generated/synced by `scripts/generate-j-alias.sh mirror-public` from `skills/mirror-public/SKILL.md` — do not hand-edit it; re-run the generator instead to pick up source changes.

Push a curated subset of this private repo to the public counterpart at `https://github.com/samwelmunga/jenga-npm` as a **one-way**, **squash-committed** mirror. Private is always the source of truth; the public repo is a downstream shadow that this skill can rebuild at any time.

Distinct from `/publish` (which ships the `jenga-agent` npm package to npmjs.com) and from `/self-sync` (which mirrors root → in-repo `.claude/.agents/`). This skill is the third distribution surface: the public GitHub repo.

## Direction & Contract

- **Direction:** private → public, one-way. Public never merges back. If a public commit exists that this skill did not create, the run aborts by default (see [Safety](#safety-model)).
- **Trigger:** manual only. There is no CI hook, no git hook, no on-commit automation. The risk of leaking WIP outweighs the convenience.
- **Commit model:** each real run produces exactly **one squash commit** on the public side. Private commit messages, authors, and history never appear on the public repo.
- **Scope model:** ships everything **except** what `.publicignore` blocks. Additive-by-default; the blocklist is the single source of truth for what stays private.

## Invocation

| Command | Effect |
|---------|--------|
| `/mirror-public --dry-run` | Read-only preview. Prints the exact "would ship" and "would be blocked" file lists plus totals. No fetch-write, no commit, no push. |
| `/mirror-public --inventory` | Read-only preview. Prints the identical "would ship" set as `--dry-run`, grouped into feature-type categories (Skills, MCP, Agents, Hooks, Scripts, Templates, Docs, Other) with a per-category count and a grand total. Same safety class as `--dry-run` — no fetch-write beyond the scratch worktree refresh, no commit, no push. Mutually exclusive with `--dry-run`. |
| `/mirror-public --exclude <path>` | Purely local. Appends `<path>` to the repo-root `.publicignore` as a new line, idempotently (no duplicate if the pattern already exists), and exits. Never loads config, never prepares the scratch worktree, never fetches, never runs the safety check, never mirrors. Requires a non-empty argument — missing or empty-string is a non-zero-exit error. Cannot be combined with `--dry-run`, `--inventory`, or `--force`. |
| `/mirror-public` | Real run. Fetches the public tip, runs the safety check, verifies the [publish-config invariant](#publish-config-invariant), rsyncs, squash-commits, pushes. Aborts if the public repo is ahead of the last mirror marker — unless the entire divergence is an ordinary `/publish` version bump, which [auto-reconciles](#version-only-auto-reconciliation) with no `--force` needed — or if the push would break the publish contract. |
| `/mirror-public --force` | Same as the real run, but overrides the safety abort — the public branch is force-updated to match private (blocklist applied). Before mutating anything it enumerates what will be lost and requires explicit confirmation (see [Enumeration and confirmation](#--force-enumeration-and-confirmation)); once confirmed, it pushes a [pre-force rescue tag](#pre-force-rescue-tag) to the pre-overwrite tip before anything else; the [publish-config invariant](#publish-config-invariant) check still applies before any mutation. Use only for recovery; see [Recovery flow](#recovery-when-the-public-repo-is-ahead). |
| `/mirror-public --force --yes` | Same as `--force`, but supplies explicit non-interactive approval so the confirmation prompt is skipped after the enumeration is printed. Required when running `--force` from a non-interactive shell — see below. |

All six delegate to `skills/j-mirror-public/scripts/mirror.sh`. This SKILL body never inlines mirror logic — everything lives in the script.

### How it is actually run

```bash
# preview
bash skills/j-mirror-public/scripts/mirror.sh --dry-run

# categorized feature inventory (also read-only)
bash skills/j-mirror-public/scripts/mirror.sh --inventory

# add a blocklist entry (purely local — no fetch, no mirror)
bash skills/j-mirror-public/scripts/mirror.sh --exclude <path>

# real run
bash skills/j-mirror-public/scripts/mirror.sh

# force overwrite when the public repo is ahead
bash skills/j-mirror-public/scripts/mirror.sh --force
```

## Blocklist — `.publicignore`

`.publicignore` lives at the **repo root** (discoverable like `.gitignore`). It is a `.gitignore`-style pattern file consumed by `rsync --exclude-from=<repo-root>/.publicignore`. Every line is a path relative to the repo root that MUST NEVER ship to the public mirror.

Current baseline (see the file for the authoritative list) blocks:

- `project/board/`, `project/queue/`, `project/logs/`, `project/rapports/`, `project/todo.md`
- `project/documentation/plans/`, `project/documentation/summaries/`, `project/instructions/`
- `.env`, `.env.*`, `*.local`, `*.pid`, `.claude/settings.local.json`
- `.claude/worktrees/`, `.agents/worktrees/`, `.mirror-worktrees/`
- `node_modules/`, `**/__pycache__/`, `*.pyc`, `.DS_Store`, `.git/`

### Adding new entries

Two supported ways to add a blocklist entry:

1. **`--exclude <path>` (recommended).** Appends `<path>` to `.publicignore` for you, idempotently — running it again with the same pattern is a no-op, not a duplicate line:
   ```bash
   bash skills/j-mirror-public/scripts/mirror.sh --exclude project/scratch/
   ```
   This is purely local (no fetch, no scratch worktree, no mirror) and prints a reminder to verify with `--dry-run` or `--inventory` afterward.
2. **Manual edit.** Edit `.publicignore` directly and add the path(s) yourself.

Rules apply to both methods:

- **Over-block, don't under-block.** Anything missed is a private leak; anything extra is merely an unshipped file.
- **Verify with `--dry-run` before pushing.** The dry-run "Files that would ship" section is the honest answer to "did my new pattern match?".
- Directory-globs must end in `/` (e.g. `project/scratch/`), otherwise rsync only matches a file of that exact name.

## Config — `skills/j-mirror-public/assets/config.json`

```json
{
  "publicRepoUrl": "https://github.com/samwelmunga/jenga-npm.git",
  "defaultBranch": "main",
  "worktreePath": ".mirror-worktrees/public"
}
```

| Field | Purpose |
|-------|---------|
| `publicRepoUrl` | URL of the public downstream repo. Can be overridden at runtime by `MIRROR_PUBLIC_URL_OVERRIDE` (used by tests and by anyone rehearsing against a local bare remote). |
| `defaultBranch` | Branch mirrored on the public side. `main` in production. |
| `worktreePath` | Relative path (from the private repo root) where the script keeps its scratch clone of the public repo. Blocked from itself via `.publicignore` (`.mirror-worktrees/`). |

## Safety model

The script maintains a **local `last-mirror-sync` tag** inside its scratch clone that records the public SHA it last produced. Before every real run it compares that tag to the current tip of `origin/<defaultBranch>`:

- **Tag missing, remote has no commits yet:** genuine first-run bootstrap against a brand-new public repo. Proceed with no ceremony.
- **Tag missing, remote already has commits:** **abort with a non-zero exit** unless `--force` is passed (see [Marker durability](#marker-durability) below).
- **Tag matches remote tip:** proceed — the public repo has not moved since our last mirror.
- **Tag lags remote tip:** the public repo has commits the mirror did not create. First checked against the narrow [version-only auto-reconciliation](#version-only-auto-reconciliation) case below — an ordinary `/publish` version bump auto-resolves with no `--force` needed. Anything else: **abort with a non-zero exit** unless `--force` is passed.

`--force` skips the abort and overwrites the public branch with the private state (post-blocklist). It is a **destructive-by-default** flag: any commit that landed on the public repo outside this skill will disappear from the public branch. As of T05, `--force` no longer relies on rescue being a separate manual step you might forget — it pushes a [pre-force rescue tag](#pre-force-rescue-tag) to the remote itself before any overwrite happens, so the discarded state is always recoverable from the public repo directly. Still worth inspecting what's about to be lost first (see [Recovery flow](#recovery-when-the-public-repo-is-ahead)) before using `--force`.

### Marker durability

`last-mirror-sync` is a **local git tag, scoped entirely to the scratch clone** at `.mirror-worktrees/public` (path from `config.json`'s `worktreePath`). It is created/advanced only as the last step of a successful real run and is **never pushed** to the public remote — nothing about it exists anywhere except that one local clone.

That has a consequence: `.mirror-worktrees/` is both **gitignored** and itself a **`.publicignore` entry**, which makes it exactly the kind of directory that looks safe to delete while tidying up (`rm -rf .mirror-worktrees/`, a `git gc` that prunes an orphaned worktree, a disk-cleanup script). Before T06, wiping it silently disabled the entire divergence check: a missing marker was unconditionally read as "first mirror" regardless of whether the public repo already had history, so the very next run would overwrite an established public branch with **no `--force`, no warning, no enumeration** — the same failure mode as the 2026-08-28 incident, just reached through a different door (accidental deletion instead of a mistaken `--force` claim).

The fix distinguishes what a missing marker actually means by checking the one thing that's still true regardless of what happened to the scratch clone — the real state of `origin/<defaultBranch>`:

- **Missing marker + empty public repo** (no commits at all yet): this is what "first mirror" is actually supposed to look like. Proceeds without ceremony.
- **Missing marker + non-empty public repo**: indistinguishable from "the scratch clone was wiped" (or, equivalently, "you pointed this at a public repo that already has content the mirror never produced"). **Aborts by default**, naming the current public tip. `--force` remains the documented override — it reuses the identical enumeration + confirmation + [pre-force rescue tag](#pre-force-rescue-tag) flow described in [`--force` enumeration and confirmation](#--force-enumeration-and-confirmation), just without a known-safe marker SHA to diff the commit list from, so the "what's about to be overwritten" section shows the public branch's full history instead of a `marker..remote` range.

No relocation of the marker outside the scratch clone was needed to close this hole — checking the *actual* remote state directly (rather than trusting local state that can silently vanish) is the fix, not moving the same single point of failure to a different local file. There is nothing about `last-mirror-sync` to add to `.publicignore`: it was never a file that could ship (it is a git ref inside a directory the blocklist already excludes wholesale), and that remains true after this change.

### Version-only auto-reconciliation

`/publish` runs from the **public** repo (`jenga-npm`) — its npm-ci workflow bumps `package.json`/`package-lock.json`'s `.version` field and commits directly to public `main` as part of every release. That is an ordinary, expected public-side commit, but before this section's fix it still tripped the marker-vs-remote abort above: two routine publish bumps (`1.1.0` → `1.1.1` → `1.2.0`) each forced a manual "notice drift → hand-bump private → `--force --yes`" cycle, even though nothing was actually at risk of being lost — the content was already reconciled by the manual bump, `--force`'s destructive machinery (enumeration, `destroy` confirmation, rescue tag) was firing for a divergence that was provably safe the whole time.

The fix: when the marker is present but `origin/<defaultBranch>` has moved past it, before falling into the `--force`/abort fork, the script checks whether the **entire** `marker..remote` divergence is version-only. This is a narrow, precisely-defined check, not a heuristic:

- The set of files that differ between the marker commit and the remote tip must be **exactly** `package.json` and/or `package-lock.json` — a subset of one (e.g. only `package.json` changed) still counts, but **any other file touched at all disqualifies the whole divergence**, even if the version bump is also present.
- Within each of those two files, the **only** changed value must be a version field — `package.json`'s top-level `.version`, and `package-lock.json`'s top-level `.version` **and** `.packages[""].version` (npm v7+'s root-package entry). Any other field change — name, dependencies, `lockfileVersion`, anything — disqualifies it, again even alongside a genuine version bump.
- A `marker..remote` range with **zero** file-level difference at all (private's version already matches public's tip exactly) counts as version-only too, trivially — there's nothing to reconcile, but it's still "safe," not "abort."

The comparison is field-level, not textual: both revisions of each candidate file are parsed and compared with their version field(s) stripped out, so a version bump that happens to also touch unrelated whitespace/formatting in the same file would (correctly) still disqualify if that formatting change altered any other field's value — but would NOT falsely disqualify on formatting alone if every non-version field is genuinely unchanged.

**On a positive detection:** the version is applied to `$REPO_ROOT/package.json`/`package-lock.json` (same two-field scope as the check itself — nothing else in either file is touched) and, if that produces an actual working-tree diff, committed to private's **current branch** (whatever branch is checked out when the script runs — it never switches branches) with a message identifying it as an auto-reconciliation:

```
chore(mirror-public): auto-reconcile version drift to <version> from public <short-sha>

Public-Commits: <sha1>,<sha2>,...
```

If private already matched (the degenerate case), no commit is made — there's nothing to commit — but the divergence is still treated as resolved. Either way, the run then proceeds directly into the normal push path: **no `--force`, no `destroy` confirmation.** The reconciliation itself is the proof that nothing is being destroyed, which is exactly the property `--force`'s enumeration/confirmation exists to establish for divergences that *aren't* provably safe.

**A load-bearing nuance:** because the reconciliation step's whole purpose is to make private's version fields match public's, the subsequent rsync diff is usually empty — there's nothing left to transfer. That means a version-only-reconciled run almost always lands on the pre-existing "nothing to mirror" idempotency fast-exit, which historically returned *before* the marker-tag-advance step further down the script. Left alone, the local marker would never move for a reconciled run, and every subsequent invocation would re-detect and re-process the identical already-resolved divergence forever. The fast-exit now advances the local marker to the remote tip whenever the run took the auto-reconcile branch, even though there's nothing to push — the marker is purely local bookkeeping (see [Marker durability](#marker-durability) above), so this is a no-op from the public repo's point of view.

**Everything else is unchanged.** Any divergence that doesn't positively classify as version-only — a mixed bump-plus-other-file-change, a non-version field edit, a whole unrelated commit — falls through to exactly the same `--force`/abort behavior described above, byte-for-byte. This mechanism only ever *widens* what proceeds automatically for a provably-safe case; it does not weaken, bypass, or change `--force`'s enumeration, confirmation, or [pre-force rescue tag](#pre-force-rescue-tag) behavior for anything else.

### `--force` enumeration and confirmation

`--force` used to report only *that* the public repo had moved (two SHAs in a WARNING line) — never *what* moving would destroy. That gap let a `--force` run on 2026-08-28 proceed on an incorrect one-commit claim when seven commits had actually diverged, silently deleting `publish.json` and `.github/workflows/npm-publish.yml` — both unmirrored public-side work — along with the rest. `--force` now enumerates before it mutates anything:

1. **Divergent commit list.** The full `marker..remote` range via `git log --oneline`, with a count, so the person running `--force` can see exactly what history is about to be overwritten instead of trusting a claim about it.
2. **Public-only file signature.** Every file that exists on the public worktree, is **not** matched by `.publicignore`, and is **absent from private** — printed with a count and an explicit "THESE N FILE(S) WILL BE DELETED" statement. This is the signature of unmirrored public-side work (exactly the set `publish.json` and the npm-publish workflow file were both in on 2026-08-28). **Blocklisted paths are deliberately excluded** from this set: the routine `--delete-excluded` purge touches hundreds of files on every run, and mixing those into the enumeration would drown the genuine-work signal in noise.

Then it requires explicit confirmation before proceeding to the rsync overwrite, commit, and push:

- **Interactive shell:** prompts for a typed `destroy` confirmation at `/dev/tty`. Anything else (including empty input) aborts with a non-zero exit and performs no further mutation — no rsync overwrite, no commit, no push.
- **Non-interactive shell:** refuses by default — `--force` alone is not enough outside a TTY. Pass **`--force --yes`** to supply explicit non-interactive approval (e.g. for scripted recovery or for rehearsal against a local bare remote via `MIRROR_PUBLIC_URL_OVERRIDE`). There is no flag that makes a non-interactive run proceed *without* having printed the enumeration first — `--yes` only skips the interactive prompt, never the enumeration itself.

### Pre-force rescue tag

Recovery from the 2026-08-28 incident worked only because the local scratch clone (`.mirror-worktrees/`) still held the seven discarded commits — and that clone is both gitignored and itself a `.publicignore` entry, so a `git gc` or a wiped scratch directory would have made the loss permanent. That was luck, not a safety property.

The instant confirmation succeeds — before the [publish-config invariant](#publish-config-invariant) check, before any rsync overwrite, commit, or push — `--force` pushes a lightweight tag to the **public remote itself**, pointing at the pre-overwrite tip (`origin/<defaultBranch>` as it stood before this run touched it):

- **Name:** `pre-force-<short-sha>`, where `<short-sha>` is the first 12 characters of the pre-overwrite tip's commit SHA.
- **Collision-safe.** If the same tip is force-overwritten more than once (so the base name is already taken on the remote), the script probes the remote first and walks numeric suffixes — `pre-force-<short-sha>-2`, `-3`, and so on — until it finds a name that isn't already there, rather than assuming the base name is free.
- **Fails closed.** If the tag push itself fails, the run aborts immediately (no rsync overwrite, no commit, no push) and the local tag is removed so no dangling ref is left behind. `--force` can never overwrite the public branch without first placing a recovery point on the remote.
- **Scoped to `--force` only.** Ordinary (non-`--force`) runs never create or push this tag.
- **Named in the summary.** A completed `--force` run's final summary block includes a `rescue tag` line, so the tag name is visible without scrolling back through the run's output.

Recovering from a rescue tag needs nothing beyond a normal clone of the public repo — see [Recovery flow](#recovery-when-the-public-repo-is-ahead).

### Publish-config invariant

Publishing runs from the **public** repo, so this mirror is the only path by which `publish.json` (and everything it points at) reaches the place `/publish` actually executes. Before **any** real push — plain or `--force`, both of which reach this same check — the script verifies the ship set it is about to push won't silently break the publish contract. This is what caught (in hindsight) the other half of the 2026-08-28 incident: the same `--force` run that deleted the two files above also reverted the `@jenga-ai/agent` package name, and nothing noticed until an agent ran `/publish` afterwards.

The check, `check_publish_invariant`, runs against `compute_full_ship_set` — the **full resulting set** of files that will exist post-sync (not `compute_ship_list`'s transfer diff, which `--dry-run`/`--inventory` use for their own preview reporting). This distinction matters: a `publish.json`-referenced path that is content-identical between private and the scratch worktree never appears in a transfer diff (rsync correctly has nothing to send), but it IS, and will remain, present in the ship set — checking against the diff alone used to false-positive an abort on exactly this case (e.g. an unchanged `project/logs/publish-history.json`). `compute_full_ship_set` reuses the identical rsync + `.publicignore` filter engine as every other set computation in this file — never an independent, hand-rolled derivation — just queried in "list everything non-excluded" mode instead of "list what changed" mode. It aborts non-zero, before any rsync write/commit/push, if:

- `package.json`'s `.name` disagrees with any `publish.json` target's `npm.package_name` — names both values.
- An `npm-ci` target's `workflow_path` (or the schema default, `.github/workflows/npm-publish.yml`, when the target omits it) is absent from the ship set — names the missing path, and the `.publicignore` line responsible if the script can identify one.
- `publish.json`'s `.defaults.history_file` is absent from the ship set — same naming behavior.

If `publish.json` does not exist at the repo root, this is a **clean no-op** — not every mirrored repo carries an npm-ci publish target. A *present but broken* `publish.json` (e.g. missing `.defaults.history_file`) still fails closed, since that is exactly the kind of silently-shipped inconsistency this check exists to catch.

## Squash-commit model

Every real run creates exactly one commit on the public branch:

```
chore(mirror): sync from private at <short-sha> <UTC-timestamp>

Source-Commit: <full-private-sha>
```

- **Subject** identifies the private HEAD at the time of the mirror.
- **`Source-Commit:` trailer** carries the full private SHA so anyone reading the public commit can cross-reference (against a private clone they have access to) which private state produced this snapshot.
- **No private log leaks.** Individual private commits, author names, and messages are never replayed on the public side.
- **Idempotent.** If the working tree matches the public tip post-blocklist, the script exits without creating a commit and prints `nothing to mirror — public tree already matches private (post-blocklist)`.

## Examples

All example outputs below were captured against a local bare remote (`/tmp/mirror-t04-test.git`) using `MIRROR_PUBLIC_URL_OVERRIDE`, so the same shape reproduces without touching the real `jenga-npm.git`.

### Dry-run

```bash
bash skills/j-mirror-public/scripts/mirror.sh --dry-run
```

Tail of the output:

```
=== Files that would ship (607) ===
...
=== Files that would be blocked (599) ===
project/board/...
project/queue/...
project/logs/...
project/rapports/...
project/todo.md
...

================ mirror-public dry-run summary ================
would ship    : 607 files
would block   : 599 files
public URL    : https://github.com/samwelmunga/jenga-npm.git
remote branch : main
dry run — no push, no commit, no remote mutation
===============================================================
```

Zero remote mutation. Use this before every real run when the mirror state is uncertain, and after every `.publicignore` edit to confirm the pattern matched.

### Inventory

```bash
bash skills/j-mirror-public/scripts/mirror.sh --inventory
```

Computes the exact same "would ship" set as `--dry-run` (same underlying `compute_ship_list` function — never re-derived), then groups it by top-level feature-type category and prints a per-category file list, count, and grand total. Report layout is defined by `skills/j-mirror-public/assets/inventory-template.md`, not inlined in this SKILL or in the script.

Tail of the output:

```
### Docs (6)
docs/skill-authoring.md
...

### Other (156)
project/PROJECT_SUMMARY.md
...

================ mirror-public inventory summary ================
Skills        : 353
MCP           : 42
Agents        : 21
Hooks         : 18
Scripts       : 48
Templates     : 45
Docs          : 6
Other         : 156
-------------------------------------------------------------------
grand total   : 689 files
public URL    : https://github.com/samwelmunga/jenga-npm.git
remote branch : main
read-only inventory — no push, no commit, no remote mutation
===================================================================
```

Each named category (Skills, MCP, Agents, Hooks, Scripts, Templates, Docs) matches both its canonical root directory (e.g. `skills/`) and its `/self-sync`-generated mirror copies under `.claude/` and `.agents/` (e.g. `.claude/skills/`, `.agents/skills/`) — those mirrors are file-for-file duplicates of the same feature-type content, and folding them in avoids the two mirror trees dominating an undifferentiated "Other" bucket. Anything that doesn't match a named category (root files, `project/`, `lib/`, `bin/`, etc.) falls into "Other".

Zero remote mutation, same safety class as `--dry-run` — no rsync write, no commit, no push.

### Real run

```bash
bash skills/j-mirror-public/scripts/mirror.sh
```

Tail of the output (first mirror against a fresh remote):

```
mirror.sh: no last-mirror-sync tag and no commits on origin/main yet — genuine first-run bootstrap, proceeding
mirror.sh: rsync <repo>/ -> <repo>/.mirror-worktrees/public/ (excludes: .publicignore + .git)
mirror.sh: pushing b955ae3380a5d562799b0e8a75bbb758f8773104 -> origin/main

================ mirror-public summary ================
files changed : 607
new commit    : b955ae3380a5d562799b0e8a75bbb758f8773104
remote branch : main
public URL    : https://github.com/samwelmunga/jenga-npm.git
=======================================================
```

A second consecutive run reports `nothing to mirror — public tree already matches private (post-blocklist)` and exits `0`.

### `--force`

Use only when the safety abort fires and you have already rescued any external work off the public branch.

```bash
bash skills/j-mirror-public/scripts/mirror.sh --force
```

Look for the WARNING line naming the divergent SHAs, then the enumeration that follows it — the divergent commit list and the public-only file signature that will be deleted — before any confirmation prompt appears:

```
mirror.sh: WARNING: origin/main (7524425...) has moved past last-mirror-sync (b955ae3...); proceeding due to --force

=== Divergent commits on public (b955ae338...​..7524425cf...), 7 commit(s) ===
7524425 add npm-publish.yml (public-only work)
c055d43 add publish.json (public-only work)
5a3271e public-side commit 6
9dfca64 public-side commit 5
3fc2e3f public-side commit 4
2106250 public-side commit 3
899ac0f public-side commit 1

=== Public-only files NOT in .publicignore and absent from private (2) ===
.github/workflows/npm-publish.yml
publish.json

THESE 2 FILE(S) WILL BE DELETED if you proceed — they exist only on public and are not blocklisted.

Type "destroy" to confirm --force will overwrite main and delete the file(s) listed above: destroy
mirror.sh: confirmed interactively — proceeding with --force
mirror.sh: pushing pre-force rescue tag pre-force-7524425cf1a2 -> origin (pre-overwrite tip 7524425cf1a2...)
mirror.sh: rescue tag pre-force-7524425cf1a2 pushed — pre-overwrite tip (7524425cf1a2...) is now recoverable from the remote independent of this scratch clone
mirror.sh: rsync ...
mirror.sh: pushing 154f7b7... -> origin/main

================ mirror-public summary ================
files changed : ...
new commit    : 154f7b7...
remote branch : main
public URL    : https://github.com/samwelmunga/jenga-npm.git
rescue tag    : pre-force-7524425cf1a2 (pre-overwrite tip, pushed to remote)
=======================================================
```

The tag lands on the remote *before* the rsync overwrite — confirmed by rehearsal against scratch `/tmp` bare remotes: checking out the rescue tag after a `--force` run recovers exactly the file(s) the overwrite discarded, and pointing a rehearsal remote at a read-only path (simulating a failed tag push) aborts the run before touching `main` at all, with no dangling tag left behind either.

Declining (anything other than `destroy`) aborts immediately with a non-zero exit and no further mutation — no rescue tag, no rsync overwrite, no commit, no push. From a non-interactive shell, `--force` alone refuses the same way; pass `--force --yes` to supply explicit approval after reviewing the enumeration (e.g. piped from a script, or rehearsing against a local bare remote):

```bash
bash skills/j-mirror-public/scripts/mirror.sh --force --yes
```

### Auto-reconcile

Simulating an ordinary `/publish` release landing on public (a version-only bump to `package.json`/`package-lock.json`, committed directly to `main` — exactly what the npm-ci workflow does), then running a normal (non-`--force`) real run against that same rehearsal remote:

```bash
bash skills/j-mirror-public/scripts/mirror.sh
```

```
mirror.sh: refreshing existing scratch worktree at .../mirror-worktrees/public
mirror.sh: origin/main (ffd9d1df4db9...) has moved past last-mirror-sync (3309ceff1afc...), but the divergence is version-only (package.json/package-lock.json .version field(s) only, detected version 1.2.2) — auto-reconciling into private, no --force needed
mirror.sh: auto-reconcile: committed version 1.2.2 to private (90acad416167...), sourced from public commit(s) ffd9d1d
mirror.sh: publish-invariant: package.json name agrees with publish.json; workflow_path + history_file present in ship set — OK
mirror.sh: rsync ...
mirror.sh: nothing to mirror — public tree already matches private (post-blocklist); advancing local last-mirror-sync marker to ffd9d1df4db9... since this run auto-reconciled version drift
```

No `--force`, no `destroy` prompt, no enumeration — the run proceeds straight through. Note the tail: because the reconciliation already made private's version fields match public's, the rsync diff is empty and the run lands on the ordinary "nothing to mirror" idempotency message — the local marker still advances, on the same line, because this run took the auto-reconcile branch (see the [load-bearing nuance](#version-only-auto-reconciliation) above). The private commit (`90acad4...` here) carries the `Public-Commits:` trailer naming which public commit introduced the drift.

If private already exactly matched public's tip before this run (nothing to actually reconcile — e.g. a manual bump already happened), the second line instead reads `auto-reconcile: private already matches public's version (<version>) — no commit needed`, and no reconciliation commit is created; everything else proceeds identically.

A **mixed** divergence — the same version bump landing alongside an unrelated file change, or any other field touched — does not match this path at all and falls straight through to the unchanged `--force`/abort behavior shown in the [`--force`](#--force) example above; the auto-reconcile log lines above never appear.

### Recovery when the public repo is ahead

If the safety abort fires:

```
mirror.sh: error: origin/main (<remote-sha>) has moved past last-mirror-sync (<marker-sha>).
The public repo has commits the mirror did not create. Re-run with --force to overwrite.
```

As of T05, recovery is no longer something you have to remember to do manually before running `--force` — the [pre-force rescue tag](#pre-force-rescue-tag) makes it automatic: the moment `--force`'s confirmation prompt is accepted, a `pre-force-<short-sha>` tag pointing at the pre-overwrite tip is pushed to the public remote, before anything is overwritten. The steps below are still worth doing to *decide* what (if anything) is worth keeping, but the tag means you are never gambling the only copy of that state on remembering to run them first.

**Primary path — recover from the rescue tag.** After a `--force` run, the discarded tip is sitting on the public remote under its rescue tag (named in the run's summary block, and discoverable any time via `git ls-remote --tags <public-repo-url> 'pre-force-*'`):

```bash
git clone https://github.com/samwelmunga/jenga-npm.git /tmp/jenga-npm-rescue
git -C /tmp/jenga-npm-rescue fetch origin 'refs/tags/pre-force-*:refs/tags/pre-force-*'
git -C /tmp/jenga-npm-rescue log <marker-sha>..pre-force-<short-sha>
git -C /tmp/jenga-npm-rescue checkout pre-force-<short-sha>
```

Nothing about this depends on the local scratch clone (`.mirror-worktrees/`) still existing — the whole point of T05 is that the recovery point lives on the remote, independent of that gitignored/blocklisted directory.

**Fallback path — manual inspection before `--force`, if you want to decide up front rather than recover after the fact.** This is the original flow and still works; it is retained as a fallback for cases where you want to make a keep/discard decision *before* running `--force` rather than recovering from the tag afterward:

1. **Inspect the divergent commits.** In a separate clone of the public repo:
   ```bash
   git clone https://github.com/samwelmunga/jenga-npm.git /tmp/jenga-npm-rescue
   git -C /tmp/jenga-npm-rescue log <marker-sha>..origin/main
   ```
2. **Decide what to keep.** For each divergent commit that has value:
   - If the change belongs in the private repo, port it into this repo (as a regular commit under normal review) so the next mirror carries it forward.
   - If the change should live only on the public repo, save the patches somewhere durable (`git format-patch <marker-sha>..origin/main -o /tmp/rescue-patches`) — this is now a belt-and-suspenders step, since the pre-force rescue tag already covers the same range, but it produces portable patch files rather than requiring a tag fetch.
3. **Re-run with `--force`** once you are confident the public branch can be overwritten:
   ```bash
   bash skills/j-mirror-public/scripts/mirror.sh --force
   ```

The marker tag advances on success, and subsequent normal runs resume the abort-by-default behaviour. Rescue tags are never deleted automatically by this script — clean up old `pre-force-*` tags manually once you've confirmed you no longer need them.

## Environment overrides

| Variable | Purpose |
|----------|---------|
| `MIRROR_PUBLIC_URL_OVERRIDE` | Replaces `publicRepoUrl` from `config.json` at runtime. Used to rehearse against a local bare remote (e.g. `git init --bare /tmp/test-mirror.git`) without touching the real public repo. |

## Out of Scope

Per epic **E28 — Public Mirror**, these are explicitly not part of this skill:

- **Two-way sync** (PR back-flow from public → private)
- **Content-level scrubbing** (regex redactions inside file bodies)
- **Automated triggers** (git hooks, CI, watch-mode)
- **Cross-linking issues/PRs** between the two repos

See `project/board/epics/E28_public-mirror.md` → *Out of Scope* for the authoritative list.

## Guard rails

- **Never inline mirror logic in this SKILL body.** All filesystem, git, rsync, and push work goes through `skills/j-mirror-public/scripts/mirror.sh`.
- **Never push to `jenga-npm.git` from an ad-hoc script.** Only this skill should push. Ad-hoc pushes bypass the blocklist and the safety marker.
- **Never commit `.mirror-worktrees/`.** It is already in `.publicignore` and should also stay untracked in the private repo. If you see it in `git status`, the scratch clone was accidentally seeded outside the configured path — investigate before mirroring.
- **Never `git add` `.publicignore` matches on the private side to "hide" them from the mirror.** The private repo tracks whatever it needs to; the blocklist is the single filter and must remain the single filter.
