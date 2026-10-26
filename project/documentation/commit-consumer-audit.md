# Commit-discovery consumer audit

Task `E79_S01_T02`, story `E79_S01`, epic `E79` (project-specific commit format for board commits).
Audited at commit `971fab17` on 2026-10-21 (UTC). Line numbers refer to that commit; re-run the commands in
section 8 to refresh them.

This audit lists every place that **finds the commits of a board item** or **classifies a commit subject**, so
that `E79_S02` (shared resolver) has a complete migration worklist before any shared code is touched
(solution assessment, Problem 21; also the evidence behind Problems 4 and 5). It changes no behaviour.

## 1. Method and vocabulary

Two passes with different pattern sets (section 8 and section 9), every hit read in context, every script
traced to its callers, and one empirical probe in a scratch repository (section 5).

| Term | Meaning |
|---|---|
| **Message search** | Finds commits by looking for a board id in the commit message (`--grep`). |
| **Anchored id** | The pattern `<id>([^0-9_]|$)` (extended regex), which stops `E51_S02` matching `E51_S02_T01`. |
| **Subject form** | Parses the shape of the subject line (`task(...)`, `E##: ...`, `type(scope): ... E##_S##`). |
| **Writes board status** | The consumer changes a board file (status or a frontmatter field), directly or through the agent following its instructions. |
| **Horizon** | How old the commits it must find can be when it runs. The proposed contract horizon is `reconcile` on a fresh clone 90 days after a client merge (Open Decision 3, still a proposal). |

"Id-free message" means a commit whose subject has no board id (for example `ASD-001 add retry`) and whose
body has no `Jenga-Task:` trailer, unless a row says otherwise. Section 5 shows what the trailer changes.

## 2. Headline findings

1. **Eleven message-search rows (M1-M11), five live subject classifiers (S1-S5) and one disabled one (S6).**
   The plan named four consumers (`close-story` stats scripts, `mark-merged.sh`, `reconcile`'s grep,
   `est_provenance` / `detect-conventions.sh`). The search found these additional ones:
   `scripts/mark-deployed.sh`, `check-privatized.sh`, `mark-publicized.sh`, `generate_release_notes.sh`
   (task-association filter), `skills/j-redo/SKILL.md`, the prose copy of the grep in
   `skills/j-close-story/SKILL.md`, `reconcile`'s Phase 3 search, `suggest_semver_bump.sh` and the release-notes
   bucket classifier. It also found that `extract-diff-stats.sh` has no caller.
2. **Seven rows write to the board.** Four are scripts that set a lifecycle status (M4 `Privatized`, M5
   `Merged`, M6 `Publicized`, M7 `Deployed to Stage/Prod`); M8 and M9 are `j.reconcile` instructions that set
   or demote a status; M1's result is written to `actual_*` frontmatter by the `close-story` steps. M4-M7
   copy the same `commits_for_ticket` function four times.
3. **Silent-empty is the dominant failure.** For every message-search row (M1-M11) an id-free message yields
   an empty or wrong result and **none raises an error**: exit 0, a log line to stderr, a `0` written to the
   board, or a fail-open. Only `j.reconcile` (M8) can turn the empty result into a destructive write (Phase 2
   demotion of a completed task to `Pending`), and only when its other evidence also fails.
4. **`j.status` is a board-writing consumer.** Step 6.5 of `skills/j-status/SKILL.md` runs
   `scripts/mark-deployed.sh`, so a "read-only overview" can promote tickets to `Deployed to Stage/Prod`.
5. **The release-notes privacy filter fails open on an id-free message.** `generate_release_notes.sh` only drops
   a task from the public changelog when it finds commits for it by the literal string `(<task_id>)`. No commit
   found means the entry is kept, so a task whose files are all in `.publicignore` can reach a public changelog.
   A body trailer does not help, because the pattern requires parentheses.
6. **The dashboard and rapport generation are not commit-discovery consumers.** Evidence in section 4.
7. **Existing quirks the resolver must reproduce or deliberately retire** (section 6): the substring/body match
   over-attributes (`chore(board)`, `chore(self-sync)`, rapport commits, and commits that merely mention an
   id), cherry-picks with `[pick <sha>]` subjects are counted twice, and `--all` counts every worktree branch.
8. **Only 5 of the 16 live rows are exercised by a `.bats` test** (M4, M6, M7, S2, S3; section 7).
   `mark-merged.sh`, `extract-task-diff-stats.sh`, `extract-diff-stats.sh`, `detect-unlinked-code.sh`,
   `suggest_semver_bump.sh` and `compute-deploy-reconcile.sh` are referenced by no test at all, and M10 is
   only a collaborator in one. `E79_S02`'s differential tests are the first coverage for them.

## 3. Consumer table

Columns: **#** | **Path:line** | **Searches for** | **Read-only / writes** | **Horizon** | **Id-free message does**

In table cells, `\|` is Markdown escaping for a literal `|` (so `([^0-9_]\|$)` is the regex `([^0-9_]|$)`).

### 3.1 Message search by board id (the resolver's migration worklist)

