import EntryListItem from './EntryListItem'
import './entry-list.css'

/**
 * EntryList — E58_S01_T06.
 *
 * Generic, reusable list of "markdown library" entries shaped `{ file, data, content, category,
 * date }` — see `EntryListItem.jsx` for the full entry-shape and onSelect-wrapping contract that
 * `E58_S02`/`E58_S03` must follow. Generalizes `../history/HistoryList.jsx` (which is left
 * untouched by this task) for consumers whose entries have no `sha`/`type` fields of their own.
 *
 * `selectedId` is compared against each entry's `file` field (the stable identity for this entry
 * shape). Pass e.g. `selected?.file` from the consuming tab's selection state.
 */
export default function EntryList({ entries, onSelect, selectedId }) {
  if (!entries || entries.length === 0) {
    return <div className="entry-list-empty">No entries found.</div>
  }

  return (
    <ul className="entry-list">
      {entries.map(entry => (
        <EntryListItem
          key={entry.file}
          entry={entry}
          isSelected={selectedId === entry.file}
          onSelect={onSelect}
        />
      ))}
    </ul>
  )
}
