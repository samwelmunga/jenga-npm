# Supabase CLI and MCP Research (`E65_S04_T01`)

**Checked:** 2026-10-01. Input contract for `E65_S04_T02` (`skills/j-connect/descriptors/supabase.json`).
Supabase facts are volatile; re-check before relying on any of them.

**How this was gathered.** Official pages were read through a fetch-and-summarise tool, so the
statements below are that tool's extraction of the page, not a raw read of it. Local claims come from
read-only `supabase --version` / `--help` runs (no login, no network call, no credential or
`~/.supabase` file was touched). Anything neither source confirmed is in "Could not verify".

## 1. Official docs URLs

| Purpose | URL | Official? |
|---------|-----|-----------|
| CLI install and getting started | https://supabase.com/docs/guides/local-development/cli/getting-started | yes, supabase.com |
| CLI source, README install list | https://github.com/supabase/cli | yes, github.com/supabase |
| CLI `supabase login` reference | https://supabase.com/docs/reference/cli/supabase-login | yes, supabase.com |
| MCP server guide (hosted URL, auth) | https://supabase.com/docs/guides/getting-started/mcp | yes, supabase.com |
| MCP server source | https://github.com/supabase-community/supabase-mcp | `supabase-community` org, linked from Supabase; not the `supabase` org itself |

Local CLI observed: `supabase --version` printed `2.109.1`; `supabase login --help` describes
"Authenticate using an access token" with flags `--token`, `--name`, `--no-browser`.

## 2. CLI install methods

Per the getting-started page and the CLI README, as extracted:

| Platform | Official method | Bare identifier | Fits `install.methods`? |
|----------|-----------------|-----------------|-------------------------|
| macOS | Homebrew, Supabase tap | `supabase/tap/supabase` (README also lists an official core formula `supabase`, noted as possibly lagging) | yes: `darwin` / `brew` |
| Linux | Homebrew (same tap formula); `.apk` `.deb` `.rpm` and `.pkg.tar.zst` from GitHub Releases | `supabase/tap/supabase` | brew: yes, `linux` / `brew`. Distro packages: no (not a supported manager), fall back to `install.docs_url` |
| Windows | Scoop | `supabase` | no (`platform` is `darwin` or `linux` only), docs fallback |
| any | npm, as a project dev dependency | `supabase` | **not used.** The runner's npm method runs a global install; the docs present npm only as a per-project dev dependency and do not document a global install, so it is omitted. Docs fallback. |
| any | an install script in the README | n/a | not expressible (and the format forbids hardcoded commands); docs fallback |

The package regex `^@?[A-Za-z0-9._/-]+$` accepts `supabase/tap/supabase` (slashes allowed), and it is
unpinned. No version appears in the descriptor. Beta-channel packages exist and are deliberately ignored.
This doc intentionally contains no copy-pasteable install command: the descriptor carries the package
name and the official `install.docs_url` (the getting-started page).

## 3. Login flow and authenticated no-op

- `supabase login` authenticates with a personal access token. Without `--token` it runs an automatic
  login flow (browser); `--no-browser` suppresses opening the browser (flag seen in local `--help`).
- Token storage per the login reference: native credential storage, falling back to a plain-text file
  under the user's home directory. Not inspected.
- Setting the `SUPABASE_ACCESS_TOKEN` environment variable lets CI skip the interactive login (login
  reference). The CLI reads it itself; `j.connect` does not need to.
- The exact text/URL/code the browser flow prints is **unverified** (login was not run). The descriptor's
  instructions therefore say "open the URL or code that `supabase login` prints" without naming either.
