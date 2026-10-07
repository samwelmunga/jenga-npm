# Preferred Tools Registry: Schema and Layering

Authoritative contract for the preferred-tools registry (epic `E66`). A registry declares which
software and tools Jenga agents should reach for, how binding that preference is, and why. This
document is the single source for the file format; `scripts/validate-tools-registry.sh` and
`scripts/merge-tools-registry.sh` implement exactly what is written here.

## 1. File format

A registry file is a single JSON object:

```json
{
  "registry_version": 1,
  "categories": [],
  "suppress": [],
  "tools": []
}
```

| Field | Type | Required | Meaning |
|---|---|---|---|
| `registry_version` | integer | yes | Schema version. Must be exactly `1`. |
| `categories` | array of string | no (default `[]`) | Extends the base category vocabulary for this file (section 4). |
| `suppress` | array of string | no (default `[]`) | Tool names that this layer removes from **lower** layers (section 6). |
| `tools` | array of object | yes (may be empty) | The entries (section 2). |

Unknown top-level or entry keys are ignored by the validator.

## 2. Tool entry

Each element of `tools[]` is an object with all of the following fields. Every field is required.

| Field | Type | Meaning |
|---|---|---|
| `name` | non-empty string | The tool's identity. Unique within one file. The merge key across layers. |
| `category` | string | One of the base categories or one declared in this file's `categories` (section 4). |
| `enforcement` | `"required"` or `"recommended"` | `required` is binding: an agent needing a different tool in this category stops and asks. `recommended` is advisory: an agent may deviate and notes a justification. Named `enforcement`, not `status`, to avoid confusion with board statuses. |
| `rationale` | non-empty string | Why this tool is preferred. |
| `alternatives` | array of `{name, why_not}` | Alternatives considered. May be empty. Each element must be an object whose `name` and `why_not` are non-empty strings. |
| `version` | string | A version constraint (section 3). |
| `install_hint` | object | How to obtain the tool (section 5). |

### Valid example

```json
{
  "name": "gh",
  "category": "CI",
  "enforcement": "recommended",
  "rationale": "Scripted GitHub operations (PRs, checks, releases) go through one authenticated CLI.",
  "alternatives": [
    { "name": "curl against the REST API", "why_not": "Needs hand-rolled auth and pagination for every call." }
  ],
  "version": ">=2.40",
  "install_hint": { "descriptor": "github", "text": "brew install gh" }
}
```

## 3. Version constraint format

`version` is one constraint string with this grammar (a deliberately small subset of npm-style
semver ranges, checkable with a single regular expression):

```
constraint := "*" | comparator ( " "+ comparator )*
comparator := [ ">=" | "<=" | ">" | "<" | "=" | "^" | "~" ] version
version    := NUMBER [ "." NUMBER [ "." NUMBER ] ]
```

Comparators separated by spaces are ANDed. Examples: `*`, `1.5.0`, `>=1.5`, `^20`, `~3.4.1`,
`>=18 <22`. Not supported (and therefore rejected as malformed): `||` alternatives, hyphen ranges,
`x`/`X` wildcards, pre-release or build suffixes, a leading `v`. The constraint states what the
project wants; this registry never installs or checks the installed version.

## 4. Category vocabulary

The base vocabulary is a closed list (case-sensitive):

`runtime`, `testing`, `lint`, `CI`, `infra`

A file extends the vocabulary by listing extra names in its own `categories` array. An extension
name must match `^[A-Za-z][A-Za-z0-9_-]*$` and must not duplicate a base name (compared
case-insensitively, so `ci` is rejected). A tool's `category` must be in the base list or in the
**same file's** `categories`: validation is per file, so a layer that uses an extended category
must declare it itself even if a lower layer already does. After merging, `categories` in the output
is the union of the extension lists of all present layers (the base list is implicit).

## 5. Install hint

`install_hint` is an object with at least one of:

- `descriptor` (string): the id of a `j-connect` service descriptor. It must match
  `^[a-z0-9][a-z0-9-]*$` and name an existing file `skills/j-connect/descriptors/<id>.json`. The
  validator checks that the file exists.
- `text` (non-empty string): a free-text hint, the fallback when no descriptor exists for the tool.
  A tool with no descriptor uses `{"text": "..."}` alone and carries no link.

Both may be present: the descriptor is the machine-actionable link and the text is the human
fallback. An empty object `{}` is invalid.

## 6. Layers, locations, precedence and suppression

Three layers, from lowest to highest precedence:

| Layer | Location |
|---|---|
| `shipped` | `skills/j-tools/assets/shipped-tools.json` (curated default list shipped with Jenga) |
| `user` | `~/.jenga/tools.json`, overridable by the `JENGA_USER_TOOLS_FILE` environment variable (used by tests) |
| `project` | `project/configs/preferred-tools.json`, located through `scripts/resolve-root.sh get configs` (the `configs` path key) and never a hardcoded `project/` literal |

A layer whose file does not exist (or whose path is empty) is simply absent and skipped. A layer
that exists but fails validation is an error: it is never silently dropped.

**Precedence.** project over user over shipped.

**Whole-entry replacement.** When a higher layer has a tool with the same `name` as a lower layer,
the higher entry replaces the lower entry **whole**. There is no field-level merge: fields omitted
by the higher entry are not inherited.

**Suppression.** A layer's `suppress` list removes tools with those exact names from **lower**
layers only. It cannot remove an entry from the same layer or from a higher layer: a user layer
listing `bats` in `suppress` does not remove a project-layer `bats`, and a layer that both
suppresses and defines `bats` keeps its own entry. Suppressing a name that no lower layer defines
is a harmless no-op.

**Merged output.** `scripts/merge-tools-registry.sh` prints one JSON document:

```json
{ "registry_version": 1, "categories": ["..."], "tools": [ { "...": "...", "layer": "project" } ] }
```

Every output entry carries all of its original fields plus `layer` (`shipped` | `user` |
`project`) recording the layer it came from. `tools` is sorted by `category`, then `name`.
`suppress` is not part of the output.

## 7. Scripts and exit codes

`scripts/validate-tools-registry.sh <file>`

| Exit | Meaning |
|---|---|
| `0` | Valid. |
| `1` | Invalid. One specific message per failure on stderr, and every failure is reported, not only the first: malformed JSON, missing field, wrong type, unknown category, bad `enforcement` value, malformed version constraint, `install_hint.descriptor` naming no descriptor file, duplicate tool name within the file. |
| `2` | Usage error (wrong argument count, file not found or unreadable). |
| `3` | `jq` is not installed. |

The descriptor directory defaults to `skills/j-connect/descriptors/` relative to the script and
can be overridden with the `JENGA_DESCRIPTORS_DIR` environment variable (used by tests).

`scripts/merge-tools-registry.sh <shipped> <user> <project>`

Each argument is a path; an empty string or a non-existent file means that layer is absent.

| Exit | Meaning |
|---|---|
| `0` | Merged document written to stdout. |
| `2` | Usage error (wrong argument count). |
| `3` | `jq` is not installed. |
| `4` | A present layer is invalid. The offending layer and file are named on stderr, followed by the validator's messages. Nothing is written to stdout. |

Both scripts are compatible with macOS bash 3.2 and pass `shellcheck`.

## 8. Resolver: the effective list

`scripts/resolve-tools.sh [--category <name>] [--format json|text]` is the one entry point agents and
skills use to read the registry. It locates the three layers, merges them with
`scripts/merge-tools-registry.sh` (so every rule in section 6 applies unchanged), optionally filters by
category, and prints the effective list. Callers never read the layer files or re-implement layering.

### Layer locations

