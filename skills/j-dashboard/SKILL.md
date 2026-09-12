---
name: j.dashboard
description: Launch the local Jenga project dashboard (API + UI) by delegating to project/app's existing npm scripts — no new server or build logic. Also supports --snapshot, a single self-contained HTML export with a point-in-time data snapshot baked in.
keywords:
  - dashboard
  - launch dashboard
  - start dashboard
  - open dashboard
  - project dashboard
  - snapshot dashboard
  - export dashboard
examples:
  - "open the dashboard"
  - "launch the project dashboard"
  - "j.dashboard"
  - "start the dashboard on port 4000"
  - "export a snapshot of the dashboard"
  - "j.dashboard --snapshot"
---

# Dashboard — Local Launch & Single-File Snapshot Export

## Purpose

E05–E09 built a working local dashboard (Express API + Vite/React UI under `project/app/api` and
`project/app/ui`), already reachable via `npm run dashboard:start` / `npm run dashboard:open` at
the repo root (which shell into `project/app/ui/scripts/dashboard-start.cjs` /
`dashboard-open.cjs`). This skill is a thin, session-level entry point to those same scripts — it
introduces **no new server-launch, health-check, or build logic** of its own. All actual
implementation lives in the two `.cjs` scripts this skill wraps; do not duplicate it here or in
`scripts/launch.sh`.

`--snapshot` (E47_S04_T02/T03) is a second, independent mode: it captures the API's `/v1/board`,
`/v1/history`, and `/v1/architecture` responses once, bakes that data inline into the UI build, and
inlines all JS/CSS into a single, fully self-contained HTML file (default `jenga.html`) — viewable
via `file://` with no running server, so it can be handed to someone on another device. It does not
start a long-running server and does not open a browser; it is a one-shot export.

## Instructions

1. **Parse the invocation.** This skill accepts either:
   - The **default/launch** form: an optional first word — `start`, `open`, or `both` — and an
     optional `--port <n>` flag (forwarded unchanged to whichever underlying npm script runs).
     `start` additionally accepts `--serve-app` (forwarded unchanged; has no effect on `open`).
   - The **snapshot/export** form: `--snapshot`, optionally with `--out <path>` (default
     `jenga.html` in the current working directory).

   If the user's phrasing already makes the intent unambiguous (e.g. "start the dashboard", "open
   the dashboard in my browser", "launch the dashboard and open it", "export a snapshot of the
   dashboard"), map it directly and skip the prompt in step 2.

2. **No explicit mode given — ask.** If intent isn't already clear from the invocation, use
   CLAUDE.md's standard Interaction Pattern rather than guessing:

   ```
   What would you like to do?
   1. Start the dashboard server (npm run dashboard:start)
   2. Open the dashboard in your browser (npm run dashboard:open) — assumes it's already running
   3. Both — start the server, then open the browser
   4. Export a single-file snapshot (--snapshot) — a portable, offline-viewable HTML file
   5. Other (describe below)
   ```

   Map option 1 -> `start`, option 2 -> `open`, option 3 -> `both`, option 4 -> `--snapshot`.

3. **Default/launch form — run the wrapper script.** Invoke `skills/j-dashboard/scripts/launch.sh
   <mode> [--port <n>] [--serve-app]` with the resolved mode and any forwarded flags. The script:
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

4. **`--snapshot` form — run the snapshot script.** Invoke
   `skills/j-dashboard/scripts/snapshot.sh [--out <path>]`. The script:
   - Captures the invoking directory (before any internal `cd`) so data is resolved against the
     *invoking* project, per `E47_S02`'s generalized data-source resolution — not this repo's own
     data, unless that happens to be the invoking project.
   - Runs `E47_S04_T02`'s capture step
     (`project/app/api/scripts/capture-snapshot.js`) to collect `/v1/board`, `/v1/history`, and
     `/v1/architecture` into one JSON artifact.
   - Runs the UI's `build:snapshot` script (`vite build --mode snapshot`), which embeds that JSON
     inline as a `<script id="jenga-dashboard-data">` tag and inlines all JS/CSS into a single
     `index.html` (via `vite-plugin-singlefile`).
   - Copies the result to the final output path (default `jenga.html` in the invoking directory,
     overridable via `--out <path>`).
   - Fails loudly with no output file written if either the capture or bundling step fails — never
     a partial/broken snapshot.

5. **Relay output.** Print the script's stdout/stderr back to the user as-is — do not
   reinterpret, summarize away, or suppress error output from the underlying scripts; they already
   produce user-facing messages (e.g. "Dashboard API running at http://localhost:3001",
   "⚠ Warning: Dashboard server does not appear to be running at ...", "Snapshot dashboard written
   to: <path>").

6. **`start` mode is long-running.** `dashboard:start` runs a foreground server process that does
   not exit on its own. When running `start` (not `both`) as part of an interactive session, make
   sure the user understands the command will keep running until stopped (Ctrl-C) — don't silently
   block the conversation waiting on it. `--snapshot` is a one-shot export and always terminates.

## Out of Scope

- Any change to `project/app/package.json`'s `dashboard:start`/`dashboard:open` scripts,
  `dashboard-start.cjs`, or `dashboard-open.cjs` — this skill only invokes them. Fixes or feature
  changes to the dashboard itself belong to those files' own epics (E05-E09, E47), not here.
- Resolving dashboard data against a *consumer* project's own `project/` directory rather than this
  monorepo's — that's `E47_S02`'s scope (already reused, not duplicated, by both `launch.sh` and
  `snapshot.sh`'s capture step).
- Any new capture/bundling logic beyond invoking `capture-snapshot.js` and `vite build --mode
  snapshot` — those live in `project/app/api/scripts/capture-snapshot.js` and
  `project/app/ui/vite.config.js`/`package.json` respectively.
