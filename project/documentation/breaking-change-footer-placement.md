# Where the `BREAKING CHANGE` footer commit must live

Task `E91_S04_T01`, story `E91_S04`, epic `E91`. Research outcome that gates `E91_S04_T02` to `E91_S04_T04`.
Date: 2026-11-11 (UTC). Line numbers are those of the tree at commit `ba722f6d`.

Sources read: `skills/j-mirror-public/scripts/release-prep.sh` (below: `release-prep.sh`),
`project/.workflows/scripts/deploy-public-prep.sh` (`deploy-public-prep.sh`), `skills/j-mirror-public/SKILL.md`
(`SKILL.md`), `skills/j-publish/scripts/suggest_semver_bump.sh` (`suggest_semver_bump.sh`), and, because they decide the
answers, `skills/j-mirror-public/scripts/mirror.sh` (`mirror.sh`) and `skills/j-publish/scripts/publish_common.sh`
(`publish_common.sh`).

## Decision (one placement)

**A commit at the tip of the release branch, made after `create_branch` and before the `preview` / `mirror` steps, whose
message carries a `BREAKING CHANGE:` footer; and `mirror.sh` copies exactly that footer into the squash commit's
message.** Both halves are required. The release-branch commit alone does not reach the public history (question 1),
and a footer written only into the squash message leaves no private commit to detect, to make idempotent, or to read
the footer from.

| Item | Value |
|---|---|
| Ref | The release branch just built by `deploy-public-prep.sh create-branch`, `release/<version>-<YYYYMMDD>`. Never `main`. |
| Moment | After `create_branch` succeeds (branch checked out, tree clean) and before `preview`. It is the last commit on the branch before `mirror.sh` runs. |
| Commit subject | `chore(release): record breaking change for <vX.Y.Z>` |
| Commit footer | One line, last paragraph of the message: `BREAKING CHANGE: <reason>` |
| Content of the commit | The release's `CHANGELOG.md` entry and the record file, when they are not on the branch yet (see "Consequences for T02 and T03"); otherwise created with `--allow-empty`. |
| Squash message after the change | `chore(mirror): sync from private at <short> <ts>`, blank line, then one final paragraph: `BREAKING CHANGE: <reason>` followed by `Source-Commit: <full-sha>`. |

Exact message shape of the release-branch commit:

```
chore(release): record breaking change for v6.0.0

Epics: E72, E86, E21

BREAKING CHANGE: <the record's reason, whitespace-collapsed to one line>
```

Rules for the shape, all driven by the evidence below:

- The footer token is `BREAKING CHANGE: ` with a **space**. `suggest_semver_bump.sh:68` greps `BREAKING CHANGE`, so the
  hyphenated `BREAKING-CHANGE:` is not detected (verified, experiment 7).
- The reason is collapsed to a single line so that extracting it from the commit is a one-line match, not a paragraph
  parser. `git interpret-trailers --parse` does **not** recognise `BREAKING CHANGE:` (space in the token; experiment 6),
  so the extraction in `mirror.sh` must be a plain `sed`/`awk` on the message body, not a trailer call.
- The `Epics:` line stays in the private commit only. The hook copies the `BREAKING CHANGE:` line alone.
- No `!` in the subject. The footer is sufficient for `suggest_semver_bump.sh` (line 68 accepts either) and for
  conventional-commit tooling; a second marker is redundant.
- The reason is shipped twice (squash body and the CHANGELOG entry, which is not blocklisted), so it must be written as
  public text. The record is where it is authored; this task does not change that.

## The four questions

### 1. What does the public history receive per run, and from where does the message come?

Exactly one squash commit per real run, pushed with force to the **staging** branch, which CI later fast-forwards to the
default branch (`SKILL.md:36-37`; `mirror.sh:2455-2456`). The message is **composed by `mirror.sh`**, not taken from the
private commits:

- `mirror.sh:2413` subject `chore(mirror): sync from private at <short-sha> <UTC-ts>`; `mirror.sh:2414` single trailer
  `Source-Commit: <full-sha>` where the SHA is the private `HEAD` (`mirror.sh:2410`); committed at `mirror.sh:2424`
  with exactly those two `-m` paragraphs.
- The skill states it as a contract: "Private commit messages, authors, and history never appear on the public repo"
  (`SKILL.md:37`) and "Individual private commits, author names, and messages are never replayed on the public side"
  (`SKILL.md:335`).
- The working tree is what ships. `mirror.sh` rsyncs it and stages with `git add -A` (`mirror.sh:2383`); the commit
  step is skipped altogether when nothing differs (`mirror.sh:2385-2400`).

