# `/doc` authoring notes

## `last_update` provenance

`/doc` writes a `last_update` frontmatter field at the top of generated documentation files. That value is derived from completed scrum-board items that explicitly declare they affected the target document.

The resolver is `skills/j-doc/scripts/resolve_last_update.py`. It scans:

- `project/board/epics/`
- `project/board/stories/`
- `project/board/tasks/`

A board item counts as provenance only when all of the following are true:

1. `status` is `Done` or `Passed`
2. `docs` is a YAML list
3. The `docs` list contains the target file path as an exact repo-relative match (for example `README.md` or `docs/API.md`)
4. `date_completed` exists and parses as `YYYY-MM-DD`

If multiple board items match, `/doc` uses the most recent `date_completed` as `last_update`.

## Required board annotations

For provenance to work, the scrum-board item that changed a documentation file must carry a matching `docs: [...]` annotation in its YAML frontmatter.

Examples:

```yaml
docs:
  - README.md
  - docs/API.md
```

Use repo-relative paths only. The resolver does not normalize absolute paths or `./`-prefixed variants.

## Fallback behavior

When `/doc` cannot determine provenance, it still emits valid YAML frontmatter and sets:

```yaml
last_update: unknown
```

This fallback is intentional. It keeps the frontmatter shape stable while making the missing provenance explicit to both humans and downstream tooling.

## Failure modes and assumptions

### Board item completed without `docs` annotations

If a task, story, or epic reached `Done`/`Passed` but omitted the target file from `docs`, `/doc` cannot attribute that item to the document. The resolver will ignore it and may fall back to `unknown`.

### Target path mismatch

Matching is exact and repo-relative. These examples do **not** match `README.md`:

- `/Users/sam/.../README.md`
- `./README.md`
- `docs/../README.md`

Authors should record the canonical repo-relative path that `/doc` was invoked with.

### Item not in a completed status

Items in statuses such as `Pending`, `In Progress`, `Blocked`, or `Failed` do not count as provenance even if they include the right `docs` annotation. Only completed work is eligible.

### Missing or invalid `date_completed`

A matching board item without a valid `date_completed` cannot contribute a `last_update` value. The resolver skips it and logs a warning to stderr.

### Malformed legacy board files

Some older board artifacts may not follow the current YAML-frontmatter schema. The resolver skips unparseable files instead of failing the whole `/doc` run. This is a degradation path, not successful provenance.
