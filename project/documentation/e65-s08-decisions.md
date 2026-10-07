# E65_S08 decisions

Maintainer-internal record of the decide-then-act items deferred out of `E65_S07` and collected under
`E65_S08`. Each item below is decided exactly once, by the task named in its heading, and is either
implemented or explicitly recorded as `won't fix` with a reason. Later tasks append their own sections.

## Policy

- Implement only where it fixes a demonstrated defect or removes a real limitation with a small, safe
  change. Otherwise document the limit and leave it.
- Format extensions keep environment-variable NAMES only (`${NAME}`). No secret value is ever accepted,
  written, printed or logged.
- The descriptor validator, the runner and [service-descriptor.md](service-descriptor.md) change together,
  with tests, or not at all.
- No version-pinned or authoritative install command is ever introduced.
- Out of scope for E65 throughout: App Store Connect and Play Console.

Each section has the fields `Decision` (`implemented` | `won't fix` | `deferred to a new story`),
`Reasoning`, `Evidence` and, for anything not implemented, `If this is ever built`.

## AC1: Re-registration preserves hand edits (E65_S08_T01)

**Decision:** implemented.

**Reasoning:** This was a demonstrated defect, not a hypothetical limit. `register-mcp.sh` compared the
existing `.mcp.json` entry with the descriptor's entry by exact equality and replaced anything different
wholesale (`.mcpServers[$n] = $e`). A deliberate hand edit such as `https://mcp.supabase.com/mcp?read_only=true`
was therefore reset to the bare descriptor URL on every run, and `run-descriptor.sh` reported `pass` (an
`updated`) instead of `skipped` for an entry the user had already configured. The fix is small and local to
one script, with no change to the descriptor format, validator or runner.

The behaviour is now:

- An existing entry *satisfies* the descriptor when its identity fields match: http, `type` is `http` and
  the URL is equal ignoring query string and fragment; stdio, `type` is `stdio` (or absent), `command` and
  `args` are equal, and every env NAME the descriptor lists is present in the entry's `env`. Extra keys
  (`headers`, hand-added `env` names, anything else) are ignored.
- A satisfying entry is left untouched (file byte-identical) and reported `unchanged`. The JSON result
  additionally carries `"note":"kept local customisation"` when the entry differs from the descriptor's
  literal entry. `note` is additive; no new `status` value exists, and `run-descriptor.sh` maps `unchanged`
  to `skipped` already, so it needed no change.
- A non-satisfying entry (different host or path, different command, different `type`, missing descriptor
  env name) is still `updated`, but the descriptor's fields are merged over the existing entry. Keys the
  descriptor does not own survive, the `env` object is merged by name, and when the `type` changes the old
  transport's own keys are dropped (`command`/`args`/`env` for stdio, `url`/`headers` for http) so no
  hybrid entry is left behind.

Deviation from the task text: when the `type` changes, transport-specific keys of the old transport are
dropped rather than preserved, because a `command` left on an `http` entry (or a `url` on a `stdio` one) is
meaningless and could be rejected by Claude Code. Every other unowned key is preserved.

**Evidence:** `skills/j-connect/scripts/register-mcp.sh` (the "satisfied" comparison and the merge
branch); `tests/register-mcp.bats` tests 13 to 18 (hand-edited URL byte-identical, different host keeps
`headers`, type change drops old transport keys, stdio extra `env`, missing env name, secret-shaped value
never printed); `project/documentation/service-descriptor.md` Runner table, `register_mcp` row.

## AC2: Header and env support for http MCP servers (E65_S08_T02)

**Decision:** `won't fix` for the header/env format extension; `implemented` for the one defect found next
to it (a silent env drop on http entries).

**Reasoning:** Both shipped http descriptors (`supabase.json`, `digitalocean.json`) register token-free
hosted OAuth endpoints with a bare `{type,url}` entry. No shipped descriptor needs a token-header variant
(Supabase CI/PAT `Authorization` header, DigitalOcean bearer-header variant), so an extension would be
speculative, and headers are a new secret-adjacent surface to validate, render and test. The story's policy
is to extend the format only for a demonstrated need, so the variants stay documented as "not expressible" in
the two research docs.

