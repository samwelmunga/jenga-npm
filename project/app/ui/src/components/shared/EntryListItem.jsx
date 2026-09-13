import './entry-list.css'

/**
 * EntryListItem — E58_S01_T06.
 *
 * One clickable row for a single "markdown library" entry, generalized from
 * `../history/HistoryEntry.jsx`'s clickable/keyboard-accessible pattern so `E58_S02` (Rapports)
 * and `E58_S03` (Documentation) can each wire a new tab against this one component instead of
 * building their own.
 *
 * ── Entry shape contract ────────────────────────────────────────────────────────────────────
 * `entry` is expected to be shaped exactly like the objects returned by
 * `api/parsers/rapports.js`'s `readRapportsFull()` and `api/parsers/documentation.js`'s
 * `readDocumentation()` (confirmed byte-identical in shape by E58_S01_T05's dispatch context):
 *
 *   {
 *     file:     string,        // display filename/path, e.g. "README.md" or a rapport filename
 *     data:     object,        // gray-matter-parsed frontmatter (may be {})
 *     content:  string,        // full, untruncated raw markdown body
 *     category: string,        // taxonomy label — differs per consuming tab (Rapports:
 *                               // analysis|problems|tests|summaries|plans|ideas; Documentation:
 *                               // summary|readme|strategy|example)
 *     date:     string|null,   // "YYYY-MM-DD" or null
 *   }
 *
 * `entry.file` is used as the stable identity/list-key (these entries carry no `sha` the way
 * git-commit history entries do). If a consumer's list ever contains two entries with the same
 * `file` value, that is the consumer's responsibility to dedupe before passing `entries` in —
 * this component does not detect or guard against the collision.
 *
 * ── Selection / wrapping contract ───────────────────────────────────────────────────────────
 * `onSelect(entry)` is called with the RAW, unwrapped entry exactly as received — this component
 * never mutates or tags it. Mirroring `components/board/BoardView.jsx`'s existing `onSelect`
 * precedent (`setSelected({ type: 'board_item', kind, ...item })`), it is the CONSUMING TAB's
 * responsibility to wrap the selected entry with a `type` discriminator before handing it to
 * `../history/EntryDetailPanel.jsx`, e.g.:
 *
 *   onSelect={entry => setSelected({ type: 'library_entry', ...entry })}
 *
 * `EntryDetailPanel.jsx`'s new `library_entry` branch (added by this same task) expects exactly
 * that wrapped shape.
 */
function formatDate(iso) {
  if (!iso) return '—'
  return new Intl.DateTimeFormat(undefined, {
    year: 'numeric',
    month: 'short',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(iso))
}

export default function EntryListItem({ entry, isSelected, onSelect }) {
  const title = entry.file || '(untitled)'

  return (
    <li
      className={`entry-list-item${isSelected ? ' selected' : ''}`}
      onClick={() => onSelect(entry)}
      role="button"
      tabIndex={0}
      onKeyDown={e => (e.key === 'Enter' || e.key === ' ') && onSelect(entry)}
    >
      <span className="entry-badge">{entry.category || '—'}</span>
      <span className="entry-title">{title}</span>
      <span className="entry-date">{formatDate(entry.date)}</span>
    </li>
  )
}
