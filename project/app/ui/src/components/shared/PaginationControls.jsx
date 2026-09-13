import './pagination-controls.css'

/**
 * PaginationControls — E58_S02_T03.
 *
 * Generic Prev/Next + "Page X of Y" pagination control, deliberately extracted out of
 * `RapportsTab.jsx` (its first consumer) rather than inlined, since `E58_S03` (Documentation tab)
 * sits on the same shared list infrastructure (`EntryList`/`EntryListItem`) and is a likely future
 * consumer of the same control. Pure presentational — no data fetching, no knowledge of the
 * entries being paginated, no internal state; the parent owns `page` and slices its own list.
 *
 * ── Design decision (no prior pagination UI existed in this codebase — see
 * `project/documentation/plans/E58_S02_T03-plan.md` for the full rationale) ────────────────────
 * Prev/Next + a text page indicator was chosen over numbered page buttons (would need a
 * truncation/ellipsis strategy once `totalPages` gets into the dozens, which real Rapports data
 * does) or "load more" (fights the fixed-height scrollable list pattern `entry-list.css` already
 * establishes). This is the simplest control that lets a caller move between pages with no
 * network request and scales to arbitrarily large `totalPages` with no extra logic.
 *
 * Renders nothing when `totalPages <= 1` — no controls needed for a single-page result.
 */
export default function PaginationControls({ page, totalPages, onPrev, onNext }) {
  if (totalPages <= 1) return null

  return (
    <div className="pagination-controls">
      <button
        type="button"
        className="pagination-btn"
        onClick={onPrev}
        disabled={page <= 1}
        aria-label="Previous page"
      >
        Prev
      </button>
      <span className="pagination-status">
        Page {page} of {totalPages}
      </span>
      <button
        type="button"
        className="pagination-btn"
        onClick={onNext}
        disabled={page >= totalPages}
        aria-label="Next page"
      >
        Next
      </button>
    </div>
  )
}
