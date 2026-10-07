## Reconciliation Report Format

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 RECONCILIATION REPORT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Scope: <resolved scope — see forms below>

📊 Scanned: <N> epics, <N> stories, <N> tasks

⬇️  DEMOTED (were Done/Passed → now Pending)
   🔧 E##_S##_T## · <Task Title>  — no commits or artefacts found

🔒 LADDER STATUS — UNVERIFIED, LEFT UNCHANGED (script-set status, implementation not confirmed — status and dates untouched)
   🔧 E##_S##_T## · <Task Title>  — status <ladder status>; no commits, artefacts, branch or worktree found

🔀 MERGED (worktree branch merged)
   🔧 E##_S##_T## · <Task Title>  — merged branch <branch-name>

⬆️  PROMOTED (were incomplete → now Passed)
   🔧 E##_S##_T## · <Task Title>  — commits found, acceptance criteria met

⏳ IN-FLIGHT — SKIPPED (implementation confirmed by commit, but not promoted — active work appears ongoing)
   🔧 E##_S##_T## · <Task Title>  — concurrency-slot holder found in <concurrency-slots-file>
   🔧 E##_S##_T## · <Task Title>  — unmerged branch <branch-name>

🔄 ROLL-UP CHANGES
   📖 E##_S## · <Story Title>  — <old status> → <new status>
   📦 E## · <Epic Title>  — <old status> → <new status>

⚠️  DOD GAPS (completed stories with unchecked Definition of Done items)
   📖 E##_S## · <Story Title>
      - [ ] <unchecked DoD item text>
      - [ ] <unchecked DoD item text>
   📖 E##_S## · <Story Title>
      - [ ] <unchecked DoD item text>

🧹 TODO CLEANUP
   Removed: <N> stale entries
   Commented out: <N> newly-reconciled entries
   todo.md deleted: yes/no

⚠️  MALFORMED TODO ENTRIES (won't be recognized as queued — see scripts/check-todo-format.sh)
   line <N>: <raw line text>
   line <N>: <raw line text>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Section rules

- `Scope:` is always the very first substantive line of the report — above `📊 Scanned:` — so a
  scoped run is never mistaken for a full pass. Its exact form depends on the scope resolved in
  `/reconcile`'s Phase 0:
  - Unscoped run (`scope_type: "full"`): `Scope: full board`
  - Epic scope (`scope_type: "epic"`): `Scope: E12 (full epic)`
  - Range scope (`scope_type: "range"`): `Scope: S03-05 (2 stories, epic E12)` — name the epic(s)
    the range's resolved stories belong to (`epic_ids`); if the range spans more than one epic,
    list all of them, e.g. `Scope: S03-05 (3 stories, epics E12, E14)`.
  When `Scope:` is not `full board`, the `📊 Scanned:` line's counts reflect the resolved scope's
  own epics/stories/tasks only — not the whole board's.
- Omit any section that has zero items (e.g. if nothing was demoted, skip the DEMOTED block entirely).
- The MERGED section should include the branch name that was merged.
- The LADDER STATUS — UNVERIFIED section is report-only: it lists a task in a script-set ladder status
  (see `/reconcile` Section 0) that Phase 2 could not confirm and found no branch for. Unlike a `completed`
  task in the same position it is **not** demoted — its status and dates are left exactly as they were. It is
  never listed under DEMOTED.
- The IN-FLIGHT — SKIPPED section is distinct from both PROMOTED and the ordinary "implementation
  not confirmed, no action" case (which is never reported at all): it means Phase 3 found a
  matching commit (implementation confirmed) but withheld promotion because an active
  concurrency-slot holder or an unmerged matching worktree/branch was also found — see
  `/reconcile`'s Phase 3. Name the specific reason found (the concurrency-slots file, or the
  branch/worktree name) so the report is checkable, not just asserted. Omit this section entirely
  when no task was skipped for this reason.
- The TODO CLEANUP section is always shown if `project/todo.md` existed at the start, even if zero changes were made (in that case show all counts as 0).
- If `project/todo.md` did not exist, omit the TODO CLEANUP section.
- The MALFORMED TODO ENTRIES section is omitted entirely when `scripts/check-todo-format.sh` finds
  nothing (exit code `0`, no output) — this is the common case and should not appear as an empty
  section. Never auto-fix these lines: report only, exactly as written, with the line number so the
  user can locate and correct them (or leave them, if the line was never meant to queue anything).
  This section is purely additive to TODO CLEANUP above — a malformed line is invisible to `_queued`
  promotion, so it is never a candidate for the "already-done" or "newly-reconciled" cleanup rules,
  which both require a resolvable ref.
- The DOD GAPS section is omitted if no completed stories have unchecked DoD checkboxes.
- When `Scope:` is not `full board`, the UNLINKED CODE section's `groups[]` / `covered_groups[]` /
  `not_checked[]` have been filtered to the resolved scope's `owned_path_hints` on a best-effort,
  non-authoritative basis (see `/reconcile`'s Phase 5) — append "(scope-filtered, best-effort)" to
  the `🗺️ UNLINKED CODE` heading in that case, since `owned_path_hints` can be incomplete and a
  path missing from it is not proof the path lies outside the scope.