| # | Path:line | Searches for | Read-only / writes | Horizon | Id-free message does |
|---|---|---|---|---|---|
| M1 | `skills/j-close-story/scripts/extract-task-diff-stats.sh:45` (id validated at `:36`; stats at `:62-88`) | `git log --all --no-merges --grep="$TASK_ID"`, basic regex, **unanchored substring**, whole message | Prints `actual_files_changed` / `actual_lines_delta`. Caller (`j-close-story/SKILL.md:74`, step 2.3) writes them to task frontmatter in step 2.4 (`:82-93`); the field is documented at `templates/SCRUM_BOARD_SCHEMA.md:392` as "extracted from its EST-tagged commits" | Story close: minutes to days after the commits | **Empty, reported as success.** `:47-52` prints `0` / `0` and exits 0. `SKILL.md:119-124` says to write the zeros "do not treat this as an error"; the final report adds "(no EST-tagged commit found)" (`:215`). The board then carries `0` as if measured. Also skips root commits silently (`:69`) |
| M2 | `skills/j-close-story/scripts/extract-diff-stats.sh:15`, `:22`, `:31` (date window `:26-29`) | `git log --all --no-merges --grep="$STORY_ID"` (story id, unanchored, so it also matches every child task id by design) | Read-only, prints four fields | Story close | **Empty, plus a wrong count.** `diff_added: 0`, `commits_matched: 0`, and `commits_unmatched_in_window` becomes *every* commit in the date window (`:33-39`), because nothing matched. Exit 0. No step in any skill invokes it: the only reference is the table at `j-close-story/SKILL.md:277`, so it is documented but has no live caller |
| M3 | `skills/j-close-story/SKILL.md:68` (step 2.2, "Extract commit SHA(s)") and `:154` | Prose copy of the M1 grep, run by the agent; its output is not passed to the script that follows | Informational (agent step) | Story close | **Empty** (agent sees no SHAs). Not greppable by a script guard; model-driven. `:154` describes bundle attribution as "each task matched by `git log --grep`" |
| M4 (migrated, `E79_S02_T07`) | `skills/j-close-story/scripts/check-privatized.sh:193` (`commits_for_ticket` `:190-195`; empty handling `:216-219`) | `git log --all --no-merges --extended-regexp --grep="${id}([^0-9_]\|$)"`, anchored, task or story id | **Writes board status `Privatized`** (and a `publicized_privatized_mismatch` event). Called from `j-close-story/SKILL.md:129` (step 2.7, per task) and `:179` (story) | Story close | **Empty, "UNCHANGED", exit 0** (`:219`). A task whose files are all blocklisted is never marked `Privatized`; it keeps its previous status with no warning |
| M5 | `skills/j-self-sync/scripts/mark-merged.sh:361` (`commits_for_ticket` `:358-362`; empty handling `:437`) | Same anchored `--grep` as M4 | **Writes board status `Merged`**. Called by `skills/j-self-sync/scripts/run.js:98` (`/self-sync`; also reached through `j.dev-done`) | Days: each `/self-sync` run, all `Done`/`Passed` tickets | **Empty, ticket left unchanged** (log line `zero matched EST-tagged commits`, `:437`). The ticket never reaches `Merged`, silently, on every run |
| M6 (migrated, `E79_S02_T07`) | `skills/j-mirror-public/scripts/mark-publicized.sh:242` (empty handling `:355-358`) | Same anchored `--grep` | **Writes board status `Publicized`**, may append a `publicized_privatized_mismatch` event. Called from `skills/j-mirror-public/scripts/mirror.sh:2070` | Days to weeks: each real mirror run | **Empty, ticket left unchanged** (`:357`). Never `Publicized`, silently |
| M7 (migrated, `E79_S02_T07`) | `scripts/mark-deployed.sh:297` (empty handling `:441-444`; ancestry check `:331`) | Same anchored `--grep`, then `git merge-base --is-ancestor` of each hit against the public tag's `Source-Commit` SHA | **Writes `Deployed to Stage` / `Deployed to Prod` and `date_deployed_prod`**. Called from `run.js:155` (`/self-sync`) and `skills/j-status/SKILL.md:40-52` (step 6.5, **every `/status`**) | **Longest of the script consumers:** weeks to months, bounded by the next public tag | **Empty, ticket left unchanged** (`:443`). The lifecycle ladder stalls at `Publicized` with no signal |
| M8 | `skills/j-reconcile/SKILL.md:177` (Phase 2, step 1) | `git log --all --oneline --grep="<task_id>"`, agent-run, unanchored | **Writes board status.** Phase 2 demotes a completed task to `Pending` and clears `date_started` / `date_completed` when implementation "cannot be confirmed" (`:183-194`) | **Unbounded**: every completed task on the board, any age | **Empty, then a destructive path.** The "strong evidence" is missing; the agent falls back to the doc-artefact and acceptance-criteria checks (`:178-179`), then to a branch/worktree name match (`:184-189`), then demotion (`:190-194`). A `Passed` task with id-free commits is demoted unless the other evidence rescues it. Ladder statuses are exempt (`:195-198`) |
| M9 | `skills/j-reconcile/SKILL.md:207` (Phase 3, step 1) | "Search git history for commits referencing the task ID", agent-run | **Writes board status** (promotion to `Passed`, stamps `date_completed`, comments out the `todo.md` line) | Unbounded | **Empty, conservative miss.** "Not confirmed" means no action, so a secretly implemented task is never found. The in-flight guards (`:220-239`) key on concurrency slots and worktree names, not commits, so they are unaffected |
| M10 (left alone, `E79_S02_T07`, see 11.1) | `skills/j-publish/scripts/generate_release_notes.sh:283` (in `_pi_task_is_fully_blocked`, `:276-309`; called `:339`) | `git log <LAST_TAG>..<TO_REF> --grep="($task_id)" -F`: the literal parenthesised id, i.e. the `task(E##_S##_T##):` scope form only | Read-only; builds the "Completed tasks" release-notes section | Since the last publish tag: weeks to months | **Empty, fails open by design** (comment `:266-275`): no commit found means the task entry is kept. A task whose commits are entirely `.publicignore`-blocked still appears in release notes. A `Jenga-Task: <id>` trailer is **not** matched either, because the pattern needs `(` and `)` |
| M11 (left alone, `E79_S02_T07`, see 11.1) | `skills/j-redo/SKILL.md:48` | `git --no-pager log --all --oneline --grep="<epic or story title>"`: a **title** search, not an id search | Read-only (finds commits and diffs to redo) | Unbounded | **Empty or wrong.** Matches only when a commit message repeats the item title; `task(E02_S03_T01): ...` subjects usually do not, so it is already unreliable. Id-free subjects change nothing for the worse. Its SHA input (`:43-44`) is unaffected, see D1 |

### 3.2 Subject classifiers (read the subject's shape, not an id search)

