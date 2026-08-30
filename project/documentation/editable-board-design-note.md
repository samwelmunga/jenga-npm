# Editable Board Design Note (E06_S03_T01)

This document answers the five design questions that must be resolved before implementing inline task editing in the Jenga AI dashboard.

---

## 1. API Contract Changes

Add a single new endpoint:

```
PATCH /board/:epicId/stories/:storyId/tasks/:taskId
Content-Type: application/json

{ "status": "In Progress" }
```

Response uses the project's standard envelope:

```json
{
  "data": {
    "id": "E01_S02_T03",
    "title": "...",
    "status": "In Progress",
    "assigned_to": "agent"
  }
}
```

On error: `{ "error": "<message>" }` with an appropriate HTTP status code (400 for bad input, 404 for unknown ids, 409 for lock conflict, 500 for write failure).

---

## 2. Safe Server-Side Markdown Writes

To avoid partial writes or corruption of task markdown files:

1. Serialize the updated frontmatter back to a string (using `gray-matter` or a compatible YAML serialiser).
2. Write the new content to a **temporary file** in the same directory (e.g., `.<filename>.tmp`).
3. Use `fs.renameSync` (or the async equivalent) to **atomically rename** the temp file over the original.

This guarantees that readers never see a half-written file; they either see the old version or the new version, never a mix.

---

## 3. Optimistic vs Pessimistic Updates

| Change type | Recommended strategy | Rationale |
|---|---|---|
| Status change | **Optimistic** | Low conflict risk; reverting on failure is cheap (re-render with old value). Gives the user instant feedback. |
| Title / description rename | **Pessimistic** | Higher chance of conflicts; the UI should wait for confirmation before reflecting the change to avoid confusing half-updated labels. |
| Story / task reorder | **Pessimistic** | Reorder operations are order-sensitive; a failed optimistic reorder is hard to roll back cleanly. |

---

## 4. Minimum Editable Field Set for v1

**v1: task `status` only.**

Rationale: status is the highest-value field for a project tracking dashboard, has a finite enum of values (making validation trivial), and maps directly to the frontmatter key already present in every task file. Expanding to title, assignee, and description can follow in v2 once the write pipeline is proven stable.

---

## 5. Locking Concerns

Use a **`.lock` file** convention (consistent with existing project conventions):

- Before writing, attempt to create `.<filename>.lock` exclusively (e.g., `fs.openSync` with flag `'wx'`).
- If the lock file already exists, return a `409 Conflict` response to the client.
- After the atomic rename completes, **delete the lock file** immediately.
- Include a **timeout / staleness check**: if the lock file is older than N seconds (e.g., 10 s), treat it as stale and remove it before acquiring a new lock. This prevents deadlocks caused by crashed processes that never released the lock.
