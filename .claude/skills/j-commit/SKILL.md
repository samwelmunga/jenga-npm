---
name: j.commit
description: Commit implemented epic, story, or task work using the EST naming convention. Also handles user-action prerequisites and new-epic boundaries. Use after completing any EST work item.
keywords:
  - commit
  - save
  - git commit
  - done
  - push
  - j-commit
examples:
  - "commit this work"
  - "save my changes"
  - "j-commit"
---

# Commit — Commit Completed Work

`skills/j-commit/` is the **canonical, hand-edited** directory for this skill, per CLAUDE.md's "The Canonical Naming Contract" (the `E50` reopening of 2026-09-09, which promoted `skills/j-commit/` from generated twin to sole canonical form). The `j-` prefix is there for collision safety — a real directory under a distinct name, so a host tool shipping its own same-named built-in command cannot shadow it (Claude Code's native skill resolution is a literal-string, directory-name-based match; see `project/documentation/skill-authoring.md`'s "Invocation Convention").

> ⚠️ **`scripts/generate-j-alias.sh` was retired by `E50_S14` and no longer exists — there is nothing to run.** This file was previously generated from a bare `skills/commit/SKILL.md` source; `E50_S15` deleted that directory. This file is now the sole canonical, hand-edited source for this skill — edit it directly.

## Arguments

- `<E##|E##_S##|E##_S##_T##>` (optional) - the scope id handed to `/reconcile` in step 1, as before.
- `--tests <ask|skip|scoped|full>` (optional) - the test gate's per-invocation override (step 3.5): it replaces the
  recorded default for this one invocation only, and `ask` forces the prompt even when a default is recorded. A
  value outside those four is rejected by `test-gate-decide.sh resolve` (exit 2) for every caller: nothing is
  committed. A valid value is ignored for a non-interactive caller. `/lgtm` and `/dev-done` forward it unchanged.
- `--caller <interactive|noninteractive>` (optional) - who is driving this commit. Pass `--caller noninteractive`
  whenever `j.commit` was reached by a sub-agent, by a sender-object caller (a developer or tester agent), or by any
  automated run with no human to answer; pass `--caller interactive` otherwise. This is the one judgment the test
  gate leaves to you; everything else is decided by scripts.

---

## Inline Mode (called by /do for inline-scoped tasks)

When invoked with the `--inline` flag OR when the environment variable `JENGA_COMMIT_INLINE=1` is set, execute inline mode:

1. **Skip** the reconcile step, the `/doc-sync` scan, and the user-action prerequisites check (steps 1-3 in normal mode). No `/reconcile` invocation, `/doc-sync` invocation, or `_INSTRUCTIONS.md` lookup is performed — inline tasks are single, already-scoped-small changes that reconcile and doc-sync would add overhead to, not risk, disproportionate to the size of the change.
2. **Skip** any worktree merge logic — inline tasks execute in the main session with no dedicated worktree to merge.
3. Stage all changed files relevant to the task (use `git add -A` or specific files if a list was provided by the caller).
3.5. **Test gate skip** — inline mode never prompts and never runs tests. Call `bash "$TG/test-gate-decide.sh" resolve --inline --caller noninteractive` (`TG` as defined in step 3.5 of normal mode, below), print the one line `Tests skipped: <reason>` from its output (never "passed"), and log it with `bash "$TG/test-gate-run.sh" log --action skip --reason "<reason>" --caller noninteractive`. Then continue.

4. **Pre-commit gate** — fire phase `pre-commit` per "Pre-commit gate" below. Inline mode skips reconcile and doc-sync but **not** this gate. On a `block` failure nothing is committed.
5. Commit using the EST naming convention:
   ```
   task(<E##_S##_T##>): <short description of what was done>
   ```
   The task ID (`E##_S##_T##`) must be taken from the context provided by `/do` — do not inspect task frontmatter independently.
   An inline commit is always a board commit, so the project's commit-format convention never applies here (see "Project commit-format convention" below).
6. **Exit** — do not check for the next epic and do not emit "All Done!" in inline mode. `/do` manages the loop and next-epic detection.

