# Plan: E07_S01_T01 — History Tab Data Fetching and State Management

## Approach
Create `dashboard/src/tabs/HistoryTab.jsx` using `useEffect` + `useState` to fetch `GET /history` on mount via the shared API client.

## Steps
1. Import API client `get()` from `dashboard/src/api/client.js`
2. Manage state: `loading`, `error`, `entries`
3. On mount, call `get('/history')` — set loading true, then resolve to entries or error
4. Render `<LoadingSpinner>` while loading, `<ErrorMessage>` on error, `<HistoryList entries={entries}>` on success
5. Sort entries reverse-chronologically before passing to list (API may already do this, but sort defensively)
6. Graceful empty state handled inside `HistoryList`
