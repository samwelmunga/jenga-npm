# How the jenga-app Dashboard Picks Up Board Items, History, and Architecture Info

## What it is

`project/app` is a small Express API + React UI workspace (`api/` and `ui/` npm workspaces) that gives a browsable dashboard over the Jenga scrum board and project state — three tabs: Board, History, Architecture.

## Why it exists

The board itself is just markdown files with YAML frontmatter under `project/board/` — perfectly usable by an agent, but not pleasant to browse as a human. The dashboard exists to render that flat file structure as a navigable tree/list without requiring anyone to hand-read task files.

## How it works

- **Entry point:** `project/app/api/server.js` mounts three routers: `/v1/board`, `/v1/history`, `/v1/architecture`.
- **Board tab** — `GET /v1/board` → `project/app/api/parsers/board.js`'s `parseBoard()`. It `readdirSync`s `project/board/epics/*.md`, `stories/*.md`, `tasks/*.md`, splits each file's YAML frontmatter from its markdown body with `gray-matter`, and joins tasks→stories→epics via their `story_id`/`epic_id` frontmatter fields into a nested tree. The UI (`ui/src/components/board/BoardView.jsx`) renders that as `EpicCard → StoryCard → TaskCard` with a status checkbox filter — not literal Kanban columns (that part, board story `E06_S05`, is still `status: Pending`).
- **History tab** — `GET /v1/history` merges `git log` output (`api/parsers/git-log.js`, shells out via `execFile`, `--max-count=200`) with parsed rapport files recursively walked from `project/rapports/` (`api/parsers/rapports.js`, also via `gray-matter`), sorted by date descending, filterable by `?type=`/`?limit=`.
- **Architecture tab** — `GET /v1/architecture` (`api/parsers/architecture.js`) reads `package.json`/`project.config.json` (plain `JSON.parse`) for the tech stack, and sources its node/edge dependency graph (`sad_map`) from `project/knowledge-graph/graph.json` (E08_S05_T01, reworking the prior board-markdown-parsing behavior) via `api/parsers/knowledge-graph.js`'s `readSADMap()`. `readSADMap()` filters out any node with `status: superseded`, transforms `STUB_SCHEMA.md`'s node/edge shape (`id,type,label,description,source,status?,superseded_by?` / `id,from,to,type,description`) into the dashboard's UI-facing shape (`{id,label,type}` / `{from,to,label}`, edge `label` falling back to `type` when `description` is empty), and degrades to `{nodes: [], edges: []}` — never throws — when `graph.json` is missing or empty. `graph.json` itself is populated separately by `scripts/populate-knowledge-graph.js` (E20_S09), one node per board Epic/Story with `source: "board"`; the Architecture tab never re-derives it from board markdown itself anymore.
- **UI side:** one fetch client (`ui/src/api/client.js`, wraps `fetch` against `VITE_API_BASE_URL`), and three tab components (`BoardTab.jsx`, `HistoryTab.jsx`, `ArchitectureTab.jsx`) each call their endpoint once on mount via `useEffect`.

Two things worth flagging:

1. **`project/PROJECT_SUMMARY.md` is still never read by the dashboard at all** — no parser references it. `project/knowledge-graph/graph.json`, by contrast, *is* now read (by the Architecture tab's `sad_map`, as of E08_S05_T01) — this is a change from the prior state, where neither path was wired in and `graph.json` didn't yet exist on disk.
2. **No polling, file-watching, or caching.** Every tab fetches once on page load; every request re-reads and re-parses the markdown/git-log/`graph.json` from disk fresh (plain synchronous `fs.readdirSync`/`readFileSync` per call), with nothing cached in memory and no cache headers set. `npm run api:dev` uses Node's `--watch` flag, but that only restarts the server process on *source* changes during development — it does not watch `project/board/` or `project/knowledge-graph/` data.

## When to use it (and when not to)

Use it to browse current board/history/architecture state visually — the Architecture tab's `sad_map` now does reflect the knowledge graph (`project/knowledge-graph/graph.json`). Don't expect it to reflect `PROJECT_SUMMARY.md` narrative content or `project/logs/events.json` — neither is wired into any dashboard endpoint. Don't expect live updates either — reload the page after board or `graph.json` changes, since there's no watcher pushing updates to an already-open tab.

## Example

Editing a task's `status:` frontmatter field in `project/board/tasks/E06_S02_T04_*.md` and hitting refresh on the dashboard's Board tab shows the new status immediately on next load (fresh parse each request) — but nothing pushes that update to an already-open tab without a manual reload.
