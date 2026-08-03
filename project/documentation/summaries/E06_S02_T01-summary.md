# E06_S02_T01 Summary — Board Data Fetching

Implemented `BoardTab.jsx` with three pieces of React state: `loading` (true initially), `error`, and `data`. A `useEffect` calls `get('/board')` on mount, sets `data` on resolve or `error` on reject, and clears `loading` in `.finally()`. The component renders the appropriate child (`LoadingSpinner`, `ErrorMessage`, or `BoardView`) based on state.