So a footer on a private commit does **not** reach the public history today. Only a change to the squash-message
composition (`mirror.sh:2411-2424`) can carry it.

### 2. Where must the footer live to satisfy (a) detection and (b) presence in what the public repo gets?

- (a) `suggest_semver_bump.sh` greps `git log <range> --format='%s%n%b'` for `BREAKING CHANGE` or `type!:`
  (`suggest_semver_bump.sh:66-72`). Any commit whose subject or body contains the phrase, inside the range, is enough.
- (b) The public repo receives one squash commit whose message `mirror.sh` composes (question 1). The footer must be in
  that message.

Candidates, with the verdict on each:

| Candidate | (a) detected | (b) in public history | Verdict |
|---|---|---|---|
| **Release-branch tip commit + `mirror.sh` copies the footer into the squash message** | Private: yes when `HEAD` is the release branch (experiment 2). Public: yes, the squash body is in the range (experiment B). | Yes. | **Recommended.** |
| Empty (or content) commit on the release branch, `mirror.sh` unchanged | Private only. | **No**: the squash message never contains it (`mirror.sh:2413-2424`, `SKILL.md:335`). Public range stays `patch` (experiment A). | Rejected: fails (b). Kept as half of the recommendation. |
| A line added to the squash message by the mirror flow, with no private commit | Public only. Nothing in the private repo to detect. | Yes. | Rejected: story `E91_S04` requires a commit whose message footer contains `BREAKING CHANGE:`; there would be no durable private artifact, no way to tell on a retry that it was already done, and nothing to read the footer from on a resumed run. |
| A commit on `main` | Only for a private `main` range, which is not what a release evaluates. | Only if cherry-picked or branched from `main` HEAD, and then only through the same (missing) squash hook. | Rejected, see "Why not `main`" below. |

### 3. What does `finish` do with release-branch commits, and is the footer commit "not on main" acceptable?

