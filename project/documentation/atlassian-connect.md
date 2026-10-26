# Atlassian connect (epic E71)

Maintainer reference for how Jenga connects to Atlassian through `j.connect`. It documents the two
service descriptors, the official sources they were written from, and what could not be verified.

> **Shared file.** This document is extended by several stories of epic E71. Each later task adds its
> own section (see "Marker and gate" and "Link script" below) and must not restructure the sections
> above it. Keep the "Could not verify" section in step with the descriptors' `hint` fields: the
> bats test `tests/atlassian-connect.bats` fails when they drift apart.

| Section | Owner |
|---|---|
| Transports and coverage; Official sources consulted; Could not verify | `E71_S01_T03` |
| Marker and gate | `E71_S02_T03` |
| Link script | `E71_S04_T03` |

## Transports and coverage

Jenga offers two transports. They are separate descriptors in `skills/j-connect/descriptors/`; neither
handles a secret value, and neither replaces the other.

| | `atlassian-cloud` | `atlassian-cli` |
|---|---|---|
| Transport | Atlassian's remote MCP server, registered in the project `.mcp.json` by `j.connect` | Atlassian's `acli` command-line tool, signed in by the user |
| Authentication | OAuth 2.1 inside Claude Code (`/mcp`); `auth.type` is `none` | API token entered by the user; `auth.type` is `browser` |
| Secrets | none declared | env-var NAMES only: `ATLASSIAN_API_TOKEN`, `ATLASSIAN_SITE`, `ATLASSIAN_EMAIL` |
| Registers an MCP server | yes, `atlassian`, http | no (`register_mcp.supported` is `false`) |
| Verify step | `claude mcp get atlassian` (configured, not approved) | `acli jira project list --limit 1` |

Coverage per product (Atlassian Cloud only; Data Center and Server are not covered by either transport):

| Product | `atlassian-cloud` (remote MCP) | `atlassian-cli` (acli) |
|---|---|---|
| Jira | Covered | Covered (`acli jira ...`) |
| Confluence | Covered | **Not covered**: the acli reference has no Confluence command group |
| Bitbucket | Bitbucket Cloud only, and only when the workspace is linked to an Atlassian organization | **Not covered**: the acli reference has no Bitbucket command group |

Other facts taken from the official pages (fetched 2026-10-06):

- The remote MCP endpoint registered is `https://mcp.atlassian.com/v2/mcp`. Atlassian lists `/v2/mcp` as
  current; `/v1/mcp` and `/v1/mcp/authv2` as legacy; the `/v1/sse` endpoint as unsupported after
  30 June 2026. A web-search snippet claiming `/v1/mcp` was seen and not relied on.
- Atlassian also documents an optional API-token mode for the remote server, enabled by an organization
  admin. The `atlassian-cloud` descriptor does not use it.
- acli: macOS install is `brew tap atlassian/homebrew-acli` then `brew install acli`, which the runner's
  bare `brew install <pkg>` cannot express, so the descriptor has no `install.methods` and links the docs.
  Each acli version is supported for 6 months after release. Atlassian Government Cloud is not supported.
  Authentication is by API token (basic auth), API key (org admin) or OAuth; `acli jira auth login`
  takes `--site` and `--email` and reads the token from standard input or a file (`--web` for OAuth).
  The command groups in the reference are `admin`, `feedback`, `jira` and `rovodev`.
- The env-var names are a Jenga convention. Atlassian documents no environment-variable sign-in for acli.

## Official sources consulted

URLs are the ones the descriptors carry in `docs`, `install.docs_url` and `auth.docs_url`, plus the
pages consulted while writing them. Wording in the descriptors is paraphrased, not quoted.

### `atlassian-cloud`