The defect that was real: `register-mcp.sh` accepted `--env-name` with `--type http`, built the env object,
and then wrote an http entry of only `{type,url}`, silently dropping the names; and `validate-descriptor.sh`
accepted an http `register_mcp` listing `env`, so a descriptor could promise env references that never
reached `.mcp.json`. Both now fail loudly: the validator rejects a non-empty `register_mcp.env` on an http
entry, naming the field path, and the script exits 2 on `--env-name` with `--type http`. Neither message
prints a supplied value. No shipped descriptor or existing fixture paired http with env, so nothing else
changed.

**Evidence:** `skills/j-connect/scripts/validate-descriptor.sh` (the `register_mcp.env` http rule);
`skills/j-connect/scripts/register-mcp.sh` (http branch of the argument checks);
`tests/fixtures/connect/descriptors/invalid-http-with-env.json`; `tests/validate-descriptor.bats` (http env
rejected, every shipped descriptor still validates); `tests/register-mcp.bats` (`--env-name` with
`--type http`); `project/documentation/service-descriptor.md` (`register_mcp` row).

**If this is ever built (header support):**
- Headers reference env-var NAMES only. A descriptor lists a header name and an env NAME; the script renders
  the value (for example `Authorization` -> `Bearer ${NAME}`) itself. A descriptor carrying a literal header
  value is rejected.
- The env NAME must also be in `secrets.env_vars`.
- The validator, `run-descriptor.sh`, `register-mcp.sh` and `service-descriptor.md` change together, with
  bats coverage for each.
- No secret value is read, printed or written; the "satisfied" comparison from AC1 must keep ignoring a
  user-added `headers` key.

## AC3: Multiple MCP servers per descriptor (E65_S08_T03)

**Decision:** `won't fix` (deferred to a new story if a second shipped endpoint is ever needed).

**Reasoning:** The limitation is real but it is not a defect, and removing it is not a small, safe change.
DigitalOcean's hosted MCP exposes one endpoint per service, and `skills/j-connect/descriptors/digitalocean.json`
registers only `digitalocean-droplets` (`https://droplets.mcp.digitalocean.com/mcp`). Supporting several
would need a validator rule for an array form, a runner loop with per-server result lines and a decision on
how they count in the summary, changes to `digitalocean.json`, tests, docs and four mirror copies, plus a
backward-compatibility rule for the single-object form. The workaround costs the user nothing:
`register-mcp.sh` merges by server name and never removes other entries, so a user can add the other
DigitalOcean endpoints by hand and re-running `j.connect` leaves them alone; `digitalocean.json`'s
`auth.instructions` already tells the user this ("add others from the MCP docs page by hand (re-running this
does not remove them)"). What would justify building it: a second endpoint that a shipped descriptor needs
registered, with a demonstrated user need rather than a hypothetical one.

**Evidence:** `skills/j-connect/descriptors/digitalocean.json` (`register_mcp`, `auth.instructions`);
`skills/j-connect/scripts/run-descriptor.sh` (the `register_mcp` step registers exactly one server);
`skills/j-connect/scripts/validate-descriptor.sh` (single-object `register_mcp` rules);
`project/documentation/service-descriptor.md` (the new "Limit" note under the field table).

**If this is ever built:**
- `register_mcp` stays valid as a single object: an additive `servers` array (or an array form) must not
  break any existing descriptor.
- Each server is merged by name, idempotently, through `register-mcp.sh` (including the AC1 "satisfied"
  semantics).
- Each server is its own runner result line, and the summary-count rule is decided and documented.
- Every env name stays a NAME listed in `secrets.env_vars`; no secret value is accepted, written or printed.
- The validator, `run-descriptor.sh`, `service-descriptor.md` and `digitalocean.json` change together, with
  tests and mirrors.

## AC4: Env-token flows and keeping the guardrail coverage honest (E65_S08_T04)

