import { useEffect, useState } from 'react'
import { get } from '../api/client'
import LoadingSpinner from '../components/LoadingSpinner'
import ErrorMessage from '../components/ErrorMessage'
import EntryList from '../components/shared/EntryList'
import EntryDetailPanel from '../components/history/EntryDetailPanel'

/**
 * DocumentationTab — E58_S03_T01.
 *
 * Fetches the full documentation aggregate from `GET /v1/documentation` (E58_S01) on mount and
 * renders it via the shared `EntryList`/`EntryDetailPanel` component pair (also E58_S01), following
 * `HistoryTab.jsx`'s loading/error/fetch-on-mount pattern exactly — the same pattern already
 * followed by `RapportsTab.jsx` (`E58_S02_T01`).
 *
 * Each entry is shaped `{ file, data, content, category, date }`, covering all 4 source categories
 * aggregated by `readDocumentation()`: `summary` (`project/PROJECT_SUMMARY.md`), `readme`
 * (`README.md`), `strategy` (`docs/STRATEGY.md`), and `example`
 * (every file under `project/documentation/examples/`).
 *
 * Selection follows `EntryListItem.jsx`'s documented wrapping contract — `onSelect` receives the
 * raw entry, and this tab wraps it with a `type: 'library_entry'` discriminator before handing it
 * to `EntryDetailPanel`, which has a dedicated `library_entry` render branch.
 *
 * No new list/detail-rendering logic and no tab-specific CSS: the shared `EntryList` component
 * (`entry-list.css`) already handles mobile layout via `tokens.css`'s `--space-*` tokens, per
 * `E58_S01_T06` and `E59_S01`'s foundation.
 */
export default function DocumentationTab() {
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [entries, setEntries] = useState([])
  const [selected, setSelected] = useState(null)

  useEffect(() => {
    setLoading(true)
    setError(null)
    get('/v1/documentation')
      .then(data => setEntries(data || []))
      .catch(err => setError(err))
      .finally(() => setLoading(false))
  }, [])

  return (
    <div className="documentation-tab">
      <h2>Documentation</h2>
      {loading && <LoadingSpinner />}
      {error && <ErrorMessage error={error} />}
      {!loading && !error && (
        <EntryList
          entries={entries}
          onSelect={entry => setSelected({ type: 'library_entry', ...entry })}
          selectedId={selected?.file}
        />
      )}
      <EntryDetailPanel entry={selected} onClose={() => setSelected(null)} />
    </div>
  )
}
