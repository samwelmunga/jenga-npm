# E06_S02_T01 Plan — Board Data Fetching

Implement `BoardTab.jsx` using `useState` + `useEffect` to call `GET /board` via the shared API client on mount. Track `loading`, `error`, and `data` states. Show `<LoadingSpinner />` during fetch, `<ErrorMessage />` on failure, and `<BoardView epics={data} />` on success.