**Decision:** `won't fix` for real env-token support in the runner; a comment-only accuracy fix in the tests
(the breakdown's premise about missing coverage turned out to be only partly right, see Evidence).

**Reasoning:** No shipped descriptor needs an env-token flow. `skills/j-connect/scripts/run-descriptor.sh`
never loads the env file (`auth.check.command` sees only the process environment), and `auth.type` is a
single value with a single `auth.env_var`. `doctl` wants `DIGITALOCEAN_ACCESS_TOKEN` while DigitalOcean's
local MCP server uses a different name, `DIGITALOCEAN_API_TOKEN`, so it is modelled as `browser`, the
format's name for "a human must act" (the user runs `doctl auth init`; the token lives in doctl's own
credential store). Supabase does the same. Both therefore never reach the pre-write `.gitignore` guardrail
(`ensure-secret-safe.sh`), by design. Loading a project `.env` into a tool's environment would add a
secret-reading surface the format deliberately lacks. Naming caveat: `browser` means "human acts", not "a
browser opens"; this is now one sentence in `service-descriptor.md`.

**Evidence (which test exercises the guardrail before an env-file write).** Re-verified with grep, not taken
from the breakdown:

```
$ grep -n -i "guard\|env_file\|env-token" tests/run-descriptor.bats
177: @test "env-token auth: guardrail ignores .env BEFORE the placeholder is written; sentinel never printed"
189: @test "env-token auth: when the guardrail refuses (tracked .env) the step fails and nothing is written"
```

The breakdown said `run-descriptor.bats` has no guardrail or env-file assertions; that was wrong. It has those
two tests: the first asserts `.env` is git-ignored and holds only the `NAME=` placeholder after a run, the
second asserts that a refusing guard (tracked `.env`) turns the step into a `fail` and leaves `.env`
byte-identical, which does show the guard runs before the write. What it does not do is observe the *order*
directly. `tests/connect-e2e.bats` is the only test that does: its `setup()` interposes on
`ensure-secret-safe.sh` and step "2. CLI installed, not authenticated" asserts `env-absent-before-guard`.
`tests/ensure-secret-safe.bats` tests the guard script alone. The per-service files
(`supabase-connect.bats`, `digitalocean-connect.bats`, `expo-connect.bats`) assert that no env file is ever
created for their descriptors and claim nothing more.

Changes made (comments only; `git diff -U0 tests/ | grep '^[+-]' | grep -v '^[+-]#'` shows only file headers):
the `tests/digitalocean-connect.bats` header now states precisely what `ensure-secret-safe.bats`,
`run-descriptor.bats` and `connect-e2e.bats` each cover, and `tests/connect-e2e.bats` gained a comment that it
is the sole test that observes the ordering and must not be removed without a replacement. No assertion was
touched. `tests/expo-connect.bats` has the same loose "covered generically" sentence at lines 36 to 37; it is
outside this task's file list and its claim is substantially true given `run-descriptor.bats`, so it was left.

**If this is ever built (real env-token flows):**
- The runner reads env-var NAMES only, and never prints or logs a value.
- It never sources a file blindly; any env-file read is explicit, allow-listed by name and covered by the
  guardrail.
- `auth.type` / `auth.env_var` would need to express more than one variable (and the DigitalOcean case of two
  differently-named variables for the CLI and the MCP server).
- The guardrail-ordering test in `tests/connect-e2e.bats` moves with the change, and a per-service test
  would then need a real ordering assertion rather than "no env file is created".
- The validator, runner and `service-descriptor.md` change together.

## AC5: Install-method coverage (E65_S08_T05)

**Decision:** `won't fix`.

**Reasoning:** The fallback is the designed behaviour, not a defect. Installs are opt-in (`--allow-install`),
and where the platform or manager is not covered the runner prints the descriptor's `install.docs_url` with a
`needs-user-action` result, which works on every platform. Each extra manager would add a vendor-shaped
command to `manager_install_argv` (`apt`, `dnf`, `winget`, `scoop` take distro- and OS-specific package names
and often need privilege or a repository setup). That is exactly the rot the design rule "no authoritative
install commands" avoids, and the package names could not be verified here.

