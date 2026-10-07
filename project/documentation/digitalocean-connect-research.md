# DigitalOcean CLI and MCP Research (`E65_S05_T01`)

**Checked:** 2026-10-01. Input contract for `E65_S05_T02` (`skills/j-connect/descriptors/digitalocean.json`).
DigitalOcean facts are volatile; re-check before relying on any of them.

**How this was gathered.** `doctl` is **not installed on the machine this was written on**, and it was
deliberately not installed to cross-check anything: no `--version`, `--help` or other `doctl` run happened,
no DigitalOcean account was used, and no credential or `~/.config/doctl` / `config.yaml` file was read.
Every fact below therefore comes from an official page read through a **fetch-and-summarise tool**, so the
statements are that tool's extraction of the page, not a raw read of it. Each fact is marked
`verified from <URL>` or `could not verify`. Anything neither a page nor the existing repo confirmed is in
section 9.

## 1. Official docs URLs

| Purpose | URL | Official? | Checked |
|---------|-----|-----------|---------|
| doctl install and configure | https://docs.digitalocean.com/reference/doctl/how-to/install/ | yes, docs.digitalocean.com | 2026-10-01 |
| doctl `auth init` reference | https://docs.digitalocean.com/reference/doctl/reference/auth/init/ | yes | 2026-10-01 |
| doctl `account get` reference | https://docs.digitalocean.com/reference/doctl/reference/account/get/ | yes | 2026-10-01 |
| doctl `version` reference | https://docs.digitalocean.com/reference/doctl/reference/version/ | yes | 2026-10-01 |
| doctl source and README | https://github.com/digitalocean/doctl | yes, github.com/digitalocean | 2026-10-01 |
| MCP overview | https://docs.digitalocean.com/reference/mcp/ | yes | 2026-10-01 |
| Remote MCP configuration (hosted URLs, auth) | https://docs.digitalocean.com/reference/mcp/configure-mcp/ | yes (page states "Last verified 1 Oct 2026") | 2026-10-01 |
| Local MCP configuration | https://docs.digitalocean.com/reference/mcp/use-local-mcp/ | yes (page states "Last verified 18 Feb 2026") | 2026-10-01 |
| MCP server source | https://github.com/digitalocean-labs/mcp-digitalocean | repo lives in the **`digitalocean-labs` org, not the core `digitalocean` org**; DigitalOcean's own docs and blog link to it as theirs | 2026-10-01 |
| Blog: MCP server public release (2025-08-26) | https://www.digitalocean.com/blog/mcp-server-public-release | yes, digitalocean.com | 2026-10-01 |
| Blog: Remote MCP now available (2025-12-09) | https://www.digitalocean.com/blog/remote-mcp-server | yes | 2026-10-01 |

The doc tree path `.../reference/mcp/configure-local/` and `.../configure-local-mcp/` returned 404; the
local page is `.../use-local-mcp/` (link read from the remote-configuration page).

## 2. CLI install methods