| Layer | Resolved from |
|---|---|
| `shipped` | `<package root>/skills/j-tools/assets/shipped-tools.json`, where the package root is the parent of the script's own directory. The same script therefore works in this repo and under `node_modules/@jenga-ai/agent/`. |
| `user` | `$JENGA_USER_TOOLS_FILE` if set, otherwise `$HOME/.jenga/tools.json`. |
| `project` | `<configs path>/preferred-tools.json`, where the configs path comes from `scripts/resolve-root.sh get configs`, run in the caller's working directory (or at `JENGA_PROJECT_ROOT`). |

A missing user or project file is normal and is skipped silently. A layer that exists but is invalid is
an error, never skipped.

### CLI

| Option | Meaning |
|---|---|
| `--category <name>` (or `--category=<name>`) | Return only entries of that category. The name is matched case-sensitively against the base vocabulary plus every category declared by a present layer. |
| `--format json` (default) | One JSON document (below). |
| `--format text` | One tab-separated line per entry (below). |
| `-h`, `--help` | Print usage and exit `0`. |

### Exit codes

| Exit | Meaning |
|---|---|
| `0` | Effective list written to stdout. A known category with no entries is still `0`: JSON `tools` is `[]`, text prints nothing. |
| `2` | Usage error (unknown option or stray argument, missing or empty option value, `--format` other than `json`/`text`), or an unknown `--category`. For an unknown category the message on stderr lists the valid categories. Nothing is written to stdout. |
| `3` | `jq` is not installed. |
| `4` | A present layer is invalid. This is the merge script's exit code passed through unchanged; stderr names the layer (`shipped`, `user` or `project`) and the file, followed by the validator's messages. Nothing is written to stdout. |
| `5` | The project configs path could not be resolved because `resolve-root.sh` failed (malformed `workflow.json`, or `JENGA_PROJECT_ROOT` names a root with no registry). Nothing is written to stdout. |

A consumer project with no `workflow.json` at all is not an error: `resolve-root.sh` falls back to
`./project/configs`, whose `preferred-tools.json` simply does not exist, so the project layer is absent.

### JSON output shape

The merged document from section 6, with `tools` filtered when `--category` is given:

```json
{
  "registry_version": 1,
  "categories": [],
  "tools": [ { "<every field of the entry>": "...", "layer": "shipped | user | project" } ]
}
```

- `registry_version` is always `1`.
- `categories` is the union of the extension lists of the present layers (the base vocabulary is implicit). It is not filtered by `--category`.
- `tools` holds the entries that survived precedence and suppression, sorted by `category` then `name`. Each entry carries all of its fields from section 2 plus `layer`, the layer it came from. `suppress` is never part of the output.

Example: a project layer that makes `shellcheck` binding and suppresses the shipped `doctl`, resolved with
`--category lint`:

```json
{
  "registry_version": 1,
  "categories": [],
  "tools": [
    {
      "name": "shellcheck",
      "category": "lint",
      "enforcement": "required",
      "rationale": "CI gate for this project.",
      "alternatives": [],
      "version": ">=0.9",
      "install_hint": {
        "text": "brew install shellcheck"
      },
      "layer": "project"
    }
  ]
}
```

Consumers read it with `jq`, for example `resolve-tools.sh --category lint | jq -r '.tools[] | select(.enforcement == "required") | .name'`.
JSON is pretty-printed and its key order inside an entry is not a contract; read fields by name.

### Text output shape

`--format text` prints one line per entry, in the same order as the JSON, with six tab-separated columns
and no header line:

```
category<TAB>name<TAB>enforcement<TAB>layer<TAB>version<TAB>rationale
```

For the example above: `lint`, `shellcheck`, `required`, `project`, `>=0.9`, `CI gate for this project.`
separated by tabs. Tabs, newlines and backslashes inside a value are escaped (`\t`, `\n`, `\\`), so the
column count is always six. Use the JSON format when a field may need exact round-tripping.

The resolver is covered by `tests/tools-resolve.bats`. Like the other registry scripts it is compatible
with macOS bash 3.2 and passes `shellcheck`.

