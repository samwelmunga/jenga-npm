# Config Descriptors

Owner epic: `E68` (Jenga Config Command). Machine-readable contract: `templates/config-descriptor-schema.json`.

`jenga config` is a deterministic, agentless command (no model, no tokens) that lists the settings in
`project/configs/*.json` and edits the scalar ones. Everything it knows about a config file comes from a
**descriptor**: one JSON file per config file. Adding a config file or a key is a descriptor edit, never a change
to command logic.

This page is for someone adding a new config file or key. If you only want to change a value, use
`jenga config` itself.

## Where descriptors live

- One descriptor per config file: `templates/config-descriptors/<file-id>.json`, where `<file-id>` is the config's
  basename without `.json` (the config `project/configs/scope-thresholds.json` is described by
  `templates/config-descriptors/scope-thresholds.json`).
- Descriptors are resolved **from the package, never from the project**. The loader finds them relative to the
  package root (`lib/config/descriptors.js` locates it from its own `import.meta.url`), so the same code works in
  this checkout and from `node_modules/@jenga-ai/agent/`, where `templates/`, `lib/` and `scripts/` are read in
  place and not mirrored into the consumer project.
- Test override: set `JENGA_CONFIG_DESCRIPTORS_DIR` to a directory and the loader reads descriptors from there
  instead. Tests use this with scratch fixtures; do not set it in normal use.
- Files in the descriptor directory whose name starts with `_` are ignored by the loader (use that prefix for
  drafts and fixtures).
- The config files themselves are found through `scripts/resolve-root.sh get configs`, so `JENGA_PROJECT_ROOT`,
  the upward search and `.project/` trees all work. Nothing under `lib/config/` hardcodes a `project/` path.

## Descriptor shape

Top level (all four required):

| Field | Type | Meaning |
|-------|------|---------|
| `descriptor_version` | integer | Always `1`. |
| `file` | string | The config basename including `.json`. Must equal the descriptor's own file name (`<file-id>.json`). |
| `description` | string | One line describing the config file. Shown in the file list. |
| `keys` | array | Ordered list of key entries, one per **top-level** key of the config file. The array order is the display order. |

