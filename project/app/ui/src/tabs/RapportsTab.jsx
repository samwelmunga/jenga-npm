import { useEffect, useMemo, useState } from 'react'
import { get } from '../api/client'
import LoadingSpinner from '../components/LoadingSpinner'
import ErrorMessage from '../components/ErrorMessage'
import EntryList from '../components/shared/EntryList'
import PaginationControls from '../components/shared/PaginationControls'
import EntryDetailPanel from '../components/history/EntryDetailPanel'
import './rapports-tab.css'

/**
 * Entries per page — E58_S02_T03. See `project/documentation/plans/E58_S02_T03-plan.md`'s
 * "Design Decision" section for the full rationale (no prior pagination UI existed in this
 * codebase to follow precedent from). Chosen to keep a single page well short of the "wall of
 * text" this task exists to fix, while producing a realistic multi-page result at both the
 * `problems/` category's real size (~115 entries -> ~5 pages) and the full aggregate's real size
 * (~880 entries -> ~36 pages at filing time).
 */
const PAGE_SIZE = 25

/**
 * RapportsTab — E58_S02_T01, search added by E58_S02_T02, pagination added by E58_S02_T03.
 *
 * Fetches the full, categorized rapports aggregate from `GET /v1/rapports` (E58_S01) on mount and
 * renders it via the shared `EntryList`/`EntryDetailPanel` component pair (also E58_S01), following
 * `HistoryTab.jsx`'s loading/error/fetch-on-mount pattern exactly.
 *
 * Each entry is shaped `{ file, data, content, category, date }`, covering all 6 source categories
 * aggregated by `readRapportsFull()`: `analysis`, `problems`, `tests`, `summaries`, `plans`, `idea`.
 *
 * Selection follows `EntryListItem.jsx`'s documented wrapping contract — `onSelect` receives the
 * raw entry, and this tab wraps it with a `type: 'library_entry'` discriminator before handing it
 * to `EntryDetailPanel`, which has a dedicated `library_entry` render branch.
 *
 * ── Search (E58_S02_T02) ─────────────────────────────────────────────────────────────────────
 * `query` filters the fetched `entries` into `filteredEntries`, a case-insensitive substring
 * match against `entry.file` — the same field `EntryListItem.jsx` itself renders as the row's
 * visible "title" (these rapport/documentation entries carry no separate frontmatter `title`
 * field; `file` IS the title the user sees). Filtering is a plain `useMemo` derivation over the
 * already-fetched in-memory list — no new network request is made when `query` changes. An empty
 * (or whitespace-only) query returns `entries` unchanged; a query matching zero entries yields an
 * empty array, which `EntryList` already renders as an explicit "No entries found." state rather
 * than a blank area.
 *
 * ── Pagination (E58_S02_T03) ─────────────────────────────────────────────────────────────────
 * `page` slices `filteredEntries` into `pagedEntries` (`PAGE_SIZE` entries per page, purely
 * client-side — no new query params are ever sent to `GET /v1/rapports`, which is still called
 * exactly once, on mount, with no arguments). Changing `query` resets `page` back to 1, so a
 * narrowed search always starts from the first page of its own result set rather than an
 * out-of-range page carried over from the previous (larger) list. A separate clamp guards the
 * case where `totalPages` shrinks out from under an already-advanced `page` for any other reason.
 * `PaginationControls` (new shared component, `../components/shared/PaginationControls.jsx`)
 * renders nothing when there's only one page.
 */
export default function RapportsTab() {
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [entries, setEntries] = useState([])
  const [selected, setSelected] = useState(null)
  const [query, setQuery] = useState('')
  const [page, setPage] = useState(1)

  useEffect(() => {
    setLoading(true)
    setError(null)
    get('/v1/rapports')
      .then(data => setEntries(data || []))
      .catch(err => setError(err))
      .finally(() => setLoading(false))
  }, [])

  const filteredEntries = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return entries
    return entries.filter(entry => (entry.file || '').toLowerCase().includes(q))
  }, [entries, query])

  // Changing the search query always resets pagination to page 1 of the new filtered result set.
  useEffect(() => {
    setPage(1)
  }, [query])

  const totalPages = Math.max(1, Math.ceil(filteredEntries.length / PAGE_SIZE))

  // Guard against `page` outliving a shrunken `totalPages` for any reason other than a query
  // change (which is already handled by the effect above).
  useEffect(() => {
    setPage(p => (p > totalPages ? totalPages : p))
  }, [totalPages])

  const pagedEntries = useMemo(
    () => filteredEntries.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE),
    [filteredEntries, page]
  )

  return (
    <div className="rapports-tab">
      <h2>Rapports</h2>
      {loading && <LoadingSpinner />}
      {error && <ErrorMessage error={error} />}
      {!loading && !error && (
        <>
          <input
            type="text"
            className="rapports-search-input"
            placeholder="Search by title..."
            aria-label="Search rapports by title"
            value={query}
            onChange={e => setQuery(e.target.value)}
          />
          <EntryList
            entries={pagedEntries}
            onSelect={entry => setSelected({ type: 'library_entry', ...entry })}
            selectedId={selected?.file}
          />
          <PaginationControls
            page={page}
            totalPages={totalPages}
            onPrev={() => setPage(p => Math.max(1, p - 1))}
            onNext={() => setPage(p => Math.min(totalPages, p + 1))}
          />
        </>
      )}
      <EntryDetailPanel entry={selected} onClose={() => setSelected(null)} />
    </div>
  )
}
