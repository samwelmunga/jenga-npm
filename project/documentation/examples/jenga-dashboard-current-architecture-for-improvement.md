# Jenga Dashboard: Current Architecture (for mobile/overlay/rapports improvement)

## What it is

`project/app` is an npm-workspaces monorepo (`api` + `ui`) that implements the Jenga dashboard, launched via `j.dashboard` → root `dashboard:start`/`dashboard:open` scripts.

- **API**: Node.js + Express (`project/app/api/server.js`), mounting `/v1/health`, `/v1/board`, `/v1/history`, `/v1/architecture`. Markdown files parsed with `gray-matter` in `api/parsers/{board,rapports,git-log,architecture,knowledge-graph}.js`.
- **UI**: React 18 + Vite 5, single `App.jsx` with local `useState` tab-switching — no router library. Components under `ui/src/components/{board,history,architecture}/*.jsx`; page-level "tabs" under `ui/src/tabs/{BoardTab,ActiveSprintTab,HistoryTab,ArchitectureTab}.jsx`. `ui/src/api/client.js` is a thin fetch wrapper with a snapshot-mode fallback for `--snapshot` static exports.

## Why it exists

Gives a local, no-infra visual overview of the scrum board, git/rapport history, and system architecture, per `project/documentation/examples/jenga-app-dashboard-board-data-ingestion.md` (written for the earlier 3-tab era; now 4 tabs with Kanban added).

## How it works

### Styling — no mobile support today
Plain per-component CSS (no Tailwind/CSS-in-JS/CSS modules): `App.css`, `components/components.css`, `components/board/{board,kanban}.css`, `components/history/history.css`, `components/architecture/architecture.css`. **Zero `@media` queries anywhere in `ui/src/`.** `ui/index.html` has a correct viewport meta tag, but nothing uses it. `.app { max-width: 1200px; margin: 0 auto }` (`App.css:7-11`); Kanban columns are fixed-width 220px with `overflow-x: auto` (`kanban.css:1-11`) — no touch-scroll/breakpoint treatment. `.status-filter` already uses `flex-wrap: wrap` (`board.css:146`).

### Existing click → overlay pattern (commit history)
`HistoryTab.jsx` → `HistoryList.jsx` → `HistoryEntry.jsx` (clickable `<li>`, `onClick`/`role="button"`/`tabIndex`/`onKeyDown` for full keyboard support) → selection state lifted into `HistoryTab` (`const [selected, setSelected] = useState(null)`) → `EntryDetailPanel.jsx` rendered unconditionally, returns `null` when nothing selected.

`EntryDetailPanel.jsx`: full-screen `.panel-backdrop` (click to close) + slide-in `<aside className="detail-panel">` docked right (`width: min(480px, 100vw)`, `animation: slideIn 0.2s`), Escape-key close via `useEffect`, content varies by `entry.type` — rapports render `entry.content_summary` through `marked.parse()` + `DOMPurify.sanitize()` into `.markdown-body`. Styles in `history.css:79-219`.

### Board item rendering — no click behavior yet
Two independent rendering paths driven by the same `GET /v1/board` payload:
- Backlog: `BoardView.jsx` → `EpicCard.jsx` (`epic-title` h3) → `StoryCard.jsx` (`story-title` h4) → `TaskCard.jsx` (`task-title` span)
- Active Sprint: `KanbanBoard.jsx`'s local `KanbanCard` (`kanban-card-title` div) — docstring notes "board stays read-only per E06_S02"

No `onClick` exists on any title element today.

### Data already available for an overlay
`api/parsers/board.js`'s `readMarkdownDir()` keeps **both** `data` (frontmatter) and `content` (everything below frontmatter, trimmed) per file via `gray-matter`. Every task/story/epic returned by `GET /v1/board` is `{ ...data, _content: <markdown body>, _file: <filename> }` — Description/Acceptance Criteria/Definition of Done are already in `_content` as one markdown blob (headings like `## Description`, `## Acceptance Criteria`, `## Definition of Done`; not every file has every section — e.g. some tasks omit "Definition of Done"). **No server changes needed to expose body content** — client can render `_content` via the same `marked`+`DOMPurify` pipeline already used for rapports, with best-effort client-side splitting by `##` heading if distinct sections are wanted.

### Rapports — actual disk layout diverges from a naive "problems/ideas/summaries/plans" assumption
- `project/rapports/{analysis,problems,tests}/` — only these 3 categories actually live under `rapports/`. `api/parsers/rapports.js`'s `readRapports()` already recursively walks this tree, parses frontmatter, returns `{ type: 'rapport', filename (relative, e.g. "problems/foo.md"), date, content_summary (first 300 chars) }` — but this is **only consumed by `/v1/history`** (merged with git commits), not exposed as its own endpoint. Category is only implicit in `filename`'s path prefix, not a separate field. Content is truncated to 300 chars.
- `project/ideas.md` — a single flat file (via `/idea` skill), not a directory.
- `project/documentation/summaries/*.md` and `project/documentation/plans/*.md` — sibling trees under `documentation/`, not under `rapports/` at all.
- **No existing `/v1/rapports` route**, and no parser touches `ideas.md`, `documentation/summaries/`, or `documentation/plans/` today.

### Documentation view — no existing backend or UI touches these files at all
Candidate sources for a "Documentation" view, confirmed on disk:
- `project/PROJECT_SUMMARY.md` (77KB) — the scrum-master-owned project summary.
- `README.md` (repo root, 17KB).
- `docs/STRATEGY.md` — the "business idea" doc (Vision, Value Proposition, Scope, Target Audience), populated via the `/strategy` skill.
- `project/documentation/examples/*.md` — the growing set of `/examplify`-produced concept docs (dozens of files).

`grep -rln "PROJECT_SUMMARY\|README\|STRATEGY" project/app/api project/app/ui/src` returns **zero matches** — no parser, route, or UI component reads any of these today. This is net-new, same shape as the Rapports gap: a new `/v1/documentation` (or similarly named) endpoint reading these four sources (three single files + one directory), and a new `DocumentationTab.jsx` following the existing tab pattern, rendering each through the same `marked`+`DOMPurify` pipeline already used elsewhere.

### Tab/navigation pattern (for adding a new view)
`App.jsx`: `TABS` array of `{ id, label }` → `useState('board')` for `activeTab` → nav buttons set `activeTab` → content area conditionally renders `{activeTab === 'x' && <XTab />}`. Each `XTab.jsx` follows: `useState` for `loading`/`error`/`data`, `useEffect` calling `get('/v1/...')` once on mount, conditional `LoadingSpinner`/`ErrorMessage`/content.

## When to use it (relevant to the improvement goal)

This current-state map is the baseline for evaluating three requested improvements: (1) mobile-friendly layout, (2) click-title-to-open-overlay for board items showing content below frontmatter, (3) a new "Rapports" view aggregating `project/rapports/*`, `project/documentation/{summaries,plans}`, and `project/ideas.md`, categorized by type.

## Example(s)

- Sample task file with `_content` body: `project/board/tasks/E33_S03_T01_add-scrum-master-session-start-reset.md:23-42`
- Sample story file with fuller body (Description/AC/DoD): `project/board/stories/E01_S07_ai-engineer-agent.md:14-40`
- Sample rapport: `project/rapports/problems/E22_S05_T01-first-release-empty-sections-crash.md`