**Evidence:**
- Limits: `skills/j-connect/scripts/validate-descriptor.sh` accepts `install.methods[].platform` of `darwin`
  or `linux` only (the `platform` rule near line 89, with the matching `manager` rule beside it);
  `skills/j-connect/scripts/run-descriptor.sh` `manager_install_argv` builds argv for `brew` and `npm` only,
  and an unsupported manager yields `needs-user-action` with the docs URL;
  `skills/j-connect/scripts/detect-platform.sh` reports `os` as `darwin` or `linux`, anything else as
  `unknown` (so Windows always falls back).
- `install.methods` of the five shipped descriptors in `skills/j-connect/descriptors/`, checked against the
  files at the time of writing: `github` darwin/brew `gh`; `supabase` darwin/brew and linux/brew
  `supabase/tap/supabase`; `digitalocean` darwin/brew `doctl`; `expo` darwin/npm and linux/npm `eas-cli`;
  `figma` has no `install.methods` (no CLI install).
- Hints: no shipped `hint` contradicts the limit. The `supabase`, `digitalocean` and `expo` hints each say
  which method is automated and send everything else to the docs page, consistent with the runner. (`github`
  has no hint.) No finding to report.

**If this is ever built:**
- A new manager is added to the validator's `manager` list, and the validator's `package` rule (a bare,
  unpinned name) is kept.
- `manager_install_argv` builds the argv from the descriptor's manager and package only.
- `detect-platform.sh` and `service-descriptor.md` change in the same change.
- No version pin and no `sudo` or other privilege escalation is ever generated; a package name that cannot
  be verified is not shipped.
- Each manager gets a unit test using a log-only stub, never a real package manager.

## E65_S06 follow-up notes (E65_S08_T06)

The six notes recorded at the end of [figma-expo-connect-research.md](figma-expo-connect-research.md)
("Follow-up notes") each get a decision here, and a one-line pointer back from that file. Nothing in the
format, the scripts, the descriptors or `skills/j-connect/SKILL.md` changed.

### Note 1: Conditional registration (`register_mcp` gated on `detect`)

**Decision:** `won't fix`.

**Reasoning:** Not a defect. "Register only if no matching server exists" needs a new format concept and,
to be safe, visibility of other scopes (note 2). `{"supported": false}` for Figma and Expo is the designed,
duplicate-safe outcome: a duplicate Figma or Expo connection is worse than asking the user to add it. See
also AC3 (single-server limit).

**Evidence:** `skills/j-connect/descriptors/figma.json` and `expo.json` (`register_mcp`);
`skills/j-connect/scripts/run-descriptor.sh` (the `register_mcp` step runs independently of `detect`).

**If this is ever built:** a descriptor field naming the condition, validated; the condition must be
evaluated by the runner without reading Claude Code's private config; it depends on note 2 being solved
first; validator, runner, `service-descriptor.md` and tests change together.

### Note 2: Visibility beyond project `.mcp.json`

**Decision:** `won't fix`.

**Reasoning:** claude.ai connectors, user/local scope entries and plugin servers
(`plugin:<plugin>:<server>`) live in Claude Code's own configuration, which the runner would have to parse
to enumerate, and which it must not read. The single `detect.command` probe sees only what `claude mcp get
<exact name>` resolves. The documented user workaround is to check `/mcp` in Claude Code.

**Evidence:** `skills/j-connect/descriptors/figma.json` (`detect`, `hint`); `tests/figma-connect.bats`
(a server connected under a different name is not seen, asserted as a documented limit).

**If this is ever built:** only through a supported `claude` CLI surface that lists servers, with exit
status or machine-readable output, never by reading `~/.claude.json` or any token store; never writing a
value; a stub-based test per scope.

### Note 3: Multi-name `detect`

**Decision:** `won't fix`.

**Reasoning:** One argv is one server name. An any-of-names probe needs a new format concept, and for the
Figma plugin the name string is still "could not verify" (the plugin was not installed when researched).