## 9. Consumers: Developer, Tester, and `test-config.json`

The Developer and Tester agents read the registry through the resolver in section 8 and nowhere
else (`E66_S04`). They never parse a layer file or re-implement layering. The agent files
(`agents/developer.md`, `agents/tester.md`) carry only a short pointer to this section; the rules live here.

### How an agent applies an entry

Before choosing a tool, the agent runs `scripts/resolve-tools.sh --category <category>` and reads the
entries with `jq` (section 8).

| `enforcement` | Behaviour |
|---|---|
| `required` | Binding. If the task needs a different tool in that category, the agent stops and asks the user. It does not pick the other tool on its own. |
| `recommended` | Advisory. The agent may use another tool, but states a one-line justification. The Developer records it on the **Tool deviations** line of the task's execution summary so it is auditable; the Tester states it in the proposal it puts to the user. |

### Failure handling

| Resolver outcome | Agent behaviour |
|---|---|
| Script not installed (an older install), or exit `0` with an empty `tools` list | No registry preference exists. This is not an error. Use current behaviour and say nothing. A missing user or project layer file is normal and already exits `0`. |
| Exit `4` (a present layer is invalid) | Surface it to the user, naming the layer and file from stderr, then fall back to current behaviour. Never carry on as if the registry were absent, and never edit or delete the invalid file. |
| Exit `2`, `3` or `5` | Surface the stderr message to the user, then fall back to current behaviour. |

### Relationship to `project/configs/test-config.json`

**Decision: separate, with `test-config.json` authoritative. The Tester reads both.** The registry is
not derived from `test-config.json`, and does not supersede it.

- `test-config.json` remains the Tester's per-test-type configuration. It is user-approved: only the
  user can change it, exactly as `agents/tester.md` ("Tool Stack Management") already requires.
- The registry is consulted only when the Tester is choosing or proposing a tool for a test type that
  `test-config.json` does not already settle (no entry for the type, or no `test-config.json` yet),
  using the `testing` category (for `unit`, `integration`, `e2e`, `performance`, `coverage`) and the
  `lint` category (for static analysis).
- **A `required` registry entry that conflicts with an existing `test-config.json` entry** (a
  different tool for the same purpose) is surfaced to the user, who decides. The Tester neither
  switches tools nor edits `test-config.json` on its own.
- **A `recommended` entry never overrides `test-config.json`.** It only informs a proposal for a
  type the config does not settle.
- Any change to `test-config.json` that follows still goes through the existing user-approval step.
- **SAST and vulnerability scanning stay opt-in.** A registry entry, `required` or not, never turns
  them on and never counts as the user's approval; the approval flow and the `tool_approval` event
  in `events.json` are unchanged. The same holds for performance testing.

Precedence, highest first: (1) a user-approved `test-config.json` entry, (2) otherwise a `required`
registry entry, (3) otherwise a `recommended` registry entry, (4) otherwise the Tester's own
assessment of the stack. Level (2) over (4) still ends in a proposal the user approves before
`test-config.json` is written.

#### Worked example

`test-config.json` has `{"tool_name": "bats", "type": "unit"}`. A project layer adds
`{"name": "vitest", "category": "testing", "enforcement": "required", ...}`.

1. The Tester needs a unit-test tool. `unit` is already settled by `test-config.json`, so it keeps
   using `bats`.
2. It resolves `--category testing`, sees `vitest` is `required` and differs from the configured
   `bats`, and tells the user about the conflict: the registry says `vitest` is binding, the approved
   config says `bats`.
3. The user chooses: keep `bats` (and fix or suppress the registry entry), or approve switching to
   `vitest`, in which case `test-config.json` is updated through the normal approval step.
4. Had the entry been `recommended`, there is no conflict and no prompt: `bats` stays.

For a type with no `test-config.json` entry (say `integration` in a new project), the same `vitest` `required`
entry is the starting point of the Tester's proposal, which the user still approves before it is written.
