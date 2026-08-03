# E06_S01_T02 Plan — Shared API Client

Create `src/api/client.js` that reads `VITE_API_BASE_URL` from Vite's `import.meta.env`. Expose a generic `request()` function and a convenience `get()` export. Throw on non-OK responses or API-level `error` fields, returning `json.data` on success.
