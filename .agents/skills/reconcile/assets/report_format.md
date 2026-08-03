## Reconciliation Report Format

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 RECONCILIATION REPORT
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

- Omit any section that has zero items (e.g. if nothing was demoted, skip the DEMOTED block entirely).
- The MERGED section should include the branch name that was merged.
- The TODO CLEANUP section is always shown if `project/todo.md` existed at the start, even if zero changes were made (in that case show all counts as 0).
- If `project/todo.md` did not exist, omit the TODO CLEANUP section.
- The DOD GAPS section is omitted if no completed stories have unchecked DoD checkboxes.
