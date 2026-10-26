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
| GET    | /v1/security           | Credential-pattern findings and dependency-audit results (section 6) |

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

---

## 6. `GET /v1/security` — credential findings and dependency audits

Added by epic E85. A read-only, singleton, query-parameter-free route (the same bulk-fetch shape as
`GET /v1/rapports`) behind the dashboard's Security tab. It is built by `project/app/api/parsers/security.js`
(`readSecurity()`), served by `project/app/api/routes/security.js` and mounted in `project/app/api/server.js`.
The reader never writes a file, never runs an audit and never records consent. Its three sources are described in
[security-audits.md](security-audits.md#9-dashboard) (section 9, Dashboard); the credential scan itself is described in
[credential-access-audit.md](credential-access-audit.md).

The `data` payload inside the standard envelope has two independent halves. A problem with one half's source is
reported in that half's own `state` and `error` and never changes the other half.

```json
{
  "credential_findings": {
    "state": "recorded | never-scanned | error",
    "scan_date": "YYYY-MM-DD | null",
    "command": "<string> | null",
    "summary": { "total": 0, "by_skill": { "<skill>": 0 } },
    "findings": [
      { "skill": "<name> | null", "file": "<path>", "line": 0, "class": "<class id>", "text": "<line>",
        "scope": "flagged | other", "verdict": "true read | benign mention",
        "reason": "<string>", "action": "reword | allow-list | none" }
    ],
    "error": "null | <message>"
  },
  "audits": {
    "state": "recorded | never-audited | error",
    "config": "null | { mode, severity_threshold, offline_behavior, production_only }",
    "targets": [
      { "scanned_dir": "<path> | null", "status": "clean | findings | unavailable | disabled",
        "threshold": "<string> | null",
        "counts": { "low": 0, "moderate": 0, "high": 0, "critical": 0, "total": 0 },
        "consent_basis": "config-mode-on | session-approval | ci-workflow | null",
        "date": "<ISO 8601 UTC> | null", "rapport": "<path> | null", "last_consent_date": "<ISO 8601 UTC> | null" }
    ],
    "history": [ "<same shape as a target, one per audit_result event, newest first, at most 200>" ],
    "error": "null | <message>"
  }
}
```

### 6.1 `credential_findings`

Source: `credential-findings.json` in the project's data directory (`paths.data` in
`project/configs/workflow.json` when that is a safe relative path, otherwise `project/data`). The file is the
classified output of `scripts/scan-credential-patterns.sh`; its own shape is in
[credential-access-audit.md](credential-access-audit.md#data-shape-credential-findingsjson).

| Field | Type | Meaning |
|---|---|---|
| `state` | `"recorded"` \| `"never-scanned"` \| `"error"` | `recorded`: the file parsed and is usable. `never-scanned`: the file does not exist. `error`: it exists but cannot be used. |
| `scan_date` | string \| `null` | `YYYY-MM-DD` of the scan, as recorded in the file; `null` when absent or not a string. |
| `command` | string \| `null` | The scan command recorded in the file; `null` when absent or not a string. |
| `summary.total` | integer | Number of findings. Taken from the file's `summary` when it is well-formed, otherwise `findings.length`. `0` unless `recorded`. |
| `summary.by_skill` | object | Match count per skill (and `scripts/`), from the file's `summary` when well-formed, otherwise counted from the findings that have a string `skill`. `{}` unless `recorded`. |
| `findings[]` | array | One element per row of the file, in file order (the reader does not sort or filter). Elements that are not objects are dropped. `[]` unless `recorded`. |
| `findings[].skill` | string \| `null` | The skill the match belongs to; `null` for a match in `scripts/` (or when the file omits it). |
| `findings[].file`, `.line`, `.class`, `.text` | string, integer, string, string | The scanner's own columns. `class` is one of `gh-auth`, `aws-env`, `dotfile-path`, `home-ref`, `credential-file`. |
| `findings[].scope` | `"flagged"` \| `"other"` | `flagged` for the skills named in the scanner issue the audit answers. |
| `findings[].verdict` | `"true read"` \| `"benign mention"` | The auditor's reading of the surrounding code. |
| `findings[].reason`, `.action` | string, `"reword"` \| `"allow-list"` \| `"none"` | Why, and what happens to the line. |
| `error` | string \| `null` | `null` unless `state` is `error`. |

The finding fields are passed through unchanged from the file; the reader does not validate their values, so a
field the file omits is omitted from the response (only `skill` is normalised, to `null`). The table is exactly the
scanner's output. Reads of credential values that the five scanner patterns cannot match (for example the
`printenv` and `xcrun` sites in `j-publish`) are not rows; they are documented in
[credential-access-audit.md](credential-access-audit.md#outside-the-five-patterns-not-rows-but-relevant-to-the-story).

`state: "error"` is reported (with the message in `error`, and an empty `summary`, `findings` and null dates) when the
file is unreadable, is not valid JSON, has a `schema_version` other than `1`, or has no `findings` array.

### 6.2 `audits`

Sources: the `audit_result` and `audit_consent` events in `project/logs/events.json` (JSONL, written by
`scripts/audit-record.sh`; the event fields are in [security-audits.md](security-audits.md#5-monitoring)) and the
settings in `project/configs/audit-config.json`.

| Field | Type | Meaning |
|---|---|---|
| `state` | `"recorded"` \| `"never-audited"` \| `"error"` | `recorded`: at least one `audit_result` event exists. `never-audited`: none does (an absent or empty `events.json` included). `error`: `audit-config.json` exists but is unreadable, invalid JSON or not a JSON object. |
| `config` | object \| `null` | `null` when `audit-config.json` is absent or unusable. Otherwise `mode`, `severity_threshold` and `offline_behavior` as written in the file (`null` for a key it omits) and `production_only` (boolean, `null` when the file's value is not a boolean). |
| `targets[]` | array | The newest `audit_result` per `scanned_dir`, ordered newest first. A result with no `scanned_dir` forms its own group (`scanned_dir: null`). |
| `history[]` | array | Every `audit_result`, newest first, capped at 200 entries (the 200 newest). Same element shape as a target. |
| `error` | string \| `null` | `null` unless `state` is `error`. |

When `state` is `error` because of the config, `targets` and `history` are still populated from the events, so the
event half is not lost.

Element fields (identical in `targets` and `history`):

| Field | Type | Meaning |
|---|---|---|
| `scanned_dir` | string \| `null` | The audited directory, as recorded (an absolute path). |
| `status` | string | `clean`, `findings`, `unavailable` or `disabled`, passed through unchanged. `unavailable` ("the audit could not run") and `disabled` ("consent was refused") are never folded into `clean`. The reader does not validate the value. |
| `threshold` | string \| `null` | The severity threshold the run used. |
| `counts` | object | `low`, `moderate`, `high`, `critical`, `total`, each an integer. Missing or non-numeric values become `0`; `audit-deps.sh`'s sixth count `info` is not carried into the event and so does not appear. |
| `consent_basis` | string \| `null` | `config-mode-on`, `session-approval` or `ci-workflow`. |
| `date` | string \| `null` | The event's ISO 8601 UTC timestamp; `null` when the event had none. "Newest" is decided by this string (it sorts lexically), ties broken by file order, a later line being newer. |
| `rapport` | string \| `null` | Path of the `security_concern` rapport the audit wrote, when it wrote one. The route returns the path only; finding detail (package names) stays in the rapport. |
| `last_consent_date` | string \| `null` | The newest `audit_consent` event for the same `scanned_dir`; `null` when there is none (and always `null` for a null `scanned_dir`). |

A line of `events.json` that does not parse (for example a torn last line) is skipped, never an error. Only lines
that mention `audit_result` or `audit_consent` are parsed at all.

### 6.3 Empty and error states, and status codes

- **Missing is not an error.** With no `credential-findings.json` the route answers `200` with
  `credential_findings.state: "never-scanned"`; with no `audit_result` event it answers `200` with
  `audits.state: "never-audited"` (and `config: null` when `audit-config.json` is absent). A project that has never
  run either gets a fully valid, empty payload. Consumer installs normally see `never-scanned`, because that file
  describes Jenga's own skills.
- **Malformed is reported, not fatal.** An unusable findings file or config sets only that half's `state` to `error`
  with a message; the response is still `200`. The UI renders explanatory text for each of the three states and never
  shows a blank table that reads as "no problems".
- **The only failure is an unresolvable project root.** `readSecurity()` resolves the root per call; if that fails
  the route answers `500` with `PARSE_ERROR` (section 3) and the message. No source problem produces a non-`200`.
- **Snapshot.** `project/app/api/scripts/capture-snapshot.js` captures this route as `routes.security` (the full
  envelope) and `project/app/ui/src/api/client.js` reads it from the embedded data, so the exported single-file
  HTML renders the Security tab offline. The two route maps are kept in sync. A snapshot taken before this route
  existed has no `routes.security`; the tab then shows a "no embedded snapshot data" error rather than an empty state.

### 6.4 Verification status

State this when relying on the page: the Security tab and its two panels were checked by server-side rendering
against stub and fixture payloads and by `tests/dashboard-security.bats` (route payload and snapshot data against a
throwaway fixture project), but they have not been run in a real browser, so layout, the filter control and the
collapsed history `<details>` were not observed live. This repository's real `events.json` held no `audit_result`
event when the panel was built, so the audits panel was verified against fixtures only.
