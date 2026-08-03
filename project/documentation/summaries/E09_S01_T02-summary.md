# Summary: E09_S01_T02 — `jenga dashboard start --serve-app` Flag

## Implemented
- Extended `dashboard/scripts/dashboard-start.cjs` with `--serve-app` flag
- When set: adds `express.static(DIST_DIR)` middleware pointing to `dashboard/dist/`
- SPA fallback: serves `index.html` for non-API routes
- Prints second URL line when `--serve-app` is used
- Warns if `dashboard/dist/` doesn't exist (user must build first)

## Status: Complete ✓
