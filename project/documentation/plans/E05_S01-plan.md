# Plan: E05_S01 — API Contract & Types

## Tasks
- **T01**: Write `docs/api-contract.md` — resource naming, response envelope, error codes, versioning
- **T02**: Create `api/types.js` (JSDoc types) and `api/response.js` (helper functions)

## Approach
- Define a standard `{ data, meta, error }` envelope used by all endpoints
- Error codes as string constants for easy reference
- URL versioning via `/v1/` prefix
- Helper functions keep response shape consistent across all routes
