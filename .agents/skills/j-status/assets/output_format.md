## Output Format

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 PROJECT STATUS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📦 E01 · <Epic Title>  [<Status>]  [███████░░░] 2/3 · 1 in progress
   📖 E01_S01 · <Story Title>  [<Status>]  [█████░░░░░] 1/2 · 1 in progress
      ✅ E01_S01_T01 · <Task Title>  [Passed]
      🔄 E01_S01_T02 · <Task Title>  [In Progress]
      ⏳ E01_S01_T03 · <Task Title>  [Pending]
   📖 E01_S02 · <Story Title>  [<Status>]
      ...

📦 E02 · <Epic Title>  [<Status>]
   ...

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 OPEN RAPPORTS  (2)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⚠️  problems/E01_S02-auth-conflict.md
📊  analysis/E01-performance-baseline.md

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 QUEUE  (1 pending trigger for scrum master)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 ⚠️  TODO.MD FORMATTING  (2 lines won't be recognized as queued)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
line 4: E05_S01_T02 – Verify terraform plan parity for dev and prod post-refactor (infra)
line 19: E12_S03 - Some other backwards entry
```

The bar after an epic or story row is the line `render-status-bars.sh` returned for that id (SKILL.md step 6.9), appended unchanged to the epic or
story row; task rows carry no bar. When the script returned nothing, rows print without it, as they always did.

Omit the `TODO.MD FORMATTING` section entirely when step 6.7's check exits `0` (nothing found) —
this is the common case and should not appear as an empty section.

## Status Icons

| Icon | Status |
|------|--------|
| ✅ | Passed / Passed with remarks |
| ❌ | Failed / Rejected |
| 🔄 | In Progress |
| ⏳ | Pending |
| 🚫 | Blocked |
| 📦 | Epic |
| 📖 | Story |
| 🔧 | Task |