- Authenticated no-op: `supabase projects list` (local `--help`: "List all Supabase projects the
  logged-in user can access"). It needs credentials, so its **exit status when logged out was not
  verified**; non-zero is expected but unconfirmed. The runner judges exit status only and discards output.
  `E65_S04_T03` proves the runner behaviour against a stub, not the real CLI.

## 4. GitHub prerequisite: recommendation is NOT to declare `requires: ["github"]`

- Official CLI docs describe a personal access token created in the Supabase dashboard; `supabase login`
  does not use `gh`, and the pages read mention no GitHub sign-in step. Dashboard "Continue with GitHub"
  sign-in appears to exist (a community issue title references it) but is **not confirmed by an
  official page** read here.
- `requires` is a hard stop: an unauthenticated `gh` ends the run with `needs-user-action` before
  Supabase detect/install/auth run. That would block anyone who signs in with email or another provider,
  for a dependency the CLI does not have. Trade-off accepted: users who sign in with GitHub in the
  browser are not helped by `gh` anyway.
- If a future finding shows login needs GitHub, adding `"requires": ["github"]` is a one-line data change.

## 5. MCP server shape

- Official hosted URL: `https://mcp.supabase.com/mcp`. Auth by default is browser OAuth with dynamic
  client registration; per the guide a personal access token is **not** needed for normal setup.
- Optional query parameters documented: `?project_ref=<id>` (scope to one project) and `?read_only=true`.
  The descriptor registers the bare URL (it cannot know the user's project); users may append them.
- Manual (CI) auth: an `Authorization` bearer header built from the `SUPABASE_ACCESS_TOKEN` env var.
- A stdio npm package `@supabase/mcp-server-supabase` exists (named in the MCP source repo). Its run
  command, args and token env-var were **not** found in the pages read, so the stdio shape is unverified
  and not used. The hosted URL is the documented primary path.

**Expressibility today.** The hosted OAuth shape is `http` + `url`, which `register-mcp.sh` and the
descriptor format express exactly: `{"type":"http","url":"https://mcp.supabase.com/mcp"}` in `.mcp.json`
under server name `supabase`. **Not expressible:** the CI variant needing an `Authorization` header (the
`http` entry written is `{type, url}` only: no `headers`, no `env`; `register_mcp.env` is ignored for
`http`). No format or script extension is made in this story. Follow-up note: add `headers`
(`${NAME}`-referenced) support to `register-mcp.sh` and the format if token-based registration is
wanted. A second consequence: re-running `j.connect` rewrites a hand-edited `supabase` entry back to the
bare URL (reported as `updated`), so appended query parameters are not preserved.

## 6. Auth type design (recommended; implemented by `E65_S04_T02`)

- `auth.type: "browser"`, `auth.check.command` = `["supabase","projects","list"]`, `auth.docs_url` = the
  login reference, `auth.instructions` = run `supabase login` yourself (use `--no-browser` on a headless
  machine), open what it prints, tell me when done. The runner never runs `supabase login`.
- No `secrets` block at all: the hosted OAuth MCP needs no token, so there is no env-var name to list in
  `secrets.env_vars` / `register_mcp.env`, and no env file.
- **Guardrail consequence:** the runner calls `ensure-secret-safe.sh` only for `env-token` auth with
  `secrets.env_file`. With `browser` auth and no `secrets.env_file`, no env file is ever created, so the
  pre-write `.gitignore` check has nothing to guard and does not run. `.mcp.json` holds only a URL. The
  guardrail would apply only to a future token-based variant (see follow-up above).
- The MCP's own OAuth consent happens later, inside Claude Code (approve the pending `.mcp.json`
  server, then authenticate it); it is separate from the CLI login and is mentioned in the instructions.

## 7. Could not verify

| Claim | Why unverified | Source |
|-------|----------------|--------|
| `supabase projects list` exits non-zero when logged out | needs credentials/network; not run | local `--help` only |
| Exact URL/code printed by `supabase login`, and that it completes without `--no-browser` interaction | login not run | login reference (describes a browser flow) |
| Token storage location details | no credential file may be read | login reference |
| Dashboard supports GitHub sign-in | only an unofficial issue title seen | community GitHub issue (not an official page) |
| Global npm install of the CLI is unsupported | docs only show a dev-dependency install; no statement either way was found | getting-started page, CLI README |
| stdio package run command and token env-var | pages read do not give them | MCP source repo (package named, no run shape) |
| MCP OAuth consent actually loads the server in Claude Code | needs a real account and session | MCP guide |
| Page contents verbatim | read through a summarising fetch tool, not a raw read | all fetched pages |
