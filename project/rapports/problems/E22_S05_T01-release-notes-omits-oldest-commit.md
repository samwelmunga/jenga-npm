# Rapport: Release notes omit oldest commit in selected range

**Date:** 2026-07-11 (UTC)
**Agent:** Tester
**Related Epic:** /publish Skill — Deployment Pipeline Orchestrator
**Related Story:** Release notes & publish ledger
**Related Task:** Release notes generator — git log + board enrichment
**Type:** `test_failure`

---

## Sender
```json
{
  "sender": {
    "agent": "tester",
    "session_id": "tester-E22_S05-20260711T114854",
    "task_id": "E22_S05_T01",
    "story_id": "E22_S05",
    "epic_id": "E22",
    "date": "2026-07-11T09:55:30Z",
    "paths": [
      "98f9846",
      "4bd2a2d",
      "e99c6dc"
    ],
    "worktree": "/Users/samwelmunga/Desktop/Projects/agents/.claude/worktrees/E22_S05-release-notes-ledger"
  }
}
```

---

## Summary
`generate_release_notes.sh` can omit the oldest commit in the selected git range, producing incomplete release notes even when the last publish tag is resolved correctly. This blocks T01 and the parent story from passing.

---

## Context
Validated E22_S05 end-to-end across isolated scratch repositories inside the supplied worktree, plus smoke checks in the actual worktree. T02 and T03 behavior passed targeted integration coverage; the failure is isolated to T01 release-note generation.

---

## Problem Description
In a scratch repo with ledger-backed tag `v1.0.0`, a higher semver tag `v1.1.0` without a matching ledger row, and subsequent commits `docs: unreconciled docs`, `feat: add shiny thing`, `fix: squash launch bug`, and `chore: maintenance tweak`, the command:

```bash
bash skills/publish/scripts/generate_release_notes.sh --target staging-ios --output output/release-notes.md
```

resolved the correct last publish tag (`v1.0.0`) but the generated draft omitted `docs: unreconciled docs`, even though `git log v1.0.0..HEAD` contained it. This indicates the script is not reliably consuming the full git-log stream, so release notes can silently miss shipped work.

---

## Findings

| # | Finding | Severity | Notes |
|---|---------|----------|-------|
| 1 | Release-note generation drops the oldest commit in the selected git range. | High | Reproduced in tester scratch repo; expected `docs: unreconciled docs` in `### Other`, but the draft omitted it while `git log v1.0.0..HEAD` showed the commit. |

---

## Impact
T01 must be reworked before E22_S05 can be marked passed. Current release-note drafts are incomplete and may hide user-facing or operational changes from a publish.

---

## Suggested Next Steps
1. Fix `generate_release_notes.sh` so it consumes every `git log` record in the selected range, including the final record when the stream lacks a trailing newline.
2. Re-run tester coverage for T01, including: last ledger-backed tag resolution, full-history fallback, commit grouping, and board-enrichment behavior with and without board data.
3. Re-submit E22_S05 to Tester once the release-note draft contains every commit from `git log <last_tag>..HEAD`.
