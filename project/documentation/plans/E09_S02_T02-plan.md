# Plan: E09_S02_T02 — `jenga dashboard open` --port Flag and Stdout Fallback

## Approach
Extend `dashboard-open.js` with full --port support and stdout fallback.

## Steps
1. `--port <number>` already in E09_S02_T01 plan
2. When `open`/`xdg-open`/`start` is unavailable (ENOENT), catch error and print `Open your browser at: http://localhost:<port>`
3. Exit code 0 always