If `--inline` is absent **and** `JENGA_COMMIT_INLINE` is not set (or is not `1`), ignore this section entirely and proceed with normal mode below.

---

## Instructions

If no epic, task, or story has been implemented, exit with the message: "No implementation to commit."

1. **Reconcile first, scoped to this commit** — Invoke the `/reconcile` skill before any other action, so the board is never committed in a drifted state.
   - **Determine the scope to pass** (in order):
     1. If `/commit` was invoked with an explicit epic/story/task id argument (e.g. `/commit E46`, `/commit E17_S04_T02`), use that id.
     2. Otherwise, if the calling context already identifies a single task/story/epic just completed (e.g. a developer or tester agent's sender object naming `task_id`/`story_id`/`epic_id`, or a `/do` invocation for one task), use that id.
     3. Otherwise, derive it from what's staged: run `git diff --cached --name-only` and filter to paths under `project/board/epics/`, `project/board/stories/`, and `project/board/tasks/`. Extract the id each matched filename encodes.
        - If every extracted id shares a single common story-or-narrower ancestor (all belong to one story's own file plus any of its own tasks' files, or are all exactly one task's own file, or are all exactly one epic's own file with nothing narrower staged), use that single most-specific id (story/task id if present, else the epic id) as the scope.
        - If matched ids span more than one distinct story, or more than one distinct epic, this case does not resolve — do not guess between them; fall through to case 4.
        - **If no board files at all are staged, skip `/reconcile` entirely — do not fall through to case 4.** A commit that touches no board file cannot itself commit board drift, so there is nothing for a pre-commit reconcile to protect against; running a full unscoped scan here would be pure waste, not a safety net. This is distinct from the multi-item case immediately above, which still falls through to case 4 since board files genuinely are changing there.
     4. Otherwise — no argument, no sender context, and staged board files span more than one distinct story or epic — fall back to unscoped `/reconcile` (full board), unchanged from prior behavior.
   - **Invoke** `/reconcile <scope> --from-commit` when a scope was determined in cases 1-3, `/reconcile --from-commit` (unscoped) on the case-4 fallback, or skip the reconcile step entirely per case 3's no-board-files-staged outcome. `--from-commit` marks this call as part of the commit flow, so `/reconcile` does not fire its own `pre-reconcile` pre-flight gate here (the commit's own `pre-commit` gate in step 4 covers it); `/commit` is the only caller that passes it. Do not re-derive or duplicate `/reconcile`'s own default-scope-to-epic expansion here — passing a bare story or task id through is sufficient; `/reconcile` itself resolves that to the containing epic.
   - **If `/reconcile` was skipped** (case 3's no-board-files-staged outcome) — continue silently to the next step, exactly as the no-drift outcome below.
   - **If reconcile detects and corrects drift** — inform the user what changed (e.g. demoted/promoted statuses, merged orphaned worktrees, cleaned `todo.md` entries) before proceeding.
   - **If reconcile finds no drift** — continue silently to the next step.

2. **Doc-sync scan, scoped to this change (report-only, non-blocking)** — Invoke `/doc-sync` scoped via its `source:` argument to the files actually changed by the work being committed — never a full-repo scan. Determine the changed-file list from the work being committed (e.g. `git diff --name-only HEAD` combined with untracked files from `git status --porcelain`, or the task's known changed-file set when commit context already identifies them) and pass it as `source:` so doc-sync only analyses what this commit touches.
   - **Design decision — report-only, not blocking:** doc-sync's own step 5 ("report findings, ask before applying") is a human-approval gate. When invoked from `/commit`, doc-sync runs only through its own step 5 (report the drift findings) and explicitly does **not** proceed to its step 6 (apply updates) as part of this flow — `/commit` never surfaces doc-sync's apply-confirmation prompt mid-commit. *Rationale: nesting a second approval gate inside an already-in-flight commit either stalls a flow the user expected to complete in one shot, or trains the user to reflexively decline the nested prompt just to get their commit through. Report-only surfaces documentation drift at the cheapest possible moment to notice it — right when the change is fresh — without forcing an apply/skip decision under commit pressure; the user reviews the findings and runs `/doc-sync` standalone afterward if they want to apply them.* This introduces no change to `/doc-sync`'s own step 5 approval semantics and no new auto-apply flag — `/commit` simply never invites it past step 5.
   - **If doc-sync reports drift findings** — surface them to the user as part of the commit output (informational), then continue to the next step regardless of the findings.
   - **If doc-sync reports no drift** — continue silently to the next step.

3. **Verify user-action prerequisites** — Check whether an `_INSTRUCTIONS.md` file exists for this task at `project/instructions/<E##_S##_T##>_INSTRUCTIONS.md`. If the task has out-of-scope prerequisites but no instructions file was created, create one now using `assets/user_instructions_template.md`. If one already exists, surface it to the user as a reminder. (The developer should have created this file during task intake — this is a final safety check.)

3.5. **Test gate** — ask whether to run tests before this commit, run them if the user chose to, and decide whether the commit may go on. This step sits **after** step 3 and **before** the pre-commit gate (step 4), and nowhere else, for two reasons: the reconcile in step 1 may merge orphaned worktrees, so the set of changed files is final only after step 3; and tests can run for a long time, so step 4's situation marker (written immediately before its first `check`) must never be open across them. The test gate writes **no** situation marker, and a halt leaves none behind. Step 4 stays the last thing before the commit command. The steps are not renumbered.

   Everything deterministic is in three scripts under `skills/j-commit/scripts/` (`test-gate-decide.sh`, `test-gate-scoped.sh`, `test-gate-run.sh`; headers are the contract). This step only relays their output and holds the conversation: it parses nothing, maps no answer and decides no proceed/halt itself. Show each script's stdout to the user verbatim. The scripts are run with `bash`, from the dual path:

   ```bash
   TG="$([ -d skills/j-commit/scripts ] && echo skills/j-commit/scripts || echo node_modules/@jenga-ai/agent/skills/j-commit/scripts)"
   ```

   **Boundary.** The developer agent never runs tests (CLAUDE.md); a human answers this prompt, and a non-interactive caller skips with a logged note instead. A non-zero exit from a `test-gate-decide.sh` call other than the answer parsers' exit 1 and `directive`'s exit 1 (a usage error, a missing `jq`) means do not proceed: show its stderr, then follow **Halt** below.

   **a. Resolve.** Run `bash "$TG/test-gate-decide.sh" resolve [--tests <value>] --caller <interactive|noninteractive>` (pass `--tests` only when it was given). It prints one JSON line; show any `warnings` entry, then branch on its `action`:
   - `skip` - print the one line `Tests skipped: <reason>` (never "passed"), log it with `bash "$TG/test-gate-run.sh" log --action skip --reason "<reason>" --caller <caller>`, and go to step 4. A non-interactive caller always lands here and is never prompted.
   - `run` - announce in one line which recorded default or per-invocation override applies and that `--tests ask` shows the prompt instead, then continue with its `choice`.
   - `prompt` - show `bash "$TG/test-gate-decide.sh" prompt` (add `--default <recorded_default>` when the JSON's `recorded_default` is not empty) exactly as printed (it offers three options: 1 a scoped run of the tests covering the committed scope, 2 the full suite through `j.test`, 3 skip; blank skips, or takes the recorded default when one exists), take the answer exactly as typed, and run `bash "$TG/test-gate-decide.sh" answer "<raw>"` (same `--default`). On exit 1 show its stderr and ask again, until the answer is valid or the user cancels; a cancel is a Halt. Its stdout is the `choice`.

   **b. Act on the choice.**
   - `skip` - say that tests were skipped by choice and none were run, and log it (`test-gate-run.sh log --action skip --choice skip --caller interactive`). Go to step 4.
   - `full` - `GATE_DIR="$(mktemp -d)"`, then `bash "$TG/test-gate-run.sh" full --out-dir "$GATE_DIR"`.
   - `scoped` - `GATE_DIR="$(mktemp -d)"`, then `bash "$TG/test-gate-scoped.sh" --out-dir "$GATE_DIR"`; it prints the plan JSON. When its `status` is `mapped`, run `bash "$TG/test-gate-run.sh" scoped --plan "$GATE_DIR/plan.json"`. When `status` is `zero` or `error` (or the script itself exited non-zero), say plainly that the mapping found no test to run or failed and that this is **not a pass**; show `bash "$TG/test-gate-decide.sh" fallback-prompt --reason "<the plan's message>"`, take the answer exactly as typed, run `bash "$TG/test-gate-decide.sh" fallback-answer "<raw>"` (re-ask on exit 1), then run `full` as above or skip, logging `bash "$TG/test-gate-run.sh" log --action fallback --choice <full|skip> --reason "<the plan's message>" --caller interactive`.

   **c. After a run.** `test-gate-run.sh` ends its stdout with `TEST_GATE_RESULT=<result>` and `TEST_GATE_FAILED=<names>`; read both. Exit 2 means two different things: with a `TEST_GATE_RESULT=error` line the run was attempted and could not execute (result `error`); with no `TEST_GATE_` line at all a plan was refused or the call was malformed and nothing ran (treat it like a `zero`/`error` plan: say nothing was run, then the fallback prompt from step b, with the stderr message as the reason). Then, by `<result>`:
   - `passed`, `unavailable` - for `unavailable` say plainly that no tests were run (never a pass). Log it (`log --action passed` or `--action unavailable`), then `bash "$TG/test-gate-decide.sh" directive <result>`.
   - `interrupted` - no prompt: log `--action interrupted`, then `directive interrupted` (it halts).
   - `failed`, `error` - log it (`--action failed` or `--action error`, `--failed "<TEST_GATE_FAILED>"`). Show `bash "$TG/test-gate-decide.sh" failure-prompt --failed "<TEST_GATE_FAILED, or unknown suite when empty>" [--kind error]` (`--kind error` for `error`), take the answer exactly as typed, run `bash "$TG/test-gate-decide.sh" failure-answer "<raw>"`; on exit 1 show its stderr and ask again (there is no default and a blank answer never proceeds); a cancel is a Halt. For `fix`, tell the user which suites failed and that `j.commit` can be re-invoked after the fix (the gate then runs again from scratch). For `anyway`, log `--action override --choice anyway --failed "<names>"`. Then run `bash "$TG/test-gate-decide.sh" directive <result> --choice <fix|anyway|abort>`.

   **d. Directive.** `directive` prints `GATE=PROCEED` (continue to step 4) or `GATE=HALT` (a **Halt**). Log every outcome with `test-gate-run.sh log` (`passed`, `failed`, `error`, `unavailable`, `interrupted`, `override`, `halt`, `skip`, `fallback`), always with `--caller`.

   **Halt.** Print the line `TEST_GATE=HALT` on its own line and then `Commit halted at the test gate: nothing was committed.`, log `--action halt`, and stop the whole of `j.commit`: nothing is staged, committed or marked, no later step runs, and no situation marker exists. `/lgtm` and `/dev-done` recognise this and stop too.

   **Cleanup.** When `GATE_DIR` was created, run `rm -rf "$GATE_DIR"` on every exit path (proceed, skip, Halt, error).

   **Never persisted.** No choice made here (a skip, a full run, a failure answer, an override) is written to `test-config.json`: the next commit gates again. A recorded default changes only when the user runs `jenga config set test-config.commit_prompt_default <value>` (`""`, `skip`, `scoped` or `full`).

4. **Pre-commit gate** — fire phase `pre-commit` per "Pre-commit gate" below: after the reconcile, doc-sync and prerequisites steps above, immediately before the commit command. On a `block` failure nothing is committed.

5. **Commit** using the following format:
   - **Epic:** `epic(<Epic Title>): <MAX_50_CHAR_SUMMARY>`
   - **Task/Story:** `story(<Epic Title>_<Story Title>): <MAX_50_CHAR_SUMMARY>`
   
   **Fallback: Group changes logically** — prefer one commit per coherent unit of work, but don't force splits. When in doubt, keep it together.

   **Non-board commits** (chore, docs, a change with no board item) follow the project's recorded commit-format convention, if any; see "Project commit-format convention" below. EST naming above is unchanged for every board commit.

6. **Check for next epic** — If a new epic is to be started, inform the user that a new conversation should be initiated. If there are no subsequent epics left, show the message: "All Done! 🎉"

---

## Project commit-format convention

A project may have recorded a `commit-format` convention through `j.conventions` (`project/documentation/project-conventions.md`). It shapes the message of **non-board** commits only. EST naming is never overridden by it.

1. **Classify the commit.** It is a **board commit** when it implements or closes an epic, story or task (EST work, which `/reconcile` relies on): the calling context names a `task_id`, `story_id` or `epic_id`, or the work being committed is board work. Its subject is EST naming: `task(<E##_S##_T##>): ...`, `story(...)` or `epic(...)`. Otherwise (chore, docs, a change with no board item) it is a **non-board commit**.
2. **Board commits: EST naming exactly as written above, unchanged and mandatory.** A recorded `commit-format` convention never changes it, whatever it says (a regex, a style, a length limit). Do not run the digest for the purpose of reshaping a board commit message.
3. **Non-board commits: apply the convention.** Run `bash "$([ -f scripts/conventions-digest.sh ] && echo scripts/conventions-digest.sh || echo node_modules/@jenga-ai/agent/scripts/conventions-digest.sh)" --agent commit` (written `scripts/conventions-digest.sh --agent commit`). If its `commit-format` line is present, write the message in that format; otherwise use the existing default. After composing the subject, run `bash "$([ -f skills/j-commit/scripts/commit-subject-check.sh ] && echo skills/j-commit/scripts/commit-subject-check.sh || echo node_modules/@jenga-ai/agent/skills/j-commit/scripts/commit-subject-check.sh)" "<subject>"`: it classifies the subject (board subjects are always reported as `kind=board`, exit 0, the convention not consulted) and, for a non-board subject, checks it against the recorded `message_regex` and `subject_max_length`. Exit 1 means rewrite the subject and re-check; this is an advisory self-check on a message you wrote, not a gate on anything else (the `pre-commit` gate fires before any message exists and cannot test one).
4. **Empty digest: behave exactly as before.** If `scripts/conventions-digest.sh --agent commit` prints nothing (no `conventions.json`, or no `commit-format` line), or it fails, this section changes nothing: the commit flow, the EST formats above and the pre-commit gate behave exactly as they did before this section existed.

---

## Pre-commit gate

Fires pre-flight checklist phase `pre-commit` (`project/documentation/preflight-checklists.md`) at exactly one
point: immediately before the commit command, after staging and after the reconcile and doc-sync steps. It
fires in normal mode (step 4) and in `--inline` mode (step 4 of Inline Mode).

Follow "Calling the checker from a skill" in that document: mint a run id for this commit, call
`checklist.sh check pre-commit --run <id>`, and branch on the exit code and each item's `action`. A `block`
failure halts here and **nothing is committed**; the reconcile and doc-sync results already shown stand, but no
`git commit` runs until the item is satisfied or the user stops. With no registry, or an empty one, this gate
is silent and the commit proceeds exactly as before.

**Mark the situation.** Immediately after minting the run id and **before** the first `check`, write
the situation marker, and clear it on **every** exit path (success, a `block` halt, a declined
`confirm`, an error):

```bash
MARKER="$([ -f scripts/checklist-marker.sh ] && echo scripts/checklist-marker.sh || echo node_modules/@jenga-ai/agent/scripts/checklist-marker.sh)"
TOKEN="$(bash "$MARKER" write --situation pre-commit --run "$RUN_ID" --skill j.commit)"
bash "$MARKER" clear --token "$TOKEN"
```

This is what lets the enforcing hook see the phase; the protocol, the stack semantics and the TTL are
in "Situation marker" in that document. A failed `write` is **not** a reason to abandon the phase — the
gate above still runs and only the hook-enforced backstop is lost: report its stderr and continue.

Phases nest here: a `/commit` run from inside `/do`'s `pre-task` phase pushes its `pre-commit` frame on top
of that one, and clearing by token pops only its own. Never clear without a token in this skill.
