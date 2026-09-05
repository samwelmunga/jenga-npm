## Reconciliation Report Format

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 RECONCILIATION REPORT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Scope: <resolved scope — see forms below>

📊 Scanned: <N> epics, <N> stories, <N> tasks

⬇️  DEMOTED (were Done/Passed → now Pending)
   🔧 E##_S##_T## · <Task Title>  — no commits or artefacts found

🔀 MERGED (worktree branch merged)
   🔧 E##_S##_T## · <Task Title>  — merged branch <branch-name>

⬆️  PROMOTED (were incomplete → now Passed)
   🔧 E##_S##_T## · <Task Title>  — commits found, acceptance criteria met

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
- The TODO CLEANUP section is always shown if `project/todo.md` existed at the start, even if zero changes were made (in that case show all counts as 0).
- If `project/todo.md` did not exist, omit the TODO CLEANUP section.
- The DOD GAPS section is omitted if no completed stories have unchecked DoD checkboxes.
- When `Scope:` is not `full board`, the UNLINKED CODE section's `groups[]` / `covered_groups[]` /
  `not_checked[]` have been filtered to the resolved scope's `owned_path_hints` on a best-effort,
  non-authoritative basis (see `/reconcile`'s Phase 5) — append "(scope-filtered, best-effort)" to
  the `🗺️ UNLINKED CODE` heading in that case, since `owned_path_hints` can be incomplete and a
  path missing from it is not proof the path lies outside the scope.
