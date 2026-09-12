---
name: j.dashboard
description: Launch the local Jenga project dashboard (API + UI) by delegating to project/app's existing npm scripts — no new server or build logic.
keywords:
  - dashboard
  - launch dashboard
  - start dashboard
  - open dashboard
  - project dashboard
examples:
  - "open the dashboard"
  - "launch the project dashboard"
  - "j.dashboard"
  - "start the dashboard on port 4000"
---

# Dashboard — Local Launch

## Purpose

E05–E09 built a working local dashboard (Express API + Vite/React UI under `project/app/api` and
`project/app/ui`), already reachable via `npm run dashboard:start` / `npm run dashboard:open` at
the repo root (which shell into `project/app/ui/scripts/dashboard-start.cjs` /
`dashboard-open.cjs`). This skill is a thin, session-level entry point to those same scripts — it
introduces **no new server-launch, health-check, or build logic** of its own. All actual
implementation lives in the two `.cjs` scripts this skill wraps; do not duplicate it here or in
`scripts/launch.sh`.

This skill currently implements only the **default (local launch) mode**. `--snapshot`
(single-file dashboard export) is a separate, not-yet-implemented mode reserved for a later task
(`E47_S04_T02`/`E47_S04_T03`) — if the user asks for a snapshot/export, tell them that mode isn't
available yet rather than attempting to build it ad hoc.

## Instructions

1. **Parse the invocation.** This skill accepts an optional first word — `start`, `open`, or
   `both` — and an optional `--port <n>` flag (forwarded unchanged to whichever underlying npm
   script runs). `start` additionally accepts `--serve-app` (forwarded unchanged; has no effect on
   `open`). If the user's phrasing already makes the intent unambiguous (e.g. "start the
   dashboard", "open the dashboard in my browser", "launch the dashboard and open it"), map it
   directly to `start` / `open` / `both` and skip the prompt in step 2.

2. **No explicit mode given — ask.** If intent isn't already clear from the invocation, use
   CLAUDE.md's standard Interaction Pattern rather than guessing:

   ```
   What would you like to do?
   1. Start the dashboard server (npm run dashboard:start)
   2. Open the dashboard in your browser (npm run dashboard:open) — assumes it's already running
   3. Both — start the server, then open the browser
   4. Other (describe below)
   ```

   Map option 1 -> `start`, option 2 -> `open`, option 3 -> `both`.

3. **Run the wrapper script.** Invoke `skills/j-dashboard/scripts/launch.sh <mode> [--port <n>]
   [--serve-app]` with the resolved mode and any forwarded flags. The script:
   - Resolves `project/app` relative to the repo root (works whether this skill is run from this
     monorepo or a mirrored/distributed copy — same resolution pattern as
     `skills/j-mirror-public/scripts/compute-publicize-diff.sh`).
   - Delegates to `npm run dashboard:start` / `npm run dashboard:open` inside `project/app` — the
     exact same commands `npm run dashboard:start` / `dashboard:open` at the repo root already run.
   - For `both`, backgrounds the (long-running) server, waits briefly, then runs `open` — which
     itself health-checks before opening the browser and always exits `0` regardless of outcome
     (that is `dashboard-open.cjs`'s own documented contract, unchanged by this skill).
   - Exits non-zero with a clear message if `project/app/package.json` is missing (e.g. a consumer
     install where the dashboard package hasn't shipped yet — see epic `E47_S01`) or if the
     underlying npm script itself fails (e.g. `--port` validation, missing dependencies).

4. **Relay output.** Print the script's stdout/stderr back to the user as-is — do not
   reinterpret, summarize away, or suppress error output from the underlying scripts; they already
   produce user-facing messages (e.g. "Dashboard API running at http://localhost:3001",
   "⚠ Warning: Dashboard server does not appear to be running at ...").

5. **`start` mode is long-running.** `dashboard:start` runs a foreground server process that does
   not exit on its own. When running `start` (not `both`) as part of an interactive session, make
   sure the user understands the command will keep running until stopped (Ctrl-C) — don't silently
   block the conversation waiting on it.

## Out of Scope

- `--snapshot` / single-file export mode — not implemented by this skill; reserved for
  `E47_S04_T02`/`E47_S04_T03`.
- Any change to `project/app/package.json`, `dashboard-start.cjs`, or `dashboard-open.cjs` — this
  skill only invokes them. Fixes or feature changes to the dashboard itself belong to those files'
  own epics (E05-E09, E47), not here.
- Resolving dashboard data against a *consumer* project's own `project/` directory rather than this
  monorepo's — that's `E47_S02`'s scope, not this skill's.