| # | Path:line | Searches for | Read-only / writes | Horizon | Id-free message does |
|---|---|---|---|---|---|
| S1 | `skills/j-reconcile/scripts/detect-unlinked-code.sh:341-342` (history read), `:450-455` (regexes), `:457-472` (`est_provenance`), `:483-489` (use) | `git log --diff-filter=A --no-renames --name-only --format='%x01%s' HEAD`, then `est_provenance(subject)`: `^(epic\|story\|task)\(...\)`, a leading `E##...:` id, or a conventional subject containing `E##_S##` | Read-only report (`/reconcile` then offers `/uncharted segment` for what it reports) | **Whole `HEAD` history, unbounded** | **Wrong match (false "no provenance").** `ASD-001 add retry` matches none of the three forms, so Signal B is false and the file is reported unlinked/uncharted even when the board owns it. Reads the subject only, so a body trailer is ignored (confirmed in section 5) |
| S2 | `skills/j-conventions/scripts/detect-conventions.sh:60` (`EST_RE`), `:338` (`git log --no-merges -n 200 --format=%s`), `:341-343` (exclusion) | Excludes `task(...)`/`story(...)`/`epic(...)` subjects from the sample used to detect the project's commit style | Read-only detection | Last 200 non-merge commits | **Wrong sample.** An id-free board commit is no longer excluded, so it is counted as a non-board sample and skews the detected style and confidence. For an opted-in project the sample would describe its own board commits (arguably desirable, but a behaviour change to decide) |
| S3 | `skills/j-commit/scripts/commit-subject-check.sh:68`, `:74-79` (board token `:74`) | Classifies the **pending** subject as board (`task(`/`story(`/`epic(`, a board id in the scope, `merge: <id>`, `Revert "task(`) or non-board | Read-only (advisory check) | None: it sees only the message about to be written | **Classified non-board**, so the project `commit-format` convention applies. This is the epic's intended effect and the place the E69 Decision 2 reversal lands |
| S4 | `skills/j-publish/scripts/generate_release_notes.sh:187`, `:256-258` | Subject of every commit in the range against `^feat(...)!?: ` / `^fix(...)!?: ` for the Features / Bug fixes buckets | Read-only | Since the last publish tag | **Unchanged in effect.** EST subjects already fall into "Other"; so do id-free ones. Not id-dependent, listed for completeness |
| S5 | `skills/j-publish/scripts/suggest_semver_bump.sh:66-70` | Subject and body of the range for `BREAKING CHANGE`, `type!:` and `^feat(...)?: ` to choose major/minor/patch | Read-only suggestion | Since the last publish tag | **Unchanged in effect.** EST and id-free subjects never match `feat:`, so both yield `patch` unless the body says `BREAKING CHANGE`. A `Jenga-Task:` trailer cannot trip the `BREAKING CHANGE` rule |
| S6 (disabled) | `templates/conventions-checklist-map.json:20` | `git log -1 --format=%s \| grep -Eq {q:values.message_regex}` as a pre-commit verify | Disabled alternative, kept off by the E69_S05_T05 finding (the hook runs before the message exists) | n/a | Not live. Encoded in `tests/conventions-precommit-timing.bats` as the reason it is disabled |

### 3.3 Reviewed and not affected by an id-free message

These read git history but by SHA, path, tag or a trailer that does not depend on the private subject.

| # | Path:line | What it reads | Why unaffected |
|---|---|---|---|
| U1 | `scripts/compute-deploy-reconcile.sh:306-307` | `git log -1 --format=%B <public tag>`, regex `^Source-Commit: [0-9a-f]{40}$` | Reads the trailer that `mirror.sh:2004` / `:2014` writes on the **public** squash commit. It is the existing precedent for exact, anchored trailer parsing. Its output feeds M7 |
| U2 | `skills/j-uncharted/scripts/find-scan-baseline.sh:433`, `:453` | `git log --follow --diff-filter=A --format=%h -- <board file>`; `git show -s --format=%ct <sha>` | Path-based: finds when a **board file** was added, not what a commit says |
| U3 | `skills/j-uncharted/scripts/diff-since-baseline.sh:488`, `:503` | `git cat-file -e <sha>^{commit}`; `git diff --name-only <sha>..HEAD -- <path>` | SHA and path based |
| U4 | `skills/j-do/scripts/bundle-resume.sh:91` | `git merge-base --is-ancestor <anchor_sha> HEAD` | SHA from the bundle manifest |
| U5 | `skills/j-mirror-public/scripts/mirror.sh:1110`, `:1117`, `:1114`, `:1121`, `:1438` | `rev-list --count`, `log --oneline` over `marker..remote` | Display and counting of public-repo commits |
| U6 | `skills/j-mirror-public/scripts/compute-publicize-diff.sh:186`, `:204` | `rev-parse --verify <sha>^{commit}` | SHA validation |
| U7 | `skills/j-reconcile-origin/scripts/reconcile-origin.sh:224`, `:262` | `rev-list --count origin/<b>..HEAD` | Counts, no message |
| U8 | `skills/j-test/scripts/map-scope.sh:496-498`; `skills/j-commit/scripts/test-gate-scoped.sh:364`, `:375` | `rev-parse --verify HEAD^{commit}` | Existence check |
| U9 | `skills/j-publish/scripts/generate_release_notes.sh:165`, `skills/j-publish/scripts/publish_deploy.sh:242`, `skills/j-publish/scripts/reconcile_tags.sh:81-85`, `skills/j-publish/scripts/publish_common.sh:155` | Tag date (`log -1 --format=%cI <tag>`), tag listing, `rev-list -n 1 <tag>` | Tag based |
| U10 | `scripts/check-events-log-shrink.sh:19`, `:23` | `cat-file -e HEAD:<file>`, `show :<file>` | Reads a file from the index |
| U11 | `scripts/mark-deployed.sh:302`, `:331`; `check-privatized.sh:198`; `mark-publicized.sh:247`; `mark-merged.sh:366` | `rev-parse --verify <sha>~1`, `diff --name-only`, `diff-tree`, `merge-base --is-ancestor` | Run on SHAs the message search already returned, so they inherit M4-M7's result and add no discovery of their own |
| U12 | `agents/tester.md:127`, `agents/developer.md` (sender object) | Requires at least one commit SHA in `paths`; the SHAs travel in sender objects and handoff files | SHA based. The board stores no commit SHAs (plan, "Current behaviour"), which is why every consumer above searches messages |

