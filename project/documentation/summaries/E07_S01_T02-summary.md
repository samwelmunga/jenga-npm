# Summary: E07_S01_T02 — History Entry List Component

## Implemented
- `dashboard/src/components/history/HistoryList.jsx` — renders reverse-chronological list; shows "No history entries found" on empty data
- `dashboard/src/components/history/HistoryEntry.jsx` — shows type badge (🔖 Commit / 📄 Rapport), subject/filename, and formatted date
- `dashboard/src/components/history/history.css` — colour-coded badges: blue for `git_commit`, green for `rapport`
- Click/keyboard navigation selects an entry (updates parent state via `onSelect`)

## Status: Complete ✓