`finish` (`deploy-public-prep.sh:392-457`) does not merge, cherry-pick or delete anything. When this was written it
switched back to `main` (`:408-420`); since `E88_S06` it no longer does (the main checkout never moves: the release
branch is built in a worktree, which `finish` removes, restoring the session's perceived branch). It then lists what the release branch carries that `main` lacks by patch id,
`git rev-list --cherry-pick --right-only main...<branch>` (`:426-427`), prints the count and up to 10 subjects
(`:431-440`), and states that this is "information, not a to-do": release branches "are never merged back", several of
their commits "are release-branch-only by design and must NOT go to main", and the only commit worth moving by hand is
the version-only auto-reconcile commit (`:441-452`). The header says the same (`:69-78`), and the branch is kept because
the squash commit's `Source-Commit:` names its tip, which is the next run's baseline (`release-prep.sh:158-171`,
`SKILL.md:159-161`).

Consequence for the footer commit: it will be **reported** in the "no patch-equivalent on main" list (experiment 4:
`f115774 chore(release): record breaking change for v2.0.0`), **not** cherry-picked, **not** lost. It stays reachable on
the kept release branch and, through `Source-Commit:`, from the public squash commit. It is expected **not** to be on
`main`, and that is the intended outcome, not a gap. The `finish` wording only names the auto-reconcile commit as the
one deliberate exception; adding the footer commit to the "release-branch-only by design" text is a follow-up (below).

### 4. Which repo and range does `suggest_semver_bump.sh` evaluate, and is the footer inside it?

Mechanics (all of it is the repo the script is **invoked in**):

- `LAST_TAG` comes from `publish_resolve_last_publish_tag "$HISTORY_FILE" HEAD` (`suggest_semver_bump.sh:59`). That
  walks `git tag --merged HEAD --list 'v*.*.*' --sort=-v:refname` (`publish_common.sh:153-160`), keeps tags matching
  strict `^v[0-9]+\.[0-9]+\.[0-9]+$` (`publish_common.sh:149-151`, so `vX.Y.Z-stage` never counts), and returns the first
  one that the ledger file lists (`publish_common.sh:186-202`).
- The range is `LAST_TAG..HEAD`, or `HEAD` when there is no tag (`:60-64`); the log is plain `git log` in the **current
  directory** (`:66`). The ledger path, by contrast, resolves from the script's own repo root
  (`publish_common.sh:8-14`), or `PUBLISH_HISTORY_FILE`.
- Callers: `publish_deploy.sh:336` (the deploy's suggested version) and `write_ledger_entry.sh:123` (when no
  `--version` is given).

Which repo it actually runs in is **not fixed by the code**, and the evidence points at the public repo:

- `SKILL.md:241`: "`/publish` runs from the **public** repo (`jenga-npm`)".
- Every ledger row for `v4.5.0` to `v5.0.1` carries a `commit_sha` that is a **public** commit; none of those 12 SHAs
  exists in the private object database (checked with `git cat-file -e`). The matching tags on the public remote are
  `vX.Y.Z-stage` (for example `v5.0.0-stage` is `db5e8248...`, the ledger SHA), and the reasons on the last four rows
  say staged or approved "via direct `gh workflow` dispatch" / "outside /publish". So the recent releases did not run
  `suggest_semver_bump.sh` at all: the version came from `deploy-public`'s `pick_version` step, whose suggestion is
  the patch bump of the newest public tag (`release-prep.sh:131-137`, `:239-241`).
- Run in the **private** repo today, the same script resolves `LAST_TAG` to `v3.5.0` (the stray local tags `v55.0.1`
  and `v9.9.9` are not in the ledger), a range of 2982 commits, and reports `patch`. That evaluation is stale and not a
  release evaluation.

Therefore the footer has to be inside **both** possible ranges, and the recommendation does that:

| Run in | Range | Footer inside it? |
|---|---|---|
| Private repo, `HEAD` = the release branch | `LAST_TAG..HEAD`; the footer commit is at the tip | Yes (experiment 2: `major`). From `main` it is not (experiment 3: `patch`); acceptable, see question 3. |
| Public repo (clone of `jenga-npm`) | `LAST_TAG..HEAD`: `LAST_TAG` is the newest **final**, ledger-listed `vX.Y.Z` tag, so the range holds squash commits and `chore(publish): bump ...` commits (`npm_ci_pipeline.sh:344`) | Yes **only if the squash body carries it** (experiment A: `patch` without, B: `major` with). A `-stage` tag does not close the range (experiment C); only the final tag does (experiment E). |

## Why not `main`

1. Wrong semantics: the release branch is cut from `main` HEAD or from the base (`release-prep.sh:445-451`) and the
   mirror ships the branch. A commit made on `main` after the branch exists is not on the branch; one made before it is
   a candidate commit like any other (`release-prep.sh:255-271`) and is dropped from a "select by commits" release.
2. Pollution: `main` is the candidate pool for every later release. A stale `BREAKING CHANGE:` commit on `main` is in
   the ancestry of every later branch cut with `--all` and in every later private `LAST_TAG..HEAD`, which turns later
   patch releases into false majors.
3. The task and story forbid it: the commit must not land on `main` when it must not (story `E91_S04`, AC 5).

## What happens to the commit afterwards (verified in a scratch repo)

- `release-prep.sh candidates --base <footer tip>` lists only later `main` commits (experiment 5b); the footer commit
  is never a candidate because it is never on `main`.
- On the `--pick` path the next branch is cut from the previous tip, so it inherits the previous footer commit in its
  private ancestry. That is why the `mirror.sh` extraction must read the range **since the previous `Source-Commit:`**,
  not the whole history (see follow-up 1), and why a private-side `suggest_semver_bump.sh` run is not a reliable
  signal for later releases (it can see old footers). The public squash message only repeats a footer when the current
  run's range contains a footer commit.
- The version-only auto-reconcile commit (`mirror.sh:1747-1770`, committed at `:1764-1766` on the **current**, i.e.
  release, branch) lands **after** the footer commit and becomes `HEAD`. So the footer commit is not necessarily the tip
  when the squash message is composed; extraction must scan a range, not just `HEAD`.

## Consequences for T02 and T03 (not made here)

- `release-prep.sh:435-437` refuses a dirty working tree at branch creation. Therefore the `CHANGELOG.md` entry and
  the record file cannot be written on `main` before `create_branch`; they are written on the release branch after it
  exists. The footer commit should be that one commit (`CHANGELOG.md` + record file + footer), created with
  `--allow-empty` only when neither changed. It must refuse to run on `main` or on a branch that is not
  `release/<same-version>-*`.
- Idempotency for a resume, retry or the reuse path: before committing, look in `<base>..HEAD` for a commit whose
  subject is exactly `chore(release): record breaking change for <version>`; if present, do nothing (no second footer
  commit, no second changelog entry). A re-run of `create-branch` cannot reuse a branch (`release-prep.sh:438-440`
  refuses an existing one), so a retry on a fresh branch simply makes the commit once on that branch.
- The footer's reason and epics are the record's, not re-asked.
- The epic text says the new step goes "directly after `pick_version`". Gathering and recording the reason can happen
  there, but the commit cannot: the branch does not exist until `create_branch` (`deploy-public.json` step order
  `pick_version`, `branch_name`, `create_branch`, `preview`). The commit step goes **between `create_branch` and
  `preview`**.

## Follow-up changes required (named, not made in this task)

1. **`skills/j-mirror-public/scripts/mirror.sh`, lines `2410-2424`.** Before composing the squash message, find the
   footer commit and add its `BREAKING CHANGE:` line to the final paragraph (before `Source-Commit:`, same `-m`). Rule:
   take the previous private tip from the `Source-Commit:` trailer of the scratch-clone marker (`MARKER_SHA`,
   `mirror.sh:1793`), then scan `<previous tip>..HEAD` in `$REPO_ROOT` for commits whose subject matches
   `^chore\(release\): record breaking change for v[0-9]+\.[0-9]+\.[0-9]+$` and copy only their `BREAKING CHANGE: `
   line. No marker, no previous tip in the repo, or no match means no change to today's message (nothing else about
   the squash commit changes, and `release-prep.sh:163-164` still finds `Source-Commit:` by line). This is a deliberate,
   narrow exception to "never replay private messages" (`SKILL.md:37`, `:335`), so it must be stated there.