## 4. Explicit coverage: `j.redo`, `j.status`, the dashboard, rapports

| # | Subject | Verdict | Evidence |
|---|---|---|---|
| D1 | `j.redo` | **Consumer** (M11) | `skills/j-redo/SKILL.md:43-44`: SHA input runs `git --no-pager log --stat -1 <SHA>` and `show <SHA>`, which is SHA based and unaffected. `:48`: the Epic/Story input runs `git --no-pager log --all --oneline --grep="<epic or story title>"`, a title search. Only `:43`, `:44` and `:48` touch git history in the file |
| D2 | `j.status` | **Consumer, indirectly** (M7), and it writes | `skills/j-status/SKILL.md:40-52` (step 6.5) runs `scripts/mark-deployed.sh`. Steps 2-5 (`:28-36`) read board files and rapport directories only: searching `skills/j-status` for `git log`, `--grep` and `rev-list` returns nothing (section 8.2) |
| D3 | Dashboard (`project/app`) | **Display only, no discovery consumer** | `project/app/api/parsers/git-log.js:24` runs `git log` with a format of sha, author, date, subject and body (`--max-count=200`) and returns subject and body unchanged. Its only callers are `project/app/api/routes/history.js:36` and the UI components `project/app/ui/src/components/history/HistoryEntry.jsx:4` and `EntryDetailPanel.jsx:58-79`, which render `sha`, `author`, `date`, `subject`, `body`. No board id is parsed from a commit anywhere in `project/app`: the only `E\d+_S\d+` patterns are in `api/parsers/todo.js:43,67,82` and `ideas.js:84`, which parse `todo.md` and `ideas.md`, not commits. An id-free message displays normally and is simply not linked to a task. Horizon: last 200 commits |
| D4 | Rapports and rapport generation | **No commit-discovery consumer** | `hooks/on_session_end.sh` (the rapport detector) contains no `git log`, `--grep` or `rev-list`; its only git call is `rev-parse --show-toplevel` (`:29`). It compares `rapports/problems/` against `.rapport_manifest.json` (`scripts/generate-rapport-manifest.sh` has no git history call either: its only git call is the same `rev-parse` at `:27`). `scripts/checklist.sh` validates a `--incident` that is "a commit SHA" by format only (`:1776-1786`; the only `git ` text in the file is in comments at `:282` and `:312`); `templates/PROBLEM_RAPPORT_TEMPLATE.md:16,58` allows a SHA as an incident reference. Rapports are named by task id (`E##_S##_T##-...md`) and committed by agent instruction as `chore(<id>): add rapport ...` (`agents/developer.md`, "Commit the rapport immediately"), so they are **producers** of id-bearing commits, not consumers |

## 5. Empirical probe: what an id-free message does

A scratch repository was built in `/tmp` (deleted afterwards) with four commits, then the real scripts and the
exact grep forms from section 3 were run against it. Commands are in section 8.4.

