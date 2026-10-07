# Service Descriptor Format (`j.connect`)

A **service descriptor** is a small JSON file that tells `j.connect`'s shared scripts how to connect one
third-party service: detect its CLI, install it, authenticate, register its MCP server, and verify. Adding a
service is a **data-only change** (a new descriptor); no `SKILL.md` or shared-script edit is needed.
Modeled on `j.cloud-connect` (`E60_S01`). Introduced by `E65_S01_T02`.

- Validator: `skills/j-connect/scripts/validate-descriptor.sh <descriptor>` (jq only).
- Runner: `skills/j-connect/scripts/run-descriptor.sh` (`E65_S01_T05`; see "Runner" below).
- Enumerator: `skills/j-connect/scripts/list-services.sh` (`E65_S02_T02`; see "Where descriptors live").
- MCP target file: `.mcp.json`, see [mcp-registration-decision.md](mcp-registration-decision.md).
- Test fixtures (never real services): `tests/fixtures/connect/descriptors/`.

## Where descriptors live

Real service descriptors live in `skills/j-connect/descriptors/` as `<id>.json`: the filename stem must equal
the descriptor's `id`, because the runner resolves `requires` ids by looking for `<id>.json` (first next to the
descriptor being run, then in this directory). That directory is also the default scan location of
`skills/j-connect/scripts/list-services.sh [--descriptors-dir <dir>]...`, which builds the `j.connect` picker
from whatever valid descriptors it finds, so adding a service is dropping in one file (no script or `SKILL.md`
edit). The default is resolved from the script's own location, not the cwd, so it also works from a
`.claude/skills/` mirror. Invalid descriptors, an `id` that differs from its filename stem, and a duplicate
`id` across scanned directories are skipped (reported in the output's `skipped` list and on stderr), never
listed. Fixtures under `tests/fixtures/connect/` are not scanned by default.

## Design rules

1. **No authoritative install commands.** Third-party install commands rot. A descriptor links the official
   docs URL; at most it names a bare package for a supported package manager. The runner always verifies by
   *executing* the tool, never by trusting a stored string.
2. **Secrets are env-var names only.** Values never appear in a descriptor, in runner output, or in logs.
3. **Commands are argv arrays** (`["fakecli", "--version"]`), never shell strings, and are judged by exit
   status only. Their stdout/stderr is discarded by the runner so a token printed by a tool cannot leak.

## Fields

| Field | Required | Type | Meaning |
|-------|----------|------|---------|
| `id` | yes | string `^[a-z0-9][a-z0-9-]*$` | Stable id; also the filename stem and the `requires` reference key. |
| `name` | yes | string | Human-readable name. |
| `docs` | yes | non-empty array of `http(s)` URLs | Official docs for the service. |
| `requires` | no | array of descriptor ids | Shared prerequisites, by reference (e.g. `["github"]`). |
| `secrets` | no | object | `env_vars`: array of env-var NAMES (`^[A-Z][A-Z0-9_]*$`). `env_file`: relative path (e.g. `.env`) where placeholders may be created. |
| `detect` | yes | `{ "command": [argv] }` | Executed to see whether the tool is present (exit 0 = present). |
| `install` | yes | object | `docs_url` (required, `http(s)`); `hint` (optional free text, non-authoritative); `methods` (optional array of `{platform: darwin\|linux, manager: brew\|npm, package}`) with a bare, **unpinned** package name. Keys such as `command`/`script`/`run` are rejected. |
| `auth` | yes | object | `type`: `browser` \| `env-token` \| `none`. Unless `none`: `check.command` (argv; an authenticated no-op). `env-token` also needs `env_var` (must be in `secrets.env_vars`). Optional `docs_url`, `instructions` (text shown to the user). |
| `register_mcp` | yes | object | Present **or** explicitly absent. `{"supported": false}` = the service has no MCP server. `{"supported": true, "name", "type": "stdio"\|"http", "command"+"args" (stdio) or "url" (http), "env": [NAMES]}`; every `env` name must also be in `secrets.env_vars`. |
| `verify` | yes | `{ "command": [argv] }` | Executed independently at the end (e.g. `<tool> --version`, an authenticated no-op); exit 0 = verified. Keys that compare against a stored string (`expect_output`, `equals`, ...) are rejected. |

`register_mcp` may never simply be omitted: that is indistinguishable from a forgotten section, so the
validator requires an explicit `{"supported": false}`.

### Validator rejections

Missing `id`/`name`/`docs`/`detect`/`install`/`auth`/`verify`; `register_mcp` neither present nor marked
absent; hardcoded install command keys or a missing install docs URL; a version-pinned or flag-bearing
package; stored-string verification; env-var lists that are not NAMES; any string value that looks like a
real credential (GitHub/OpenAI-style tokens, AWS key ids, JWTs, private-key blocks, bearer tokens); any
secret-named key (`token`, `password`, `api_key`, ...) holding a value. The secret check is a heuristic and
is not exhaustive: it is a guardrail, not a proof. Messages name the field path, never the offending value.

Exit status: `0` valid, `1` invalid (one `ERROR:` line per problem on stderr), `2` usage error or not JSON.

## Step result vocabulary

The runner emits one JSON object per step and a final summary. Every step `status` is exactly one of:

| Status | Meaning |
|--------|---------|
| `pass` | The step ran and its goal is achieved. |
| `fail` | The step ran and failed. Stops the run unless `--continue`. |
| `skipped` | Not needed or not applicable: its check already passes, or the service has no MCP server. |
| `needs-user-action` | A human must act (browser sign-in, set a token, install manually). The runner prints what to do and stops. |

Steps, in order: `requires:<id>` (once per prerequisite), `detect`, `install`, `auth`, `register_mcp`,
`verify`. See "Runner" for the JSON shape and exit codes.

## Runner

`skills/j-connect/scripts/run-descriptor.sh <descriptor> [--step <name>] [--continue] [--allow-install]
[--project-root <dir>] [--descriptors-dir <dir>]` validates the descriptor (rejecting it, with no step run,
if invalid) and executes the steps in order. Output is one JSON object per line on stdout:

```json
{"descriptor":"fakeservice","step":"detect","status":"pass","message":"tool is present","detail":"present"}
{"summary":true,"descriptor":"fakeservice","status":"pass","counts":{"pass":3,"fail":0,"skipped":2,"needs-user-action":0},"steps":5}
```

Exit codes: `0` pass, `1` any `fail`, `3` `needs-user-action` (no fail), `2` usage error or invalid descriptor.

| Step | Behaviour |
|------|-----------|
| `requires:<id>` | Each referenced prerequisite descriptor (`<id>.json` in `--descriptors-dir`, default the descriptor's own directory, then `skills/j-connect/descriptors/`) is validated and run **once per invocation**; later references (including through a diamond, `A -> B,C` and `B -> C`) report `skipped` and reuse the result. A missing or circular prerequisite is a `fail`. |
| `detect` | Runs `detect.command`; always `pass`, with `detail` `present` or `absent`. |
| `install` | Present: `skipped`. Absent: if the platform (`uname -s`, or the `JENGA_CONNECT_PLATFORM` override) is not darwin/linux, or no `install.methods` entry for it has its package manager on `PATH`, the docs URL is printed and the result is `needs-user-action`; **no install command is run or guessed**. With a usable method but without `--allow-install` the result is also `needs-user-action` (installs are opt-in). With `--allow-install` the runner runs the package manager itself (`brew install <package>` or `npm install -g <package>`, built only from the descriptor's manager and bare package name), then re-runs detection: still absent is a `fail`. |
| `auth` | `none` or `auth.check.command` already passing: `skipped`. `browser`: prints the instructions/URL, `needs-user-action` (consent is never attempted). `env-token`: before writing `secrets.env_file`, calls `ensure-secret-safe.sh` (a refusal is a `fail` and nothing is written), appends a `NAME=` placeholder line (name only), and returns `needs-user-action`. The runner does not load the env file; `auth.check.command` sees the process environment. |
| `register_mcp` | Not supported: `skipped`. Otherwise calls `register-mcp.sh` (`.mcp.json`, see [mcp-registration-decision.md](mcp-registration-decision.md)): `added`/`updated` are `pass`, `unchanged` is `skipped`; `detail` carries `added`/`updated`/`unchanged`. |
| `verify` | Runs `verify.command`: exit 0 is `pass`, otherwise `fail`. |

By default the run stops at the first `fail` or `needs-user-action` (later steps depend on it);
`--continue` keeps going and the summary reports the worst status. A command's own output is discarded (or,
for install, sent to stderr), never to stdout, so a token a tool prints cannot reach the results.