2. **`skills/j-mirror-public/SKILL.md`, "Squash-commit model" (`:323-336`) and "Release branch" (`:123-168`).** Document
   the footer line in the squash message shape, the one exception to `:335`, and that the footer commit is
   release-branch-only like the auto-reconcile commit. Same for `project/documentation/mirror-release-branch.md`
   ("Consequences").
3. **`project/.workflows/scripts/deploy-public-prep.sh`, `finish`, lines `441-452`.** Add the footer commit to the
   "release-branch-only by design, do not cherry-pick" wording. No logic change: `finish` already reports it and
   leaves it. A new subcommand (for example `breaking-footer`) that calls the `E91_S04_T03` script from the
   `create_branch` to `preview` gap is the other change to this file, and a matching step in
   `project/.workflows/deploy-public.json`.
4. **`skills/j-mirror-public/scripts/release-prep.sh`: no change required.** Branch creation, candidates and baseline
   all behave correctly with a trailing release-branch-only commit (experiments 4 and 5b).
5. **`E91_S04_T02` / `T03`:** follow "Consequences for T02 and T03" above. T03's script must also refuse to create the
   commit when the current branch is `main`.

## Experiments run (scratch repos only; no push, no mirror, no commit on a real branch)

All in a throwaway directory under the session scratchpad, using the real
`skills/j-publish/scripts/suggest_semver_bump.sh` and `release-prep.sh candidates` with `PUBLISH_HISTORY_FILE` /
`RELEASE_PREP_REPO` pointed at scratch data. `mirror.sh` was not run.

| # | Setup | Result |
|---|---|---|
| 1 | Private scratch, `main`, tag `v1.0.0` in ledger, two task commits | `patch -> v1.0.1` |
| 2 | Release branch with an empty `chore(release): record breaking change for v2.0.0` + `BREAKING CHANGE:` footer | `major -> v2.0.0` |
| 3 | Back on `main` | `patch -> v1.0.1` (footer not on `main`) |
| 4 | `git rev-list --cherry-pick --right-only main...release/...` (what `finish` runs) | lists the footer commit |
| 5 | `git cherry <footer tip> main` | empty; with one new `main` commit, `release-prep.sh candidates --base <footer tip>` lists only that commit |
| 6 | `git interpret-trailers --parse` on the message | prints nothing: `BREAKING CHANGE` is not a parsed trailer |
| 7 | Hyphen form `BREAKING-CHANGE:` | not detected (`patch`); it does parse as a trailer |
| A | Public scratch: squash commits as `mirror.sh` writes them today (subject + `Source-Commit:`) | `patch -> v1.0.1` |
| B | Same, squash body carrying `BREAKING CHANGE: ...` | `major -> v2.0.0` |
| C | Plus a `v2.0.0-stage` tag | still `major` (a `-stage` tag does not close the range) |
| D | Plus a `chore(publish): bump ...` commit, no final tag | still `major` |
| E | Final `v2.0.0` tag listed in the ledger | `patch -> v2.0.1` (range reset) |

The one thing these cannot settle is a full end-to-end squash of a real release branch, because that needs `mirror.sh`
(which this task must not run). It is covered by `E91_S05_T02`, which runs each script twice in a scratch repo.
