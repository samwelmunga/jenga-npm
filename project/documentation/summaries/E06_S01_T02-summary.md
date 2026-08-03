# E06_S01_T02 Summary — Shared API Client

Implemented `src/api/client.js` with a `request()` helper that reads `VITE_API_BASE_URL` via `import.meta.env`, fetches the given path, and throws on HTTP errors or API-level error fields. Exported a named `get()` convenience function and a default object for broader usage across tabs and components.
