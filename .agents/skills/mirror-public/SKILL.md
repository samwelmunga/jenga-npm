---
name: mirror-public
description: Mirror this private repo one-way to its public counterpart (`https://github.com/samwelmunga/jenga-npm`), applying a `.publicignore` blocklist and producing a single squash commit per run so private board, queue, log, and rapport artefacts never leak downstream.
keywords:
  - mirror public
  - public mirror
  - jenga-npm
  - one-way sync
  - publicignore
  - squash mirror
examples:
  - "/mirror-public --dry-run"
  - "/mirror-public"
  - "/mirror-public --force"
  - "preview what would ship to the public repo"
  - "sync the public mirror"
---

# Mirror-Public

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
| `/mirror-public` | Real run. Fetches the public tip, runs the safety check, rsyncs, squash-commits, pushes. Aborts if the public repo is ahead of the last mirror marker. |
| `/mirror-public --force` | Same as the real run, but overrides the safety abort — the public branch is force-updated to match private (blocklist applied). Use only for recovery; see [Recovery flow](#recovery-when-the-public-repo-is-ahead). |

All three delegate to `skills/mirror-public/scripts/mirror.sh`. This SKILL body never inlines mirror logic — everything lives in the script.

### How it is actually run

```bash
# preview
bash skills/mirror-public/scripts/mirror.sh --dry-run

# real run
bash skills/mirror-public/scripts/mirror.sh

# force overwrite when the public repo is ahead
bash skills/mirror-public/scripts/mirror.sh --force
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

Edit `.publicignore` and add the path(s). Rules:

- **Over-block, don't under-block.** Anything missed is a private leak; anything extra is merely an unshipped file.
- **Verify with `--dry-run` before pushing.** The dry-run "Files that would ship" section is the honest answer to "did my new pattern match?".
- Directory-globs must end in `/` (e.g. `project/scratch/`), otherwise rsync only matches a file of that exact name.

## Config — `skills/mirror-public/assets/config.json`

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

- **Tag missing** (first ever run, or scratch clone was wiped): proceed.
- **Tag matches remote tip:** proceed — the public repo has not moved since our last mirror.
- **Tag lags remote tip:** the public repo has commits the mirror did not create. **Abort with a non-zero exit** unless `--force` is passed.

`--force` skips the abort and overwrites the public branch with the private state (post-blocklist). It is a **destructive-by-default** flag: any commit that landed on the public repo outside this skill will disappear from the public branch. Rescue that work first (see [Recovery flow](#recovery-when-the-public-repo-is-ahead)) before using `--force`.

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
bash skills/mirror-public/scripts/mirror.sh --dry-run
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

### Real run

```bash
bash skills/mirror-public/scripts/mirror.sh
```

Tail of the output (first mirror against a fresh remote):

```
mirror.sh: no last-mirror-sync tag found (first mirror or wiped scratch) — proceeding
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
bash skills/mirror-public/scripts/mirror.sh --force
```

Look for the WARNING line — it names the divergent SHAs so you can verify you meant to overwrite them:

```
mirror.sh: WARNING: origin/main (7524425...) has moved past last-mirror-sync (b955ae3...); proceeding due to --force
mirror.sh: rsync ...
mirror.sh: pushing 154f7b7... -> origin/main
```

### Recovery when the public repo is ahead

If the safety abort fires:

```
mirror.sh: error: origin/main (<remote-sha>) has moved past last-mirror-sync (<marker-sha>).
The public repo has commits the mirror did not create. Re-run with --force to overwrite.
```

Do this before you reach for `--force`:

1. **Inspect the divergent commits.** In a separate clone of the public repo:
   ```bash
   git clone https://github.com/samwelmunga/jenga-npm.git /tmp/jenga-npm-rescue
   git -C /tmp/jenga-npm-rescue log <marker-sha>..origin/main
   ```
2. **Decide what to keep.** For each divergent commit that has value:
   - If the change belongs in the private repo, port it into this repo (as a regular commit under normal review) so the next mirror carries it forward.
   - If the change should live only on the public repo, save the patches somewhere durable (`git format-patch <marker-sha>..origin/main -o /tmp/rescue-patches`) — they will not survive `--force`.
3. **Re-run with `--force`** once you are confident the public branch can be overwritten:
   ```bash
   bash skills/mirror-public/scripts/mirror.sh --force
   ```

The marker tag advances on success, and subsequent normal runs resume the abort-by-default behaviour.

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

- **Never inline mirror logic in this SKILL body.** All filesystem, git, rsync, and push work goes through `skills/mirror-public/scripts/mirror.sh`.
- **Never push to `jenga-npm.git` from an ad-hoc script.** Only this skill should push. Ad-hoc pushes bypass the blocklist and the safety marker.
- **Never commit `.mirror-worktrees/`.** It is already in `.publicignore` and should also stay untracked in the private repo. If you see it in `git status`, the scratch clone was accidentally seeded outside the configured path — investigate before mirroring.
- **Never `git add` `.publicignore` matches on the private side to "hide" them from the mirror.** The private repo tracks whatever it needs to; the blocklist is the single filter and must remain the single filter.
