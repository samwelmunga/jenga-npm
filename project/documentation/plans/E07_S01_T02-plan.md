# Plan: E07_S01_T02 — History Entry List Component

## Approach
Create `HistoryList.jsx` (container) and `HistoryEntry.jsx` (individual row).

## Steps
1. `HistoryList`: maps `entries` to `<HistoryEntry>` with `onSelect` callback; shows empty state div if no entries
2. `HistoryEntry`: display date (formatted via `Intl.DateTimeFormat`), type icon/label (🔖 git_commit vs 📄 rapport), and subject/filename
3. Color-coded type badge using CSS classes: `.badge-commit` (blue) and `.badge-rapport` (green)
4. Click handler calls `onSelect(entry)` to update selected entry state in parent