Install page and README, as extracted (verified from the install page and https://github.com/digitalocean/doctl):

| Platform | Official method | Bare identifier | Fits `install.methods`? |
|----------|-----------------|-----------------|-------------------------|
| macOS | Homebrew | `doctl` | yes: `darwin` / `brew` |
| Linux | Snap (Ubuntu, needs extra permission setup per the page) | `doctl` | no (`manager` is `brew` or `npm` only). Docs fallback |
| Linux | distro packages named in the README: pacman (Arch), dnf (Fedora) | `doctl` | no. Docs fallback |
| Linux and macOS | binary archive from GitHub Releases | n/a | no. Docs fallback |
| Windows | binary archive from GitHub Releases | n/a | no (`platform` is `darwin` or `linux` only). Docs fallback |
| any | Docker Hub images (README), Nixpkgs (README, community-maintained), build from source with Go | n/a | no. Docs fallback |

- **Homebrew on Linux is not stated** by the install page (it names Homebrew for macOS only), so a
  `linux` / `brew` entry is **not** added. Linux users get the runner's docs-URL fallback.
- The package regex accepts `doctl`; it is unpinned. No version appears in the descriptor (the install page
  shows a current release number, deliberately ignored).
- This doc intentionally contains no copy-pasteable install command: the descriptor carries the bare package
  name and the official `install.docs_url`.

## 3. Authentication flow and authenticated no-op

All verified from the pages named; nothing was run.

- **`doctl auth init`** (https://docs.digitalocean.com/reference/doctl/reference/auth/init/): "initializes
  doctl with an API token"; it **prompts for the token**. Flags on that page: `--context <name>` (named
  authentication contexts; default context name is `default`; lets you hold several accounts or tokens with
  different scopes) and `--token-validation-server`. The install page's flow: create an API token in the
  control panel, then run the command with `--context <NAME>` and "pass in the token string when prompted".
- **`--access-token` / `-t`**: documented on the `auth init` page as a global flag that bypasses
  initialisation by supplying the token **on each command**. Passing a token on argv is the worst option for
  this repo (shell history, process list), so the descriptor never uses it.
- **Environment variable**: the `auth init` and install pages state none; the **README of
  https://github.com/digitalocean/doctl** states `DIGITALOCEAN_ACCESS_TOKEN` (name exactly as stated there).
  doctl reads it itself.
- **Where the token is stored**: the `auth init` page does not say. The README gives a `config.yaml` path
  per OS under the user's config directory (macOS `Application Support/doctl`, Linux `~/.config/doctl`,
  Windows `%APPDATA%\doctl`). Recorded as location only; **not inspected**, and whether the token sits in that
  file in plain text is **could not verify**.
- **Authenticated no-op**: the install page shows `doctl account get` (and `doctl auth list`) as example
  commands for checking authentication. The `account get` reference describes it as returning the account
  profile (email, team, droplet limit, status, UUID). **What it does when unauthenticated (exit status) is
  not stated** on either page: could not verify. The runner judges exit status only and discards output;
  `E65_S05_T03` proves the runner behaviour against a stub, not the real CLI.
- **`doctl version`**: the reference page says it "displays the version of the doctl software"; it does not
  say whether it needs authentication (it would be odd if it did; **could not verify**). The descriptor
  detects with `["doctl","version"]`, as the story AC states.

## 4. Auth type design (recommended; implemented by `E65_S05_T02`)

DigitalOcean is secret-bearing (an API token), unlike Supabase's browser flow, so the two designs in
`project/documentation/service-descriptor.md` are weighed honestly:

- **(a) `auth.type: env-token`**, `auth.env_var` + `secrets.env_vars` (+ `secrets.env_file`): the runner calls
  `ensure-secret-safe.sh`, appends a `NAME=` placeholder to the env file, returns `needs-user-action`. Problems:
  (1) the runner does **not** load the env file, so `doctl` only sees a token the user also exports into the
  process environment, which makes a project `.env` mostly decorative; (2) it puts a long-lived token in a file
  on disk next to the project; (3) `auth.env_var` holds a single name, but DigitalOcean uses **two different
  names**: `DIGITALOCEAN_ACCESS_TOKEN` for doctl (README) and `DIGITALOCEAN_API_TOKEN` for the local MCP server
  (local-MCP page and blog), so one design cannot serve both with one export.
- **(b) CLI credential store** (recommended): the user runs `doctl auth init` themselves and pastes the token
  at doctl's own prompt; doctl keeps it in its own store (no `secrets` block, no env file). Following the
  `github.json` / `supabase.json` precedent, the descriptor uses `auth.type: "browser"`, the runner's "print
  instructions, `needs-user-action`, re-run" path. The runner never runs `doctl auth init`, and `j.connect`
  never sees the token. The story AC allows this ("env-var name or the CLI's own credential store").
  Honesty note: `browser` is the format's name for "a human must act", not a claim that a browser opens
  (the runner message says "sign in yourself"; the instructions say what to do). The format has no
  `interactive` type; none is added.
- **Guardrail consequence:** with (b), `auth.type` is not `env-token` and there is no `secrets.env_file`, so
  **the pre-write `.gitignore` check never runs and no env file or other secret-bearing file is ever
  created**; there is nothing for it to guard. The guardrail would apply only to an env-token variant.
- **Interaction with the MCP token:** with the hosted OAuth MCP (section 5) no token is needed at all, so
  there is no second env-var name to reconcile. This is the main reason (b) is recommended.