- https://support.atlassian.com/atlassian-rovo-mcp-server/docs/getting-started-with-the-atlassian-remote-mcp-server/
- https://support.atlassian.com/atlassian-rovo-mcp-server/docs/supported-tools/
- https://support.atlassian.com/atlassian-rovo-mcp-server/docs/authentication-and-authorization/
- https://github.com/atlassian/atlassian-mcp-server
- https://support.atlassian.com/rovo/kb/fix-oauth-consent-block-for-atlassian-rovo-mcp-server-in-atlassian-cloud/ (consulted for the admin allowlisting note; not in the descriptor)
- https://support.atlassian.com/atlassian-rovo-mcp-server/docs/setting-up-ides/ (consulted; it held no endpoint or Claude Code detail, so it is not cited)

### `atlassian-cli`

- https://developer.atlassian.com/cloud/acli/guides/introduction/
- https://developer.atlassian.com/cloud/acli/guides/how-to-get-started/
- https://developer.atlassian.com/cloud/acli/reference/commands/
- https://developer.atlassian.com/cloud/acli/guides/install-acli/
- https://developer.atlassian.com/cloud/acli/guides/install-macos/ (consulted for the Homebrew steps; not in the descriptor)
- https://developer.atlassian.com/cloud/acli/reference/commands/jira-auth-status/ (consulted)
- https://developer.atlassian.com/cloud/acli/reference/commands/jira-project-list/ (consulted)

Web searches for an Atlassian CLI also return Appfire's unrelated ACLI and community `atlassian-cli`
tools; those were not used as sources.

## Could not verify

Nothing here was run against a real Atlassian account, site, workspace or token. Each descriptor says so
in its `install.hint` with the label "Not verified against a real account". The items below match those
labels one to one: five for `atlassian-cloud`, three for `atlassian-cli`. If a descriptor's label changes,
change the matching item here in the same commit.

### `atlassian-cloud`

1. **CV-CLOUD-1.** That the registered endpoint accepts a real sign-in. The docs were read, no live
   account was used.
