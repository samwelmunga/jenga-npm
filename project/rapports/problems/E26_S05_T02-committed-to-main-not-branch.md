---
id: E26_S05_T02-committed-to-main-not-branch
kind: problem
severity: low
status: open
date_opened: 2026-08-01
opened_by: tester (inline)
related:
  - E26_S05_T02
  - E26_S05_T01
---

# T02 developer commit landed on `main` instead of its worktree branch

## What happened
The T02 developer sub-agent was assigned worktree `agent-a39a1c833d1719c0a` at
`.claude/worktrees/agent-a39a1c833d1719c0a`. Its commit `a7803ba` — `feat(E26_S05_T02):
create validate_npm_env.sh` — was authored inside that worktree per the dev's report,
but the commit landed on branch `main` and the assigned branch
`agent-a39a1c833d1719c0a` remained at the pre-existing head `78c3e96`.

Observable state after the run:
- `main` HEAD: `a7803ba` (contains `skills/publish/scripts/validate_npm_env.sh`)
- `agent-a39a1c833d1719c0a` HEAD: `78c3e96` (no `validate_npm_env.sh`)
- `agent-abf72e2cee0c3ffb1` HEAD: `e4f1a85` (T01, correctly on its branch, contains `npm_pipeline.sh` only)

## Impact
- Low. T02's artifact is on `main` and passed all ACs on validation, so no work
  was lost.
- The T02 worktree is now orphaned — its branch pointer is behind main and its
  working tree lacks the file the dev claims to have written there.
- T01 still needs a normal branch merge to land on `main`; nothing about this
  anomaly blocks it.

## Likely cause
The worktree was created from `main`, and either (a) the dev used `git checkout main`
inside the worktree before committing, or (b) a hook or wrapper pushed the commit
to `main` directly. The dev's own report also mentions overwriting
`.session_handoff.json` — a shared, single-object file — suggesting the framework's
worktree isolation contract is porous.

## Recommendation
- Do NOT try to "restore" T02's branch — the file is already on `main`, and moving
  it would just re-create work. Leave `agent-a39a1c833d1719c0a` orphaned; it can be
  pruned with `git worktree remove` and `git branch -D`.
- Follow up on the [[session-handoff-race]] concern the T01 dev flagged: convert
  `.session_handoff.json` to JSONL to eliminate the parallel-worktree write race.
- Consider adding a guardrail to the developer agent template: assert `git branch --show-current`
  matches the assigned branch before committing.
