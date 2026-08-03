# API Contract — JengaAgent Dashboard API

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
