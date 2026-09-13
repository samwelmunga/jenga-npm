# API Contract — Jenga AI Dashboard API

## 1. Resource Naming Conventions

- Base path: `/v1/`
- Resource names are **lowercase kebab-case** and **plural** where they represent collections (e.g. `/v1/epics`).
- Singleton resources use a descriptive noun (e.g. `/v1/health`, `/v1/architecture`).
- Sub-resources use a forward-slash path segment: `/v1/board/:epicId`.
- No trailing slashes.

### URL Examples
| Method | Path                   | Description                       |
|--------|------------------------|-----------------------------------|
| GET    | /v1/health             | Server health check               |
| GET    | /v1/board              | Full nested board (epics→stories→tasks) |
| GET    | /v1/board/:epicId      | Single epic with stories and tasks |
| GET    | /v1/history            | Merged git log + rapport entries  |
| GET    | /v1/architecture       | Tech stack and dependency info    |

---

## 2. Standard Response Envelope

Every response — success or error — is wrapped in the same JSON envelope:

```json
{
  "data": <T> | null,
  "meta": {
    "timestamp": "2026-05-05T12:00:00.000Z",
    "version": "1.0.0"
  },
  "error": {
    "code": "ERROR_CODE",
    "message": "Human-readable message",
    "details": {}
  } | null
}
```

- `data` — the resource payload on success, `null` on error.
- `meta` — always present; `timestamp` is ISO 8601 UTC, `version` is the API version string.
- `error` — `null` on success; populated on error.

---

## 3. Error Codes

Error codes are string enums. All codes are `SCREAMING_SNAKE_CASE`.

| Code                  | HTTP Status | Meaning                                  |
|-----------------------|-------------|------------------------------------------|
| `EPIC_NOT_FOUND`      | 404         | No epic matched the given `:epicId`      |
| `PARSE_ERROR`         | 500         | Failed to parse board markdown files     |
| `INTERNAL_ERROR`      | 500         | Unexpected server-side failure           |
| `NOT_FOUND`           | 404         | Generic resource not found               |
| `INVALID_QUERY_PARAM` | 400         | A query parameter has an invalid value   |

---

## 4. Versioning Strategy

- The current version is **v1**, expressed as a URL prefix: `/v1/`.
- All new endpoints are added under `/v1/` until a breaking change is required.
- When a breaking change is introduced, a new `/v2/` prefix is added and `/v1/` is kept alive for a deprecation window (minimum 3 months).
- The `meta.version` field in the envelope reflects the API version string (`"1.0.0"`, `"2.0.0"`, etc.).
- Non-breaking additions (new fields, new endpoints) do **not** require a version bump.
- Clients should treat unknown fields in the envelope as ignorable for forward compatibility.

---

## 5. Board Item Fields Not Sourced from Frontmatter

`GET /v1/board` (and `GET /v1/board/:epicId`) returns each epic, story, and task with its board-file
frontmatter spread onto the object. A few fields are **not** frontmatter — they are derived by
`project/app/api/parsers/board.js` and prefixed with `_` to mark them as parser-supplied:

| Field | Type | Meaning |
|---|---|---|
| `_file` | string | Basename of the markdown file the item was parsed from. |
| `_content` | string | The item's markdown body (frontmatter stripped, trimmed). |
| `_itemType` | string | Added client-side by `kanbanColumns.js`'s `flattenBoardItems()`, not by the API. |
| `_queued` | `true` | **Present only when** the item's id is named by an active entry in the project's `project/todo.md` (E06_S05_T04). |

### `_queued` — `project/todo.md` provenance

`project/app/api/parsers/todo.js` reads `<projectRoot>/project/todo.md` (resolved via
`resolveProjectRoot()`, the same mechanism `BOARD_ROOT` uses — never a `__dirname` climb) and
extracts the board refs its **active** entries name. An entry is a line of the documented
`<mission title>: <E##_S##>` / `<mission title>: <E##_S##_T##>` form, where the ref is the last token
on the line. Everything else is ignored: `<!-- ... -->` comment lines (including the file's many
`<!-- RECONCILED: ... -->` entries), lines with no ref, epic-only refs (`E34`), and refs merely cited
mid-line (e.g. inside a rapport filename).

Semantics to be aware of when consuming it:

- `_queued` is **additive and optional**: items that aren't queued carry no such field, so a project
  with no `todo.md` produces exactly the pre-E06_S05_T04 payload. Per §4, treat it as an ignorable
  unknown field if you don't need it.
- It is **provenance, not status**. It says "the user has queued this for execution"; the item's
  `status` is untouched. A consumer decides what to do with it — the dashboard's Active Sprint tab
  promotes `Pending`/`Backlog` queued items into its In Progress column and marks them "queued",
  while the Backlog tab ignores the field entirely.
- A ref that matches no board item (deleted/renamed) simply flags nothing — it can never synthesize
  an item that isn't on the board.
- A missing, unreadable, or unparseable `todo.md` is never an error: it degrades to "nothing is
  queued" rather than failing the board response.
- The board remains read-only (E06_S02): `todo.md` is only ever read.