Per key entry:

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `key` | string | always | Exact top-level key name in the config file. Letters, digits, `_` and `-`, starting with a letter or `_` (so `<file-id>.<key>` stays unambiguous). |
| `label` | string | always | Short human name, one line. |
| `type` | string | always | One of `integer`, `string`, `boolean`, `array`, `object`. |
| `description` | string | always | One-line explanation. |
| `editable` | boolean | always | `true` only for scalar types (see below). |
| `default` | same as `type` | editable keys | The value to document as the default. It must itself satisfy the key's `type`, `min`/`max` and `allowed`. |
| `min`, `max` | integer | optional | Inclusive bounds. `integer` keys only, and `min` must be `<=` `max` when both are given. |
| `allowed` | array | optional | A closed set of legal values (non-empty, no duplicates, every entry of the key's `type`). Any scalar type. |
| `pattern` | string | optional | A JavaScript regular expression the value must match. `string` keys only. |
| `pointer` | string | read-only keys | A non-empty one-line pointer to the validator, script, document or wizard that owns the content. |
| `bump_on_change` | string | optional | Name of the version-counter key a successful set increments by 1. Editable keys only. |

Rules:

- **`editable: true` is legal only for scalar types** (`integer`, `string`, `boolean`). An `array` or `object` key
  is always `editable: false` and carries a `pointer`. Nested lists and objects are listed read-only.
- **Version-counter keys are `editable: false`.** `threshold_version` and `config_version` are listed so people can
  see them, but the command owns them: if a user could set one, the command could then bump it on top of their
  value. A `bump_on_change` value must therefore name an existing key in the same descriptor that has
  `type: integer` and `editable: false`, and a key never names itself.
- **No bump rule where the file pins its version.** `checklists.json`'s `checklist_version` is pinned to the
  integer `1` by `scripts/validate-checklists.sh`, so it has no `bump_on_change` anywhere.
- **Every `label`, `description`, `pointer` and the top-level `description` is a single line** (no newline), so
  the renderer can emit exactly one `ranked_list` line per key.
- **No duplicates**: a `key` appears at most once per descriptor.
- **Full coverage**: every top-level key in the real config file must have a descriptor entry, and every
  descriptor entry must name a key that exists in the file. `lib/config/descriptors.js`'s `checkAgainstConfig`
  reports both directions, so a key added to a config file without a descriptor is caught, as is a typo in a
  descriptor. It also reports a key whose current value does not match its declared `type`.
- **Pointers must be real.** A pointer names something that exists in the repo: a path such as
  `scripts/validate-checklists.sh`, or a skill such as `j.tools`. Tests resolve every shipped pointer.

## Worked example: an editable integer key

```json
{
  "key": "inline_max_files",
  "label": "Inline max files",
  "type": "integer",
  "description": "Most files a task may touch and still run inline (no subagent, no worktree).",
  "editable": true,
  "default": 3,
  "min": 1,
  "max": 50,
  "bump_on_change": "threshold_version"
}
```

It pairs with a version-counter entry in the same descriptor:

```json
{
  "key": "threshold_version",
  "label": "Threshold version",
  "type": "integer",
  "description": "Version counter for this file, incremented by jenga config on every successful set.",
  "editable": false,
  "pointer": "project/configs/README.md"
}
```

## Worked example: a read-only nested key

```json
{
  "key": "items",
  "label": "Checklist items",
  "type": "array",
  "description": "The standing pre-flight items. Edited by hand or through suggestions, never by jenga config.",
  "editable": false,
  "pointer": "scripts/validate-checklists.sh"
}
```

A read-only key is listed with its value summarised (for example `38 items`, never dumped) and the pointer, as
`Checklist items: 38 items [read-only; see scripts/validate-checklists.sh]`.

## Exit codes

`jenga config get` and `set`, the interactive flow and the helper scripts all use one table, so a script can rely
on it. It is also recorded in `templates/config-descriptor-schema.json` under `exit_codes`, so the guide and the
command cannot drift.

| Code | Meaning |
|------|---------|
| `0` | Success. |
| `2` | Usage error: missing or surplus arguments, an unknown sub-command or flag. |
| `3` | Unknown config file or unknown key: no descriptor, or the descriptor does not list that key. |
| `4` | Invalid value: wrong type, outside `min`/`max`, not in `allowed`, or failing `pattern`. |
| `5` | Read-only key: the key is not editable (nested value, version counter, or any `editable: false` key). |
| `6` | Config file missing or malformed, or the configs directory could not be resolved. |

The helper scripts add `1` for an unexpected failure that is not the caller's fault (for example an invalid
descriptor, found by `scripts/validate-config-descriptors.sh`).

## Adding a new config file or key

You never touch command logic.

1. **New key in an existing file.** Add a key entry to `templates/config-descriptors/<file-id>.json`, in the
   position you want it displayed. Match the real value's `type`. If it is a scalar users may change, set
   `editable: true`, a `default`, and its bounds; if it belongs to a version-counted file, add
   `bump_on_change`. Otherwise make it `editable: false` with a `pointer`.
2. **New config file.** Create `templates/config-descriptors/<file-id>.json` with the four top-level fields and one
   entry per top-level key of the file. Copy the closest existing descriptor as a starting point.
3. **Validate.**

   ```bash
   bash scripts/validate-config-descriptors.sh --all          # every shipped descriptor against the real configs
   bash scripts/validate-config-descriptors.sh path/to/x.json # one descriptor
   ```

   It exits non-zero with one message per problem: a malformed descriptor, a key the config file does not have,
   or a config key with no descriptor entry.
4. **Look at it.** `bash scripts/render-config-list.sh` lists the config files, and
   `bash scripts/render-config-list.sh <file-id>` lists the keys of one, in the Jenga `ranked_list` shape
   (`<n>. <id> — <text>`, 1-indexed, no trailing menu line).

The loader, validator and renderer are `lib/config/descriptors.js` and `lib/config/render.js`; the scripts above are
thin wrappers over them.
