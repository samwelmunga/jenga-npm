# Figma and Expo Connect Research (`E65_S06_T01`)

**Checked:** 2026-10-02. Input contract for `E65_S06_T02` (`skills/j-connect/descriptors/figma.json`) and
`E65_S06_T03` (`skills/j-connect/descriptors/expo.json`). Figma and Expo facts are volatile; re-check before
relying on any of them.

**How this was gathered.** Neither a Figma tool nor `eas` / `expo` is installed on the machine this was written
on (`which figma eas expo` found nothing), and nothing was installed to cross-check anything: no `figma`, `eas`
or `expo` command was run, no real Figma or Expo account was used, and no token, credential or `~/.claude.json`
file was read or edited. Every vendor fact below comes from an official page read through a **fetch-and-summarise
tool** (WebFetch), so each statement is that tool's extraction of the page, not a raw read of it. Each fact is
marked `verified from <URL>` or `could not verify`. The Claude Code facts in section A3 come from the official
Claude Code docs and from read-only `claude mcp` probes (section A3.2). Anything neither a page nor a probe nor a
repo file confirmed is in the final "Could not verify" section.

---

# Part A: Figma

## A1. Official docs URLs

| Purpose | URL | Official? | Checked |
|---------|-----|-----------|---------|
| Remote MCP server setup | https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/ | yes, developers.figma.com | 2026-10-02 |
| Desktop (local) MCP server setup | https://developers.figma.com/docs/figma-mcp-server/local-server-installation/ | yes | 2026-10-02 |
| Claude Code and Figma: set up the MCP server | https://help.figma.com/hc/en-us/articles/39888612464151-Claude-Code-and-Figma-Set-up-the-MCP-server | yes, help.figma.com | 2026-10-02 |
| Guide to the Figma MCP server | https://help.figma.com/hc/en-us/articles/32132100833559-Guide-to-the-Figma-MCP-server | yes | 2026-10-02 |
| Claude Code MCP docs (scopes, claude.ai connectors, plugin naming) | https://code.claude.com/docs/en/mcp | yes, Anthropic-owned | 2026-10-02 |

None of the Figma pages states a last-updated date (verified: "not stated" on each); the dates above are the
dates this research read them.

## A2. What Figma offers

- **Hosted remote MCP server (recommended).** URL `https://mcp.figma.com/mcp`, transport HTTP, authentication by
  OAuth: the user clicks "Allow access" on a Figma page opened by the client. Available "on all seats and plans".
  Verified from the remote setup page, the Claude Code help page and the Guide page.
- **Desktop (local) MCP server.** URL `http://127.0.0.1:3845/mcp`, HTTP; needs the Figma desktop app running with the
  desktop MCP server enabled in Dev Mode and an open Design file; "available on a Dev or Full seat for all paid
  plans". The page states no authentication for it. Figma "recommends the remote MCP server instead". Verified
  from the desktop setup page and the Guide page. The Claude Code help page's manual command names it
  `figma-desktop`.
- **Claude Code ways to connect** (verified from the remote setup page and the Claude Code help page): the preferred
  route is the Figma **plugin** from the `claude-plugins-official` marketplace (it bundles MCP settings plus agent
  skills; the server is named `figma`; authenticate by selecting it under `/plugin`'s Installed tab and clicking
  "Allow access"); the manual alternative is a `claude mcp add --transport http` command naming `figma` and the
  URL above. No install string is copied into the descriptor.
- **Figma CLI to install and authenticate: none.** The remote setup page and the Guide page do not mention one
  (verified "not mentioned"). The only prerequisite stated is Claude Code itself (Claude Code help page).
- **Secrets: none involved.** Auth is in-client OAuth. No token, header or env-var name is stated on any page read.
  Whether Figma offers a token-based variant for the MCP server is **could not verify** (pages are silent), so none
  is modelled. Consequently the recommended descriptor needs no `secrets` block and the pre-write `.gitignore`
  guardrail never fires (nothing secret-bearing is ever written). The format could not express a header-based token
  anyway: `http` registrations have no headers and no env (see `project/documentation/digitalocean-connect-research.md` section 5).

## A3. Already-connected detection (story AC, first criterion)

### A3.1 From the official Claude Code docs (verified from https://code.claude.com/docs/en/mcp)