| Commit subject | Body | Result |
|---|---|---|
| `task(E01_S01_T01): impl` | none | Found by the anchored grep. `extract-task-diff-stats.sh` printed `0 / 0` only because it is the repository's **root commit**, which `:69` skips silently (an existing quirk, unrelated to the message) |
| `ASD-001 add retry` | none (this is task `E01_S01_T02`) | Anchored grep: **empty**. `extract-task-diff-stats.sh E01_S01_T02`: `actual_files_changed: 0`, `actual_lines_delta: 0`, exit 0 |
| `ASD-001 add backoff` | `Jenga-Task: E01_S01_T03` | Anchored grep: **found** (git's `--grep` searches the whole message, so every `--grep` consumer M1-M9 finds a body trailer unchanged). `extract-task-diff-stats.sh E01_S01_T03`: `1 / 1`. The `generate_release_notes.sh` pattern `-F "(E01_S01_T03)"`: **not found** (needs parentheses) |
| `feat(retry): add jitter (E01_S01_T04)` | none | Anchored grep: found. Release-notes `(E01_S01_T04)` pattern: found |

`detect-unlinked-code.sh --repo-root <scratch> --board-dir <empty board>` reported `linked_by_commit: 2`
(`a.txt` via `task(...)`, `d.txt` via the conventional-with-id form) and `unlinked_paths: 2` (`b.txt` and
`c.txt`). `c.txt` has the trailer and was still unlinked, so S1 reads the subject only.

Consequences for the design inputs: a body trailer is already discoverable by M1-M9 with no change to their
grep; what breaks for it is S1 (subject only), M10 (needs parentheses), and every consumer's behaviour on
*zero* results, which is what the resolver's `--require-nonempty` addresses.

## 6. Baseline on this repository's own history

The differential tests of `E79_S02` compare against these behaviours, so they are recorded as measured
(`--all`, no merges, 2026-10-21; commands in section 8.5; the counts move as branches are added).

| Measure | Count |
|---|---|
| Non-merge commits reachable from `--all` | 3336 |
| Subject starts with `task(` / `story(` / `epic(` | 2102 |
| Message (subject or body) contains `E##_S##` | 3056 |
| Message contains no `E##_S##` at all (the commits today's consumers can never find) | 279 |
| Subject starts `chore(board)` | 48 |
| Subject contains a `[pick <sha>]` marker (cherry-picks) | 326 |

For one task, `E67_S04_T02`, the M1 grep returns 21 commits: 13 whose subject is `task(E67_S04_T02)`, 4 whose
subject names a *different* id (they only mention this one in the body), and only 12 distinct subjects once the
`[pick <sha>]` suffix is removed, so 9 of the 21 are cherry-pick duplicates that M1 counts again. Other tasks show the same
pattern: for `E75_S01_T03` the grep also returns `chore(board)`, `chore(self-sync)` and `chore(E75_S01_T03): add
rapport` commits. So the current "all commits of task X" already includes board bookkeeping, mirror syncs,
rapports and duplicates. This matters for Open Decision 6 (do `chore(board)`, roll-up, merge, `chore(self-sync)`
and mirror commits keep their Jenga forms or inherit the ref?): those commits are matched today **because**
they carry the id, and M4-M7 rely on the file union including them (`mark-merged.sh` comment on `COPY_SET`).

## 7. Tests that encode current commit-discovery behaviour

Separate from the consumer table, as the task requires. Found by `git grep -l` for the script names and for
`git log` / `--grep` / `task(E` under `tests/` and `project/app`.

| Test file | Encodes | Fixture commit style |
|---|---|---|
| `tests/mark-publicized.bats` | M6: eligibility, full / partial / zero-match coverage (`:97` "zero matched commits leaves the ticket unchanged"), union over several commits (`:105`), **anchored story id** (`:115`), bundled commit gives full credit (`:128`), idempotence | `task(E01_S01_T01): ...` subjects (`:69-107`); `unrelated work` for the zero-match case (`:99`) |
| `tests/mirror-publicize-wiring.bats` | M6 reached through `mirror.sh:2070` | `task(E98_S01_T0n): ...` (`:57-59`) |
| `tests/external-refs-absent-safe.bats` | M4 and M7 (and `j.status` step 6.5) run on tickets with and without `external_refs`; the fixture comment at `:182-184` says commits are "tagged with the task ids so the EST-commit matching in mark-deployed.sh / check-privatized.sh sees them" | EST-tagged fixture commit; tests at `:341`, `:450` |
| `tests/npm-stage-approve-changelog.bats` | M10 / S4 only as a collaborator of the deploy path (seed commit `chore: seed fixture repo`, `:50`); does not assert the task-association filter | `chore: ...` |
| `tests/conventions-detect.bats` | S2: `@test` at `:187` ("EST subjects excluded"); asserts `3 EST board subjects excluded` | `task(E01_S01_T01): board work`, `story(...)`, `epic(...)` (`:197-199`) |
| `tests/conventions-commit.bats` | S3: board vs non-board classification (`:104`, `:113`, `:122`, `:131`, `:139`) | subject strings |
| `tests/conventions-e2e.bats`, `tests/conventions-no-leak.bats` | S3 end to end; "EST naming for board commits is carried by the generated text" (`e2e 8`) | subject strings |
| `tests/conventions-precommit-timing.bats` | S6: shows `git log -1` cannot see the pending message at hook time (`:73`, `:146`) | n/a |
| `tests/dev-done-post-sync-commit.bats`, `tests/merge-task-into-perceived-branch.bats`, `tests/commit-version-bump-root-climb.bats`, `tests/gitignore-repair.bats`, `tests/init.bats` | **Producers** only: read back the subject they created with `git log -1`. Not discovery behaviour, but they pin the subject forms (`chore(self-sync)`, `merge: <id> into <branch>`) relevant to Open Decision 6 | various |

No `.bats` file under `tests/` and no `*.test.js` under `project/app` references the following, so they have
**no test** today: `mark-merged.sh` (M5), `extract-task-diff-stats.sh` (M1), `extract-diff-stats.sh` (M2),
`detect-unlinked-code.sh` (S1), `compute-deploy-reconcile.sh` (U1), `suggest_semver_bump.sh` (S5), and the
dashboard's `git-log.js` (D3). `generate_release_notes.sh` (M10, S4) is only a collaborator in
`npm-stage-approve-changelog.bats`, and the task-association filter is not asserted. The `SKILL.md` prose
consumers (M3, M8, M9, M11) cannot be unit tested. `M4` and `M7` are covered only by
`external-refs-absent-safe.bats`, which tests `external_refs` handling, not the zero-match path.

## 8. Search commands (re-runnable)

Run from the repository root of a checkout at the audited commit. `$SCOPE` is the pathspec used throughout.

Run these under **bash** (they rely on word-splitting of the unquoted `$SCOPE`, which zsh does not do; under zsh
every pass-1 search silently returns nothing).

```bash
SCOPE='skills scripts agents hooks lib mcp templates project/app'
EXCL=(':!*.bats' ':!tests' ':!*/node_modules/*' ':!project/app/ui/dist')   # .claude/ and .agents/ are generated mirrors: not searched
```

Per-file hit counts these commands returned at `971fab17`: 8.1a (`--grep`) hit 10 files (`mark-merged.sh` 4,
`extract-diff-stats.sh` 3, `mark-publicized.sh` 2, `check-privatized.sh` 2, `j-close-story/SKILL.md` 2, one each in
`j-redo/SKILL.md`, `j-reconcile/SKILL.md`, `generate_release_notes.sh`, `extract-task-diff-stats.sh`,
`mark-deployed.sh`); 8.1b (`git ... log`) added `detect-unlinked-code.sh`, `detect-conventions.sh`,
`suggest_semver_bump.sh`, `publish_deploy.sh`, `compute-deploy-reconcile.sh`, `find-scan-baseline.sh`,
`mirror.sh`, `git-log.js`, `check-events-log-shrink.sh` and `templates/conventions-checklist-map.json`. 8.1d's
`est_tag` substring also hits unrelated words (`oldest_trigger` in `skills/j-check-in/scripts/collect-liveness.sh`,
`DEST_RELATIVE_PATH` in `skills/j-dashboard-share/scripts/upload-snapshot.sh`): those are false positives.
8.1e's `(task|story|epic)\(` also matches `ensure_publish_history()` in `run_gates.sh` and `ios_pipeline.sh`:
false positives too.

### 8.1 Pass 1: message search and history readers

```bash
# a) message search flag
git grep -nE -e '--grep' -- $SCOPE "${EXCL[@]}"
# b) git log in any invocation shape, including  git -C "$X" log  and  git --no-pager log
git grep -nE 'git.* log( |$)' -- $SCOPE "${EXCL[@]}"
# c) same, restricted to prose consumers (agent instructions)
git grep -nE 'git( --no-pager)? log|--grep|rev-list|git show ' -- 'skills/**/*.md' 'agents/*.md' 'templates/*.md'
# d) the subject classifier
git grep -n 'est_provenance\|est_tag\|EST_RE\|EST_TAG_RE' -- $SCOPE "${EXCL[@]}"
# e) EST subject regexes and board-id regexes
git grep -nE '(task|story|epic)\\?\(|E\[0-9\]+_S\[0-9\]+|E\[0-9\]\{[0-9,]+\}_S|\^E[0-9]' -- $SCOPE "${EXCL[@]}" ':!*.md'
```

### 8.2 Pass 1: explicit subjects

```bash
git grep -nE 'git( --no-pager)? log|--grep|rev-list' -- skills/j-redo skills/j-status          # j.redo, j.status
git grep -nEi 'commit' -- project/app ':!*/node_modules/*' ':!project/app/package-lock.json' ':!*.md'   # dashboard
git grep -nE 'git|commit' -- hooks/on_session_end.sh scripts/generate-rapport-manifest.sh              # rapport generation
git grep -nE 'readGitLog|git_commit|\.subject\b|commit\.(sha|body|subject)' -- project/app ':!*/node_modules/*'
```

### 8.3 Trace each script to its callers

```bash
for s in extract-task-diff-stats extract-diff-stats check-privatized mark-merged mark-publicized mark-deployed \
         detect-unlinked-code generate_release_notes suggest_semver_bump detect-conventions commit-subject-check \
         compute-deploy-reconcile; do
  echo "## $s"; git grep -n -- "$s" -- skills scripts agents hooks lib mcp project/app ':!*.bats' ':!tests' \
    ':!lib/legacy-shipped-paths.json' ':!*/node_modules/*'
done
```

### 8.4 Empirical probe (section 5)

```bash
D=$(mktemp -d /tmp/e79-audit-demo.XXXXXX); cd "$D"; git init -q
git config user.email d@e.x; git config user.name d; git config commit.gpgsign false; git config core.hooksPath /dev/null
mkdir -p project/board/epics project/board/stories project/board/tasks
echo a > a.txt; git add -A; git commit -q -m "task(E01_S01_T01): impl"
echo b > b.txt; git add -A; git commit -q -m "ASD-001 add retry"
echo c > c.txt; git add -A; git commit -q -m "ASD-001 add backoff" -m "Jenga-Task: E01_S01_T03"
echo d > d.txt; git add -A; git commit -q -m "feat(retry): add jitter (E01_S01_T04)"
for id in E01_S01_T01 E01_S01_T02 E01_S01_T03 E01_S01_T04; do
  git log --all --no-merges --extended-regexp --grep="${id}([^0-9_]|\$)" --pretty=format:'%h %s'; echo "  <- $id"; done
for id in E01_S01_T02 E01_S01_T03; do bash <repo>/skills/j-close-story/scripts/extract-task-diff-stats.sh $id; done
for id in E01_S01_T03 E01_S01_T04; do git log --grep="($id)" -F --pretty=format:%h; echo "  <- ($id)"; done
bash <repo>/skills/j-reconcile/scripts/detect-unlinked-code.sh --repo-root "$D" --board-dir "$D/project/board"
rm -rf "$D"
```

### 8.5 Baseline on real history (section 6)

```bash
git log --all --no-merges --pretty=format:%H | wc -l
git log --all --no-merges --pretty=format:%s | grep -cE '^(task|story|epic)\('
git log --all --no-merges -E --grep='E[0-9]+_S[0-9]+' --pretty=format:%H | wc -l
git log --all --no-merges -E --invert-grep --grep='E[0-9]+_S[0-9]+' --pretty=format:%H | wc -l
git log --all --no-merges --pretty=format:%s | grep -cE '^chore\(board\)'
git log --all --no-merges --pretty=format:%s | grep -c '\[pick '
git log --all --no-merges --grep=E67_S04_T02 --pretty=format:%s | sed 's/ \[pick.*//' | sort -u | wc -l
```

### 8.6 Tests that encode behaviour (section 7)

```bash
for p in extract-task-diff-stats extract-diff-stats mark-merged mark-deployed mark-publicized check-privatized \
         detect-unlinked-code generate_release_notes suggest_semver_bump detect-conventions commit-subject-check \
         compute-deploy-reconcile find-scan-baseline; do
  echo "## $p"; git grep -l -e "$p" -- tests 'project/app/**/*.test.js'
done
git grep -nE '(git|GIT)[^|]* log |--grep|est_tag|id_prefix' -- tests
```

## 9. Cross-check with a different pattern set

Pass 1 searched for message-search *flags* and subject *regexes*. Pass 2 searched for the *git subcommands and
output formats* a consumer would need, and for wrappers, so a consumer that does not use `--grep` or `git log`
literally is still caught.

```bash
# 1. other history/object readers and output formats
git grep -nE 'git( -C [^ ]+)? (show|diff-tree|cherry|blame|describe|name-rev|notes|interpret-trailers|cat-file|for-each-ref|merge-base|rev-list)\b|--contains|--format=%[sbBHhcCaAtT]|--pretty(=|:)format|%\(trailers' \
  -- $SCOPE "${EXCL[@]}" ':!*.md'
# 2. wrappers that hide the word "git log" (git_q, run_git, ...)
git grep -nE '(git_q|git_c|gitc|run_git|_git)\s+(-C [^ ]+\s+)?log\b' -- $SCOPE "${EXCL[@]}"
# 3. JavaScript / Python subprocess callers
git grep -nE "(execSync|execFileSync|execFile|spawnSync|spawn|exec)\(|simple-git|subprocess\.(run|check_output|Popen)\(" \
  -- lib mcp project/app skills 'scripts/*.js' ':!*/node_modules/*' | grep -iE 'git'
git grep -nE '\["git"|'"'git',\s*'" -- skills scripts hooks lib mcp project/app ':!*.bats' ':!*/node_modules/*'
# 4. trailer / message readers
git grep -nE 'Source-Commit|Jenga-Task|interpret-trailers|%B|%b' -- $SCOPE "${EXCL[@]}"
# 5. date-window and author readers
git grep -nE -e '--(since|until|after|before|author)|log -[SG]' -- $SCOPE "${EXCL[@]}" ':!*.md'
# 6. prose: agent instructions that say "find the commits"
git grep -nEi '(search|grep|find|locate|look up)[^.]{0,40}commit|commit[^.]{0,40}(matching|search)|EST[- ]tagged' \
  -- 'skills/**/*.md' 'agents/*.md' 'templates/*.md'
# 7. commits that a script *writes*, to separate producers from consumers
git grep -nE 'git( -C [^ ]+)? commit .*-m|commit -F' -- $SCOPE "${EXCL[@]}" ':!*.md'
```

**Result of the cross-check.** Pass 2 found no consumer that pass 1 missed in `skills/`, `scripts/`, `agents/`,
`hooks/`, `lib/`, `mcp/` or `project/app`. It added only rows that pass 1 had already classified as not
discovery: the path- and SHA-based readers in section 3.3 (U2-U11), and it confirmed the dashboard
(`git-log.js`) as the only JavaScript git caller (9.3 filtered to lines mentioning `git` returns that one file;
the other `child_process` users spawn `node` (`lib/commands/dashboard.js:72`), `bash` (`lib/config/paths.js:44`,
`mcp/training_runner/index.js:69`) or a platform opener (`project/app/ui/scripts/dashboard-open.cjs:64`,
`dashboard-start.cjs:100`)). The three Python files that run `git` (`skills/index/scripts/board_index.py`,
`skills/j-doc/scripts/resolve_last_update.py`, `skills/j-train/train_cli.py`) only call `rev-parse --show-toplevel`.
Pass 2 (4) found the only trailer reader, `compute-deploy-reconcile.sh` (U1), which reads the *public* mirror
commit, and no `Jenga-Task` reference anywhere in the tree. Pass 2 (7) lists the producers in section 10.

## 10. Producers of board-related commit subjects (context for Open Decision 6)

Not consumers, and out of scope for the resolver, but the subject forms below are what the consumers above
currently match, so `E79_S05`/`E79_S06` must decide for each whether it keeps its Jenga form or inherits the ref.

| Producer | Subject form |
|---|---|
| `skills/j-commit/SKILL.md` (developer agent) | `task(<id>): ...`, `story(<id>): ...`, `epic(<id>): ...` |
| `skills/j-dev-done/scripts/commit-post-sync.sh:191-193`, `:222` | `chore(self-sync): mirror root -> .claude/.agents[, update N board ticket(s)]`: no board id. Hand-written self-sync commits do carry one (`chore(self-sync): mirror E75_S01_T03 events-append helper ...` is in this repository's history) |
| `skills/j-mirror-public/scripts/mirror.sh:2004`, `:2014` | `chore(mirror): sync from private at <sha> <ts>` plus the `Source-Commit:` trailer (public repo) |
| `scripts/merge-task-into-perceived-branch.sh:379` (asserted in `tests/merge-task-into-perceived-branch.bats:336`) | `merge: <task-branch> into <perceived-branch>`; the task branch is named `E##_S##_T##-slug`, so the id is in the subject (a merge commit, so `--no-merges` consumers skip it, and S3 classifies it as board) |
| `agents/developer.md`, `agents/tester.md` ("Commit the rapport immediately") | `chore(<id>): add rapport ...`; tester verdict and `chore(board)` commits |
| `skills/j-distribute/scripts/commit-version-bump.sh:107`, `skills/j-gitignore/scripts/untrack-jenga-files.sh:178`, `skills/j-init/scripts/init.sh:153`, `skills/j-publish/scripts/droplet_pipeline.sh:207`, `npm_ci_pipeline.sh:283` | Non-board forms (`chore(publish)`, `init:`, version bump); carry no board id |

## 11. What this means for `E79_S02` and the Open Decisions

Migration worklist for the shared resolver (`E79_S02`), in dependency order. `E79_S02_T04` to `T07` already
name `close-story`, `mark-merged`, `reconcile` and "remaining audited consumers"; this audit fixes the last one.

| Resolver call site | Rows | Notes for the task |
|---|---|---|
| Anchored id, returns SHAs | M4, M5, M6, M7 (identical `commits_for_ticket`) | Four copies of one function; reuse its pattern as the base (assessment, Problem 4). Add the prefix-collision fixture (`E51_S02` vs `E51_S02_T01`) |
| Unanchored task id | M1 (and M3 prose) | Today's substring match over-attributes; decide whether the resolver reproduces it for EST history (differential test) or tightens it, and record which |
| Story id, unanchored by design | M2 | Documented but uncalled. Migrate or retire; do not assume it is exercised |
| Parenthesised id, ranged | M10 | Needs the resolver to accept a range and the `(id)` form, or to be taught the trailer, or the filter keeps failing open for id-free commits |
| Agent prose | M3, M8, M9, M11 | Replace the grep instructions with a call to the resolver script; M8 additionally needs `--require-nonempty` semantics so an empty result is reported as "unresolvable", not as "not implemented" |
| Subject classifier | S1 | Needs full-message / trailer parsing (assessment, Problem 5, Solution A); S2 needs the exclusion rule re-stated |

Answers this audit supplies to the Open Decisions it feeds:

- **Decision 3 (horizon).** The consumers' horizons are: instant (S3), last 200 commits (S2, D3), same story
  (M1-M4), days (M5, M6), weeks to months bounded by the next public tag (M7, M10), and unbounded (M8, M9, S1,
  M11). The proposed horizon (`reconcile` on a fresh clone 90 days after a client merge) is the M8 / S1 case,
  and it is the only one that also depends on whether `git log --all` still sees the commits after a squash
  merge. It remains a proposal until a person confirms it.
- **Decision 6 (Jenga-form commits).** Section 6 and section 10 are the evidence: the id-bearing bookkeeping
  commits are matched today and are part of the file union that M4-M7 compare against.
- **Not answered here, because it needs the client:** merge method, squash-body behaviour, commitlint rules for
  body and footers, and whether hooks must run in task worktrees (Open Decision 4; template in
  `E79_S01_T03`).

### 11.1 Final status of the rows owned by `E79_S02_T07`

Added by `E79_S02_T07`. Rows `M1`-`M3` are `E79_S02_T04`, `M5` is `E79_S02_T05`, `M8`/`M9` are `E79_S02_T06`, and
`S1`-`S5` are `E79_S05`/`E79_S06`; this table does not touch them.

| Row | Consumer | Final status | Detail |
|---|---|---|---|
| M4 | `skills/j-close-story/scripts/check-privatized.sh` | **Migrated** | `commits_for_ticket` now calls `scripts/commits-for-item.sh <id> --repo "$REPO_ROOT"`, located package-relative first (`$SCRIPT_DIR/../../../scripts/`), then `node_modules/@jenga-ai/agent/scripts/`; a missing resolver is a `die`, not an empty result. No `--require-nonempty` (`E79_S06`). |
| M6 | `skills/j-mirror-public/scripts/mark-publicized.sh` | **Migrated** | Same shape and lookup order as M4. |
| M7 | `scripts/mark-deployed.sh` | **Migrated** | Resolver located beside the script (`$SCRIPT_DIR/commits-for-item.sh`), with no `REPO_ROOT` fallback, matching how this script already finds `with-lock.sh` (a consumer's own repo need not ship it). |
| M10 | `skills/j-publish/scripts/generate_release_notes.sh` (`_pi_task_is_fully_blocked`) | **Left alone, needs a decision** | The filter is range-limited (`git log "$LAST_TAG..$TO_REF"`) and matches the literal `(<task_id>)`. The resolver is `--all`, unranged, and matches the id anywhere in the message, so a drop-in would change which commits count for a privacy filter that publishes to a public changelog (a task whose only matching commit is older than the last tag, or on another branch, would newly count; a body-only mention would newly count). Making the filter trailer-aware, or not fail open on an id-free commit, is a separate decision about that filter. See the rapport `project/rapports/problems/E79_S02_T07-release-notes-and-redo-left-alone.md`. |
| M11 | `skills/j-redo/SKILL.md:48` | **Left alone, needs a decision** | It is a *title* search (`--grep="<epic or story title>"`), not an id search, so the resolver cannot express it. Moving it to ids (story id -> its task ids -> one resolver call each, unioned) changes what the user is shown and is contract row `O5`. Its SHA input is unaffected. Same rapport. |

Tests: the previously untested discovery paths of M4 and M7 now have focused cases in
`tests/E79_S02_T07-migrated-consumers.bats` (anchoring, union over all commits, zero-match, side-branch commit,
trailer, missing resolver, ancestry). M6 is covered by `tests/mark-publicized.bats`. The three existing fixtures
(`tests/check-privatized-event.bats`, `tests/mark-publicized.bats`, `tests/external-refs-absent-safe.bats`) gained one
`cp` of the resolver in their setup because those scripts now depend on it; no assertion changed.

## 12. Limits of this audit

- **Model-driven consumers are not fully greppable.** M3, M8, M9 and M11 were found because their prose names
  `git log` or `--grep`. An instruction that says "check whether the work was committed" without naming a
  command would not appear in any pattern above. The assessment's mitigation for this class is a `.bats`
  guard that fails on new raw `--grep=<task_id>` uses outside the resolver; it belongs to `E79_S02`.
- **`.claude/` and `.agents/` are not searched.** They are generated copies of the root directories.
- **Line numbers drift.** They are exact at `971fab17`; the section 8 commands are the durable form.
- **Counts in section 6 depend on the refs present** (`--all` includes every local worktree branch).
- **Documentation outside the searched trees** (`project/documentation/`, `site/`, `docs/`) describes the
  consumers but does not run them, and was not audited as consumers.

## 13. The shared resolver (added by `E79_S02_T01`)

The worklist in section 11 now has its target: [`scripts/commits-for-item.sh`](../../scripts/commits-for-item.sh)
(`commits-for-item.sh <id> [--require-nonempty] [--repo <dir>]`). Its header is the authoritative reference (usage,
forms, anchoring, `--all --no-merges` choice, exit codes); this section records only how it maps onto the rows above.
No consumer is migrated by this task; `E79_S02_T04` to `T07` do that, and `E79_S02_T02` / `T03` prove it.

| What the resolver does | Rows it serves | Notes for the migrating task |
|---|---|---|
| Anchored id (`<id>([^0-9_]\|$)`), `--all --no-merges`, newest first, prints full SHAs | M4, M5, M6, M7 (the four `commits_for_ticket` copies) | A drop-in for the function body: `commits_for_ticket() { "$REPO_ROOT/scripts/commits-for-item.sh" "$1" --repo "$REPO_ROOT"; }`. EST-only output is identical (the `E79_S02_T02` differential test is the proof) |
| Recognises a `Jenga-Task: <id>` trailer through git's trailer parser, and never matches a template-form subject by its ref | M1 to M9 once a project opts in | Pass B of the script. The grep alone already finds a body trailer (section 5); the explicit trailer pass keeps working if the EST pass is ever narrowed |
| `--require-nonempty`: exit 1 naming the id; exit 3 `history unavailable (shallow clone)` when the repository is shallow | M1, M5 first (`E79_S06`), M8 | Implements the contract's fail-loud rule (section 6) and its shallow-clone distinction. Default stays exit 0 on empty, so migrating a consumer changes nothing until it asks for the flag |
| Epic/story ids match only commits that name that id | M2 (`extract-diff-stats.sh`) | **Difference to decide in `E79_S02_T04`:** M2 is unanchored by design, so a story id also matches every child task id. The resolver is anchored, so a story query does not return commits that only name a child task. Either the consumer resolves the story's tasks and unions them, or a descendant option is added then, deliberately |
| Not covered | M10 (`(<task_id>)` ranged filter), M3/M8/M9/M11 prose, S1 to S5 classifiers | M10 needs a revision range; S1 needs per-commit (reverse) attribution. Both are `E79_S02_T07` / `E79_S05` questions, not answered here |

Known behaviours reproduced rather than fixed, so the differential test can pass: `--all` counts every local
branch and worktree branch, cherry-picks with `[pick <sha>]` subjects count as separate commits, `chore(board)`,
`chore(self-sync)` and rapport commits that mention the id are returned, and the left side of the id is not
anchored.