**Evidence:** `figma-expo-connect-research.md`, "Could not verify" (plugin server name);
`skills/j-connect/descriptors/figma.json` `detect.command`.

**If this is ever built:** `detect` would accept a list of alternative argvs, any exit 0 meaning present;
validator, runner, doc and tests together; the plugin name added only once verified against a real install.

### Note 4: Wording for services with no CLI

**Decision:** `deferred to a new story`. The messages were checked rather than assumed, and one is
demonstrably misleading. A new `kind: mcp-only` field is `won't fix`.

**Reasoning:** `run-descriptor.sh skills/j-connect/descriptors/figma.json` was run in a temp project with a
log-free `claude` stub first on `PATH` (the real `claude` was not invoked; no account, install or secret).
Observed step messages, verbatim:

Not connected (stub exits 1):

```
detect   pass              tool not found; the install step decides what to do
install  needs-user-action no usable package manager found for darwin in this descriptor; install it yourself, following the official instructions: https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/
```

Connected (stub exits 0):

```
detect        pass     tool is present
install       skipped  already installed
auth          skipped  service needs no authentication
register_mcp  skipped  service has no MCP server
verify        pass     verification command succeeded
```

The not-connected output is awkward ("tool", "package manager", "install it yourself" for a service with no
CLI) but the URL it points at is the right place to go, so it is not wrong. The connected output is
misleading: `service needs no authentication` is wrong for Figma, which needs an OAuth consent inside
Claude Code, and the descriptor's own `auth.instructions` (which say exactly that, and that a successful
check only means "configured", not "approved") is never shown, because the runner prints a fixed string for
`auth.type` `none`. This is a runner-generated message (`run-descriptor.sh`, the `auth` step for `none`),
so the fix is not "descriptor text only" as the task anticipated: it is either surfacing
`auth.instructions` when present on an `auth.type: none` descriptor, or a wording change in the runner.
That belongs in its own story with its own tests, not inline here.

**Evidence:** the verbatim output above; `skills/j-connect/scripts/run-descriptor.sh` (the `install` message
for no usable package manager, and the `auth` `none` message); `skills/j-connect/descriptors/figma.json`
(`auth`).

**If this is ever built:** reword or surface descriptor text without adding a `kind` field; never weaken
the existing disclosure that `claude mcp get` exit 0 means "configured", not "approved"; update
`tests/figma-connect.bats` and `tests/run-descriptor.bats` assertions that pin today's strings; no secret
value involved.

### Note 5: Exit status cannot express "connected"

**Decision:** `won't fix`.

**Reasoning:** A property of the external CLI: `claude mcp get` exits 0 for a pending-approval entry and
the status text is on stdout, which the runner discards. It is already disclosed in `figma.json`'s `hint`
and `auth.instructions` ("A successful check only means the server is configured in Claude Code, not that
you have approved it"). That disclosure is not to be weakened or hidden (see note 4, which concerns the
connected-path message hiding it).

**Evidence:** `skills/j-connect/descriptors/figma.json` (`hint`, `auth.instructions`, `verify`).

**If this is ever built:** only via a documented, stable machine-readable status from the CLI; verified
against a real session first; the runner must still never read a token or Claude Code's private config.

### Note 6: No `j.publish` Expo/EAS target

**Decision:** recorded as an idea, not built.

**Reasoning:** Out of E65 scope: EAS Build and EAS Submit have no skill home today, which is `j.publish`
territory (a separate epic), and `j.connect expo` deliberately leaves them out (it connects the account CLI
and the hosted MCP server only). Not built or planned here, and no App Store Connect or Play Console work is
introduced. The idea is logged untagged in `project/ideas.md` through `scripts/idea_manager.sh add`
(origin: E65_S08_T06).

**Evidence:** `project/ideas.md` (one new line, origin comment `E65_S08_T06`);
`skills/j-connect/descriptors/expo.json` `hint` (out of scope on purpose).

**If this is ever built:** its own `j.publish` target and epic, with its own descriptor-free design; never
handles store credentials through `j.connect`.