- Connectors added in claude.ai are "automatically available in Claude Code" when logged in with a claude.ai
  account and appear in `/mcp` with a claude.ai indicator, named like `claude.ai Slack` / `claude.ai Claude Docs`.
  `ENABLE_CLAUDEAI_MCP_SERVERS=false` (or `disableClaudeAiConnectors: true`) disables them.
- Scopes: local (`~/.claude.json` under the project's path, default), project (`.mcp.json`), user (`~/.claude.json`).
- A plugin's MCP server registers under `plugin:<plugin-name>:<server-name>`.
- `claude mcp list` shows a status per server; `claude mcp get <name>` shows details for one server. The page does
  **not** state the exit status for an unknown name, and does not explicitly state that `list`/`get` include claude.ai
  connectors (it says they appear in `/mcp`). Those two points were settled by the probes below.

### A3.2 Read-only probes (observed 2026-10-02, `claude` 2.1.236)

Run with the working directory inside **one fresh `mktemp -d` throwaway git repo** (never the project repo); only
`claude mcp get <name>` and `claude mcp list` were used, never `add|remove|reset`, never a `--scope` write, and
`~/.claude.json` was never read or edited. The temp directory was deleted afterwards. The only file created in it
by hand was a `.mcp.json` containing a `figma` http entry (written with a shell redirect, not via `claude`) to
observe project-scope behaviour. I did **not** snapshot `~/.claude.json` before or after, so I cannot affirm
that `claude` left it untouched; I only did nothing that was meant to touch it.

| Probe | Observed |
|-------|----------|
| `claude mcp get "claude.ai Figma"` | exit **0**; prints `claude.ai Figma:`, `Scope: claude.ai config`, `Status: ✔ Connected` |
| `claude mcp get figma` (no entry) | exit **1**; `No MCP server named "figma". Configured servers: claude.ai Claude Docs, claude.ai Figma, ...` |
| `claude mcp get no-such-server-xyz` | exit **1**, same message |
| `claude mcp get figma` after the temp `.mcp.json` held a `figma` entry | exit **0**; `Scope: Project config (shared via .mcp.json)`, `Status: ⏸ Pending approval (run claude to approve)` |
| `claude mcp list` | exit 0; prints `Checking MCP server health…` first, took about 2 s, so **it performs live health checks**; lists `claude.ai Figma: https://mcp.figma.com/mcp - ✔ Connected` and, with the temp file, `figma: ... (HTTP) - ⏸ Pending approval` |

Findings from the probes:

1. The claude.ai connector is found by `claude mcp get` under the exact name string **`claude.ai Figma`** (contains a
   space; an argv array handles that as one element). Unknown name exits **1**.
2. **Exit status means "configured", not "connected" or "authorised".** A project entry that is pending approval
   also exits 0, and the status text is only on stdout, which the runner discards. A probe by exit status cannot tell
   "connected" from "present but not yet approved/authenticated". (I did not observe a "Needs authentication" case,
   so what `get` exits with then is could not verify.)
3. `claude mcp get` takes **one exact name**, so one `detect.command` argv covers one name only.

### A3.3 Which already-connected cases an argv exit-status `detect.command` can see

| Case | Detectable by `["claude","mcp","get","claude.ai Figma"]`? | Basis |
|------|----------------------------------------------------------|-------|
| (i) claude.ai connector | **yes**, exit 0 | probe, name `claude.ai Figma` |
| (ii) project `.mcp.json` entry | **only if its name is exactly `claude.ai Figma`**, which a hand-written entry will not be (docs/help pages use `figma`, `figma-desktop`); a probe for `figma` would see it (exit 0, probe) | probe: `get figma` exit 0 with entry |
| (iii) user/local-scope entry or Figma plugin | **no** for a single fixed name: a user/local entry may carry any name, and the plugin's server registers under `plugin:<plugin>:<server>` (docs); the exact plugin-server string for Figma is **could not verify** (plugin not installed here) | docs, no probe |

The format has one `detect.command` argv judged by exit status (`project/documentation/service-descriptor.md`), no OR across names,
and a shell string would break the argv-only rule (design rule 3), so **one** case is covered. Unseen cases degrade
safely under the recommended design: the run reports "absent", prints the docs URL, and registers nothing (A4).

## A4. Mapping onto the runner (read from `skills/j-connect/scripts/run-descriptor.sh`)

Confirmed by reading the script:

- **(a) Confirmed: `register_mcp` is not gated on `detect`.** The step runs when `.register_mcp.supported == "true"`
  and `STOP` is 0 (script `register_mcp` block); `present` is not consulted. A registering Figma descriptor would
  write a `.mcp.json` entry even when the connector is present, i.e. the duplicate the story forbids.
- **(b) Confirmed: `register-mcp.sh` is project-`.mcp.json`-only** (`rargv` passes `--project-root`; it merges by name
  in that file). It cannot see a claude.ai connector, a user/local scope entry, or a plugin server.
- **(c) Confirmed: absent detect stops the run at `install`.** With no usable `install.methods` the install step
  returns `needs-user-action` with the docs URL, `STOP=1`, and `auth`/`register_mcp`/`verify` never run (without
  `--continue`).

Step walk for a no-CLI, OAuth-only service:

| Step | What it means for Figma | Expressible? |
|------|-------------------------|--------------|
| `detect` | "Is a Figma MCP server already connected?" via the `claude mcp get` probe | yes, one name (A3.3) |
| `install` | Nothing to install. Present: `skipped` ("already installed"). Absent: `needs-user-action` + docs URL (no `methods`) | yes; the wording says "install it yourself", which fits imperfectly: the `install.hint` carries the real meaning (add Figma's server from the official page) |
| `auth` | OAuth happens inside Claude Code, not via a CLI login. `auth.type: none` makes the runner report `skipped` ("service needs no authentication"); `browser` needs a `check.command`, and reusing the connection probe would report "already authenticated" for a merely configured server | `none` is the honest fit; OAuth is described in free text |
| `register_mcp` | Registering is unsafe (a), (b) | `{"supported": false}` |
| `verify` | Re-run the same probe independently | yes, same family as `detect`; exit status means "configured" only (A3.2 finding 2) |

**Recommended design (exactly one): (A) "detect and report".**

- `detect.command` and `verify.command`: `["claude","mcp","get","claude.ai Figma"]`.
- `install.docs_url`: the remote setup page; no `methods`; `install.hint` says Figma's MCP server needs no CLI here
  and, when none is connected, to add it from the official page (the plugin or the manual command) yourself, that an
  entry under another name or scope is not seen by this probe (then nothing more is needed), and that the probe is
  unverified against a plugin install.
- `auth.type: "none"` with `auth.instructions` free text explaining that the OAuth "Allow access" step happens in
  Claude Code (`/mcp` or `/plugin`), and that exit 0 means configured, not authorised.
- `register_mcp: {"supported": false}`, reason in free text: registering could duplicate an existing Figma connection
  and the runner cannot see claude.ai/user-scope/plugin entries.
- No `secrets`, no `requires`.

**Design (B), a registering descriptor, cannot be made duplicate-safe in the existing format** (it would need a
conditional on `detect`, and visibility of connectors/user scope, neither of which exists), so it is rejected and
recorded as a finding.

## A5. Follow-up notes (Figma; none implemented here)

See the "Follow-up notes" list at the end. Candidate home: the deferred `E65_S08` (no task breakdown).

---

# Part B: Expo

## B1. Official docs URLs

| Purpose | URL | Official? | Checked |
|---------|-----|-----------|---------|
| EAS CLI reference (install, login, whoami) | https://docs.expo.dev/eas/cli/ | yes, docs.expo.dev | 2026-10-02 |
| Create your first build (EAS CLI install step, `eas login`, `eas whoami`) | https://docs.expo.dev/build/setup/ | yes | 2026-10-02 |
| Programmatic access (access tokens) | https://docs.expo.dev/accounts/programmatic-access/ | yes | 2026-10-02 |
| Expo CLI | https://docs.expo.dev/more/expo-cli/ | yes | 2026-10-02 |
| Expo MCP server | https://docs.expo.dev/mcp/ | yes (page dated "September 03, 2026") | 2026-10-02 |
| Claude Code and Expo | https://docs.expo.dev/agents/claude/ | yes | 2026-10-02 |
| Source repo | https://github.com/expo/eas-cli | yes (`expo` org); the fetched GitHub page showed only the file tree, so **nothing was verified from it** | 2026-10-02 |

## B2. Which CLI to connect

- **`expo`** is "included in the `expo` package" and invoked as `npx expo`, a project-local dependency run through
  the package runner (verified from https://docs.expo.dev/more/expo-cli/). It also offers `register`, `login`,
  `whoami`, `logout`, and that page says its credentials are "shared across Expo CLI and EAS CLI". It cannot be
  detected or installed without a project, so it does not fit a user-level "connect Expo" flow.
- **EAS CLI** (`eas`) is "the command-line app that you will use to interact with EAS services from your terminal"
  (verified from https://docs.expo.dev/build/setup/), installed globally. **Recommendation: the descriptor connects
  EAS CLI** (the Expo account CLI): `detect`/`verify` target `eas`.
- **Install methods** (verified from https://docs.expo.dev/eas/cli/ and https://docs.expo.dev/build/setup/): global
  install via npm, yarn, pnpm or bun, all with the package identifier **`eas-cli`**; a no-install alternative runs it
  through each package runner at `@latest`.

| Platform | Official method | Bare identifier | Fits `install.methods`? |
|----------|-----------------|-----------------|-------------------------|
| macOS, Linux | npm global | `eas-cli` | yes: `darwin` / `npm` and `linux` / `npm` (the runner also needs `npm` on `PATH`) |
| any | yarn / pnpm / bun global | `eas-cli` | no (`manager` is `brew` or `npm` only). Docs fallback |
| any | package-runner `@latest` (no install) | n/a | no. Docs fallback (and `@latest` is a pin-style suffix) |
| Windows | npm global | `eas-cli` | no (`platform` is `darwin` or `linux` only). Docs fallback |
| any | Homebrew | not stated by any page read | no entry added |

No copy-pasteable install command appears here and no version is pinned (the pages show a current CLI version
number, deliberately ignored). **Node prerequisite: could not verify** (the CLI reference and the build setup pages
both say "not stated").

## B3. Authentication

- **Login:** `eas login` (alias of `eas account:login`); `-b, --[no-]browser` logs in "with your browser (default;
  use `--no-browser` for CLI-based login)", `-s, --sso` logs in with SSO (verified from https://docs.expo.dev/eas/cli/).
  So it is a browser flow by default with a CLI-prompt variant; whether it prompts interactively in that variant is
  could not verify beyond the flag description.
- **Non-interactive credential:** `EXPO_TOKEN` is the access-token variable (verified from
  https://docs.expo.dev/accounts/programmatic-access/, which says tokens are created under the dashboard's Access
  tokens page). The EAS CLI reference page states **no** environment variable (verified "not stated"), so that EAS
  CLI itself honours `EXPO_TOKEN` is stated only on the programmatic-access page. It is a secret-bearing name;
  no value was seen or handled.
- **Credential storage:** the EAS CLI reference states no location (verified "not stated"). Not inspected.
- **Authenticated no-op:** `eas whoami` (alias of `eas account:view`, "Show the username you are logged in as"; the
  build setup page: "You can check whether you are logged in by running `eas whoami`"). **Exit status when logged out:
  could not verify** (pages silent; only a real run would show it).
- **Version command:** neither the EAS CLI reference page nor the build setup page states a version command
  (verified "not stated"). A web-search summary asserted `eas --version`, but it was not on a page that was
  fetched, so it is **could not verify**; it is nevertheless the only plausible detect probe. A wrong guess fails
  safe: detect reports "absent", the runner prints the install docs URL, and `--allow-install` would reinstall.
  This caveat goes into the descriptor's free text.

**Recommendation (exactly one): `auth.type: "browser"`.** The user runs `eas login` themselves; the CLI keeps the
token in its own store; there is no `secrets` block and no env file; `auth.check.command` is `["eas","whoami"]`.
Effect on the pre-write `.gitignore` guardrail: `auth.type` is not `env-token` and no `secrets.env_file` exists,
so **the guardrail never runs and no secret-bearing file is ever created** (same as `supabase.json` /
`digitalocean.json`). The `env-token` alternative (`auth.env_var` `EXPO_TOKEN`, `secrets.env_vars`) was weighed and
rejected: the runner does not load an env file, so a project placeholder is decorative; a long-lived token in a
file adds exposure; and the browser flow is the documented default. `EXPO_TOKEN` stays out of the descriptor.

## B4. Expo MCP server

**An official one exists** (verified from https://docs.expo.dev/mcp/): "Expo MCP Server" is a remote server hosted
by Expo at `https://mcp.expo.dev/mcp`, transport "Streamable HTTP", authentication **OAuth**, added to Claude Code
with an HTTP-transport `claude mcp add` command naming `expo` and that URL (the page gives the exact string; not copied here) and then `/mcp` to authenticate. Conditions:
the `search_documentation` tool "requires an EAS paid plan" (other features' requirements not stated); local
capabilities (simulator/DevTools) need the `expo-mcp` package in the project and the dev server started with
`EXPO_UNSTABLE_MCP_SERVER=1` (a per-project step). The page's capability table includes EAS build triggering,
workflows, TestFlight data and App Store interactions. Authorisation scopes: not stated. Whether the hosted server
needs the CLI installed or logged in: not stated. `https://docs.expo.dev/agents/claude/` recommends the Expo
**plugin** (installs Expo skills and "registers the Expo MCP Server"), which the MCP page says already registers
the server.

**Expressibility today:** hosted OAuth is `http` + `url` only, exactly expressible
(`{"type":"http","url":"https://mcp.expo.dev/mcp"}`); no header/env is needed. The per-project local server is not
expressible.

**Recommendation: `register_mcp: {"supported": false}`**, reasons in free text (`install.hint` /
`auth.instructions`), as a judgment call:
1. Same duplicate problem as Figma: the Expo plugin already registers this server, and `register-mcp.sh` only sees
   the project `.mcp.json`, so a registered `expo` entry could duplicate a plugin-provided one, with no way to skip
   on detect.
2. The server's tools reach EAS builds, TestFlight and App Store data, which the story and epic keep with
   `j.publish`; leaving registration to the user (one documented command or the plugin) keeps `j.connect` from
   quietly wiring that surface.
Flipping to the `http` registration later is a one-line data change once conditional registration exists.

## B5. Relationship to `j.publish` `mobile-ios`

Evidence (read from the files in this repo):

- `skills/j-publish/adapters/mobile-ios.md` lines 1-3: the adapter "drives the `/publish deploy` flow for iOS App
  Store targets" and delegates to `skills/j-publish/scripts/ios_pipeline.sh`. Lines 37-41: required env vars
  `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_PRIVATE_KEY_PATH`,
  `CODE_SIGN_IDENTITY`, `PROVISIONING_PROFILE_UUID`. Lines 59-65: phases `validate`, `build`, `sign`, `export`,
  `upload`; "external publish-side commands are restricted to direct `xcodebuild` and `xcrun` invocations".
- `skills/j-publish/scripts/ios_pipeline.sh`: builds `xcodebuild archive` (line 325), `xcodebuild -exportArchive`
  (line 367), `xcrun notarytool` / `altool` upload (lines 395-407); reads signing identity and provisioning UUID via
  env references (lines 303-304).
- `grep -rniE "\bexpo\b|eas-cli|\beas\b|react[- ]native" skills/j-publish` finds **nothing**: `j.publish` has no
  Expo/EAS target.
- `project/board/epics/E65_*.md` "Out of scope / Handoff" (lines 52-58): App Store Connect and Play Console "are
  explicitly OUT of this epic ... handed off to `j.publish` (its `mobile-ios` target)".

| Concern | `j.connect` `expo` descriptor | `j.publish` `mobile-ios` |
|---------|-------------------------------|--------------------------|
| Install and authenticate the Expo/EAS account CLI (`eas`) | **owns** | no |
| Register Expo's MCP server | does **not** (`supported: false`, free-text pointer to the official page) | no |
| EAS Build, EAS Submit | **never runs** | no (it does not use EAS at all) |
| Signing credentials (cert, provisioning profile) | **never** manages | owns, as env references |
| App Store Connect / Play Console credentials | **never** manages | owns (App Store Connect); Play Console has no adapter |
| Creating a publish target, reading/writing `publish.json` | **never** | owns |
| Native Xcode pipeline `validate -> build -> sign -> export -> upload` | not involved | owns |

**Plainly:** `j.publish` has no Expo/EAS target, so an Expo user's EAS-based build and store-submission flow is
currently served by **neither** skill. That is not fixed here. **Durable pointer:** this doc plus the Expo
descriptor's free-text hint; **no edit to any `j.publish` file** is needed (nothing in the research shows a
concrete need).

---

# Descriptor inputs (summary for T02 and T03)

**`figma.json`:** `id` `figma`; `docs` the remote setup page and the Claude Code help page; `detect` and `verify`
`["claude","mcp","get","claude.ai Figma"]`; `install.docs_url` the remote setup page, no `methods`; `auth.type`
`none` + free text; `register_mcp` `{"supported": false}`; no `secrets`, no `requires`.

**`expo.json`:** `id` `expo`; `docs` `https://docs.expo.dev/eas/cli/` and `https://docs.expo.dev/mcp/`; `detect`
`["eas","--version"]` (flag could not verify); `install.docs_url` `https://docs.expo.dev/eas/cli/`, `methods`
`darwin`/`npm`/`eas-cli` and `linux`/`npm`/`eas-cli`; `auth.type` `browser`, `auth.docs_url`
`https://docs.expo.dev/eas/cli/`, instructions name `eas login` (with `--no-browser` for headless), `auth.check`
and `verify` `["eas","whoami"]`; `register_mcp` `{"supported": false}`; no `secrets`, no `requires`; free text states
the EAS/store boundary and points at `j.publish` `mobile-ios`.

---

# Follow-up notes (found limits; none implemented, nothing in the format, scripts or `SKILL.md` was changed)

Candidate home: the deferred `E65_S08` (no task breakdown yet). For the scrum-master to place.

1. **Conditional registration:** `register_mcp` is not gated on `detect`; a descriptor cannot say "register only if
   no matching server exists". This forces both Figma and Expo (plugin overlap) to `{"supported": false}`. Decided in e65-s08-decisions.md: won't fix.
2. **Visibility beyond project `.mcp.json`:** neither `register-mcp.sh` nor a single `detect.command` can see
   claude.ai connectors, user/local scope entries or plugin servers (`plugin:<plugin>:<server>`) under arbitrary names. Decided in e65-s08-decisions.md: won't fix.
3. **Multi-name detect:** `detect.command` accepts one argv, so one exact server name; an any-of-names probe would
   need a format change. Decided in e65-s08-decisions.md: won't fix.
4. **No-CLI services:** the `install` step's message ("install it yourself") and `auth`'s "already authenticated"
   wording fit services with no CLI poorly; a `kind: mcp-only` notion could say "add the server" instead. Decided in e65-s08-decisions.md: deferred (wording only; the `kind: mcp-only` field is won't fix).
5. **Exit status cannot express "connected":** `claude mcp get` exits 0 for a pending-approval entry; the status text
   is stdout, which the runner discards. Decided in e65-s08-decisions.md: won't fix.
6. **No `j.publish` Expo/EAS target:** EAS Build/Submit has no skill home (not an E65 concern; candidate for a
   `j.publish` epic). Decided in e65-s08-decisions.md: idea (recorded in project/ideas.md, not built).

---

# Could not verify

| Claim | Why unverified | Source |
|-------|----------------|--------|
| `eas --version` is the documented version command | neither fetched EAS page states a version command; only a web-search summary mentioned it | docs.expo.dev/eas/cli, docs.expo.dev/build/setup |
| `eas whoami` exits non-zero when logged out | pages silent; needs a real run | EAS CLI reference, build setup |
| Where `eas login` stores credentials | EAS CLI reference "not stated"; nothing inspected | EAS CLI reference |
| EAS CLI honours `EXPO_TOKEN` | stated only on the programmatic-access page; EAS CLI page silent | programmatic-access page |
| Node.js (or other) prerequisite for EAS CLI | both EAS pages "not stated" | EAS CLI reference, build setup |
| Homebrew install of `eas-cli` | no page read states it | n/a |
| Contents of https://github.com/expo/eas-cli | fetch returned only the file tree | GitHub page |
| Whether the Expo MCP server needs EAS CLI installed/logged in; its authorisation scopes; requirements beyond `search_documentation` needing a paid plan | page "not stated" | docs.expo.dev/mcp |
| Expo MCP OAuth end to end in Claude Code | needs a real account and session | docs.expo.dev/mcp |
| Whether Figma has a token-based MCP auth variant | pages silent | Figma MCP pages |
| Last-updated dates of the Figma pages | "not stated" on each | Figma pages |
| `claude mcp get` exit status for a server needing authentication | not observed (no such server in the probe environment) | probes |
| `claude mcp get` result for the Figma **plugin** server and its exact registered name | plugin not installed; only the docs naming pattern `plugin:<plugin>:<server>` is known | Claude Code MCP docs |
| Whether `claude mcp get` performs a live network check | `list` printed "Checking MCP server health…" and `get` printed a status, but I did not establish it for `get` | probes |
| That the `claude` probes left `~/.claude.json` untouched | not snapshotted before/after | n/a |
| Probe results hold for other users | observed once in one environment (claude 2.1.236, with the maintainer's claude.ai connectors) | probes |
| Page contents verbatim | read through a summarising fetch tool | all fetched pages |
| An end-to-end run against a real Figma or Expo account | no account used; no Figma/Expo/EAS tooling present or installed | n/a |