2. **CV-CLOUD-2.** That the OAuth consent screen completes for a given site. An organization admin may
   have to allowlist the redirect domain (Atlassian Administration, Rovo, Rovo MCP server, Domain
   settings, per Atlassian's knowledge-base article).
3. **CV-CLOUD-3.** That the Jira, Confluence and Bitbucket tools all appear for a given site and
   workspace. Atlassian documents the Bitbucket Cloud tools as needing the workspace linked to an
   organization.
4. **CV-CLOUD-4.** That the entry `j.connect` writes to `.mcp.json` is picked up after the user approves
   the project server in Claude Code.
5. **CV-CLOUD-5.** That `claude mcp get atlassian` reports a project-scoped server before it is approved,
   which is what "configured" means for the verify step.

Also unknown, but not carried as a label in the hint: Atlassian's docs say nothing about Data Center or
Server for the remote MCP server (the descriptor states they are not covered), and the authentication page
does not document token expiry, refresh or consent-screen behaviour.

### `atlassian-cli`

1. **CV-CLI-1.** The Linux and Windows install steps. The guide pages exist; they were not read in detail.
2. **CV-CLI-2.** Which of Jira, Confluence and Bitbucket the Atlassian Cloud MCP server serves, from the
   acli side. This is the other transport's question; it is labelled in both descriptors' context.
3. **CV-CLI-3.** Whether `acli jira auth status` and `acli jira project list` exit non-zero when the user
   is not signed in. Exit-code behaviour is undocumented, and it decides whether the verify step can fail.

The `auth.instructions` of `atlassian-cli` carries one further label, beyond the hint: the exact flags of
`acli jira auth login` (taken from a summarised fetch of the docs, not a run) and whether the check
fails when signed out (the same question as CV-CLI-3).

## Marker and gate

Two scripts in the root `scripts/` directory (mirrors are regenerated by `E71_S08`, never edited):

- `scripts/atlassian-configured.sh`, the **gate**. The link prompts of `E71_S05` (`/reconcile`) and `E71_S06`
  (`j.todo`) call it and show themselves only on exit `0`. A project with no Atlassian connection is the normal
  case, not an error: the gate answers "not configured" without writing anything to stderr.
- `scripts/atlassian-write-marker.sh`, the **only writer** of the marker.

### The marker

`<configs>/atlassian.json`, where `<configs>` comes from `scripts/resolve-root.sh get configs` (in this repo
`project/configs/atlassian.json`; never a hardcoded path). It holds exactly five fields and no secret, token or
env-var value:

| Field | Type | Meaning |
|---|---|---|
| `enabled` | boolean | `false`, or no marker at all, means not configured. |
| `products` | array | A non-empty subset of `jira`, `confluence`, `bitbucket`, stored de-duplicated in that order. |
| `deployment` | string | `cloud` or `datacenter`. |
| `site_base_url` | string | The site, as an `https://` base URL with no credentials, query string or fragment, for example `https://example.atlassian.net`. Trailing slashes are stripped. |
| `transport` | string | `mcp` (the Atlassian MCP server entry is in the project `.mcp.json`) or `cli` (a local, authenticated `acli`). It selects the confirmation method the gate uses. |

### Do not edit the marker by hand

The marker is written **only** by `scripts/atlassian-write-marker.sh`, as the last step of the `j.connect`
Atlassian flow. Do not edit `atlassian.json` by hand, and do not write it from any other skill, script or the
linking layer. A hand-written marker is a claim nothing has verified, and a stale one is exactly what the drift
check exists to catch. To turn the feature off, run the writer with `--disable` (it needs no confirmation and
keeps the other fields); to turn it on, run the `j.connect` Atlassian flow again.

```
atlassian-write-marker.sh --transport mcp|cli --deployment cloud|datacenter \
                          --site <https-base-url> --products jira,confluence,bitbucket
atlassian-write-marker.sh --disable
```

Writer exit codes: `0` written (or nothing to disable), `2` invalid arguments (the message names the option and
never echoes its value; nothing is written), `3` connection not confirmed (nothing is written, the gate's reason
is printed on stderr), `4` could not write (missing `jq` or resolver, lock timeout, filesystem error). On exit `0`
it prints `{"written":true,"enabled":<bool>,"path":"<marker>"}`. The write is atomic and serialised under
`scripts/with-lock.sh`, and identical arguments leave a byte-identical file. The writer takes no credential option.

### Verify before claiming

The marker is a claim, so the writer records `"enabled": true` **only after** `atlassian-configured.sh
--check-transport <transport>` confirms the connection. That mode runs the confirmation for the named transport
and neither requires nor reads the marker, so the confirmation logic exists in one place (the gate) and is not
copied into the writer. If the confirmation fails the writer exits `3` and leaves no marker, so a marker never
exists for a connection that could not be shown to work. For `mcp` this means the `.mcp.json` entry has to exist
before the writer runs (register first, then write).

### The gate: exit codes and output

`atlassian-configured.sh` makes no network call on any path and never hangs. It prints exactly one JSON object on
stdout, always:

| Exit | Meaning | JSON object |
|---|---|---|
| `0` | Configured | `{"configured":true,"reason":"...","products":[...],"deployment":"...","transport":"...","site_base_url":"..."}` |
| `1` | Not configured, including drift and a malformed marker | `{"configured":false,"reason":"..."}` |

The `reason` string says why. With `--check-transport mcp|cli` the object is `{"configured":<bool>,"reason":"..."[,"transport":"..."]}`
and a failure reason says the connection is "not confirmed" rather than naming drift.

The confirmation is cheap and offline. `mcp`: the project `.mcp.json` has the Atlassian server entry (name and URL
read from the `atlassian-cloud` descriptor's `register_mcp`, URL compared ignoring query string and fragment). `cli`:
a local `acli` auth-status check bounded by a short timeout (5 s, `JENGA_ATLASSIAN_ACLI_TIMEOUT` overrides). The
exact `acli` subcommand is unverified against a real account (`E71_S08`), so both `acli auth status` and `acli jira
auth status` are tried and either succeeding counts.

### Drift

Drift is a marker that says `enabled: true` while the connection it claims is gone: the MCP entry was removed from
`.mcp.json`, or `acli` is missing, signed out or timed out. It is never silently treated as configured: the gate
exits `1` with `configured: false` and a `reason` that names the drift. **Remedy:** re-run `j.connect` for Atlassian
(which re-confirms and rewrites the marker), or disable the marker with `atlassian-write-marker.sh --disable`.
A missing marker and `enabled: false` also exit `1` ("not configured"); a malformed marker exits `1` with a reason
saying so, never a crash.

### How the marker gets written today

`j.connect` runs a descriptor with `skills/j-connect/scripts/run-descriptor.sh`, which executes argv arrays only
and has no post-step hook. The two Atlassian descriptors therefore do **not** write the marker from their `verify`
step: an argv cannot resolve the writer's path in a consumer project, cannot supply the site URL (the cloud site is
chosen by the user on the consent screen), and chaining two commands would need a shell string, which the descriptor
format forbids. Rapport `project/rapports/problems/E71_S02_T03-descriptor-cannot-write-marker.md` records this and
proposes the minimal alternative, a follow-up step the skill runs after a passing verify. Until that lands, the
writer is invoked as shown above, with `--transport mcp` for `atlassian-cloud` and `--transport cli` for
`atlassian-cli`, after the descriptor's run passes; it refuses (exit `3`) if the connection is not confirmed.

## Link script

`scripts/link-external-ref.sh` (root `scripts/` directory; mirrors are regenerated by `E71_S08`, never edited) is
the **only sanctioned writer** of the `external_refs` field and of the skip marker on a board item. It validates a
Jira issue key, a Confluence page URL or a Bitbucket repository or pull-request URL, and records it in the
frontmatter of an epic, story or task file. The field contracts it writes are in
`templates/SCRUM_BOARD_SCHEMA.md` ("External Refs Fields" and "Declined External Refs Fields");
`scripts/validate-board.sh` enforces them.

### Offline and independent of the gate

The script makes no network call and does not need Atlassian to be configured. It does not read the marker and does
not call `scripts/atlassian-configured.sh`: the gate (see "Marker and gate" above) decides only whether a link
**prompt** is shown to the user; it never decides whether this script may run. It can always be run directly from a
shell. Whether a link is real (the Jira issue exists, the page is reachable) is not checked either; the script
validates the **shape** of the value only.

### Who may write

Only the scrum-master writes `external_refs` and the skip marker, and only through this script. The `E71_S05`
(`/reconcile`) and `E71_S06` (`j.todo`) prompts record a link, or a skip, by calling it. Do not edit those fields
by hand and do not write them from any other skill, agent or script.

### Interface

```
link-external-ref.sh <item-id> --system jira|confluence|bitbucket --kind issue|page|repo|pull-request \
                     (--key <KEY> | --url <URL>)
link-external-ref.sh <item-id> --decline
```

- `<item-id>` is `E##`, `E##_S##` or `E##_S##_T##` and must be the first argument. The board directory comes from
  `scripts/resolve-root.sh get epics|stories|tasks`, never a hardcoded `project/` path, so `JENGA_PROJECT_ROOT`
  redirects the script to another board (a scratch copy, for example). The target is the unique `<id>_*.md` file.
- `--system` and `--kind` are both required for a link, and `--key` or `--url` takes the value (`--key` for Jira
  only, `--url` for the other two).
- `--decline` records that the user was offered the link prompt and skipped it (see "Decline mode"). It takes none of
  `--system`, `--kind`, `--key`, `--url`.
- There is no option that takes a credential, and a rejected value is never echoed back: messages name the expected
  shape only.

### Accepted shapes

Anything not in this table is rejected with exit `2`, the message names the expected shape, and nothing is written.

| System | Kind | Option | Accepted shape | Valid example | Invalid example (and why) |
|---|---|---|---|---|---|
| `jira` | `issue` | `--key` | `[A-Z][A-Z0-9]+-[0-9]+` | `PROJ-123` | `proj-123` (lower case), `PROJ123` (no dash), `P-1` (project part needs two characters) |
| `confluence` | `page` | `--url` | `https://<site>.atlassian.net/wiki/spaces/<SPACE>/pages/<numeric-id>[/<title>]` | `https://example.atlassian.net/wiki/spaces/ENG/pages/123456789/Link-script-design` | `https://example.atlassian.net/wiki/spaces/ENG` (a space, not a page), `https://confluence.example.com/wiki/spaces/ENG/pages/1` (not an `atlassian.net` host) |
| `bitbucket` | `repo` | `--url` | `https://bitbucket.org/<workspace>/<repo>` | `https://bitbucket.org/example-workspace/example-repo` | `https://bitbucket.org/example-workspace` (no repo), `https://bitbucket.org/example-workspace/example-repo.git` (clone suffix) |
| `bitbucket` | `pull-request` | `--url` | `https://bitbucket.org/<workspace>/<repo>/pull-requests/<number>` | `https://bitbucket.org/example-workspace/example-repo/pull-requests/42` | `https://bitbucket.org/example-workspace/example-repo/pull-requests/latest` (not a number) |

Rules that apply to every URL: `https` only; host and path only, so no port, query string, fragment, whitespace or
quote; and **no credentials**. A URL carrying a user-info part before the host is rejected before anything is read
or written, because no secret value is ever accepted. The host is lowercased and trailing slashes are stripped
before the value is compared or stored, so one page written two ways is one link.

**Atlassian Cloud hosts only in v1.** Confluence accepts `*.atlassian.net` and Bitbucket accepts `bitbucket.org`.
A Data Center, Server or other custom-host URL (for example a self-hosted Confluence or Bitbucket) is rejected
with exit `2`. This matches the Cloud-only coverage of the two descriptors (see "Transports and coverage" above).

### What gets written

The edit is a text-level insertion under `scripts/with-lock.sh`, not a YAML round trip, so every byte of the file
outside the `external_refs` lines is left exactly as it was (key order, comments, quoting, line endings, a missing
final newline). A file with no `external_refs` gets the field as the **last** frontmatter lines, immediately before
the closing `---`; `external_refs: []` is replaced by a block list; an existing block list is appended to. Each
entry carries `system`, `kind`, `key` or `url`, and `linked_on` (today's UTC date):

```yaml
external_refs:
  - system: jira
    kind: issue
    key: PROJ-123
    linked_on: 2026-10-06
  - system: confluence
    kind: page
    url: https://example.atlassian.net/wiki/spaces/ENG/pages/123456789/Link-script-design
    linked_on: 2026-10-06
```

After every write the script runs `scripts/validate-board.sh` on the file; if that fails, the original bytes are
restored and the script exits `5`.

### Idempotence

Linking the same system, kind and key-or-URL to the same item again changes nothing, leaves exactly one entry,
and exits `0` printing `already linked: ...`. A different reference is appended as a further entry.

### Decline mode

`link-external-ref.sh <item-id> --decline` records a skipped link prompt by adding two top-level frontmatter lines
at the end of the frontmatter:

```yaml
external_refs_declined: true
external_refs_declined_note: "Skipped 2026-10-06: user skipped the external link prompt."
```

It uses the same item resolution, the same lock (exit `4` when not acquired), the same byte-preserving edit and the
same validate-and-restore self-check, and it leaves any `external_refs` entries untouched. It is idempotent: an item
already carrying both lines changes nothing and exits `0` printing `already declined: ...`. A skip marker in any
other shape (a value other than `true`, a missing note, a note without the marker, a duplicated key) is refused
untouched with exit `6`.

### Exit codes

| Exit | Meaning |
|---|---|
| `0` | Linked, already linked, declined or already declined |
| `2` | Invalid arguments or a value of the wrong shape (also a credential-bearing URL and a non-Cloud host); nothing written |
| `3` | Unknown item id: no board file matches; nothing written |
| `4` | The lock on the board file could not be acquired; nothing written, and the lock is never bypassed |
| `5` | The written file failed `scripts/validate-board.sh`; the original is restored |
| `6` | Any other failure: unresolvable board directory, more than one file matching the id, an unrecognised `external_refs` or skip-marker form, a filesystem error |

stdout carries one line (`linked:`, `already linked:`, `declined:` or `already declined:`); stderr carries error
messages only.

### Removal is out of scope for v1

There is deliberately no option that removes a link or a skip marker, and none that edits an existing entry. A
wrong link is corrected by hand-editing the board file (and re-validating it with `scripts/validate-board.sh`);
removal support is a candidate for a later version.

### Known follow-up: the marker is not yet written automatically

The link script does not need the marker, but the prompts that call it are shown only when the gate passes, and the
gate needs the marker. Today the `j.connect` flow **cannot** write that marker automatically after a passing verify,
so `scripts/atlassian-write-marker.sh` still has to be run by hand. The cause and the proposed fix are in the
rapport `project/rapports/problems/E71_S02_T03-descriptor-cannot-write-marker.md`; it is not repeated here.

### Hand demonstration

The interface above was exercised by hand against a scratch copy of three board files (an epic, a story and a task
in a temporary directory, with `JENGA_PROJECT_ROOT` pointing at it), never the live board. The commands and their
output are in `project/documentation/summaries/E71_S04_T03-summary.md`. To repeat it, copy
`project/configs/workflow.json` and one file from each of `epics/`, `stories/` and `tasks/` into a temporary
directory laid out like `project/`, export `JENGA_PROJECT_ROOT` as that directory, and run the script.

### Reader script

`scripts/read-external-refs.sh` (added by `E79_S04_T04`) is the **read-only** counterpart of the link script. It prints
the Jira `key` of each matching `external_refs` entry of one epic, story or task, one per line in file order. It is
what the commit-ref resolution chain of epic `E79` reads, and the schema allows the developer and tester agents to
read `external_refs` (never write it).

```
read-external-refs.sh <item-id> [--system jira|confluence|bitbucket] [--kind <kind>]
```

- **Same lookup as the writer.** `<item-id>` is `E##`, `E##_S##` or `E##_S##_T##`; the board directory comes from
  `scripts/resolve-root.sh get epics|stories|tasks`, so `JENGA_PROJECT_ROOT` redirects it to a scratch board; the file
  is the unique `<dir>/<id>_*.md` or `<dir>/<id>.md`.
- **One level only, no inheritance.** It reads exactly the item it is given. A Jira key identifies one imported board
  item at any level (decision 7 of `E79`), so several tasks can share one key by inheriting it from their story or
  epic; walking task, story, epic is the resolver's job. The `Jenga-Task` id stays the trace key.
- **Frontmatter only, text-level.** It reads the lines between the first two `---` lines, never the body, so a body line
  that looks like frontmatter is ignored. It reads the block list of mappings the validator accepts, `external_refs: []`
  and an absent field. `external_refs_declined*` markers are not entries and print nothing.
- **Untrusted data.** No `eval`, no shell interpolation of a value, no network, no lock, no write. Only values matching
  `[A-Z][A-Z0-9]+-[0-9]+` are printed (checked twice). An entry with a `url` and no `key` is skipped silently; a
  malformed key is skipped with a stderr notice that never echoes the value.
- **Defaults.** `--system` defaults to `jira`; only Jira entries carry a `key`, so `confluence` and `bitbucket` print
  nothing. `--kind` adds a filter on the entry's `kind`.

| Exit | Meaning |
|---|---|
| `0` | Keys printed, or none found (printing nothing is a normal answer) |
| `2` | Usage error: missing or invalid id, unknown option, bad `--system` or `--kind` |
| `3` | The item file is missing or ambiguous, or the board directory cannot be resolved; never read as "no refs" |
| `4` | The file has no readable frontmatter (no opening or closing `---`) or repeats `external_refs:` |

On any non-zero exit stdout is empty. Tests: `tests/read-external-refs.bats`.
