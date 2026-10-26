# Dependency audits and monitoring

How Jenga audits npm dependencies, for itself and for the services it builds, and how a maintainer sees the
result. This page describes what ships. The field-by-field table for the config lives in
[`project/configs/README.md`](../configs/README.md#audit-configjson), and this page links to it instead of repeating it.

## 1. Why

A critical vulnerability was published against a dependency, and it would have been caught by `npm audit` at any
point in the lifecycle. Nothing in Jenga ran that command: no gate, no pre-flight item and no CI workflow audited
dependencies, and the CI workflow generated for a service published without an audit step. Remembering to run the
check by hand does not scale, so the audit now runs at defined points, against a configurable severity threshold,
and every result is recorded.

## 2. The model

**One script does the audit.** `scripts/audit-deps.sh` wraps `npm audit --json`. Every other surface calls it, and
none re-implements audit logic. It takes the package directory with `--dir`, so the repository root, `project/app`
and a service's own tree are all reachable.

```
scripts/audit-deps.sh [--dir <path>] [--threshold <low|moderate|high|critical>] [--approved] [--ci] [--json]
```

`--threshold` overrides the config for one run. `--json` prints only the JSON object on stdout; diagnostics always
go to stderr. The script reads `npm audit`'s JSON and ignores npm's own exit code, because npm exits non-zero
whenever it finds anything.

**One config.** `project/configs/audit-config.json`, editable with `jenga config get|set audit-config.<key>`. Keys:
`config_version`, `mode` (`off` | `ask` | `on`, shipped `ask`), `severity_threshold` (`low` | `moderate` | `high`
| `critical`, shipped `high`), `offline_behavior` (`warn` | `fail`, shipped `warn`) and `production_only` (boolean,
shipped `false`, adds `--omit=dev`). Meanings and the descriptor are in the README section linked above and in
`templates/config-descriptors/audit-config.json`. A missing config file means those defaults; a present but invalid
one is a usage error (exit `2`).

**Exit codes of `audit-deps.sh`:**

| Code | Meaning |
|---|---|
| `0` | Clean (nothing at or above the threshold), or the audit was unavailable under `offline_behavior: warn` |
| `1` | Findings at or above the threshold |
| `2` | Usage or config error: bad flag or value, `--dir` missing or without a `package.json`, `jq` missing, or a malformed or invalid config |
| `3` | Audit unavailable under `offline_behavior: fail` |
| `4` | Not permitted: `mode: off`, or `mode: ask` with neither `--approved` nor `--ci` |

"Unavailable" means no `npm` on `PATH`, no `package-lock.json` or `npm-shrinkwrap.json` in the directory, a registry
error, or output that could not be parsed. An unavailable run prints its reason on stderr and still emits a JSON
object with `status: "unavailable"` and zero counts, so it is never mistaken for clean.

**JSON contract** (stdout with `--json`): `status` (`clean` | `findings` | `unavailable`), `threshold` (the
effective one), `counts` (`info`, `low`, `moderate`, `high`, `critical`, `total`), `findings[]` (`name`, `severity`,
`fix_available`, `range`, most severe first), `scanned_dir` (absolute), `generated_at` (UTC ISO 8601) and
`consent_basis` (`config-mode-on` | `session-approval` | `ci-workflow`). Differences from the design brief, all
verified against the script:

- `disabled` is not emitted. A refused run (exit `4`) prints nothing on stdout, so there is no object to carry it.
  `audit-record.sh` still accepts `disabled` as a status.
- `info` is a sixth count. It is reported but never trips the threshold.
- The script writes no file and no event. Recording is the job of its caller (`scripts/audit-record.sh`, section 5).

## 3. Consent

Audits are opt-in. The script evaluates consent before it invokes `npm`, so a refused run makes no network call.

| `mode` | Behaviour |
|---|---|
| `off` | Always refused (exit `4`), even with `--approved` or `--ci` |
| `ask` | Refused (exit `4`) unless `--approved` or `--ci` is given |
| `on` | Runs. This is the user's standing opt-in, made by their own `jenga config set audit-config.mode on` |

- `--approved` is passed only by an agent that has just obtained the user's approval in the session and logged it.
- `--ci` is passed only by a committed workflow, which is the user's standing consent for that workflow.
- `consent_basis` records which one applied: `--ci` gives `ci-workflow`, else `--approved` gives
  `session-approval`, else `config-mode-on`. A flag outranks `mode: on`.
- **`/j-publish` does not treat `--yes` as consent.** `skills/j-publish/scripts/run_gates.sh` passes `--ci` to the
  audit only on a real CI signal: its own `--ci` argument, `CI=true`, or `GITHUB_ACTIONS=true` in the environment.
  `--non-interactive`, which `deploy --yes` sends, and a missing tty are not consent. A human running `deploy --yes`
  under `mode: ask` gets `audit:skipped (no consent)`. It never passes `--approved`.

Where consent is logged, in `project/logs/events.json` (written through `scripts/events-append.sh`):

- The tester logs a `tool_approval` event with `tool_type: "vulnerability"` after the user approves, then
  `scripts/audit-record.sh consent` appends an `audit_consent` event. Both come before the audit runs.
- `mode: on` and CI runs have no per-run approval to log. They are traceable through the `consent_basis` field of the
  `audit_result` event instead.

Nothing runs silently: the tester only offers, the pre-flight item passes neither flag and so cannot opt the user
in, and a refused gate is reported as skipped with the command that would opt in.

### One-time opt-in notice

Because `ask` is the default, a new project would otherwise never learn that audits exist but are not running.
`scripts/audit-notice.sh show [--context init|publish]` prints a short notice (at most 6 lines: audits are not
running yet, they are opt-in, enable with `jenga config set audit-config.mode on`, or answer yes to the in-session
approval prompt, or let a committed CI workflow supply the consent) exactly once per clone. `j.init` and `j.publish`
only call it.

- Mode `on` or `off`: silent, no marker, exit 0. A missing config counts as `ask`. A malformed config or unknown
  `mode`: silent, one stderr line, exit 2, no marker.
- Memory is the file `audit-notice-shown` under the `data` path (`project/data/`), holding the UTC date. It is written
  atomically under `scripts/with-lock.sh`, only when the notice is printed. `project/data/` is partly tracked, so the
  marker is listed in the repo `.gitignore` and in the `j-init` scaffold template; a write failure (for example a
  read-only data directory) only prints a stderr warning, the exit status stays 0.
- `audit-notice.sh status` prints `shown` or `not-shown`.

## 4. Wiring

| Surface | What it does | Implemented in |
|---|---|---|
| Tester | The opt-in `vulnerability` executor. A task diff touching `package.json`, `package-lock.json` or `npm-shrinkwrap.json` only triggers an offer. After approval it logs consent, runs `audit-deps.sh --approved --json`, records the result. Recommends `Passed with remarks` for findings unless the task names the vulnerability check in its acceptance criteria | `agents/tester.md` (section "Dependency audit") |
| Pre-flight items | `dependency-audit-before-release` (`machine`, `pre-release` and `pre-publish`, `confirm`) and `dependency-audit-reviewed` (`judgment`, `pre-commit`, `advisory`). Identical in the shipped default and the project instance | `templates/checklists.json`, `project/configs/checklists.json`; background in [preflight-checklists.md](preflight-checklists.md) |
| `/j-publish` gates | A built-in `audit` gate in the `pre` phase for `npm` and `npm-ci` targets, after the mandatory gates, not configurable through `checks.pre`. Other target types report `audit:skipped (not an npm target)`. `deploy`, `deploy --dry-run` and `stage` all reach it | `skills/j-publish/scripts/run_gates.sh`; behaviour table in `skills/j-publish/adapters/npm.md` |
| Jenga's own CI | Weekly (Mondays 05:23 UTC), on demand, and on pull requests touching a `package.json` or `package-lock.json`. A matrix over `.`, `project/app`, `project/app/api`, `project/app/ui` and `mcp/training_runner`, each leg running `audit-deps.sh --ci --json` | `.github/workflows/dependency-audit.yml` |
| Generated service workflows | An `audit` job that the `publish` and `stage` jobs both `need`, plus a scheduled `dependency-audit.yml` rendered from a template. Both run plain `npm audit --audit-level=<audit_level>`. The level comes from the target's `audit_level` key in `publish.json` (`low`, `moderate`, `high` default, `critical`, `off`) | `skills/j-publish/scripts/npm_ci_pipeline.sh`, `skills/j-publish/assets/audit-workflow.yml.tpl`; `audit_level` validated in `skills/j-publish/scripts/validate_config.sh` and `skills/j-publish/schemas/publish.schema.json` |
| `/j-init` | Scaffolds `project/configs/audit-config.json` with `mode: ask` into a new project. Config only, no workflow | `skills/j-init/scripts/init.sh` (step 6.6), `skills/j-init/assets/audit-config_template.json` |
| `/j-status` | Prints the latest audit result per directory, or says none is recorded | `skills/j-status/SKILL.md` (step 6.8) calling `scripts/audit-status.sh` |

The `/j-publish` gate outcomes: exit `0` passes (an `unavailable` result under `warn` passes with a visible
warning); exit `1` fails the gate, or, interactively, asks to proceed anyway or stop; exits `2` and `3` fail; exit
`4` is reported as skipped, never as passed or failed. Every result that carries JSON is handed to
`audit-record.sh result` with `--agent j-publish`.

## 5. Monitoring

`scripts/audit-record.sh` is the recording half. It is the only thing that turns an audit into a durable trace:

```
scripts/audit-record.sh consent --dir <path> [--session-id <id>] [--agent <name>]
scripts/audit-record.sh result  --file <audit.json> [--session-id <id>] [--agent <name>]
```

Exit codes: `0` recorded; `2` usage error, or an unreadable result file or one with an unknown status; `3` a path
could not be resolved or the rapport or event could not be written.

- **Events.** `audit_consent` (`agent`, `tool_type`, `approved_by`, `scanned_dir`, `session_id`, `date`) and
  `audit_result` (`agent`, `status`, `threshold`, `counts`, `scanned_dir`, `consent_basis`, `rapport`, `session_id`,
  `date`). The event's `counts` carries `low`, `moderate`, `high`, `critical` and `total`; findings detail stays out of
  the event. An unavailable or clean result is recorded too, so "could not run" never equals "clean".
- **Rapports.** A `findings` result writes a `security_concern` rapport in the problems rapport directory (resolved
  with `scripts/resolve-root.sh get rapports_problems`), named `audit-<scanned-dir-slug>-<YYYYMMDD>.md`, listing
  every finding. A second result for the same directory and day overwrites it. Other statuses write no rapport.
- **`/j-status`.** `scripts/audit-status.sh` is read-only: no audit, no `npm` call, no file written. It prints the
  newest `audit_result` per `scanned_dir` with status, threshold, counts, age in days and, for findings, the rapport
  path. With no result it prints `Dependency audit: no audit recorded`, plus an opt-in hint when `mode` is `off` or
  `ask`. It exits `0` on a normal run, `2` on a bad argument, `3` when `jq` is missing or a path cannot be resolved.
- **Stale** means the newest result for a directory is more than 14 days old; `(stale)` is appended to its line.

Only the tester and the `/j-publish` gate record results. The CI workflow's result is a downloadable build artifact
(a JSON file per leg, kept 30 days) and is not written to `events.json`, so it does not appear in `/j-status`.

## 6. Mirror and consumer context

- **In `@jenga-ai/agent`** (the npm package's `files` list): `scripts/` (so `audit-deps.sh`, `audit-record.sh`,
  `audit-status.sh`), `templates/` (the shipped `checklists.json` and the config descriptor), `skills/` and
  `agents/`. Skills and the tester resolve the scripts with a dual path, `scripts/<name>` in a Jenga checkout and
  `node_modules/@jenga-ai/agent/scripts/<name>` in a consumer. `project/configs/audit-config.json` is not in the
  package; a consumer gets it from `/j-init`, and without one `audit-deps.sh` uses its defaults (`mode: ask`).
- **On the public repo:** `.github/workflows/` is not blocklisted by `.publicignore`, so `dependency-audit.yml`
  runs there along with the `scripts/audit-deps.sh`, `project/configs/audit-config.json` and
  `project/configs/workflow.json` it needs. `--ci` supplies the consent that the shipped `mode: ask` requires. The
  rules for what reaches the public repo are in [public-mirror-content-parity.md](public-mirror-content-parity.md).
- **A generated service audits with plain `npm audit`**, not `audit-deps.sh`, because `scripts/` is not copied into a
  consumer's tree. Running `npm audit` in a CI job is itself the CI consent.

Known limits, each deliberate or accepted:

- **A silent pass is possible when the registry is unreachable, unless `offline_behavior` is `fail`.** Under the
  shipped default `offline_behavior: warn`, `audit-deps.sh` exits `0` with `status: "unavailable"`, so a run goes
  green while auditing nothing; only the JSON artifact and the "Show findings" step show it. The same goes for a
  missing lockfile. Set `offline_behavior` to `fail` to make that exit `3`. This repository's own
  `project/configs/audit-config.json` sets `fail`, so Jenga's scheduled workflow fails loudly instead; projects
  scaffolded by `j.init` still start from the `warn` default.
- **The generated-service audit covers the root lockfile only.** Its `npm audit` runs at the repository root and the
  pull request trigger watches the root `package.json` and `package-lock.json`.
- **`audit_level: "off"` does not delete an existing `dependency-audit.yml`.** It stops the generator from emitting
  the `audit` job (and the `needs` lines) and the scheduled workflow, and prints a warning on stderr. A file
  written by an earlier run stays until removed by hand.
- **The `/j-publish` gate uses `audit-config.json`; a generated service uses `audit_level`.** They are separate
  thresholds for separate runtimes.

## 7. Non-goals

- **Other ecosystems.** npm only. pip, cargo and the rest would be a later adapter behind the same JSON contract.
- **Writing from the dashboard.** The dashboard's Security tab (section 9) only reads. It never runs an audit,
  never records consent and never writes a file; `/j-status` and the scripts in section 5 stay the way results get
  recorded.
- **Auto-remediation.** The audit reports. It never runs `npm audit fix`, edits a lockfile or opens a pull request.
  What to do with a finding stays with the maintainer or the agent's judgment.

## 8. Running it by hand

```bash
# audit the repository root, printing a short summary (needs consent: mode on, or pass --approved yourself)
bash scripts/audit-deps.sh --dir . --approved

# machine-readable, with a one-off threshold, then record the result
bash scripts/audit-deps.sh --dir project/app --threshold moderate --approved --json > /tmp/audit.json
bash scripts/audit-record.sh result --file /tmp/audit.json --agent maintainer

# what /j-status shows
bash scripts/audit-status.sh

# standing opt-in, and the threshold
jenga config set audit-config.mode on
jenga config set audit-config.severity_threshold critical
```

Pass `--approved` only when you are the one agreeing to the audit. In a consumer project, use
`node_modules/@jenga-ai/agent/scripts/` in place of `scripts/`. To check the pre-flight items, run
`scripts/checklist.sh check pre-release`, or validate the registries with `scripts/validate-checklists.sh templates/checklists.json project/configs/checklists.json`.

## 9. Dashboard

The project dashboard (`/j-dashboard`) has a **Security** tab that shows, side by side, what Jenga touches
(the credential-access findings) and when dependencies were last audited. It is read-only and renders from three
files; nothing on the page is typed in by hand. The route behind it is `GET /v1/security`, whose payload is
specified field by field in [api-contract.md](api-contract.md#6-get-v1security--credential-findings-and-dependency-audits).

**Data sources**

| Half | Source | Written by |
|---|---|---|
| Credential findings | `credential-findings.json` in the project's data directory (`project/data/` unless `paths.data` in `project/configs/workflow.json` says otherwise; `scripts/resolve-root.sh get data` prints it) | The classified result of `scripts/scan-credential-patterns.sh`, recorded by hand together with [credential-access-audit.md](credential-access-audit.md). No script writes the file. |
| Dependency audits | The `audit_result` and `audit_consent` events in `project/logs/events.json` | `scripts/audit-record.sh result` and `scripts/audit-record.sh consent` (section 5) |
| Dependency audits, settings | `project/configs/audit-config.json` (`mode`, `severity_threshold`, `offline_behavior`, `production_only`) | `jenga config set audit-config.<key>` or `/j-init` (section 2) |

**What the tab shows**

- **Dependency audits.** The audit settings in force; one row per audited directory (the newest result: status badge,
  low, moderate, high, critical and total counts, threshold, consent basis, last consent date, timestamp, and the
  rapport path as text when the audit wrote one); and the full history, newest first, in a collapsed section. The
  four statuses are shown as themselves, so `unavailable` ("could not run") and `disabled` ("consent refused") are
  never displayed as `clean`. Package-level detail is not copied into the tab; it stays in the rapport, which the
  Rapports tab already lists.
- **Credential access findings.** A summary line (scan date, command, total, count per skill) and a table with the
  skill, file, line, pattern class, verdict, reason and proposed action of each row. `true read` rows sort first and
  are visually distinct, and a filter narrows to the flagged skills or to true reads. The table is exactly the
  scanner's output: reads of credential values that its five patterns cannot match (the three `j-publish`
  environment captures) are not rows and are documented in
  [credential-access-audit.md](credential-access-audit.md#outside-the-five-patterns-not-rows-but-relevant-to-the-story).
- **Empty and error states.** Each half says in words when it has nothing (`never-scanned`, `never-audited`) or
  cannot read its source (`error`), and one half's state never affects the other.
- **Snapshot.** `/j-dashboard --snapshot` embeds the same payload (`routes.security`), so the exported HTML shows the
  tab offline.

**Consumer installs.** `credential-findings.json` describes Jenga's own skills and scripts, so a service Jenga built
normally has none, and its Security tab says no credential scan is recorded (`never-scanned`). That is the expected
state, not a fault. The audits half is meaningful in every project: it shows whatever the project's own
`events.json` and `audit-config.json` hold, and `never-audited` until the first recorded result.

**Refreshing each half**

```bash
# credential findings: re-run the scanner, then re-classify and update the table and the JSON together
bash scripts/scan-credential-patterns.sh                    # enumerates matches (tsv); add --format json for machine output
# the verdict, reason and action of each row are a reading of the code, edited into
# project/documentation/credential-access-audit.md and project/data/credential-findings.json so both carry the same rows

# dependency audits: run an audit with consent (section 8), then record it
bash scripts/audit-deps.sh --dir . --approved --json > /tmp/audit.json
bash scripts/audit-record.sh result --file /tmp/audit.json --agent maintainer
```

Reload the tab (or take a fresh `--snapshot`) afterwards; the live route re-reads the files on every request, so
there is nothing to restart. As with section 8, pass `--approved` only when you are the one agreeing to the audit.

**Verification status.** The tab was verified by server-side rendering of its components against stub and fixture
payloads and by `tests/dashboard-security.bats`, which checks the route payload and the snapshot data against a
throwaway fixture project. It was not run in a real browser, so the filter control, the collapsed history and the
layout were not observed live. When the panel was built this repository's real `events.json` held no `audit_result`
event, so the audits panel was checked against fixtures only. The first real run has since happened: on 2026-10-25 the five lockfile directories (`.`, `project/app`,
`project/app/api`, `project/app/ui`, `mcp/training_runner`) were audited with the user's approval and each result was
recorded with `scripts/audit-record.sh`. The registry was reachable (no `unavailable` result) and all five directories
had vulnerabilities (critical/high/moderate/low, total): `.` 1/1/2/0 (4), `project/app` 1/6/4/1 (12),
`project/app/api` 1/2/2/0 (5), `project/app/ui` 0/4/2/1 (7), `mcp/training_runner` 1/7/3/0 (11). Every directory got a
`security_concern` rapport. A remediation pass followed (the Express family and `js-yaml`, the dashboard build tooling
including a `vite` 5 to 6 bump, the MCP SDK family, and a `zod` 3 to 4 bump), and on 2026-10-26 the same five
directories were re-audited with the user's approval: all five returned `clean` with zero findings at every severity,
and each result was recorded as an `audit_result` event. The first-run rapports were then closed as resolved. This is
the state on 2026-10-26, not a guarantee about future lockfiles; the weekly workflow exists to catch new advisories.
`audit-status.sh` reports the latest result per directory, and results recorded from remediation worktree copies
appear as extra rows.