- A project `.env` is therefore **not useful**: doctl reads its own store and the hosted MCP uses OAuth.

## 5. DigitalOcean MCP server

**An official server exists, in two forms** (verified from the MCP overview, remote and local pages above):

- **Hosted remote**: one HTTPS endpoint **per service**, 22 listed on the remote page (24 stated), e.g.
  Droplets `https://droplets.mcp.digitalocean.com/mcp`, App Platform `https://apps.mcp.digitalocean.com/mcp`,
  Kubernetes `https://doks.mcp.digitalocean.com/mcp`, Databases `https://databases.mcp.digitalocean.com/mcp`,
  Accounts, Spaces, Networking, Documentation (no token needed) and others. Auth: **OAuth recommended**
  ("add the server's URL to your client's configuration without an `Authorization` header"; "all remote MCP
  servers that require authentication support OAuth"), or an API token as `Authorization: Bearer <token>`.
  The page's example JSON omits a transport `type`; the page does not state one. The older 2025-12-09 blog
  says API-token only and mentions no OAuth; the docs page is newer and dated, so it is relied on, but the
  conflict is recorded in section 9.
- **Local stdio**: command `npx`, args `-y @digitalocean/mcp --services <list>` (services such as `apps`,
  `droplets`, `databases`), token via env var **`DIGITALOCEAN_API_TOKEN`**; needs Node 18+/npm 8+. Source repo
  is `digitalocean-labs/mcp-digitalocean` (non-core org, see section 1).

**Expressibility today** (`register-mcp.sh` and the format):
- Hosted OAuth is `http` + `url`, expressible exactly: `{"type":"http","url":"https://droplets.mcp.digitalocean.com/mcp"}`
  in `.mcp.json`. **Not expressible:** the API-token variant needing an `Authorization` header (`http`
  entries are `{type, url}` only, no headers, no env).
- Local stdio is expressible (`command`, `args`, env NAME `DIGITALOCEAN_API_TOKEN` written as
  `${DIGITALOCEAN_API_TOKEN}`), but it forces a token into the Claude Code process environment under a
  second variable name (section 4) and the `${VAR}` expansion in `.mcp.json` is itself only recorded as
  to-confirm in `project/documentation/mcp-registration-decision.md`.
- **One entry per descriptor.** `register_mcp` registers a single server, and the hosted server is one
  endpoint per service, so a single descriptor can register only one DigitalOcean service endpoint.

**Recommendation:** register the **hosted OAuth** Droplets endpoint, `name` `digitalocean-droplets`, type `http`,
no `env`, no `secrets`. Droplets is chosen because it matches the adjacent `j.publish` `droplet` target; this
is a judgment call, flagged: the user can add the other service endpoints by hand (re-running `j.connect`
merges by name and does not remove other entries). The descriptor says so in free text. Follow-up notes, not
done here: (1) support for several `register_mcp` entries (or a service picker) in the format; (2) `headers`
(`${NAME}`-referenced) in `register-mcp.sh` for token-based registration.

## 6. GitHub prerequisite: recommendation is NOT to declare `requires: ["github"]`

`doctl auth init` takes a DigitalOcean API token, and the hosted MCP uses DigitalOcean OAuth; none of the pages
read mention `gh` or a GitHub sign-in for either. `requires` is a hard stop (`needs-user-action` when `gh` is
unauthenticated), which would block users with no GitHub login for a dependency the tools do not have. The
droplet **deploy** flow needs authenticated `gh`, but that is `j.publish`'s prerequisite, not this
descriptor's. Adding `"requires": ["github"]` later is a one-line data change.

## 7. Relationship to `j.publish` droplet

Evidence (read from the files, not from DigitalOcean):
- `skills/j-publish/adapters/droplet.md` lines 4-5: "Despite the name, nothing in the flow is
  DigitalOcean-specific - it works against any Linux host reachable via SSH." Its Trust Boundary section
  (lines 25-43) lists the five secret values: SSH private key, host, user, port and known_hosts, held as
  **GitHub Actions secrets**; `publish.json` holds only their names.
- Required tools: `jq`, `git`, and `gh`, which must be authenticated (`droplet.md`, "Required environment and
  tools"). `skills/j-publish/assets/secrets-guide.md` ("Droplet" section) and `skills/j-publish/wizards/droplet.md`
  set those secrets with `gh secret set` and `ssh-keygen`/`ssh-keyscan`.
- `grep -rin "doctl\|api token\|api_token" skills/j-publish` finds no DigitalOcean API token and no `doctl`;
  the only DigitalOcean mentions are descriptive ("including DigitalOcean Droplets").

| | `j.publish` `droplet` | `j.connect` `digitalocean` |
|---|---|---|
| Credential | SSH key + known_hosts (+ host/user/port) as GitHub Actions secrets | DigitalOcean API token held by `doctl`'s own store; MCP via DigitalOcean OAuth |
| Tool | authenticated `gh`, a generated workflow | `doctl`, the hosted DigitalOcean MCP server |
| Talks to | any SSH-reachable host | the DigitalOcean API |

**The two credential sets do not overlap**, so `j.connect` duplicates none of the droplet setup and needs no
`gh`. When to use which: `j.connect digitalocean` to let the agent inspect/manage DigitalOcean resources
(including creating the Droplet itself); `j.publish` droplet to deploy code to an already-existing SSH host
(DigitalOcean or not). A user may want both for a DigitalOcean Droplet; they are independent.

**Pointer placement:** this doc is the durable home; `E65_S05_T02` adds at most a 3-6 line "See also" in
`skills/j-publish/adapters/droplet.md` pointing here. **No `j.publish` script, schema or behaviour needs to
change.** (The `droplet.md` copies under `.claude/` and `.agents/` are plain copies and are re-copied.)

## 8. Descriptor inputs (summary for `E65_S05_T02`)

- `detect`: `["doctl","version"]`. `install.docs_url`: the install page. `install.methods`: only
  `darwin` / `brew` / `doctl`.
- `auth.type`: `browser`; `auth.check.command` and `verify.command`: `["doctl","account","get"]`;
  `auth.docs_url`: the `auth init` reference; instructions tell the user to run `doctl auth init`
  themselves and enter the token at its prompt. No `secrets` block, no `requires`.
- `register_mcp`: `http`, name `digitalocean-droplets`, URL above, no env. `docs`: the install page and the
  remote MCP configuration page.

## 9. Could not verify

| Claim | Why unverified | Source |
|-------|----------------|--------|
| `doctl account get` exits non-zero when unauthenticated | needs a real run; no page states it | install page, `account get` reference |
| `doctl version` works without authentication | reference page silent | `version` reference |
| Where `doctl auth init` stores the token and whether it is plain text | `auth init` page silent; README gives only the config file location; no credential file may be read | README |
| `DIGITALOCEAN_ACCESS_TOKEN` is honoured by the current doctl | stated only in the GitHub README (summarised), not on docs.digitalocean.com pages | https://github.com/digitalocean/doctl |
| `brew` installs `doctl` on Linux | install page names Homebrew for macOS only | install page |
| Hosted MCP OAuth works end to end inside Claude Code with a bare `{type,url}` `.mcp.json` entry | needs a real account and a Claude Code session | remote MCP page |
| Hosted MCP supports OAuth at all vs token only | the 2025-12-09 blog says token only; the 2026-10-01-verified docs page says OAuth is supported and recommended; docs page relied on | blog vs remote MCP page |
| Remote MCP endpoint count (24 stated, 22 listed) and that the Droplets URL is current | page extraction | remote MCP page |
| Whether the hosted entry needs an explicit `"type": "http"` | the page's example omits a transport type | remote MCP page |
| The local MCP server and doctl both need Node/other prerequisites beyond those listed | not stated | local MCP page |
| That `digitalocean-labs` is a supported, non-experimental org | the repo org is non-core; DigitalOcean docs and blog call the server theirs; a summarising tool labelled it "experimental" but that was its inference, not page text | repo README, docs, blog |
| `.mcp.json` `${VAR}` expansion | recorded as to-confirm in `project/documentation/mcp-registration-decision.md` | that doc |
| Page contents verbatim | read through a summarising fetch tool, not a raw read | all fetched pages |
| An end-to-end run against a real DigitalOcean account | no account used, `doctl` not installed locally | n/a |
