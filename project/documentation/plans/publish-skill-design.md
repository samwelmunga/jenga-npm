# `/publish` Skill — Design Brainstorm

## Overview
A single skill with sub-commands that guides and/or executes deployment pipelines from
the current project to remote environments (staging, production, app stores, etc.).
The skill always runs through a confirmation wizard before deploying and executes
the pipeline directly where automation is possible, surfacing manual steps otherwise.

## Sub-commands

| Command | Description |
|---|---|
| `/publish setup [<target>]` | Run the setup wizard for a new or existing deployment target |
| `/publish deploy` | Interactive deploy: prompt for target → confirm → execute pipeline |
| `/publish history` | Show recent publish history from `project/logs/publish-history.json` |
| `/publish release-notes` | Generate release notes without deploying |

## Configuration

**Location:** `project/configs/publish.json`

Stored alongside `workflow.json` and `test-config.json`. Contains named deployment
targets, each with a type, platform-specific settings, environment variable references
for secrets, and configurable quality gates.

**Example schema:**
```json
{
  "targets": {
    "staging": {
      "type": "mobile-cross-platform",
      "platforms": ["ios", "android"],
      "checks": { "pre": ["build", "lint", "test"], "post": ["smoke-test"] },
      "ios": {
        "bundle_id": "com.example.app",
        "team_id": "$APPLE_TEAM_ID",
        "api_key": "$APP_STORE_API_KEY",
        "profile": "AdHoc"
      },
      "android": {
        "package": "com.example.app",
        "service_account": "$GOOGLE_PLAY_SERVICE_ACCOUNT"
      }
    }
  }
}
```

## Secrets Handling

- `publish.json` stores **only variable references** (e.g. `"api_key": "$APP_STORE_API_KEY"`)
- Actual secrets live in the environment (`.env` gitignored, OS keychain, or CI/CD secrets manager)
- The setup wizard includes a **standard secrets guide** directing users to production-safe
  secret storage (recommended: OS keychain → export to `.env` locally; CI secrets for pipelines)
- On run, `/publish` validates that all referenced env vars are present before executing

## Deploy Flow (agentic execution)

```
/publish deploy
  ↓
1. Prompt: Select target (suggestions from publish.json)
   └─ If target has missing config → auto-run /publish setup for that target
2. Show board summary (closed tasks/stories since last publish tag) — informational only
3. Generate draft release notes (git log + closed board tasks since last tag)
4. User reviews + edits release notes
5. Pre-deploy quality gates (configurable per target): build → lint → tests
   └─ Any gate failure → halt, surface error, offer to continue or abort
6. Confirmation prompt: "Deploy v1.x.x to <target>? [y/N]"
7. Execute pipeline steps (platform-specific, driven by target type + wizard template)
8. Post-deploy quality gates (e.g. smoke test live endpoint)
9. On success: create git tag (e.g. v1.2.3) + append to publish-history.json
10. Surface manual steps (e.g. "Submit for App Store review in App Store Connect")
```

## Setup Wizard

- Triggered by `/publish setup` or auto-triggered when a target has missing config
- Wizard template is selected based on target `type`
- Initial wizard templates:
  - `mobile-cross-platform` — iOS App Store + Google Play Store (first priority)
  - Others to be added: `webpage`, `web-api`, `desktop`, `docker`, etc.
- Wizard collects: target name, bundle IDs, signing identities, env var names for secrets,
  quality gates to enable, build commands, post-deploy verification steps
- Writes populated config to `project/configs/publish.json` (merging with existing)

## Wizard Templates Location

`.agents/skills/publish/wizards/<type>.md` — each wizard is a structured prompt template
that walks through gathering all required fields for that deployment class.

## Scrum Board Integration

- **Loosely integrated** — `/publish` reads board state for context but never blocks deploys
- Closed stories/tasks since last publish tag are surfaced in the release notes draft
- No hard gate on board status for production deploys (user decides readiness)

## Deploy Recording

On successful deploy:
1. Git tag: `v<major>.<minor>.<patch>` (semver, auto-suggested based on change scope)
2. Append entry to `project/logs/publish-history.json`

## Quality Gates (configurable per target)

Pre-deploy gates: `build`, `lint`, `test`, `type-check`
Post-deploy gates: `smoke-test`, `ping`, `custom-script`

Wizard asks which gates apply for each target and stores them in `publish.json`.
On failure, `/publish` halts and surfaces the error — does not proceed silently.

---

## 🔍 Deep Dive Synthesis

### Scrutiny Findings

The scrutiny assessment rated this **5/10 (SKEPTICAL)**, flagging three structural problems:

1. **Oversized single skill** — bundling setup, release notes, quality gates, deployment orchestration, and history tracking into one skill creates a large, stateful command with tangled failure modes.
2. **Interactive-first, automation-last** — the wizard approach has no defined non-interactive contract, making CI, agent, and scripted use effectively impossible without rework.
3. **High-risk execution surface** — partial-success across platforms (one store succeeds, one fails), dual publish records drifting, and configurable gates being weakened under delivery pressure are all rated **High severity, High likelihood**.

→ Full assessment: `./scrutiny-publish-skill.md`

### Solution Paths

The solution assessment verdict is **CHALLENGING — tractable in narrowed form**:

| Decision | Recommended approach |
|---|---|
| Single skill vs multiple | ✅ Single `/publish` with bounded sub-commands (NOT monolith or separate skills) |
| Skill vs script | Skill is the entry point/orchestrator; execution logic lives in adapter scripts |
| Interactive vs agentic | Non-interactive contract is the primary spec; interactive wizard wraps it |
| Quality gates | Mandatory global minimum gates + optional per-target gates |
| Publish record | One canonical ledger (`publish-history.json`); git tags mirror it |
| v1 scope | **One target, one platform** — do NOT attempt multi-platform mobile v1 |

**Recommended resolution sequence (v1):**
1. Define non-interactive contract (inputs, outputs, exit codes) first
2. Implement thin orchestrator with bounded sub-commands
3. Choose one canonical system of record for publish state
4. Set mandatory global quality gates
5. Build one adapter (e.g. iOS OR Android, not both at once)
6. Add partial-failure/recovery handling for that adapter
7. Ship release-note generation as best-effort (git-first, board as enrichment only)

→ Full assessment: `./solution-assessment-publish-skill.md`

### Open Decisions

Before implementation begins, the following must be decided:

1. **v1 target scope** — narrow to a single platform (iOS *or* Android *or* a static web target) before tackling cross-platform mobile
2. **Ownership matrix** — which agent (Scrum Master, Developer, Tester) approves, executes, and validates a publish action
3. **Trust boundary for adapters** — are wizard templates allowed to contain arbitrary shell snippets, or are commands allowlisted?
4. **Canonical publish ledger** — is `publish-history.json` the system of record, with git tags as a mirror? Or vice versa?
5. **Non-interactive contract** — what flags/env vars drive `publish deploy` without interactive prompts?
