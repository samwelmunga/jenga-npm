# Project Summary

## Overview
Jenga AI is a meta-framework for agentic software development. It provides a suite of Claude-based AI agents (scrum-master, developer, tester, ai-engineer), a skill library, scripting infrastructure, and a project board system (epics/stories/tasks). It is designed to be installed into consumer projects to give them a structured agentic workflow.

## Architecture & Structure
- `skills/` — Markdown skill files invoked by the CLI (e.g. `/do`, `/distribute`, `/publish`, `/doc`, `/uncharted`)
- `project/board/` — Scrum board (epics, stories, tasks) tracked as Markdown files with frontmatter
- `project/queue/` — Inter-agent communication (triggers, handoff files, update proposals)
- `project/logs/` — Event log for agent activity
- `scripts/` — Shell scripts for validation, board operations, and CI hooks
- `templates/` — Schema files and agent scaffolding templates
- `agents/` — Agent definition files consumed by the CLI
- `hooks/` — Git hooks and session lifecycle hooks
- `docs/` — **Published GitHub Pages content only.** Maintainer-internal documentation lives in `project/documentation/` (`paths.documentation` in `project/configs/workflow.json`). E34_S06 (2026-10-02, `Passed with remarks`) moved 10 internal docs there (`skill-authoring`, `distribution`, `public-mirror-content-parity`, `hook-parity`, `JENGA_PROTOCOL`, `api-contract`, `service-descriptor`, `mcp-registration-decision`, `digitalocean-connect-research`, `supabase-connect-research`). There is no longer any exception: E34_S06 had kept the strategy brief at `docs/STRATEGY.md`, but E34_S07 (2026-10-04, merged `c4dbcae9`) reversed that. The strategy brief now lives at `project/documentation/STRATEGY.md` (`paths.strategy` in `project/configs/workflow.json`), resolved via `scripts/strategy_path_resolver.sh` / `scripts/resolve-root.sh`, so it is gitignored with the other Jenga files under `project_files_visibility: ignored` and tracked under `visible`. `/init` no longer creates `docs/`. A legacy fallback to an existing `docs/STRATEGY.md` is retained in the resolver for projects that already have one; there is no auto-migration.
- `jobs/` — ML training job scaffolds (used by `/train` skill)
- `skills/uncharted/scripts/resolve-segment-target.sh` — canonical "does this path have board provenance?" check, with a single-path and a batch (`--paths-from -`) interface. Treat this as **shared tooling**: `/reconcile` (E40_S05_T02) is contracted to reuse it rather than write a second linkage implementation, and future skills should do the same instead of re-deriving board linkage. Known duplication: `run-engine.sh` keeps a private substring-based version for the understanding document's Board Linkage row and the two can disagree on the same target; `resolve-segment-target.sh` is authoritative. Collapsing them is an open follow-up in `project/rapports/problems/E40_S02_T01-segment-remarks.md`. The E40_S02 closure walkthrough (2026-08-26) pinned down one concrete instance: for a target **outside** the repository, `run-engine.sh` renders Board Linkage as `unlinked` while `resolve-segment-target.sh` correctly returns `not_checked` with reason "target is outside this repository". Those are not the same claim — `unlinked` asserts a *verified absence* of board references that was never actually checked. `skills/uncharted/SKILL.md` already names Step 1 authoritative where the two disagree, so the guardrail holds, but the generated row is wrong as written and `segment` mode has no documented handling for the `not_checked` case at all. Filed 2026-08-27 as `E40_S02_T04` under the reopened `E40_S02` story (`status: In Progress`), pending implementation.
- `/publish` skill — Configures and orchestrates release workflows; `publish.json` at project root stores target configs; `skills/publish/scripts/` contains `validate_config.sh`, `setup_wizard.sh`, `check_target_config.sh`; `skills/publish/assets/` contains the secrets guide used during setup.

## Distribution
Jenga AI supports two distribution paths:

**Public (npm):** Jenga AI is distributed as a public npm package (`@jenga-ai/agent`) via npmjs.com. Consumer projects install it with `npm install @jenga-ai/agent`; a postinstall hook copies only `skills/` and `agents/`, mirrored into both `.claude/` and `.agents/` under the consumer project root. `hooks/`, `scripts/`, and `templates/` deliberately stay inside `node_modules/@jenga-ai/agent/` and are sourced from there at runtime (narrowed in the E26 fix, commit `619198b`, well before this note — see the in-file comment in `scripts/postinstall.js`). Publishing is handled entirely through the `/publish` skill's `npm` target type (added in E26). The version source is `package.json`; `latest` and `beta` dist-tags are supported, and the npm pipeline honours a `--dry-run` flag. **Upgrade cleanup (E26_S08_T01):** `postinstall.js` now writes a provenance manifest (`.jenga-postinstall-manifest.json`) into each mirror root recording the relative paths that run mirrored, and on the next run deletes only paths a prior manifest lists that the current run did not rewrite — so a release that renames or removes a skill no longer leaves the old copies loading forever. `lib/mirror.js`'s blanket `reconcileDeletes` flag stays `false` at the consumer call site by design; the manifest diff is a separate, narrower mechanism. Consumer-authored files are never deletable because they were never manifest-recorded, and no prior manifest means no delete pass at all. `project/documentation/distribution.md` is the reference for the whole consumer install path. **Pre-manifest orphan cleanup (E26_S08_T02/T03, closed 2026-09-07):** T01's manifest diff was forward-looking only — orphans that predated a consumer's first manifest never entered any manifest and so were never deletion candidates, leaving the original defect unresolved for anyone already installed on 2.0.0 or 3.0.0. T03 closes this by seeding the first manifest from a shipped list of known-shipped legacy paths intersected with what's actually on disk, so pre-manifest orphans become reconcilable on the very next upgrade. T02 ships an interactive `jenga doctor` / `jenga clean` CLI command as the manual, confirmation-gated stopgap for consumers already broken today, and also covers ordinary mirror drift beyond this one migration. Both tasks were independently re-verified by the tester (real pty rehearsal for T02; real published `@jenga-ai/agent@3.0.0` tarball fixture rehearsal for T03). With T01–T03 all `Passed`, story `E26_S08` and epic `E26` are both rolled up to `Passed`.

**Private (filesystem):** For projects that consume the private monorepo directly, the `/distribute` skill handles local filesystem distribution (restored in E31). The monorepo root holds `distribute.config.json` — a structured JSON registry of consuming project paths with `name`, `path`, and `active` fields, replacing the retired `.jenga_paths` plain-text file. Each consuming project holds a `jenga.config.json` tracking `version`, `last_distributed`, `source: "private"`, `target_dir`, and (E31_S05) `project_files_visibility` (enum: `visible`/`ignored` — `hidden` was implemented then withdrawn as functionally broken; see E31_S05's Scope Correction) — controls whether the consumer's own `project/` working tree stays visible and tracked, or is git-ignored. This field covers only the `project/` working tree, **not** the distributed `.claude`/`.agents` framework scaffold — there is currently no config option that keeps that scaffold out of a consumer's git history, tracked as new scope under E31_S07 (filed 2026-09-15 from a problem rapport). Unlike the other fields, `project_files_visibility` is written by `/init` (`skills/init/scripts/apply-project-visibility.sh`), not by `/distribute`. Known gap: `distribute-changes.sh` rebuilds `jenga.config.json` from a fixed six-field `jq -n` expression and currently drops this field on the next distribution run — tracked as a follow-up under E34/E31_S06. The skill owns the full version lifecycle: release type selection (`major`/`minor`/`patch`/`amend`), dry-run preview, `npm version` bump, file copy to `.agents/` and `.claude/` in each target (respecting per-project `.jenga_ignore`), atomic `jenga.config.json` update, and a git commit of the version bump. `/distribute` is independent of `/self-sync` and `/mirror-public`.

## Epics
- **E01** — Model Training Agentic Workflow
- **E02** — Agent Conversation Guardrails
- **E03** — Parallel Workflow Orchestration
- **E04** — Dataset Conversion Skill
- **E05** — Agent Dashboard API Layer
- **E06** — Agent Dashboard Board Tab *(Reopened 2026-08-31 — In Progress, E06_S04 added)*
- **E07** — Agent Dashboard History Tab
- **E08** — Agent Dashboard Architecture Tab *(Reopened 2026-09-11 — In Progress. E08_S05 sources the Architecture tab from `project/knowledge-graph/graph.json` instead of parsing board markdown directly; T01–T03 rolled up `Passed` 2026-09-11/12. A 4th task, E08_S05_T04, was added 2026-09-12 for the story's outstanding DoD item — a manual/visual check that "Architecture tab renders correctly from graph.json-sourced data" — since none of T01–T03 were scoped to perform it. Story stays `Pending` until T04 also completes)*
- **E09** — Agent Dashboard CLI Interface
- **E10** — Script Infrastructure & Skill Refactor
- **E11** — Jenga Router
- **E12** — Claude Code Integration
- **E13** — Jenga CLI
- **E14** — Config & Skill Metadata
- **E15** — Multi-Project Router & Attach *(Reopened 2026-09-01 — In Progress, E15_S04 added: jenga attach was found clobbering the WorktreeCreate commit-guard hook)*
- **E16** — Multi-Platform Agent Config Parity *(Reopened 2026-09-07 — In Progress. E16_S05 (Copilot Sub-Agent Delegation Parity) rolled up to `Passed` 2026-09-07: T01 confirmed Copilot CLI has a native `--agent`/`/agent` agent loader (`.github/agents/` and `.claude/agents/` are live discovery paths, `.agents/agents/` is not); T02 wired a new `.github/agents/` mirror into `skills/self-sync/scripts/run.js` and documented `prefered_agent` routing in `templates/copilot-instructions.md.tpl`. Epic stays `In Progress`, gated on E16_S04: `/reconcile` found E26 silently reverted E16_S04's `.agents/settings.json` dual-write; new task E16_S04_T04 (fix stale docs, record the decision) is still `Pending`, T01–T03 keep their original `Passed` status)*
- **E17** — Workflow Quality Enforcement *(Reopened 2026-09-09, fourth time — rolled up to `Passed with remarks` 2026-10-05, fifth completion. E17_S08 added: `agents/tester.md` step 6d — authored by this epic's own `E17_S01` — forces `status: Failed` on any story with an unverifiable DoD item, but the tester runs **per task**, so mid-story the DoD items gated on later tasks are necessarily unverifiable. The rule is unsatisfiable for every multi-task story. Two tester runs in the 2026-09-09 `E50_S10` session hit it and both declined to follow their own contract, leaving the story `Pending` instead — correct judgment, but it means 6d is enforced by agent discretion rather than by its text. S08 must narrow *when* 6d applies without weakening *what* it does, or the fix re-opens this epic's own `S03`/`S04` false-completion failure mode)*
  - `E17_S10` added 2026-10-03 (P1): `/j-reconcile`'s completed-status list omits the five script-set ladder statuses that sit after `Passed` (`Merged`, `Publicized`, `Privatized`, `Deployed to Stage`, `Deployed to Prod`), so Phase 3 "promotes" a `Merged` ticket back to `Passed` and overwrites its `date_completed`. `/j-commit` runs a reconcile on every commit, so this bites after any `/j-self-sync`; 14 of E67's 21 tasks and 12 of E66's 15 currently carry `Merged`. `E17_S09` (guard Phase 3 promotion against an in-flight pipeline) and `E17_S10` are both `Passed with remarks` (S10 completed 2026-10-05); `E17_S08` then landed 2026-10-05 (`Passed`, `3bf524af`), so every E17 story is terminal-success and the epic rolled up to `Passed with remarks`.
- **E18** — README & Documentation Overhaul
- **E19** — Train Skill Enhancement *(Rejected 2026-09-10 — superseded by E57; never started, premise reversed)*
- **E20** — Knowledge Graph *(S09 — Mechanical Board-to-Graph Populator — rolled up to `Passed` 2026-09-12: T01 defined the `board` source-provenance value in `STUB_SCHEMA.md`, T02 built `scripts/populate-knowledge-graph.js` (a rapport-flagged node-pruning gap was addressed in the same task and re-verified, upgrading it from `Passed with remarks` to `Passed`), T03 added test coverage (16 tests, full suite 195/195). This is the populator side that E08_S05 consumes. 2026-09-18: a `/j-deep-dive` on E08_S05's graph-sourcing approach added `E20_S10` (active scope — architecture-map provenance gating, interim UX, mixed-provenance edges, entity resolution, staleness revalidation) plus `E20_S11`-`E20_S13` as gated/provisional backlog, see below. Epic remains `Pending` overall — S01–S08 are still `Pending`/undecomposed)*
- **E21** — Clarify Skill *(Passed with remarks)*
- **E22** — Publish Skill *(In Progress — reopened 2026-10-05 to add `E22_S10`: `skills/j-publish/adapters/droplet.md` documents a `gh workflow run` trigger phase that `droplet_pipeline.sh` does not implement, although `E22_S07`'s acceptance criteria require it, so a droplet `deploy` can report success without deploying; the task decides between implementing the phase and amending the contract. Found as doc drift by `E67_S07_T01`)*
- **E23** — Human–Agent Handoff Protocol
- **E24** — `/doc` Document Synthesis Skill *(Passed)*
- **E25** — Board Index Substrate
- **E26** — NPM-Compatible Distribution *(Passed)*
- **E27** — Repo Self-Sync — Restore Root → .claude/.agents Mirror Automation
- **E28** — Public Mirror — One-Way Private → Public Repo Sync *(`E28_S18` added 2026-10-03: three `tests/mirror-test-subject-invariant.bats` failures that six E67 task summaries had cited as "known baseline failures" — now diagnosed by `E28_S18_T01` (see `project/documentation/mirror-test-subject-invariant-diagnosis.md`) as a true positive: the gate correctly refuses the push because `tests/checklist-gating.bats` ships to the mirror while asserting blocklisted `skills/j-mirror-public/SKILL.md` exists; only cases 5/6/7, the three asserting status 0, go red; the baseline-failure framing is retired, fix filed as `E28_S18_T03`, loop early-exit as `E28_S18_T04`; plus `mirror.sh` pushing a `pre-force-*` rescue tag to the public remote under `--force --dry-run`. **2026-10-22 — `E28_S19` contract decision, `E28_S21` added, `E28_S19`/`E28_S20` closed.** `E28_S19` (mirror-time reference guard) is **`Passed with remarks`** — all six AC and all four DoD items ticked, including the fourth DoD item the scrum master added on 2026-10-22, certified by the re-judgement pass (session `e28-rejudge-20261022`, board verdict `63d4d74e`). `E28_S19_T07` narrowed the guard from the whole ship set to 192 instruction files, which made it enforceable (598 criticals to 0) but left 239 path-form references to never-public skills across 54 shipped files unreported and untracked. The scrum master resolved the stale contract on 2026-10-22 by **narrowing AC1 and the Scope bullet to the instruction-file scope and stating the accepted weakening explicitly**, rather than writing an AC for a broader scan that does not exist yet. Five non-blocking remarks were recorded; three were figure corrections to the amendment's own cost breakdown (`project/` 61 not 59, no `settings.json` hits at all, ship set 1710/1518) applied 2026-10-22. `E28_S20` (release branch and commit selection) is **`Passed`** — all eight AC, 3/3 DoD, same pass — and is **merged into `main` as `0453792e`**, its one `.publicignore` conflict resolved by keeping both blocklist entries. `E28_S21` (full-ship-set path-reference coverage, five tasks) closed **`Passed with remarks`** on 2026-10-23: T01-T04 merged as `23bef16d`, and `E28_S21_T05` (the mirror guard's path-hit scan broadened from instruction files to the npm-reach set via the new fail-closed `scripts/npm-reach-files.sh`, name hits still instruction-scoped) merged as `4949f4d4` on 2026-10-24, after the story had already been judged. The story-closing scope test gate was waived by the user on 2026-10-23 (its reds were a background-bats SIGINT artefact plus carried pre-existing failures; the `consumer-install-testbed` test 2 red seen on 2026-10-22 no longer reproduces on `main`, 9 of 9 ok). `E28` is **`Passed with remarks`** (rolled up 2026-10-23, all 21 stories terminal). Two hygiene loose ends from T05, a missing executable bit on `npm-reach-files.sh` and three untracked `zz-plant` leftovers in its worktree, are filed as `E42_S11`)*
- **E29** — npm Trusted Publishers CI Adapter *(Reopened 2026-09-12 — In Progress: E29_S05 Passed with remarks, verified against a real public-repo CI run; E29_S06 added from the tester's rapport to fix npm_ci_pipeline.sh's trigger phase always defaulting to a live `mode: publish`, still Pending)*
- **E30** — Strategy Brief Convention
- **E31** — Restore /distribute Skill — Private Filesystem Distribution *(In Progress — E31_S07 added 2026-09-15 from a problem rapport: decide+implement scope for excluding the distributed `.claude`/`.agents` scaffold from consumer `/init` commits, plus a trivial `.gitignore_template` stray-`EOF`-line cleanup; T01/T02 shipped that fix to `skills/init/` only and rolled the story up `Passed`, then the story was reopened the same day for `E31_S07_T03` once it was found that `skills/j-init/` — the copy that actually ships to public/npm consumers — never received it)*
- **E32** — Adaptive Execution Scope for /jenga + /do *(Passed)*
- **E33** — `/jenga-permission-level` — 5-Tier Permission System *(Passed with remarks; `E33_S09` added 2026-10-03 — `.jenga-permission-level.json` went 5 → 2 with no `permission_level_reset` event, because that log is **optional** in `agents/scrum-master.md` step 4c. The transition direction is the designed one; its unauditability is the defect)*
- **E34** — Working-File Path Centralisation — Single Source of Truth for `project/` Paths *(Pending — broken down 2026-09-29 into 5 stories: E34_S01 resolution bootstrap & shared resolver mechanism, E34_S02 `board_resolver.sh` migration + removal of its silent-default failure mode, E34_S03 `on_session_end.sh` + remaining `scripts/`/`hooks/` migration, E34_S04 skill/agent prose convention (scoped to `agents/*.md`, with `skills/*.md`'s 306 references explicitly deferred to a follow-up per the story), E34_S05 end-to-end relocated-tree lifecycle verification closing out F1/F2 of `E31_S05_T01-hidden-mode-path-resolution-gaps.md`. E34_S06 (maintainer-internal docs moved out of the public `docs/` site dir into `project/documentation/`, with `scripts/strategy_path_resolver.sh` and the documented placement rule) added and shipped `Passed with remarks` 2026-10-02 (6 tasks); E34_S07 (strategy brief moved from `docs/STRATEGY.md` into `project/documentation/STRATEGY.md`, `paths.strategy` default changed, `/init` creates no `docs/`, legacy `docs/STRATEGY.md` resolver fallback retained with no auto-migration, ignored-vs-visible behaviour covered by `tests/strategy-visibility.bats`) added after S06 and shipped 2026-10-04 (7 tasks all `Passed with remarks`, merged `c4dbcae9`; story rolled up to `Passed with remarks`, committed `6947113d`); S02-S05 remain Pending with no tasks decomposed yet, so the epic does not roll up. **E34_S01 shipped `Passed with remarks` 2026-10-03** (6 tasks, merged e99e0b8b + 7b3f2449): shared resolver `scripts/resolve-root.sh` (layered resolution: `JENGA_PROJECT_ROOT` override, upward search for `project/`/`.project/` registry, `./project/` default; `get`/`list` for all 18 `workflow.json` `paths` keys, `--strict`), contract documented in `templates/SCRUM_BOARD_SCHEMA.md`, `scripts/strategy_path_resolver.sh` migrated onto it, covered by `tests/resolve-root.bats`; `board_resolver.sh` and `hooks/on_session_end.sh` deliberately untouched until S02/S03)*
- **E35** — Idea Capture Pipeline — `/idea` Skill & `/spinoff` Integration *(Passed - rolled up 2026-10-17; reopened for E35_S03/S04, both now terminal)*
- **E36** — Standing CHANGELOG.md — Persistent Release Notes Across `/init` and `/publish` *(Pending)*
- **E37** — Inter-Agent Completion Signaling & Worktree Lifecycle Safety *(Passed with remarks - rolled up 2026-10-17 after reopen for E37_S05)*
- **E38** — Scenario Library & Comparison Playground *(Pending)*
- **E39** — Crucial Flag — Tiered Item-Level Caution & Escalation *(Pending)*
- **E40** — `/uncharted` — Investigative Workflow for Foreign & Pre-Existing Code *(Passed with remarks)*
- **E41** — Launch & Discoverability (npm + GitHub Go-to-Market) *(Pending)*
- **E42** — Maintenance — Framework Hygiene & Schema Drift *(In Progress — reopened 2026-09-15 for E42_S06, a stray-`EOF`-line gitignore-template cleanup in `skillify`'s `init-new` scaffold, found while investigating E31_S07's `skills/j-init/` gap)*
- **E43** — Shell Test Harness — Make the Declared bats Suite Real *(Pending)*
- **E44** — Execution Control — /break, Stop-the-Line, Scoped Run Status & Agent Check-In *(Passed with remarks — rolled up 2026-10-13; `S01`-`S11` terminal, `S04` Rejected; `/break` and `j.check-in` both exist; live drill run 2026-10-13 in a scratch repo confirmed soft/hard break, resume and entry refusal on the `/do` bundle path, and fixed 3 defects; the one remaining remark is that it used no developer subagent and not the real board, and `/dooo`/`/jenga` were not live-exercised; see below)*
- **E45** — Interactive Scope Selection for /jenga *(Pending)*
- **E47** — Distributable Project Dashboard *(Passed with remarks - re-rolled up 2026-10-25; S01-S09 all terminal; S09 added a dashboard header (Jenga logo linking to Backlog plus project title) and a new title source (strategy doc, then README, then git repo name), merged 2026-10-25; S08 added dashboard UI polish: dark-mode leftover card backgrounds, leave-dashboard confirmation on Back, verified-free dynamic ports; merged 23cb4009)*
- **E48** — Agent Dashboard — Live AI Item Review *(Pending — unblocked when E47's productization DoD was satisfied 2026-09-12; E47's subsequent `E47_S04` reopen/re-close for a remote-delivery addendum doesn't touch that DoD, so the unblock still holds)*
- **E50** — Skill Namespace Prefix & Anti-Masquerading Allow-List *(In Progress — reopened 2026-09-09 to hard-break the bare `/<name>` form, see below)*
- **E53** — Jenga Natural-Language Dispatcher & Playbooks *(Reopened — In Progress. Playbooks v2 shipped 2026-09-09 and the epic first rolled up 2026-09-10, see below; E53_S13 (`/route` retirement) shipped `Passed with remarks` 2026-09-27; E53_S14 is Pending, so no re-rollup yet)*
- **E57** — Train Skill Deprecation & Package Extraction *(Pending — supersedes E19, see below)*
- **E58** — Dashboard Markdown Library *(Pending — filed via `/brainstorm` 2026-09-13, see below)*
- **E59** — Dashboard Mobile Responsive Rollout *(Pending — filed via `/brainstorm` 2026-09-13, see below)*
- **E60** — Cloud Storage Connectivity *(Pending — filed via `/brainstorm` 2026-09-14, see below)*
- **E64** — Skill Catalog Smoke Testing & Critical-Error Reporting *(Passed with remarks — filed via `/j-todo` 2026-09-26, rolled up 2026-10-14; one story `E64_S01` Passed with remarks. `/j-smoke-test` (`skills/j-smoke-test/`) structurally smoke-tests every skill and renders critical findings as a `Feature | Error | Consequences` table from `templates/CRITICAL_ERROR_TABLE_TEMPLATE.md`; the row shape is the registered `error_table` type in `templates/playbook-types.json`. Remark: it reports 5 genuine critical defects in four existing skills, so the task-level "zero critical on the real catalog" criterion is unmet as written; remediation is epic `E74`)*
- **E65** — Service Connect (MCP and CLI setup) *(Pending — filed via `/brainstorm` 2026-10-01, see below)*
- **E66** — Preferred Tools Registry *(Done — filed via `/j-brainstorm` and completed 2026-10-03; all four stories closed: `E66_S01` Passed, `E66_S02` Passed with remarks, `E66_S03` Passed, `E66_S04` Passed, see `project/board/epics/E66_preferred-tools-registry.md`)*
- **E67** — Project-Scoped Pre-Flight Checklists *(Passed with remarks — filed via `/j-brainstorm` 2026-10-03; completed 2026-10-15. `S01` Passed, `S02`/`S04`/`S05`/`S07`/`S08` Passed with remarks, `S03` Merged, `S06` Passed; `E67_S08` (hook fail-open hardening and live `Task`/`Agent` matcher verification) was the last to close, see below. **Reopened 2026-10-22** (`In Progress`) to add `E67_S09`: `tests/checklist-suggest.bats:1067`, from `E67_S05`, asserts on the real `project/rapports` directory and the real `git status`, so any session that legitimately writes a rapport while the suite runs fails it spuriously — observed in the `E28_S19` gate run and absent from a clean re-run. One task, P3)*
- **E69** — Project Conventions Wizard *(Passed with remarks — filed via `/j-brainstorm` 2026-10-06, rolled up 2026-10-07; six stories `E69_S01`-`E69_S06`: `S01`-`S04` Passed, `S05`/`S06` Passed with remarks. Remarks: full `npm test` and `tests/mirror-test-subject-invariant.bats` not run to completion by user decision (targeted suites green); `commit-format` stays advisory because `pre-commit` cannot see the commit message; see below)*
- **E71** — Atlassian Connect and Work-Item Linking *(Pending — filed via `/j-brainstorm` 2026-10-06, nine stories `E71_S01`-`E71_S09`, see below)*
- **E72** — j.test Runner Skill and Commit-Time Test Gate *(Passed with remarks 2026-10-14; reopened 2026-10-21 for `E72_S06`, the per-scope test-run policy, and completed again 2026-10-22 as Passed with remarks: epic and story scope-test gates not run, accepted-unverified by user decision — filed via `/j-todo` 2026-10-07, six stories `E72_S01`-`E72_S06`, see below. **Reopened 2026-10-22** (`In Progress`) to add `E72_S07`, because the gate `E72_S06` landed could not, as filed, be passed by **any** story in this repository: the `E28_S19` story-closing run failed 23 of 3471 assertions, 19 of them one cluster of mirror assertions attempting a real push and correctly refused by `check_permission_level_invariant` while `session_level` was 5. Restoring the level to 2 cleared 14 of those 19, leaving the four reds `E72_S07_T04` now tracks by assertion number (661, 1582, 2229, 2233); and `E28_S19`/`E28_S20` both closed on 2026-10-22 despite the gate's exit 1, ruled not attributable by the tester (`project/rapports/problems/E28_S19-S20-story-gate-exit-1-not-attributable-ruling.md`), so the gate still fails but is no longer story-blocking. `test-config.json` declares bats as one monolithic suite, so `test_run_story: scoped` and `test_run_epic: full` are operationally identical and one unrelated red assertion anywhere fails every story gate. Four tasks, P1; both candidate fixes — splitting the catalog and skipping elevated-session-sensitive suites — are carried as candidates for `E72_S07_T01` to choose between on measured evidence)*
- **E74** — Skill Catalog Defect Remediation *(Pending — filed 2026-10-14 as the follow-up to `E64_S01`; one story `E74_S01`, tasks `T01`-`T06`, see below)*
- **E77** — Test-Suite Runtime Safety: Nesting Guard and Manual-Only Tests *(Pending — filed 2026-10-16 as the follow-up to E72 and `E28_S16`/`E28_S18`, rather than reopening two rolled-up epics. `E77_S01` Passed with remarks, `E77_S02` Pending (manual-only classification for extra-long tests). **`E77_S03` added 2026-10-22:** `check_test_subject_invariant` in `mirror.sh` materialises the whole ~1650-file ship set into a temp tree whose cleanup is not under a trap, so every interrupted run leaks it — 348 MB reclaimed once, and 34 directories totalling 404 MB measured with the oldest a week old. The fix promotes the variable to script scope and extends `mirror.sh`'s reassigned five-site EXIT trap chain; two tasks)*
- **E80** — Workflow: service area and toolbox *(Pending — filed 2026-10-21 via `/j-pi-plan`; no stories yet)*
- **E81** — Sprint workflow *(Pending — filed 2026-10-21 via `/j-pi-plan`; depends on E80; no stories yet)*
- **E82** — Roadmap *(Pending — filed 2026-10-21 via `/j-pi-plan`; depends on E81; no stories yet)*
- **E83** — Assertion: tests linked to the architecture map *(Pending — filed 2026-10-21 via `/j-pi-plan`; depends on E80 for the refresh flow only; no stories yet)*
- **E84** — Await-answer marker for skills that delegate their conversation to a sub-agent *(Pending — filed 2026-10-22 via `/j-error`, from an upstream change request by the Kazi project (`../agent-gui`) written against `@jenga-ai/agent` 4.3.0; one story `E84_S01`, see below)*
- **E85** — Security audits, monitoring and credential-access transparency *(Passed with remarks 2026-10-26 — filed 2026-10-25 via `/j.todo`; reopened 2026-10-25 for `E85_S04` and `E85_S05`; all five stories `Passed with remarks`, all 46 tasks terminal and merged into local main. Delivered: consent-gated, opt-in npm dependency audit for Jenga and for generated services (`scripts/audit-deps.sh`, `audit-config.json`, `audit_result` events) wired into the tester, pre-flight checklists and `/j-publish` gates; audit jobs in Jenga's own CI (`dependency-audit.yml`, a gating job in `npm-publish.yml`) and in the CI `/j-publish` generates; a one-time audit opt-in notice; the scanner-issue response (findings audit, `credential-access-audit.md`, `What this skill touches` sections in `j-connect`/`j-publish`/`j-uncharted`, a bats credential-access guard, and a `j-uncharted` secret-file skip); a dashboard Security tab (live and in `--snapshot`); and remediation of the first real audit's findings in all five of Jenga's lockfile directories, with a clean re-audit recorded 2026-10-26. Open items: the epic-level full-suite gate was not re-run after the reopening (targeted suites stood in); `tests/mirror-test-subject-invariant.bats` never completed; the reply draft `project/documentation/credential-access-issue-reply-draft.md` is for the user to post on the public repo after mirroring and releasing (fill its `<version>` placeholder first); regenerating through `/j-publish` would replace the hand-added `npm-publish.yml` audit job; the stale `project/app/api/package-lock.json` is to be removed in a follow-up. Agents never post to the public repo or run the mirror)*

## Project-Scoped Pre-Flight Checklists (E67)
Filed 2026-10-03 via the `idea-to-committed` playbook (`/j-idea` → `/j-brainstorm` → `/j-todo`), from the
situation-bound checklist idea in `project/ideas.md`. Standing project policy — prioritised
investigations, considerations and required actions — has no home today: per-item Acceptance Criteria and
Definition of Done are authored per board item and die with it. E67 adds a registry at
`project/configs/checklists.json` where each item declares **which lifecycle phases it applies to**
(`pre-commit`, `pre-task`, `pre-release`, `pre-reconcile`), so the set gating `/j-commit` differs from the
set gating `/j-do`, which differs again from the release path.

Settled in brainstorm: triggers are lifecycle phases, not skill names (phases survive renames — E50
renamed 40 skill directories); every item carries `kind: machine | judgment` so a tick records a
verification rather than an agent's self-assertion; `enforcement` is per item (`block` / `confirm` /
`advisory`); and `tick_scope` is per item (`run` / `persistent`). Enforcement lands in two phases —
`scripts/checklist.sh` wired into the gating skills' script chains first (`E67_S03`), then a
hook-enforced layer with a `project/queue/` situation marker that can genuinely block (`E67_S04`).

Eight stories (the seven below plus `E67_S08`, described after the delivery notes): `E67_S01` schema, validator and a generic `templates/checklists.json` default kept distinct
from this project's instance (`project/configs/` is not in `.publicignore`, so the instance ships
downstream like `test-config.json` does); `E67_S02` the `list`/`check`/`tick` checker; `E67_S03` wiring
into `/j-commit`, `/j-do`, `/j-reconcile`, `/j-publish` and `/j-mirror-public`; `E67_S04` the hook layer; `E67_S05` agent-suggested items — developer and tester can propose a new item
either as a precaution or to stop an issue recurring, via a `checklist_suggestion` rapport modelled on E39's
`crucial_escalation`, with the Scrum Master as sole writer and user confirmation required (added the same day,
after the original four-story breakdown). Two further stories were added at the 2026-10-03 story-rollup review: `E67_S06` user-facing documentation, because the whole epic's documentation was deliberately maintainer-internal and the feature is therefore invisible to consumers (`grep -i checklist` returns zero hits in `README.md`, in `docs/`, and in `project/.wiki/`); and `E67_S07`, which collects the non-blocking residue of four `Passed with remarks` rapports (stale doc references, a `/jenga` Phase 4 sub-step ordering defect, and two weak test assertions).

**Delivered 2026-10-03 (S01, S02, S03, S05):** the registry, validator and generic default; `scripts/checklist.sh`
(`list`, `check`, `tick`, plus `suggest`, `pending`, `rejected`, `resolve`) with run-scoped and persistent tick state
and a distinct exit code for a `block` failure (10) versus a `confirm` that needs a decision (11); the gate wired into
`/j-commit`, `/j-do`, `/j-reconcile`, `/j-publish` and `/j-mirror-public` by prose in each skill; and the suggestion flow
(developer and tester file a `checklist_suggestion` rapport, the Scrum Master reviews it and is the only writer of
`project/configs/checklists.json`, after user confirmation). Decisions made while building: the two release skills fire the
shared `pre-release` phase and then their own extension phase (`pre-publish` / `pre-mirror`) rather than sharing one, because
an item can name phases but not skills; registry selection is whole-file with no merging, so a project instance must carry
the generic release items itself; a reconcile run by `/j-commit` does not fire `pre-reconcile` (it would warn on every
commit); and a unit deferred at the `pre-task` gate when `/j-do` has no live user is never re-dispatched in the same
`/jenga` run (`E67_S03_T06`, a defect found while verifying the wiring). **The wiring is prose honoured by the agent
running the skill; it is not mechanically enforced until `E67_S04` (hook layer).**

**Delivered 2026-10-04/05 (S04, S06, S07):** `E67_S04` shipped the hook layer: `scripts/checklist-marker.sh` (a per-session situation marker with a push/clear stack, a 60-minute TTL and an explicit `refresh --token`) and `hooks/on_preflight_check.sh`, registered on `PreToolUse` with the matcher `Bash|Task|Agent`, which reads the marker, runs `checklist.sh check <phase>` and refuses a phase's own irreversible operation when a `block` item fails; with no marker it is a silent, subprocess-free no-op. The level-5 criterion was verified live on 2026-10-05, **for the Bash `git commit` path only**, by the orchestrator in a persistent-cwd main session (a Tester subagent cannot reproduce it because its Bash cwd resets between calls), so the claim "the wiring is prose honoured by the agent" above no longer holds for that path. `E67_S06` put the feature in front of consumers (`README.md`, the published page `docs/preflight-checklists.md`, `project/.wiki/preflight-checklists.md`). `E67_S07` cleaned the residue of four `Passed with remarks` rapports (stale `/j-do` reference, `/jenga` Phase 4 step ordering, two weak test assertions) and those rapports are now closed.

**Known limits of the hook, tracked as `E67_S08` (filed 2026-10-05, Pending):** a `cd` inside the gated command is not seen (the hook locates the marker from the cwd before the command runs), a nonexistent harness cwd fails open, and the `Task`/`Agent` matcher path has never been exercised live. The planned hardening (parse a leading `cd`/`git -C`, fall back to `CLAUDE_PROJECT_DIR`) is best-effort: `bash -c`, subshells, `pushd` and variable-built paths cannot be closed by parsing and are to be documented as accepted limits rather than claimed as covered.

**Not yet evidenced at rollup (2026-10-03):** two `E67_S03` boxes were deliberately left unticked. Its "existing bats suites still passing" criterion cannot be evidenced while `tests/mirror-test-subject-invariant.bats` carries three failures on a suite covering one of the five wired skills (tracked as `E28_S18`; now diagnosed, and partly self-inflicted: the culprit is `tests/checklist-gating.bats`, added by `E67_S03_T05` in commit `fe53ce95` on 2026-10-03, which passes 17/17 privately but fails 4 of 17 in a mirror-shaped tree because it asserts blocklisted `skills/j-mirror-public/SKILL.md` exists; the mechanism predates E67, since an earlier culprit, skill-allow-list-bijection, cleared after a `/j-self-sync`; the criterion becomes evidenceable once `E28_S18_T03` lands); and its `E61` instruction-mirroring criterion cannot be evidenced because `CLAUDE.md`, `AGENTS.md` and `WARP.md` carry no checklist content at all, even though `E67_S03` and `E67_S05` both declare `docs: ["CLAUDE.md"]` — a provenance claim no commit in the epic fulfilled (`E67_S06_T02` resolves it either way).

**Explicitly out of scope:** absorbing E39's `gated` tier. E39 shipped `Passed with remarks` 2026-08-27
and its risky-action list is marked fixed-and-verbatim across `agents/developer.md` and
`agents/tester.md`; making it resolve from this registry would reopen a contract documented in five
places, and is recorded as a candidate for a future E39 reopening rather than a dependency in either
direction. A `j.checklist` authoring wizard is also deferred and deliberately not filed.

## Project Conventions Wizard (E69)
Filed 2026-10-06 via `/j-brainstorm`. A project has conventions of its own (naming, commit format, code
commenting) but Jenga has nowhere to record them: agents infer style from the codebase and the E67
checklist registry is hand-authored. E69 adds `j.conventions`, a step-by-step, install-wizard-style flow
(modelled on `skills/j-tools/`) that detects the standards a project already follows, offers 2-3 general-standard
presets per category, and records the answers in `project/configs/conventions.json`. An idempotent generator
then writes `conv-` provenance-tagged items (`provenance.source: "convention"`) into
`project/configs/checklists.json`, advisory or confirm strength only, never `block`; the E67 checker and hook
are untouched. Nine coarse v1 categories: commit format, branching, naming, code comments, formatting/linting,
testing expectations, file/directory layout, language/tooling, documentation placement. EST commit naming stays
mandatory for board commits (`/reconcile` relies on it); a project commit-format convention applies to non-board
commits only. Six stories: `S01` schema/validator/descriptor/presets, `S02` detection script, `S03` checklist
generator, `S04` the wizard skill, `S05` agent consumption (digest, `agents/developer.md` precedence rule,
`j-commit`, init/onboard offer), `S06` documentation and mirror resync. Out of scope: a user layer, a general
`j.checklist` authoring wizard, and five deferred categories (error handling/logging, dependency policy,
security hygiene, review/PR rules, release/versioning). See `project/board/epics/E69_project-conventions-wizard.md`.

## Atlassian Connect and Work-Item Linking (E71)
Filed 2026-10-06 via `/j-brainstorm`. Teams using Jira, Confluence and Bitbucket cannot tie a board item to its
counterpart there. E71 lets a project connect to Atlassian through `j.connect` and **manually link** board items
(epics, stories, tasks) to Jira cards, Confluence sources and Bitbucket repos/PRs, with a link prompt that
appears only when Atlassian is configured. A **sibling of E65, not part of it**: E71 adds Atlassian descriptors
on top of E65's descriptor format, runner and `register-mcp.sh` (`E71_S01` depends on `E65_S01`/`E65_S02`), and
has no structural overlap with E69. Decisions: Cloud first (Data Center is the follow-up `E71_S07`, with
`deployment: cloud|datacenter` in the marker from day one so the linking layer is deployment-agnostic); both
transports (remote MCP with browser OAuth, and `acli` with an API token referenced by env-var NAMES only);
no fixed source of truth, manual linking only; a single optional `external_refs` list on board items rather
than per-system fields. Stories: `S01` the `atlassian-cloud.json` and `atlassian-cli.json` descriptors
(unverifiable vendor facts ship labelled "not verified against a real account", as Figma did); `S02`
`scripts/atlassian-configured.sh` plus the `project/configs/atlassian.json` marker, the offline-safe gate with
marker-drift detection; `S03` the `external_refs` schema field and `external_refs_declined` skip marker
(absent-safe across validator, dashboard, `j.status`, rollup, mirror; the story carries a pending
`crucial_level: advisory` proposal awaiting user confirmation); `S04` the offline link script (Jira key,
Confluence page URL, Bitbucket repo/PR URL shape checks, written under `with-lock.sh`); `S05` an optional
`/reconcile` Phase 5.5 link prompt; `S06` the same prompt in `j.todo` (`j.btw` left out of v1); `S07` Data
Center descriptor (deferred, P5); `S08` docs, mirror resync and real-account verification (needs a user with an
Atlassian account); `S09` (added 2026-10-06 after the `E71_S02_T03` rapport, P1, gates `S05`/`S06`) makes the
`j.connect` flow itself write the configured marker, via a generic optional `post_verify` descriptor field
(a framework script named by bare file name, static args and declared user inputs such as the site URL) run by
`run-descriptor.sh` after a passing `verify`, so no service name or marker logic enters `SKILL.md`; the marker
stays secret-free, idempotent and is never written when verification fails. **Non-goals:** two-way sync and Jira import. Developer and tester agents may read links but
never write them; scrum-master owns writes. All items `Pending`. See
`project/board/epics/E71_atlassian-connect-and-work-item-linking.md`.

## j.test Runner Skill and Commit-Time Test Gate (E72)

Filed via `/j-todo` (2026-10-07). Jenga has no user-facing way to run a project's tests. This repo
has `npm test` (109 bats files) and the tester agent runs tests as part of the board lifecycle, but a
user who wants to run the suite — or one suite out of many — has no generic skill. Consuming projects
are worse off: Jenga ships into Node, Python, Go and shell projects alike and offers nothing for any
of them.

E72 delivers **`j.test`**: a skill that discovers every runnable test suite in a project, presents
them as a **numbered list** the user can select from, and runs the selection. **The full suite is the
default** — selection is the opt-in. It also closes the loop at commit time. `j.commit` gains a
**three-option prompt**: (1) run tests covering the committed scope only, (2) run the full `j.test`,
(3) skip tests.

**Decisions settled at filing (2026-10-07):**

1. **Generic, multi-ecosystem discovery.** A detector script reads what is on disk — npm scripts,
   bats, pytest, go test, cargo test, shellcheck — treating `project/configs/test-config.json` as
   an authoritative overlay. A detector that only understood this repo's bats stack would be useless
   in the projects Jenga ships to.
2. **`j.commit` always asks, but remembers a default.** The three options are shown every commit
   unless the project has recorded a default in `test-config.json`. The default is overridable per
   invocation.
3. **Scoped tests resolve by path heuristic mapping.** Changed files map to test files via
   convention (e.g. `src/foo.js` → `test/foo.test.js`, `skills/j-x/` → `tests/*j-x*.bats`) plus a
   configurable mapping table, as a deterministic script.
4. **`j.test` does not replace the tester agent.** It is a user-invoked convenience runner. The
   tester remains the sole owner of the board testing lifecycle and status writes. The developer
   agent never runs tests — `j.commit`'s prompt is answered by a human, not by an agent.
5. **Scripts Over Inline Logic** — discovery, catalog rendering, scope mapping, execution and result
   summarisation are scripts under `skills/j-test/scripts/`. `SKILL.md` holds only conversation and
   selection logic.

Five stories: `S01` discovery script and `test-config.json` descriptor updates; `S02` `j.test` skill
(full suite, numbered list, default all); `S03` scope-mapping script for commit-time scoped runs; `S04`
`j.commit` test-gate prompt and three-option flow; `S05` documentation, mirror sync, end-to-end
validation. **Completed 2026-10-14, `Passed with remarks`:** all five stories are terminal and merged. `j.test` and the
`j.commit` three-option test gate (with a recorded-default override and a tested failure contract) now exist, documented in
`project/documentation/test-runner.md`. Verified by targeted suites per story plus Tiers 1 and 2 of the whole-epic manifest
(611 ok / 212 ok, 2 skips from upstream Copilot CLI drift); the full `npm test` was **not run**, accepted-unverified by user
decision, 2026-10-14. Follow-ups are listed in the epic's Rollup Remarks. See `project/board/epics/E72_test-runner-skill-and-commit-test-gate.md`.

**Reopening 2026-10-21 — per-scope test-run policy (`E72_S06`, status `Pending`, six tasks).** Filed via `/j-btw`:
the user wants configuration for *when* tests run and *which* tests, key/enum based, with the defaults tasks: no test
runs beyond the ones the tester agent creates; stories: scoped test runs; epics: the full suite, each run before that
scope is closed. E72 is `In Progress` again; the first completion (2026-10-14) is kept in `dates_previously_completed`.

Decisions settled with the user:

1. Three flat top-level string keys in `project/configs/test-config.json`: `test_run_task` (default `none`),
   `test_run_story` (default `scoped`), `test_run_epic` (default `full`); allowed values `none`, `scoped`, `full`.
   Flat because the config descriptor schema expresses an editable key only as a scalar (as with `commit_prompt_default`);
   editable with `jenga config get|set`, descriptor-validated.
2. `none` runs nothing beyond the tester agent's own tests for the item; `scoped` runs the suites `map-scope.sh` maps
   from the scope's changed files (same scope map as `j.commit`); `full` runs the whole `j.test` catalog (manual-only
   tests stay excluded once `E77_S02` lands, as the same scripts are reused).
3. The policy runs before the scope closes: task before the tester writes its judged status, story in the tester's
   story-closing pass, epic before the scrum master's rollup writes the epic status.
4. An absent key reads as its default; an invalid value reads as the default with a warning, never a silent skip.
5. A `scoped` run mapping to zero suites says so and falls back to the full catalog, never a green run that executed nothing.
6. The tester runs the policy (the developer never runs tests; the tester stays the sole writer of judged statuses and
   its SAST/vulnerability approval flow is unchanged); the scrum master requests the epic gate from the tester. A failure
   blocks closing: task or story `Failed` plus a rapport, epic stays `In Progress` plus a rapport.
7. Independent of `j.commit`'s commit-time gate; `commit_prompt_default` is unchanged.
8. Scripts Over Inline Logic: `skills/j-test/scripts/scope-policy.sh` (resolver) and `scope-test-gate.sh` (gate); the
   agent files only call them. Root directories are canonical; mirrors are synced with `cp -p`.

Tasks: `T01` config keys, `T02` resolver script, `T03` gate script, `T04` tester and scrum-master wiring, `T05`
documentation, `T06` verification. See `project/board/stories/E72_S06_scope-test-run-policy.md`.

**Completed again 2026-10-22, `Passed with remarks`.** `E72_S06` is terminal (`T01`-`T04` `Passed`, `T05`/`T06` `Passed with
remarks`), all merged to `main`, so all six stories of E72 are done. The per-scope test-run policy now exists: the three keys,
`scope-policy.sh`, `scope-test-gate.sh`, the tester and scrum-master wiring and the documentation in
`project/documentation/test-runner.md`. Verified by targeted suites (241 / 457 / 88 cases ok, 0 not ok, 0 skipped over Tiers 1,
2 and 2b). **Not run, by user decision 2026-10-22 (accepted-unverified):** the epic scope-test gate (`test_run_epic` = `full`,
the full `npm test`) and the story gate for `E72_S06` (`test_run_story` = `scoped`, which equals the full `npm test` in this
repository because the shipped scope map maps the story's files to the whole bats suite; whether that equivalence is
acceptable is a design point left to the user). Carried follow-ups: `tests/commit-test-gate-run.bats` SIGINT case fails only
as a background job, `workflow_template.json` and other root-versus-mirror drift, and the board files plus about 220 other
changes still uncommitted. Details in the epic's "Rollup Remarks (2026-10-22 reopening)".

## Agent Check-In — j.check-in Liveness Instrument (E44 reopening, 2026-10-07)
Filed via `/j-brainstorm` on 2026-10-07; `E44` reopened and expanded from four stories to seven. `j.check-in`
answers an axis nothing on the board owned: **is the item the board calls `In Progress` actually alive right
now, at the OS and harness level?** `j.status` reports declared board state, `j.reconcile` repairs
board-versus-git divergence, and `E44_S03` (`/break status`) reports current run scope while its own DoD
forbids the evidence liveness needs ("never reads a `.md` file outside `project/board/` and
`project/todo.md`"). Motivating case, which narrowed the scope: an operator who has just fanned out several
agents via `j.dooo` and wants to know which are alive, which have gone silent, and which finished but left
live processes behind.

**Three stories.** `E44_S05` the read-only collector `skills/j-check-in/scripts/collect-liveness.sh` (reads
`ListAgents` output on stdin — a bash script cannot call a harness tool; emits one JSON object; exits `0`
always, a deliberate divergence from `scripts/check-worktree-liveness.sh`'s exit-1-on-found; performs zero
writes; plus the `j.do` change naming each background subagent after its board id so the agent-to-item join
is free). `E44_S06` the `j.check-in` skill — two-tier report, numbered option lists only for findings whose
`actionable` field is `true`, delegation of every repair to its owner, allow-list and mirror resync.
`E44_S07` automatic invocation: **no new trigger mechanism** — `skills/j-do/SKILL.md` section 4.1.2 already
fires the `pre-task` pre-flight phase exactly once per unit, so this adds one registry item
(`checkin-run-before-dispatch`, `machine`/`confirm`/`persistent`, `checklist_version` 1→2) plus a small
`checkin-gate.sh`, and modifies **no hook wiring** — the root `settings.json` and all five
`templates/permission-levels/level-*.json` files are untouched.

**Key finding, valuable independently of the feature:** `/break` halts **dispatchers at task boundaries** and
never reaches inside a running agent. Every `E44_S02` checkpoint sits at a task boundary by design, so a
wedged agent mid-task has no boundary to halt at and `TaskStop` is the only intervention that reaches it —
`/break` and `TaskStop` act on different subjects. `E44`'s Purpose section now records this as a Correction;
the epic's original prose did not make it explicit. Consequence: `j.check-in` first shipped a **two-rung** ladder
(observe → re-observe → confirmed `TaskStop`); `E44_S10` has since added the `/break` rung
(`skills/j-break/` now exists, `E44_S01`/`S02` `Passed`), with `TaskStop` still the only rung that reaches a wedged agent.

**Containment is the design.** `j.check-in`'s entire write surface is append-only `events.json` entries plus
`TaskStop` after explicit confirmation. Triggers, rapports and `status_review` delegate to the scrum-master;
stale worktrees and board demote/promote to `j.reconcile`; worktree removal nowhere through this skill
(`scripts/worktree-remove-guard.sh` and the `WorktreeRemove` hook own it and already hard-block on exactly
the condition it detects); other sessions' slot files report-only, since both slot scripts' headers state
they never touch another session's counter file. A scrum-master subagent is spawned **only** when a finding
is actionable, so a clean session costs one sub-two-second script run and no agent invocation.

**Honest-by-design blind spots.** Collection is not delegable: from inside a delegated scrum-master subagent,
`ListAgents` returned only that subagent plus seven unrelated interactive peer sessions — the parent's
sibling developer/tester subagents were invisible. So the skill carries no `metadata.prefered_agent` and the
host session must collect. The collector's `visibility` object is mandatory in every output and the report
always states what it could not see; `check-worktree-liveness.sh` exit `4` degrades `cross_session` to
`"none"` rather than reading as "clear". The automatic path is deliberately weaker (no `ListAgents`) and says
so.

**Follow-ups since filed:** `E44_S08` bundle resume, `E44_S09` per-session execution ledger for `/break status`,
`E44_S10` the `/break` rung of the ladder, `E44_S11` independent tester verification — all terminal. The epic
rolled up `Passed with remarks` on 2026-10-13; the remaining remark is that no real `/jenga` run has been
interrupted by a real `/break` (live drill in progress).

**Still deferred, deliberately not filed as board items** (recorded in the epic's own "Deferred Follow-On Work"
section): moving the hardcoded 20/45-minute thresholds into `scope-thresholds.json` as
`checkin_idle_warn_minutes`/`checkin_idle_stall_minutes` (`threshold_version` 4→5 plus `jenga config`
descriptors). The 45-minute stall value must not be lowered: session `tester-E69_S06-bundle` logged nothing
between `22:58:05Z` and `23:20:17Z`, 22 minutes of silence from a perfectly healthy tester. See `project/board/epics/E44_execution-control.md`.

## Train Skill Deprecation & Package Extraction (E57) — supersedes E19
Captured via `/btw` on 2026-09-10 by direct user instruction: `/train` is disabled and deprecated in
both the private repo and the public mirror, but **preserved** — it is being moved to its own package
later, so deprecation here means "stop offering it as a Jenga skill", never "delete it".

This reverses `E19`'s premise wholesale. E19 (`/train` Skill Enhancement — Production-Grade ML
Orchestration) sat at `Backlog` with 7 decomposed stories and a 12-item DoD aimed at growing `/train`
inside this repo; it is now closed `Rejected` — the schema's deliberate, non-failure closure, same
usage as `E53_S07` — with `E19_S01`–`S06` left as written so the abandoned plan stays readable.
`E19_S07` (*"Document that `/train` is excluded from the public npm package"*) was already `Passed`
and its outcome carries forward.

Two findings shaped the scope. First, **most of "remove it from public" was already true**:
`check-publicignore-match.sh` reports `BLOCKED` for both `skills/train/SKILL.md` and
`skills/j-train/SKILL.md`, since `train` sits in `.publicignore`'s "Private Claude / agent skills"
block alongside `mirror-public` and `self-sync`. It has never shipped publicly in either form and is
absent from `CLAUDE.md`'s skill table, so the public deliverable is a deprecation *notice*, not a
removal. Second, **`.training/` (100K, repo root) has no board provenance** — the 2026-09-10 reconcile
scan reported 9 fully-unlinked groups under `.training/template/…`, which blocks confident extraction
until ownership is established (`E57_S02`).

Interaction with `E50_S15` is settled by user decision 2026-09-10: **let `E50_S15` run normally.** It
deletes `skills/train/` as one of the 40 bare-name directories while `skills/j-train/` survives, and
extraction sources from the twin. E57 therefore adds no prerequisite to `E50_S15` and does not grow
its permanent-exception list — at the cost of depending on twin completeness, which `E50_S19_T04`'s
audit gate is meant to guarantee.

## Skill Namespace Prefix & Anti-Masquerading Allow-List (E50) — bare-form hard-break reopening
E50 originally decided (DoD, checked off) to keep the old bare `/<name>` form as a permanent,
never-deprecated alias alongside the `j.<name>`/`j:<name>` canonical form, with `j-<name>` directory
twins (E50_S05) documented as a purely complementary, collision-safety-only duplicate — never a
replacement for the canonical bare-name directory. Reopened 2026-09-09 after a `/j-error` session
traced a public-mirror stage-deploy gate failure (`tests/load-playbooks-stepobject.bats`) to that very
split: `E28_S09`/`E28_S10` blocklisted 34 canonical bare-name skill directories in `.publicignore`, so
the public mirror carries only their `j-<name>` twins, while `skills/jenga/playbooks/brainstorm-to-mirror.json`
still references those skills by bare name in its `steps` array — `load-playbooks.sh` requires every
step's `skills/<name>/SKILL.md` to exist or silently skips the whole playbook, so it fails to load in
the public mirror (the private repo is unaffected; its bare-name directories were never removed).
Rather than patch `.publicignore` to restore parity with the original policy, the user chose to invert
it: bare-name directories are retired everywhere — private repo included — `j-<name>` is promoted from
twin to the sole canonical form, and bare `/<name>` hard-breaks once its directory is deleted, with no
redirect or deprecation shim. Amended in place rather than filed as a new epic, since it reverses
rather than extends E50's original DoD decision (see new DoD bullets in `project/board/epics/E50_skill-namespace-prefix-and-allow-list.md`).
Story breakdown for this reopening is left to `/jenga`'s decomposition pass.

## Distributable Project Dashboard (E47)
E05–E09 built a working local dashboard (Express API + Vite/React UI, `project/app/api` + `project/app/ui`), but it only ever worked against this monorepo's own `project/` directory and is excluded from the published npm package's `files` list (confirmed via `npm pack --dry-run`) — a consumer who runs `npm install @jenga-ai/agent` has no access to it at all, despite E09's own story titles (`jenga dashboard start`, `jenga dashboard open`) already naming it as a CLI feature it never became. Filed via `/btw` (2026-08-31) after a session that fixed three bugs blocking the dashboard from working even in this repo: a nested-`npm run` flag-forwarding bug, a missing `express` dependency unreachable from `project/app/ui/scripts/dashboard-start.cjs`, and a route-shadowing bug where the API server's catch-all 404 (registered at module-require time) silently defeated `--serve-app`'s static/SPA-fallback middleware. This epic generalizes the now-working dashboard into a real per-consumer-project feature: S01 ships it in the npm package, S02 resolves its data source against the *invoking* project rather than this repo, and S03 wires actual `jenga dashboard start`/`open` CLI subcommands into `bin/jenga.js` (currently only `init`, `start`, `attach`, `status` exist). S02 explicitly reuses E46's path-resolution precedent (fail loudly rather than assume monorepo-relative paths) instead of rediscovering the same defect pattern independently. Scoped by the user as a generalization/relocation of existing working code, not a rewrite.

**E47_S01 (ship the dashboard in the published npm package) shipped 2026-09-12 — `Passed`.**
Decomposed into 4 tasks: `E47_S01_T01` (packaging-location decision + `files` field), `E47_S01_T02`
(prepack UI build step), `E47_S01_T03` (root-level runtime dependencies — `express`, `cors`,
`gray-matter` moved from `project/app/api`'s inert nested `package.json` to root, since npm never
installs nested `node_modules`/`package.json` for a real consumer), `E47_S01_T04` (extends
`E47_S02`'s `scripts/verify-consumer-install.sh` to drop its two documented "KNOWN SIMPLIFICATION"
workarounds — a scratch `files`-field patch and a manual dependency install — now that T01-T03 make
both unnecessary). All 4 tasks `Passed`, tester-verified via a real `npm pack`+`install` rehearsal
across 5 scenarios (`scripts/verify-consumer-install.sh`, 19/19 assertions); all story AC/DoD
ticked. `T01`-`T03` edited root `package.json` directly (the "public-facing distribution" Crucial
Level heuristic), but the `gated`-tier proposal surfaced during breakdown was never confirmed
in-session, so no `crucial_level` was written to any of the three tasks.

**Two reusable packaging gotchas found during `E47_S01`, documented in full in
`project/documentation/distribution.md`'s "Dashboard packaging decision" section:** (1) an explicit `files` entry
for a path does **not** override a nested `.gitignore` in that same directory, even when the repo
root has its own `.npmignore` — npm prefers a directory's own `.npmignore` over its `.gitignore`
when both exist, so the fix was an empty (comment-only) per-directory `.npmignore`
(`project/app/ui/.npmignore`), not a root-level rule; (2) a bare `**/*.js` glob in `files` does
**not** stop at a `node_modules` boundary — once npm's packer sees any file inside a
`node_modules/<pkg>/` directory selected by an explicit `files` pattern, it packs that nested
package's entire tree, not just the one matched file. This only reproduces when `node_modules`
actually exists on disk at pack time (e.g. a maintainer checkout), and requires explicit negated
`!**/node_modules/**` entries to fix — root `.npmignore`'s own `**/node_modules/` pattern does not
catch it, since an explicit `files` allow-list entry takes precedence over a blanket `.npmignore`
pattern. Worth checking for on any future `files`-field change.

**E47_S04 (`j.dashboard` skill — launch + snapshot export) rolled up `Passed with remarks` — first closed `Passed` 2026-09-12, reopened the same day for `E47_S04_T04`, then re-closed `Passed with remarks`; rollup re-verified 2026-09-13 with no status change needed.** All four tasks complete: `E47_S04_T01` (default launch mode, `Merged`), `E47_S04_T02` (snapshot data capture built on `E47_S02`'s generalized resolution, `Passed`), `E47_S04_T03` (single-file bundle/inline + `file://` render, `Merged`), `E47_S04_T04` (`data:` URL remote-delivery mode, `Passed with remarks`) — no findings on the first three. `skills/j-dashboard/SKILL.md` + `scripts/launch.sh` delegate to `project/app`'s existing `dashboard:start`/`dashboard:open` npm scripts for the default (no-flag) path; a tester-found blocking regression (bash < 4.4, incl. macOS's stock `/bin/bash` 3.2, throws "unbound variable" on `"${EXTRA_ARGS[@]}"` when no `--port`/`--serve-app` is passed — i.e. the primary bare-invocation shape) was fixed and independently re-verified, rapport closed as `.IGNORE.md`. `--snapshot` mode captures `/v1/board`, `/v1/history`, `/v1/architecture` once via `E47_S02`'s data-source resolution (verified actually-driven, not defaulted, via a scratch fixture with distinct board data), then bundles a fully self-contained `jenga.html` (all JS/CSS inlined, `client.js` reads embedded data instead of live `fetch()`) that renders correctly via `file://` with zero network requests — independently confirmed via Playwright. All 4 story Acceptance Criteria and DoD items ticked. **Board-provenance note, resolved:** the developer session that implemented `E47_S04_T01` found no prior git history for `E47_S04`/`E47_S04_T01` and bootstrapped its own copies of the story/task files verbatim from its dispatch content, flagging for scrum-master confirmation that this matched whatever planning session actually produced it (a suspected instance of the known cross-worktree board-visibility gap logged in `project/todo.md`). Confirmed during the merge: a separate, later scrum-master session had independently scaffolded the same story under a different filename (`E47_S04_j-dashboard-skill-launch-and-snapshot-export.md`, listing all three tasks including then-unstarted `T02`/`T03`) — the fuller, later scaffold was kept as canonical and the developer's thinner bootstrap copy was dropped. **`E47_S04_T04` addendum (`data:` URL delivery, `Passed with remarks`):** `--snapshot` only helped when the agent and the user shared a filesystem, so `T04` added a `--data-url` flag to `skills/j-dashboard/scripts/snapshot.sh` that base64-encodes the already-self-contained `jenga.html` into a `data:text/html;base64,...` URI any browser opens directly — no hosting, third-party service, or GitHub round-trip — with an upper size threshold that refuses rather than emitting an unusable URI. The one carried-forward non-blocking remark is documentation only: `CLAUDE.md`'s `j.dashboard` skills-table row still does not mention `--data-url` (`project/rapports/problems/E47_S04_T04-claude-md-data-url-mention-gap.md`). A second rapport recorded a resolved *process* gap — `T04`'s own board file and the story's reopen edit had never been committed to git anywhere, the same class of gap as `E51_S05_T02` (`project/rapports/problems/E47_S04_T04-board-files-never-committed.md`); both files are now tracked. **`Merged` was deliberately not set on `T02`/`T04` during the 2026-09-13 rollup re-verification:** both branches are ancestors of `main`, but `Merged` is script-set by `skills/j-self-sync/scripts/mark-merged.sh` from a `/self-sync` mirror diff and never agent-judged, and mirror state currently contradicts it — `T04`'s `--data-url` code appears 10 times in the root `snapshot.sh` and 0 times in either `.claude/` or `.agents/` copy. Both tickets will flip on the next `/self-sync` run from deterministic evidence.

**E47_S02 (generalize dashboard data-source resolution) shipped 2026-09-11 — `Passed`.** All four data-root call sites the story named (`BOARD_ROOT` in `parsers/board.js`, `REPO_ROOT` in `parsers/git-log.js`, `RAPPORTS_ROOT` in `parsers/rapports.js`, `ROOT` in `parsers/architecture.js`) computed their root via a fixed `path.resolve(__dirname, '../../../...')` climb — the same defect *pattern* `E46_S01` fixed for `/init`, and one that only resolves correctly from this monorepo's own checkout; from inside a real consumer's `node_modules/@jenga-ai/agent/`, that climb lands inside/above `node_modules`, never at the consumer's own root. `E47_S02_T01` added a shared `resolveProjectRoot()` (`project/app/api/lib/resolve-project-root.js`): explicit `JENGA_PROJECT_ROOT` override → `cwd` walk-up for a `project/board` marker (20-level bound) → fail loudly, with `fs.realpathSync` symlink resolution on both paths. `E47_S02_T02` wired all four parsers onto it, pinned `server.js` to resolve the root at load time via the same function (a raw `process.cwd()` literal would have broken self-hosting, since this repo's own `dashboard:start`/`api:start` scripts run with `cwd=project/app`), and added `scripts/verify-consumer-install.sh` — a reproducible 3-scenario harness (self-hosting, symlinked invocation, real `npm pack`/`npm install` consumer simulation) that both the developer and the tester independently ran clean (11/11). Two developer judgment calls, both reviewed and accepted by the tester: (1) a 5th file, `parsers/knowledge-graph.js`, was found with the identical `__dirname`-climb defect (feeding `architecture.js`'s `sad_map` field) and fixed the same way, since leaving it would have kept `/v1/architecture` reading this repo's own data even inside a real consumer install — a same-day/same-pattern extension, not scope creep; (2) `verify-consumer-install.sh`'s real-consumer scenario stands in for `E47_S01` (still `Pending` — the dashboard isn't in the npm `files` list yet) with a documented, scratch-copy-only `package.json` `files` patch, a reasonable simplification rather than scope avoidance. Epic `E47` stays `In Progress` (2026-09-12 rollup check) — `S01`, `S02`, and `S04` are now all `Passed`; only `S03` (`jenga dashboard` CLI subcommand, decomposed into `E47_S03_T01`/`T02` but not yet dispatched) remains `Pending`, and epic rollup is blocked purely on it.

**E47_S03 (`jenga dashboard start`/`open` real CLI subcommands) shipped 2026-09-12 — `Passed`, and epic `E47` rolled up `Passed` the same day.** Both tasks (`E47_S03_T01`, `E47_S03_T02`) complete and merged to `main`; tester-verified via `scripts/verify-consumer-install.sh` (25/25 assertions across Scenarios A–F, including a new Scenario E that drives the installed tarball's own `bin/jenga.js` CLI entry point for `dashboard start`/`dashboard open` end-to-end, not just this monorepo's dev checkout). All story AC/DoD ticked. With `S01`, `S02`, `S03`, and `S04` all `Passed`, epic `E47`'s full Definition of Done is now satisfied — dashboard ships in the npm package, data source resolves against the invoking project, `jenga dashboard start`/`open` exist as real CLI subcommands, and the whole thing is verified end-to-end against a real consumer install simulation. Epic status set to `Passed`, `date_completed` 2026-09-12. This unblocks both `E06_S04` (Board tab collapse/expand) and `E48` (Agent Dashboard — Live AI Item Review), which were explicitly sequenced behind E47's productization per the user's 2026-08-31 brainstorm decision.

## Cloud Storage Connectivity (E60) and Dashboard Snapshot Cloud Sharing (E47_S05)
Filed via `/brainstorm` (2026-09-14), starting from a request to turn
`project/documentation/examples/dashboard-cloud-sharing-google-drive-rclone.md` (a manual, Drive-only
two-step recipe: `j.dashboard --snapshot` then `rclone copyto`, with `rclone link` as a separate,
deliberate share-link step) into a repeatable capability. Extended dialogue narrowed several genuinely
open questions before anything was written to the board:

- **Upload only, no auto-link.** The new dashboard-sharing flow never runs `rclone link` or any other
  share-link-creating command automatically — the source doc treats upload and link-creation as two
  distinct actions with a real permission consequence (a link exposes the entire snapshot to anyone
  with the URL), and that separation is preserved rather than collapsed into one auto-chained step.
- **Split into two skills, not one.** `rclone` install/config/auth is generic infrastructure with no
  dependency on the dashboard; bolting it onto `j-dashboard` would have coupled an external-network,
  third-party-auth concern to what is otherwise a deterministic, self-contained local export. Scoped
  as two skills instead: `j.cloud-connect` (new epic **E60**, generic setup wizard) and
  `j.dashboard-share` (new story **E47_S05** on the existing dashboard epic, thin consumer of it).
- **Real multi-backend support, not Drive-only.** The user confirmed "whatever cloud storages are
  supported by rclone" is the actual target, not a curated subset — this is what pushed the setup
  wizard into its own epic rather than a task bump on the dashboard epic. v1 scope is bounded
  practically: the backend menu is sourced *dynamically* from rclone's own provider list (so
  "supported by rclone" holds by construction, nothing hardcoded to go stale), and the same generic
  config/auth-link/verify flow applies identically to every backend, Drive included — no
  backend-specific hand-built guidance beyond what rclone's own `config create` already provides
  per-backend.
- **Setup is a wizard, not a check-and-bail.** Initial framing was a simple prerequisite check that
  fails fast with a doc pointer; the user pushed back and asked for an actual guided flow instead:
  automated `rclone` binary install (not just detection), a live backend picker, and — critically —
  for the OAuth step specifically, forwarding whatever auth link the backend's config flow produces
  and waiting for the user to confirm completion before verifying (`rclone about <remote>:`), rather
  than just detecting "not configured" and stopping. Note the hard constraint this respects: no agent
  session can complete a browser OAuth consent flow itself, so "automated setup" means automating
  everything *around* that human step, never the consent step itself.
- **Destination path is templated, not hardcoded.** The source doc's example path
  (`gdrive:Skolkartan/snapshots/...`) was project-specific; the generalized upload script builds
  `JengaAI/<repo-directory-name>/<datetime>-board-snapshot.html` instead, sourcing the project-name
  segment from the repository directory name (deterministic, no parsing, immune to a project title
  changing later) rather than any project metadata.

**E60 — Cloud Storage Connectivity** (new epic, `Pending`): one story, `E60_S01` (`j-cloud-connect`
setup wizard), decomposed into three tasks — `T01` automated cross-platform `rclone` install, `T02`
the dynamic backend-selection + unified config/auth-link/verify flow (the core of the wizard), `T03`
the `SKILL.md` wiring the two together. `T02` touches the "auth, secrets, or credentials" heuristic
from the Crucial Level Heuristic Proposal (default tier `gated`) — this was surfaced during breakdown
but not confirmed in-session before the board write, so no `crucial_level` was set on it per the
confirm-before-write gate; it will be re-evaluated fresh on the next breakdown pass over this task.

**E47_S05 — Dashboard snapshot cloud sharing** (new story on existing epic `E47`, `Pending`): two
tasks — `T01` the templated-path `rclone copyto` upload script (depends on `E60_S01` for a configured
remote; points the user at `j.cloud-connect` rather than surfacing a raw `rclone` error if none is
configured), `T02` the `j-dashboard-share` `SKILL.md` wiring `j-dashboard`'s existing
`scripts/snapshot.sh` to `T01`'s upload script. Epic `E47` — previously `Passed with remarks` — is
reopened to `In Progress` for this story; `E47_S01`–`E47_S04` keep their prior terminal statuses
unchanged.

## Agent Dashboard — Live AI Item Review (E48) and Board Tab reopening (E06_S04)
Filed via `/brainstorm` (2026-08-31) as a two-part request. Part one, a collapsible epic→story→task tree in the dashboard's Board tab, is a genuine gap in the already-`Done` E06 epic (`BoardView.jsx` renders a flat, always-expanded list — zero collapse/expand logic in the UI source), so E06 was reopened for a fourth story, **E06_S04**: collapse at both epic→story and story→task levels, default fully collapsed on load, no persistence across reloads. Part two is new capability with no prior epic behind it: **E48** adds a click-to-score AI review of any board item (0–10 integer, no decimals, plus improvement suggestions) computed **live** on every click via a new skill shelled out to from the dashboard API, rather than precomputed by a background job. This breaks E05's original "read-only board parsing" design principle for the API layer, so E48_S02's new endpoint is guarded by a secret token generated at `jenga dashboard start` time (only the dashboard UI can trigger a review), and requires an already-authenticated `claude` CLI on the server's host machine — documented as a known current limitation, not a permanent lock-in. E48_S01 defines the rubric + skill (strict JSON output contract), E48_S03 persists each live result back to the reviewed item's own frontmatter (score + suggestions + timestamp, via `scripts/with-lock.sh`) so the board can passively show a "last reviewed" state, and E48_S04 is the UI (icon, loading state, score badge, suggestions panel, error/retry state). **Both E06_S04 and all of E48 were blocked on E47's Definition of Done; that block cleared 2026-09-12** when E47 rolled up `Passed` (see E47 section above) — productization was explicitly sequenced first by the user, since neither feature was meaningful to an actual npm consumer until the dashboard shipped in the package and resolved data against the consumer's own project rather than this repo's. Both are now eligible for decomposition/dispatch. The 3001→4305 port rename surfaced during the brainstorm has nowhere to live in E47's own stories (none name a specific port), so it is recorded as an explicit assumption in E48's Purpose section instead. Two open items were surfaced to the user during breakdown but not yet confirmed in-session, so no `crucial_level` was written to either story per the confirm-before-write gate: E48_S02 (generates and checks a secret token — touches the "auth, secrets, or credentials" heuristic) and E48_S03 (amends `templates/SCRUM_BOARD_SCHEMA.md` and `scripts/validate-board.sh` — touches the "schema or frontmatter contracts" heuristic). Both will be re-evaluated fresh on the next breakdown pass over these items.

## Board Tab Split — Backlog / Active Sprint (E06_S05) and Deployed-to-Prod Date Field (E51_S05)
Filed via `/todo` (2026-09-12) as step 2 of a `j.brainstorm` → `j.todo` → `j.do` → `j.commit`
playbook run. `E06_S05` (Kanban-Style Status Columns, `Pending`, previously undecomposed) is
amended and decomposed into three tasks: today's "Board" tab is relabeled **"Backlog"**
(`E06_S05_T01`, unfiltered/unchanged, `inline` scope — confirmed via grep to be a single
`label: 'Board'` string in `project/app/ui/src/App.jsx`); the story's original kanban-column layout
moves to a new **"Active Sprint"** tab, filtered to exclude `Pending` items (`E06_S05_T02`, `task`
scope); and a second, independent filter excludes items whose `date_deployed_prod` is more than 10
days old from the Active Sprint view only (`E06_S05_T03`, `task` scope, `depends_on: E51_S05` since
that field doesn't exist yet). `E06_S05` gained `depends_on: E51_S05` at the story level for the
same reason.

`E51_S05` ("Deployed to Stage"/"Deployed to Prod" Consumption) gained a new Acceptance
Criterion in the same session: when its reactive script sets a ticket to `Deployed to Prod`, it
must also write `date_deployed_prod: <ISO 8601 date>` to that ticket's frontmatter in the same
write — including adding the field to `templates/SCRUM_BOARD_SCHEMA.md` and
`scripts/validate-board.sh`'s `ALLOWED_KEYS`. This is the source of `E06_S05`'s new dependency.
Because the change touches the schema/frontmatter-contract heuristic, the user confirmed a
`crucial_level: advisory` tier in-session (`crucial_set_by: user`) — purely additive (new
allow-listed key, no existing validation logic changed), so no escalation to `gated`.

**Update 2026-09-12 (later same day) — decomposed and rolled up `Passed with remarks`:** `E51_S05`
was subsequently decomposed into three tasks (discovery/marker script, ticket-matching/write script
+ schema support, and wiring into `/self-sync`/`/status` + verification) and all three passed
tester verification (`T01`/`T02` clean `Passed`, `T03` `Passed with remarks`). The story rolled up
to `Passed with remarks`: everything works end-to-end against a realistic hand-tagged fixture, but
the one DoD line requiring verification against a **real** public stage/prod tag remains open — no
such tag has been pushed to `jenga-npm` yet, and `E51_S04_T02` (real end-to-end tagging
verification) is still `Pending`. See
`project/rapports/problems/E51_S05_T03-real-tag-verification-still-open.md`. This does not block
`E06_S05_T03`, whose `depends_on: E51_S05` is satisfied by `E51_S05` reaching a terminal status —
`date_deployed_prod` is fully implemented and verified, which is all `E06_S05_T03` consumes.

**`E06_S05` rolled up `Passed` 2026-09-13.** All three tasks (`T01`, `T02`, `T03`) reached terminal
`Passed`. `T03` briefly went `Failed` mid-flight: the tester's first verification pass found
`isStaleDeployedProd()` fail-safe-passing every real `Deployed to Prod` item silently, because
gray-matter/js-yaml parses unquoted `YYYY-MM-DD` frontmatter into a native `Date` object rather than
the plain string the function assumed, so its string-template date reconstruction produced an
unparseable value and fell into the "not stale" fail-safe on every real item (see
`project/rapports/problems/E06_S05_T03-stale-filter-fails-on-real-gray-matter-date-objects.md`). The
developer reworked `isStaleDeployedProd()` to branch on `Date` vs. string input, and the tester
independently re-verified against genuine scratch board fixtures round-tripped through the real
`parseBoard()`/`bucketIntoColumns()` pipeline (not just the developer's hand-constructed fixture
script) before re-passing `T03`. Since the defect was caught and fully resolved pre-merge with no
surviving caveat, the story rolled up to a clean `Passed` rather than `Passed with remarks`. Parent
epic `E06` does not roll up yet — `E06_S04` (Collapsible Epic → Story → Task Tree) is still
`Pending`.

## Knowledge Graph Provenance Gating (E20_S10) and Gated Backlog (E20_S11–E20_S13)
Filed via a `/j-deep-dive` (challenge mode) session on 2026-09-18, triggered by a user critique of
`E08_S05`'s graph-sourcing approach. The diagnosis: `scripts/populate-knowledge-graph.js` hard-codes
`source: 'board'` on every node derived from epics/stories/tasks/dependencies, and nothing downstream
(`parseArchitecture()`, `SADMap.jsx`) filters on that field before rendering — so the dashboard's
Architecture tab actually renders project-management structure (epics → stories → tasks), not a map
of real services, components, and their connections. `project/knowledge-graph/STUB_SCHEMA.md` already
anticipates this: its `source: human | ast | board` provenance field and Evidence-Wins Conflict Rule
were defined for exactly this purpose, just never activated by a consumer-side filter.

The deep-dive's original proposal bundled four stories under a reopened E20. Scrutiny scored it
CAUTIOUS (5/10): Story 1 (provenance gating) was sound and reused an already-anticipated schema
field, but Stories 2-4 were under-specified, and shipping Story 1's filter alone — with nothing else
changed — would regress the Architecture tab to a near-empty, unexplained state (no interim UX was
defined). The solution assessment (verdict CHALLENGING) recommended de-scoping to Story 1 plus two
cheap companion fixes now, holding Stories 2-4 as gated/provisional backlog behind individual
scoping spikes rather than committing all four as one bundle. The user explicitly approved this
narrower option. Full reasoning: `project/documentation/plans/e20-arch-graph-provenance-and-dynamic-tracing.md`,
`scrutiny-e20-arch-graph-provenance-and-dynamic-tracing.md`,
`solution-assessment-e20-arch-graph-provenance-and-dynamic-tracing.md`.

**`E20_S10` (new story, `Pending`, active scope) — Architecture-Map Provenance Gating, Interim UX &
Data-Quality Companions.** Five tasks, all `execution_scope: task` (branching logic disqualifies each
from `inline`): `T01` filters `parseArchitecture()`/`SADMap.jsx` to render only `human`/`ast`-provenance
nodes (`board` nodes stay in `graph.json`, just excluded from architecture rendering); `T02` ships, in
the same change as `T01`, a provenance-coverage indicator and an honest "no verified architecture data
yet" empty state — closing the scrutiny's top-flagged risk of an unexplained near-empty tab; `T03`
handles mixed-provenance edges (a `board` epic node linked to a `human`/`ast` service node) via
node-level filtering with dimmed "ghost" endpoint stubs, preserving board↔architecture traceability
without a schema change; `T04` and `T05` fold in two more solution-assessment-recommended fixes as
their own tasks, since they're small and structurally coupled to the filter rather than independent
scope — a deterministic key-based entity-resolution/merge-on-write policy in
`populate-knowledge-graph.js` (so duplicate nodes across sources merge instead of accumulating), and a
timestamp + content-hash staleness/revalidation badge for non-`board` provenance tiers (closing the
scrutiny's critique that gating on `source` alone relocates, rather than solves, the original
"board data goes stale" defect). No heuristic in the Crucial Level Heuristic Proposal list matched
any of these five tasks (the schema/frontmatter-contract heuristic's examples and rationale are
scoped to the *board* schema/`validate-board.sh`, not `STUB_SCHEMA.md`), so no `crucial_level` was
proposed.

**`E20_S11`/`E20_S12`/`E20_S13` (new stories, `Pending`, gated/provisional backlog — not queued via
`/do`)** capture the deep-dive's original Stories 2-4 without committing to their full scope: static
schema extraction (`E20_S11`, depends on nothing), synthetic fixture generation (`E20_S12`,
`depends_on: E20_S11`), and dynamic tracing (`E20_S13`, `depends_on: E20_S08, E20_S11, E20_S12`).
Each opens with exactly one `[SPIKE]`-tagged, `execution_scope: inline` scoping-spike task (a
findings/design-note doc only, no implementation code) per the solution assessment's own recommended
next steps, rather than being decomposed into full implementation task lists — each story's own
Acceptance Criteria/DoD explicitly state that further tasks wait on the spike's outcome and a human
go/no-go decision. `E20_S11`'s spike targets the scrutiny's flagged gap that Story 2 has no defined
fallback for codebases lacking OpenAPI/DB-migration/schema artifacts. `E20_S13` carries the deep-dive's
single highest-severity open item, called out explicitly in its own Related Work section and DoD as a
hard human gate rather than a note in passing: network-egress sandboxing alone does not cover
DB/disk/local-queue side effects from running real test code against `E20_S12`'s synthetic payloads —
this is **UNRESOLVED** per the solution assessment §5 (not merely a documented risk), and no
instrumentation or trace-execution code may be written until a human explicitly picks between a full
ephemeral sandbox (2-3 weeks, closes the gap) or a cheaper snapshot/restore approach (~1 week, leaves
the local-queue/external-process side-effect class explicitly uncovered).

E20 was never previously completed (`status: Pending` throughout), so this reopening simply appends
`E20_S10`-`E20_S13` to the epic's existing `stories:` list — no `reopened_on`/`dates_previously_completed`
frontmatter was needed (contrast `E08`'s reopening pattern for the consumer-side half of this same
underlying critique). One new epic DoD line was added: architecture-map consumers must render only
provenance-verified nodes, with the interim-UX/edge/entity-resolution/staleness companions `E20_S10`
ships. No implementation was started and no developer handoff was written — this session is board-item
creation only, per explicit instruction.

## Launch & Discoverability (E41)
E26 built the npm distribution pipeline and is marked `Passed`, but `jenga-agent` was never actually published — `npm view jenga-agent` returns 404, so there is no registry page and no download history. Every discovery-driving field is simultaneously empty or wrong: `package.json` carries `keywords: []`, `author: ""`, and no `repository`, `homepage`, `bugs`, or `engines`; the description contains none of the terms the target audience searches for; and the public-facing `samwelmunga/jenga-npm` repo has an empty description, zero topics, and no homepage, while the richer `samwelmunga/Jenga AI` repo is private. E41 fixes the whole in-our-control discovery surface and ships the first public release at **v1.1.0**. Keywords are deliberately broad rather than brand-led — `npm search jenga` is already contested by an unrelated z-index library and Equity Bank's payments API, and nobody searches the brand yet — spanning generic agentic terms, multi-vendor ecosystem terms (`claude-code`, `copilot`, `codex`, `agents-md`), and category terms (`scrum`, `project-management`). The multi-vendor claim is grounded in real architecture: `postinstall.js` mirrors `skills/` and `agents/` into both `.claude/` and `.agents/`, and `lib/commands/init.js` already generates `.github/copilot-instructions.md`. One gap is closed first, and it turned out to be a `/init` setup miss rather than a Codex-only one: `/init` scaffolds no root-level agent context file at all — Copilot alone gets a pointer via `.github/copilot-instructions.md`, while Claude Code and Codex receive a fully populated framework their agents cannot see. S04 makes `/init` generate `CLAUDE.md` and `AGENTS.md` from a single source template (this repo's own `CLAUDE.md` and `AGENT.md` have already drifted by one skills-table row, so two hand-maintained copies is a proven failure mode), writes the Jenga copy as `J-<NAME>.md` with a reference inserted into the user's existing file when one is already present, and adds `codex` to the `agentTarget` enum — so no shipped keyword outruns the implementation. S05 gates on S01–S04 and publishes; S06 tracks off-npm channels while stating plainly that npm ranking is driven by download volume that only off-registry attention produces. Separately flagged for `/reconcile`: E16 is marked `Done` with every DoD checkbox unticked despite the work appearing implemented — since resolved by the 2026-09-07 reopening below, which also added a new DoD line rather than only reticking the old ones, so the checkbox/implementation gap this flag pointed at is now folded into E16's own tracked scope instead of living only in this paragraph.

**E16 reopened for sub-agent delegation parity (2026-09-07).** Filed via `/error` + `/todo`. `templates/copilot-instructions.md.tpl` documents Copilot's discovery of `.github/skills/` / `.agents/skills/` / `.claude/skills/` (E16_S02, `Done`), but never mentions the `agents/*.md` sub-agent personas or explains a skill's `metadata.prefered_agent` frontmatter field — the parallel piece Claude Code gets natively via root `CLAUDE.md`'s "Skill Frontmatter" section. `skills/self-sync/scripts/run.js`'s copy-set mirrors `agents/` into `.claude/` and `.agents/` but never into `.github/`. New story **E16_S05** (`Copilot Sub-Agent Delegation Parity`) closes this: `E16_S05_T01` empirically verifies whether Copilot CLI has any native custom-agent-loading mechanism (undetermined as of filing — deliberately left open rather than guessed at during breakdown); `E16_S05_T02` implements whichever path that finding points to (a real `.github/agents/`-style mirror via the self-sync copy-set, or a documented prose convention in `copilot-instructions.md.tpl`, mirroring the existing `j.skill-name` routing-table precedent). `E16_S05_T01` merged 2026-09-07 (`Passed`, later `Merged` post-self-sync) — Copilot CLI does have a native custom-agent-loading mechanism (`--agent`/`/agent`, `.github/agents/` and `.claude/agents/` are both live discovery paths, `.agents/agents/` is not), so `E16_S05_T02` took the native-integration path: it wired a narrower `GITHUB_COPY_SET = ['agents']` mirror into `skills/self-sync/scripts/run.js` (a new `.github/agents/` target alongside the existing `.claude/`/`.agents/` mirrors) and added a "Sub-Agent Delegation (`prefered_agent`)" section to `templates/copilot-instructions.md.tpl` mirroring `CLAUDE.md`'s "Skill Frontmatter" section. `E16_S05_T02` verified `Passed` 2026-09-07 and the story rolled up to `Passed` the same day.

**E16_S04 reopened — dual-write silently reverted by E26 (found via `/reconcile`, 2026-09-07).** `E16_S04` (`jenga attach` writing `mcpServers.jenga` into both `.claude/settings.json` and `.agents/settings.json`) was `Done`/`Passed` since 2026-07-11, but commit `619198b` (E26, 2026-08-04) deliberately dropped the `.agents/settings.json` half of that write from `lib/commands/attach.js` as "redundant" — current `attach.js` only writes `.claude/settings.json`, and `project/documentation/examples/jenga-mcp-and-cli.md` still describes the dual-write as live. By explicit human decision, `E16_S04_T01`–`T03` keep their original `Passed` status (this is a documented, deliberate revert, not an oversight to silently re-fix); new task **`E16_S04_T04`** corrects the stale docs and records the decision trail, and reopens the story to `In Progress` since it now has real unfinished work. `T04` also carries an open, deliberately unresolved question — should the dual-write return, or should this story be formally closed as superseded by E26 — for a human to decide later.

## Jenga Natural-Language Dispatcher & Playbooks (E53) — Playbooks v2 reopening
E53 shipped `Passed with remarks` on 2026-09-08 (S01: `/jenga`'s NL fallback branch absorbing
`/route`'s matching; S02: multi-skill playbook proposals with a JSON-file playbook catalog,
`match-playbook.sh`, an editable confirmation renderer, and a halt-on-failure sequential runner).
A `/deep-dive` on a `/improve` request against README's Skills section surfaced a much larger
underlying feature gap — per-step parameters, a shared type registry, conditionals, and
playbook-to-playbook composition — captured in
`project/documentation/plans/e53-playbooks-v2-extension-plan.md` (locked design),
`scrutiny-e53-playbooks-v2-extension.md` (verdict: CAUTIOUS, 6/10 feasibility — two real
design-level blockers), and `solution-assessment-e53-playbooks-v2-extension.md` (verdict:
CHALLENGING, 4-6 weeks realistic). E53 was reopened (`dates_previously_completed: 2026-09-08`,
`reopened_on: 2026-09-09`) for five new stories, committed via `/todo` on the user's explicit
sign-off of the locked design:

- **E53_S03** — Type registry, `StepObject` schema (`skill`/`playbook`/`instruction`/
  `forward_from`/`resolve`, plus a reserved `version` field), and load-time validation.
  Implements the deep-dive's **Blocker 1 resolution**: `{when, type}` predicates for
  classifier-script skills (`j.jenga`) are redefined as a purely *structural*, load-time-only
  check — "does this step have `forward_from`, and does its source's declared type guarantee
  non-empty output" — never a claim about `j.jenga`'s actual runtime classification, which
  `detect-nl-intent.sh` still resolves at real invocation time, unchanged. Initial `output_types`
  adoption is deliberately partial: `j.status`, `j.uncharted`, `j.jenga`, `j.reconcile` only.
- **E53_S04** — Conditional step execution, reusing the same typed-output capture
  `forward_from` already needs (no second data-capture mechanism). Introduces a `skipped` status
  scoped strictly to playbook-step context (never written to task/story board status, no change
  to `templates/SCRUM_BOARD_SCHEMA.md`'s Status Values table), gated on an explicit
  rollup-consumer audit. Also defines artifact persistence/retention (reusing `events.json`-style
  conventions with redaction).
- **E53_S05** — Playbook-to-playbook composition (`{playbook: "id"}` step type, cycle detection,
  configurable depth limit defaulting to 3, transparent cross-boundary data-flow, and a
  nesting-**preserving** confirmation display rather than a flat undifferentiated list).
- **E53_S06** — `resolve` scoped explicitly to reshape/filter/type-bridge only (documented as a
  named, scoped exception to "Scripts Over Inline Logic"), hard-fail-on-unresolvable-transform,
  and the new `j.playbook <id>` direct-invocation skill with structured load-time-failure
  reasons (not a generic "not found").
- **E53_S07** — **Deliberately split out**, per explicit user requirement, from S06:
  confirmation-driven `resolve` (pre-authorizing a downstream confirmation gate) implementing the
  solution assessment's Problem 3 Solution B. This directly touches Jenga's interactive-by-default
  human-in-the-loop safety model (scrutiny's Assumption 3, Key Question 1, and its one
  High-severity risk entry) — the story's first Acceptance Criterion is a hard gate: no
  implementation begins until a dedicated safety review's outcome is recorded on the story file
  itself. Filed now only so the reasoning isn't lost before that review happens.

**Triage-first, per the solution assessment's Problem 13 (near-zero cost, may reshape scope):**
new trivial task `E53_S02_T05` (added directly to the already-`Passed with remarks` E53_S02,
`execution_scope: inline`) classifies E53_S02's own two open remarks before S03-S07 start:
(1) `E53_S01_T02`'s YAML folded/literal block-scalar parsing bug in `load-nl-catalog.js`
(`project/rapports/problems/E53_S01_T02-yaml-folded-scalar-description-gap.md`) is **orthogonal**
to Playbooks v2 (single-skill NL catalog parsing, not schema/conditional/composition/resolve
work) — the task files a new small Maintenance (E42) task for it rather than folding it in here;
(2) `E53_S02_T02`'s remark that `match-playbook.sh`'s `ambiguous` multi-way-tie path was only
exercised against scratch data (the catalog holds one playbook) is expected to resolve
**organically** once `E53_S05` lands a real second playbook — no new task filed for it, only a
cross-reference note already written into `E53_S05`'s own Definition of Done.

**Explicitly out of scope, already tracked elsewhere, no board items created:** multi-source
`resolve` (logged in `project/ideas.md`) and the post-output intercept/countdown mechanic (was
board stub `E44_S04` — rejected 2026-09-11 after its own dedicated `/brainstorm` found the
live-countdown-with-inline-edit mechanism unbuildable in this agentic tool-calling environment; see
the story file's Resolution section for the reasoning and disposition for any future variant).

**Epic closed 2026-09-10 — rolled up to `Passed with remarks`.** All 7 stories reached a terminal
state (S01/S02 `Passed with remarks`, S03-S06 `Passed`, S07 `Rejected` as a deliberate,
non-failure safety-review outcome — its own DoD explicitly names `Rejected` as a valid closure,
not a failure to reach `Passed`). `Passed with remarks` was chosen at the epic level to carry that
mixed-but-fully-resolved picture forward rather than either burying S07's decision under a plain
`Passed` or misrepresenting a fully-delivered epic as unfinished; full reasoning recorded in the
epic file's own "Rollup Notes" section (`project/board/epics/E53_jenga-nl-dispatcher-and-playbooks.md`).
All six "Playbooks v2 extension" DoD lines plus all six original DoD lines are now ticked, verified
against each story's own Definition of Done and the tester rollup-trigger messages already in
`project/queue/scrum_triggers.jsonl` — except `E53_S02`, which has no Definition of Done section
at all (see the Known Gaps entry on pre-existing stories missing this section) and was instead
verified via its own "Remarks Triage" section's live re-run of `match-playbook.sh` against the
real catalog, plus three independently-tested downstream stories (S03/S05/S06) explicitly
describing themselves as extending "E53_S02's shipped playbook mechanism."

**Mechanics note:** per `/todo`'s normal (non-`--trivial`) flow, only story-level board files were
written for S03-S07 — task-level decomposition is deferred to `/do`'s own breakdown pass when each
story is picked up. No `crucial_level` was proposed for any of the five new stories: none of them
touch the four fixed heuristics in `agents/scrum-master.md`'s Crucial Level Heuristic Proposal
(auth/secrets, `templates/SCRUM_BOARD_SCHEMA.md`/`scripts/validate-board.sh`, production config,
public-facing distribution) even though `E53_S07` is substantively the highest-risk item in this
batch — its risk is instead controlled narratively, via the hard safety-review gate written into
its own first Acceptance Criterion.

**`/route` retired (E53_S13, 2026-09-27, `Passed with remarks`).** `skills/j-route/` is deleted outright (hard break, no shim). `/jenga`'s Skill Matching & Invocation Contract is now the sole owner of the matching logic, which ends the hand-synced jenga/route duplication caveat from the 2026-09-26 `j.error` resolution (earlier references in this summary to `/route`'s matching are historical). `/route`'s board+docs enrichment survives as the opt-in `--enrich` flag on `/jenga`'s natural-language branch, implemented by `skills/jenga/scripts/enrich-nl-prompt.sh`. Two non-blocking, pre-existing/environmental findings are recorded in `project/rapports/problems/E53_S13-preexisting-validate-board-and-mirror-dryrun-remarks.md`.

## Skill Namespace Prefix & Anti-Masquerading Allow-List (E50)
The canonical skill-namespace separator changed from `j:` (colon, E50_S01) to `j.` (dot, E50_S07_T01): every `skills/*/SKILL.md` frontmatter now reads `name: j.<name>` (twins: `j.j-<name>`). Reason: GitHub Copilot CLI validates the frontmatter `name` *value* and rejects any character outside `[A-Za-z0-9]`, hyphen, underscore, dot, space — the colon made all 82 skills fail to load there, a total Copilot outage. **Both of the two claims this paragraph originally closed with were reversed by the 2026-09-09 reopening of E50 and are no longer true.** (1) Directory names are *not* unchanged: the canonical directory is now `skills/j-<name>/`, and the 40 bare directories are deleted by `E50_S15`. (2) The bare `/<name>` form is *not* a permanent, never-deprecated alias: it **hard-breaks** — no redirect, no alias, no deprecation shim. The canonical frontmatter value stays `name: j.<name>` on the surviving twin (**not** `j.j-<name>`), and the surviving invocation forms are `j.<name>` and `/j-<name>`. **The authoritative contract is `project/documentation/skill-authoring.md` → "The Canonical Naming Contract"** — read it there rather than trusting any restatement here or in `CLAUDE.md`, both of which have now drifted once. `E50_S11`–`E50_S18` implement against that contract; `E50_S18` owns proving this summary and the shipped behaviour agree at cutover. (Corrected 2026-09-09 by scrum-master from a developer proposal queued during `E50_S10_T01`; the developer correctly refused to edit this scrum-master-owned file directly.)

**Coupling to sweep on any future separator change.** The `j` prefix separator is consumed by at least four normalizers, not just the two generator scripts: `scripts/apply-j-prefix.sh`, `scripts/generate-j-alias.sh`, `lib/generate-skill-allow-list.js` (E50_S02 anti-masquerading allow-list), and `mcp/router/skill-index.js` — plus `tests/generate-j-alias.bats`, which asserts the emitted value. `lib/generate-skill-allow-list.js` silently populated the security allow-list with prefixed identifiers when its `/^j:/i` regex stopped matching the new `j.` form; fixed to `/^j[.:]/i` (accepts both separators — the policy choice for that file).

**Correction (2026-09-06) — the router bug is wider than first logged.** An earlier same-session note understated the `mcp/router/` gap as matching `lib/generate-skill-allow-list.js`'s one-line regex bug. Tester re-verification (rapport `project/rapports/problems/E50_S07_T01-router-guard-fail-open.md`) found `mcp/router/index.js:110` gates the *entire* E50_S02 anti-masquerading guard block on `text.startsWith('j:')`, so a `j.`-prefixed prompt — the canonical form after E50_S07_T01 — never reaches `checkAllowList` at all: `j:notaskill` is caught as unrecognized, `j.notaskill` is not. `mcp/router/skill-index.js:90` additionally makes `index.js:186` emit a doubled, wrong-separator `j:j.status`. Five call sites total, not one line. Owned by `E50_S07_T02`, whose AC as originally written ("`mcp/router/` matches and emits the `j.` form") is satisfiable while still shipping the fail-open — policy point recorded for whoever picks up `E50_S07_T02`: match `lib/`'s `/^j[.:]/i` (accept both separators) rather than a straight `:`→`.` swap, or the legacy `j:` form becomes the new unguarded one.

## /uncharted — Investigative Workflow for Foreign & Pre-Existing Code (E40)
A shared investigative engine (`skills/uncharted/`) produces a consistent understanding document (purpose, structure, dependencies, tests, risk areas) for code with no Jenga board provenance, across three scale modes: `segment` (a specific foreign or in-repo file/dir/feature — analyzed, then board-integrated via the normal epic/story/task path), `import` (an external source not yet in the repo — pulled in, then handed to `segment` mode), and `onboard` (an entire pre-existing codebase at framework-adoption time — the common real-world case, since `/init` currently has zero handling for a non-empty existing repo). `onboard` mode is deliberately **board-level only**: a coarse-first, explicitly capped pass produces backfilled epics tagged `provenance: backfilled`, populates `PROJECT_SUMMARY.md` for a project that previously had a stub, and never modifies, moves, or restructures the consumer's actual application code — Jenga's board/skills live alongside the app, so the app itself never needs to conform to Jenga conventions. `/uncharted` hooks into `/init` (existing-codebase detection) and `/reconcile` (unlinked-code detection) in addition to manual invocation.


**Acquisition contract (E40_S03_T01), which E40_S03_T02 and T03 both depend on.** `skills/uncharted/scripts/import-source.sh` stages an external source — git URL, external local path, or pasted snippet — into a `mktemp -d` staging root **outside every git working tree**, with content at `<staging>/source`, and emits a JSON summary (`source_type`, `source`, `staging_path`, `content_path`, `file_count`, `total_size_bytes`, `total_size_human`, `symlink_count`, `git_ref`). It never places, prompts, or analyses — those are T02's and T03's jobs. The acquired tree is treated as hostile and is never executed, sourced, built, or installed: `--depth 1` clone with `core.hooksPath=/dev/null`, `protocol.ext.allow=never`, `GIT_TERMINAL_PROMPT=0`, and no submodule recursion; `.git` is deleted post-acquisition; staged files are `chmod a-x`; and source paths are canonicalised (symlinks and `..` resolved) then refused if git reports them inside any working tree.

**Build state as of 2026-08-26 — epic complete.** All five stories are terminal and the epic rolled up to `Passed with remarks`: S01 (shared engine), S02 (`segment` mode), S03 (`import` mode), S04 (`onboard` mode), and S05 (`/init`/`/reconcile` hooks + skill-table registration) all closed `Passed with remarks` — none cleanly `Passed`, none broken. `import` and `onboard` modes and the `/init` + `/reconcile` hooks are now built; every task under E40 is terminal-pass. See each story file's own Rollup Note for its specific carry-forward remarks (S01: T01/T03/T04 rapports; S02: T01/T02/T03 rapports plus the unfiled out-of-repo Board Linkage defect below; S03: `E40_S03_T01-cwd-derived-own-repo-roots.md`; S05: two `/reconcile`-detection rapports plus the registered-before-runnable note below). The skill inventory line in *Architecture & Structure* now advertises `/uncharted` as available — the hold requested on 2026-08-25 was pending exactly this landing. `/uncharted` is registered in the `CLAUDE.md` and `README.md` skill tables (E40_S05_T03), which the tester flagged as registered-before-runnable in `project/rapports/problems/E40_S05_T03-uncharted-registered-before-runnable.md` — that gap is now closed since the epic itself is runnable.
## Crucial Flag — Tiered Item-Level Caution & Escalation (E39)
A `crucial_level` frontmatter field (`advisory` | `gated` | `locked`) on stories/tasks gives per-item risk signaling orthogonal to E33's session-level permission tiers. `advisory` raises rapport reporting cadence; `gated` requires explicit confirmation before a defined risky-action list (deletes, pushes, secrets, schema changes) regardless of session permission level; `locked` force-sets `execution_scope: inline` (E32) so the item can only run in the current foreground session — the only place a live pause-and-confirm is architecturally possible, since backgrounded subagents (spawned via the Agent tool) run to completion and cannot interrupt the user mid-run. The flag can be set directly by the user, proposed by scrum-master heuristically during breakdown (requires explicit human confirmation, mirroring `epic_scope_approval`), or requested mid-task by developer/tester via a new `crucial_escalation` rapport routed through the existing `on_session_end.sh` → `scrum_triggers.jsonl` queue — not a new synchronous interrupt, which E37 already ruled out as a footgun (ad-hoc polling loops).

## Scenario Library & Comparison Playground (E38)
Onboarding docs currently show only single-skill examples and one thin multi-skill README sequence, with no real evidence backing the framework's "Problem It Solves" claims. E38 builds a habit-tracker playground (reusing the domain already used illustratively in `documentation.md`'s `/pi-plan` example) twice — once via Jenga AI, once via a raw AI agent session — as the basis for a growing `project/.wiki/scenarios/` library of real, captured workflow transcripts, framed explicitly as illustrative comparisons (not a fair benchmark, since single-sitting runs can't demonstrate Jenga AI's inherently multi-session claims) and scoped to Claude Code only for v1. Scope discipline is enforced via a pilot spike (S03) that measures real per-scenario authoring cost before capping the v1 scenario list, and a hash-pinned staleness detector (S04, wired into the existing `SessionEnd` → `scrum_triggers.jsonl` pattern via a new `scenario_staleness_review` trigger) prevents the scenario library from silently drifting the way the two `documentation.md` copies already had. That drift was a real bug discovered during scoping: `project/.wiki/documentation.md` (linked from `README.md`'s own header as the "Full reference" doc) and `project/documentation/documentation.md` had already diverged; S01 consolidates them onto the `.wiki` copy as canonical, and S06 replaces README's inline scenario section with a teaser linking into the scenario library. E38 does not wait on the in-progress E28 (Public Mirror) epic — the manual redaction-review checkpoint only applies at the eventual `/mirror-public` step.

## Adaptive Execution Scope (E32)
Tasks carry two new frontmatter fields assigned by the scrum-master at breakdown: `execution_scope` (`task` | `story` | `inline` | `epic`) and `needs_docs` (boolean). These fields allow `/jenga` and `/do` to right-size execution footprint — routing tiny self-contained changes to `inline` (main-session, no subagent), bundling related tasks into a single developer context for `story` scope, and keeping full isolation for `task` scope. Thresholds (1-file/20-line for inline, 5-file for story) are stored in `project/configs/scope-thresholds.json` and read at runtime by both skills. `epic` scope requires explicit human approval (`epic_scope_approval: true`) and is never assigned autonomously by the scrum-master. Additional required fields: `scope_rationale` (measurable criterion), `jenga_assigned` (machine vs human assignment), and `override_justification` (required when `jenga_assigned: false`).

## Inter-Agent Completion Signaling & Worktree Lifecycle Safety (E37)
Two incidents (a `.session_handoff.json` clobbering race and an orphaned ad-hoc polling loop that survived a worktree removal) exposed the same root cause: the workflow has no single, deterministic, race-free way for one agent/session to know another is done. E37 fixes this with a "deterministic over instructional" bias throughout: (S01) the single-slot `project/queue/.session_handoff.json` becomes per-session files under `project/queue/handoffs/`, `hooks/on_session_end.sh` consumes all pending files instead of one fixed path, and the previously advisory `.lock`-file board-write convention in `templates/SCRUM_BOARD_SCHEMA.md` is replaced by an atomic, cross-platform `scripts/with-lock.sh` (portable — not a bare `flock` call, since macOS/BSD lacks it); (S02) a `pre-commit` git hook is installed automatically into every worktree at creation time (via `WorktreeCreate`) to structurally block tester commits landing on any branch but the one being verified, paired with an explicit, doc-only prohibition in `agents/developer.md`/`agents/tester.md` against ad-hoc shell polling loops as a completion signal (this one piece is irreducibly instructional — its backstop is S03); (S03) the `WorktreeRemove` hook gains a hard-block-by-default liveness precondition (`scripts/check-worktree-liveness.sh`, process-cwd based, since `ListAgents` only sees agent lifecycle and not detached shell processes an agent may leave behind) with a named override flag (`--force-ignore-liveness`) for deliberate bypass.


**Live evidence from the E40 orchestration waves (2026-08-25).** The single-slot race S01 predicts was observed twice, in both of its forms. (a) *In-session collision:* during E40_S01_T01 the tester ran in-session and wrote its `passed_with_remarks` verdict to `project/queue/.session_handoff.json`; the developer's mandated handoff would then have overwritten it, destroying the verdict and enqueuing a redundant `test_assignment` for already-verified work. (b) *Concurrent-dispatch collision:* `/jenga` runs multiple developer+tester pairs at once, and during wave 1 the same fixed path held E40_S01_T02's tester handoff while E40_S03_T01 was also completing — last writer wins, `on_session_end.sh` routes only that one task to the scrum queue, and every other pending handoff is lost silently with no error. Both were worked around by writing to `project/queue/handoffs/<agent>-<session>-<task>.json`, which the current `hooks/on_session_end.sh` does not read (it consumes only the fixed path) — so the workaround trades a silent overwrite for a silent no-op. This confirms both halves of E37_S01 are required together: per-session handoff files **and** the hook change to consume them. It also reprices the defect: because developer/tester in-session invocation and concurrent `/jenga` dispatch are both routine, this collision is the normal case, not a rare one. A fourth manifestation surfaced during E40_S04_T06: the tester wrote its verdict directly to main outside a worktree while the developer's own worktree branch independently appended a `sender_received` event to the same `project/logs/events.json`; both sides routed their handoffs to `project/queue/handoffs/<role>-<session>.json` to avoid clobbering an already-unconsumed E40_S05_T02 handoff sitting in the single-slot file, and the developer had to hand-reconcile the two independent `events.json` edits into one ordered array during the merge rather than the merge silently picking a side. This is a same-file-different-branch content race on `events.json` itself, distinct from the `.session_handoff.json` case S01 is scoped to — worth confirming S01's fix (or a follow-up) also covers append-only logs edited concurrently on unmerged branches, not just the handoff file.

**Further corroboration (2026-08-26/27), queued via `project_summary_updates.jsonl` and folded in at the 2026-08-27 E39_S02 rollup session.** Two more independent incidents reinforce the same diagnosis. (1) While validating E37_S04_T01, the tester found `project/logs/events.json` in a corrupted mixed-format state (a JSON array with raw JSONL text appended after the closing bracket) caused by a concurrent-write race, and separately recovered one of its own events silently lost to a concurrent overwrite in the same window — both repaired in place; a live example to reference when scoping remaining E37 work on concurrent-write safety for shared log/queue files. (2) During E39_S02_T03, the tester wrote its verdict to the single-slot `project/queue/.session_handoff.json`; the developer's own mandatory session-end handoff for the same task would then have overwritten it, destroying the unconsumed verdict before scrum-master could route it to a story_rollup check — the same in-session collision shape already documented above. Worked around, as with E40 and E39_S02_T02/E42_S02_T02 earlier in the same session, by writing to `project/queue/handoffs/developer-jenga-e39s02-20260827-E39_S02_T03.json` instead of the single slot, leaving the tester's verdict untouched. This is a fifth corroborating occurrence of the same root cause; no new board item needed, cite alongside the existing E40-wave evidence when E37_S01 is picked up.

**Sixth corroborating near-miss (2026-09-11, developer, queued via `project_summary_updates.jsonl`).** During `E20_S09_T02`, the tester's mid-write re-verification commit inside worktree `.claude/worktrees/E20_S09_T02-board-graph-populator` raced a concurrent merge-and-remove of that same worktree (apparently the tester itself finalizing `Passed`), orphaning the in-flight commit off the deleted branch. Reconciled losslessly this time — `main`'s `e5ef374` turned out byte-identical to the orphaned commit — but the hazard (concurrent read/write vs. merge/remove on the same worktree path, no lock) is squarely E37's subject matter and is distinct from the already-documented worktree-removal liveness check (`E37_S03`, which guards orphaned polling against an *already-removed* worktree, not a removal racing a still-in-flight write). Filed here as a concrete repro case for E37's eventual worktree-lifecycle-safety design; no new task created — fold in when that design work is picked up.

**Reopened (2026-08-29) — E37_S05.** Epic had rolled up to `Passed with remarks` on 2026-08-27; reopened via `/btw` for a fifth story, same "deterministic over instructional" bias as S01–S04 but targeting a different completion-path gap: `/do`'s step-7 `todo_manager.sh` cleanup (removing a finished task from `project/todo.md`, tearing the file down when empty) only runs inside `/do`'s own session loop. `/jenga` Phase 4 dispatches developer agents directly as background sub-agents without routing through that loop, so completed tasks can sit stale in `todo.md` indefinitely. Confirmed live during the 2026-08-29 `/jenga` run on `E41_S04_T03`/`E41_S02_T02` — both merged and marked `Passed` on the board, but both stayed listed in `todo.md` until the orchestrating session caught it manually during queue drain. S05 extracts the cleanup into a reusable procedure invokable from any execution-loop skill (`/do`, `/jenga`, `/dooo`, and `/do`'s story-bundle path), not just `/do`'s own loop.

**Known gap flagged for E37_S04 (2026-08-26, tester, queued):** Story DoD item 4 ("`templates/SCRUM_BOARD_SCHEMA.md`'s Queue Trigger Types section reflects that `scrum_triggers.jsonl` may now be drained mid-session by `/jenga`") has no task assigned under the story's current tasks list — only E37_S04_T01 (drain-procedure extraction) and E37_S04_T02 (`/jenga` Phase 4 wiring) exist. Needs either a third task (e.g. `E37_S04_T03`) to update `SCRUM_BOARD_SCHEMA.md`, or an explicit scope-fold into T02, before the story can close. Not actioned here (out of scope for this session's E39_S02 rollup) — flagged for the next planning pass that picks up E37_S04.

**E37_S01 progress (2026-08-27, folded in at this session's queue processing).** T01 landed (Passed with remarks): the write-side per-session handoff convention is now defined precisely as `project/queue/handoffs/<agent>-<session_id>-<task_id>.json` (`session_id` alone is already collision-free; `task_id` is appended for human debuggability), documented across `agents/scrum-master.md`/`agents/developer.md`/`agents/tester.md` and `templates/SCRUM_BOARD_SCHEMA.md`. `hooks/on_session_end.sh` was intentionally left unchanged by T01 (a short, sanctioned coordination gap — handoffs land in the new directory but aren't yet auto-routed — until the sibling T02 lands to consume it). T03 then landed `scripts/with-lock.sh` (`mkdir`-based atomic exclusive lock, portable to macOS since `flock` is Linux-only) and rewired `agents/scrum-master.md`, `agents/tester.md`, and `templates/SCRUM_BOARD_SCHEMA.md`'s File Locking section onto it. Independent tester re-verification of T03 held up rigorously under 8-way and 6-way concurrent-load stress tests (zero mutual-exclusion violations, including racing to reclaim a pre-existing stale lock), with one disclosed, self-healing gap: a direct `SIGTERM`/`SIGINT` to the `with-lock.sh` PID (not its process group) doesn't release the lock promptly as the script's header/dev notes claim — bash defers non-`EXIT` traps while waiting on a foreground child — though the 60s stale-lock reclamation means this never causes a silent overwrite or permanent deadlock (see `project/rapports/problems/E37_S01_T03-signal-release-deferred.md`). Two follow-up gaps noted, both left for a future small task rather than actioned now: (a) `agents/developer.md` still carries a stale, duplicate copy of the old manual `.lock`-file protocol under its own "Scrum Board Concurrency Control" heading, even though the developer agent never itself writes board-file statuses — should be retired or pointed at `scripts/with-lock.sh`; (b) `project/logs/events.json` has no lock protocol at all (unlike board files), and was found corrupted mid-session by concurrent unlocked writers on two separate occasions now (repaired in place both times) — this is already the exact scope of `E37_S01_T04` (status `Running`), which wraps `events.json`'s read-modify-write in `scripts/with-lock.sh` and fixes the shared, non-unique `/tmp/events_tmp.json` temp path, so no new task was filed for it.
## Permission Level System (E33)
`settings.json`'s `permissions` block gets a 5-tier session-switchable system: Locked (1) → Guarded (2, the permanent default) → Standard (3) → Elevated (4) → Unrestricted (5). Two fields vary by level — `permissions.deny` and `autoMode.allow`; `defaultMode` stays `acceptEdits` and `permissions.allow` stays `["Bash(*)"]` at every level, and root `settings.json` matches `level-2-guarded.json` exactly. `autoMode.allow` is `["$defaults"]` at levels 1-3 and additionally carries `Bash(bash skills/mirror-public/scripts/mirror.sh*)` at levels 4-5, gated there because `permissions.deny` matches the command string the agent invokes and not what that command spawns in a subprocess: `mirror.sh` internally runs `git reset --hard` and `git push` against the public repo, so auto-approving it by name at levels 1-3 would grant an unprompted public push those levels explicitly deny, and level 4 is the first tier permitting `git push *` directly and therefore the first where auto-approving it is coherent. Every template carries an explicit `autoMode` key — including the `$defaults`-only ones — because a level switch is a whole-file overwrite that silently drops destination keys absent from the template. `sudo`, `su`, `dd`, `mkfs`, `shred`, and `truncate` are denied at every level, including 5. Canonical templates live in `templates/permission-levels/`; `/jenga-permission-level [1-5]` switches the current session by copying the matching template into `.claude/settings.json` and `.agents/settings.json` and recording the level in `.jenga-permission-level.json`. The scrum-master resets an elevated session back to Guarded at the start of every session it starts (known gap: sessions started directly via developer/tester bypass this reset — tracked in E33_S03). Skills may declare a minimum required level in frontmatter and gate via `scripts/check-permission-level.sh`, which requires explicit user confirmation to elevate and resets immediately after the skill finishes.

**Two-gate pattern for `crucial_level: gated` git-push tasks (2026-09-12, confirmed during `E29_S05_T02`).** A `gated`-tier item's chat confirmation (`agents/developer.md`) and this permission-level system's own deny rules (`.jenga-permission-level.json` / `settings.json`) are two separate mechanisms — the user's explicit in-chat approval of a gated action does **not** itself unblock a hard `Bash(git push *)` deny rule at `session_level 2` (Guarded). `E29_S05_T02` needed a second, distinct user action (`/jenga-permission-level 5`) before the already-approved push to the public `jenga-npm` repo could actually execute. Future gated tasks that push against a Guarded-or-lower session should expect this two-step pattern (chat confirmation, then a separate permission-level elevation) and flag it early rather than assuming chat confirmation alone suffices.

**Gated-tier chat confirmation vs. the harness's own deny rules are two separate mechanisms** (surfaced by the developer during `E29_S05`, 2026-09-12): a user's explicit chat confirmation for a `crucial_level: gated` action (per `agents/developer.md`) does not itself unblock a hard `Bash(git push *)` deny rule at session level 2 (Guarded) — that requires a second, distinct user action (`/jenga-permission-level [3-5]`) before the command can actually run. `E29_S05_T02` needed a real `git push` to the public `jenga-npm` repo and hit exactly this: the user confirmed the gated action in chat, but the push still didn't execute until the session was separately elevated. Future gated tasks involving `git push` (or any other harness-denied command) against a Guarded-or-lower session should expect this two-step pattern and flag it early rather than assuming chat confirmation alone suffices.

## Testing & Tooling
- **Test-surface constraints (measured 2026-10-05).** (1) `mirror.sh`'s `check_test_subject_invariant` runs the entire shipping bats suite serially once per real-push case; at 83 shipping files one pass costs 549s on an idle machine, and `tests/` grew from 43 to 92 `.bats` files between 2026-09-26 and 2026-10-05, so the cost grows with every test file added anywhere. (2) `bats -j` does not work on this machine: bats 1.14.0 delegates `-j` to GNU parallel, which is not installed, so `bats -j 4 <file>` runs zero tests (it exits 1, failing closed). `npm test` is a single serial `bats tests/*.bats`; no sharding or parallel-bats guidance exists in `agents/tester.md`, `scripts/`, or `project/configs/`.
- **Tooling hazard — `j.self-sync` bundled side effects (found in E53_S13_T02, 2026-09-27).** `node skills/j-self-sync/scripts/run.js`, even for a narrow resync, also runs the bundled `mark-merged.sh`/`mark-deployed.sh` subsystems. These write board-file `status` fields (it flipped several unrelated tasks/stories to `Merged`) and `project/data/deploy-reconcile-marker.json`, and make live `git ls-remote`/fetch calls against the public mirror. Developer-agent sessions must never write board status, so check `git status` for unexpected board-status writes before committing after running it.
`project/configs/test-config.json` declares **bats** as both the unit and the integration tool, and states that e2e is covered by "bats integration tests". No bats harness exists: there are zero `.bats` files in the repo and `bats` is not installed. In practice every shell script under `skills/`, `scripts/`, and `hooks/` is covered by manual verification plus **shellcheck** (the one declared tool that is real, wired as the `sast` entry). Confirmed by the tester while verifying E40_S01_T03 and re-confirmed on 2026-08-26. The declared stack therefore overstates actual coverage. Two ways to close it — stand up a bats suite (starting with `skills/uncharted/scripts/*.sh`, which are the newest and most script-dense) or amend `test-config.json` to state that unit/integration coverage is manual. Not yet filed as a board item; the choice between the two is a call for the maintainer.

`project/data/rapport_manifest.json` (the committed seed `hooks/on_session_end.sh` diffs new rapports against) was found stale during the E39_S04_T04 walkthrough on 2026-08-27: two real, pre-existing rapports (`project/rapports/problems/E37_S02-tester-still-writes-legacy-handoff-path.md`, `project/rapports/problems/E37_S02_T01-claude-settings-json-not-synced.md`) were absent from it on `main`, so `on_session_end.sh` would re-flag both as new `rapport_review` items even though they already exist. Root cause: the manifest is only rewritten by the hook when *new* files are found, not on every rapport commit, so a rapport committed without a subsequent `on_session_end.sh` run in that session/worktree before merge silently drifts the baseline. Not yet fixed — run `bash scripts/generate-rapport-manifest.sh` on `main` to resync when picked up. Not filed as a board item.

## Restore /distribute Skill — E31_S07 reopened for skills/j-init/ gap (2026-09-15)
`E31_S07` (Distributed Scaffold Commit Scope Decision + Gitignore Template Cleanup) shipped
`Passed` earlier the same day: `E31_S07_T01` decided and implemented a distinct `scaffold_visibility`
config flag (kept separate from `project_files_visibility` per its documented boundary) so `/init`
can exclude the distributed `.claude`/`.agents` scaffold from a consumer's git history, and
`E31_S07_T02` removed a stray leftover-heredoc `EOF` line from `skills/init/assets/.gitignore_template`.
Both tasks correctly scoped their fix to `skills/init/` only. Verification the same day found a gap
neither task could have known to cover: `skills/j-init/` is a second, separate, hand-maintained
directory — never auto-synced with `skills/init/` (`scripts/generate-j-alias.sh` explicitly excludes
this pair as "hand-maintained") — and it is `skills/j-init/`, not `skills/init/`, that actually ships
to public-GitHub-mirror and npm-package consumers (`skills/init/` is blocked by `.publicignore` and
confirmed absent from the live public `jenga-npm` repo; `skills/j-init/` is confirmed present there).
Concretely, `skills/j-init/scripts/init.sh` has no `--scaffold-visibility` flag at all, and
`skills/j-init/assets/.gitignore_template` still carries the stray `EOF` line. The private-filesystem
`/distribute` consumer path (`skills/distribute/scripts/distribute-changes.sh`, which has no
`skills/init/` exclusion) almost certainly received the real fix correctly — the gap is specifically
public-mirror and npm-package consumers who invoke `/j-init`. `E31_S07` was reopened the same day
(`reopened_on: 2026-09-15`) for a new task, `E31_S07_T03`, which ports the already-decided
`scaffold_visibility` implementation to `skills/j-init/` (adapted to that directory's own
already-established path-resolution style, not copy-pasted), removes the same stray `EOF` line there,
mirrors the doc update into `skills/j-init/SKILL.md` (a full duplicate of `skills/init/SKILL.md`, not
a thin pointer), and adds new bats regression coverage exercising the mirrored npm-consumer install
fixture pattern specifically against `skills/j-init/scripts/init.sh` — since no such coverage existed
for `--scaffold-visibility` on either copy before this. A related-but-distinct stray-`EOF`-line defect
in `skills/j-skillify/assets/init-new/assets/.gitignore_template` (a completely separate `skillify`
scaffold asset, unrelated to `/init`'s `scaffold_visibility` work) was found in the same investigation
and filed separately under the Maintenance epic as `E42_S06` rather than bundled into `E31_S07` — see
below.

## Maintenance — Framework Hygiene & Schema Drift (E42)
Standing home for chore-shaped work with no other epic to own it (`agents/scrum-master.md`'s
"Maintenance epic is the default home for chore tasks" convention). Reopened 2026-08-30 for `E42_S03`,
a retroactive record of a 149-file rename (`JengaAgent` → `Jenga AI`, commit `c01d0a3`) that was
executed directly on `main` outside the normal Developer/Tester lifecycle — no task ticket, worktree,
or handoff preceded it. Judged acceptable because the change was a pure, line-for-line text
substitution (268 insertions / 268 deletions) with no code-behavior impact, bringing stale mentions of
the pre-rebrand name in line with the identity the project had already adopted elsewhere (npm package
`@jenga-ai/agent`, README title). File count is well beyond this epic's usual one-line-to-one-file
scale, but the work is still chore-shaped by kind and has no other natural epic home. Excluded from the
rename, and not part of `E42_S03`'s scope: `E28_public-mirror.md`, `project/todo.md`, `publish` skill
adapters/scripts, `settings.json`, and the untracked `E28_S06_*`/`E41_S01_T01` files — all separate,
unrelated in-flight work at the time. Epic rolled back up to `Passed` the same session.

**Reopened 2026-09-15 — E42_S06.** While investigating `E31_S07`'s `skills/j-init/` gap (see above
and `E31_S07_T03`), a second, unrelated stray-`EOF`-line gitignore-template defect was found in
`skills/j-skillify/assets/init-new/assets/.gitignore_template` — the same defect class as
`E31_S07_T02`, but a distinct asset belonging to `skillify`'s own `init-new` scaffold with no
relationship to `/init`'s `scaffold_visibility` work. Filed as its own one-line-to-one-file story/task
(`E42_S06`/`E42_S06_T01`) rather than bundled into `E31_S07`.

## Dashboard Markdown Library (E58) and Dashboard Mobile Responsive Rollout (E59)
Filed via `/brainstorm` (2026-09-13), following an evaluation rapport
(`project/rapports/analysis/improve-jenga-dashboard-mobile-overlay-rapports-eval.md`) covering four
requested dashboard improvements. One (a board-item content overlay) was scoped as a new story under
the existing `E06` epic (`E06_S07`, see below) since it's a UI addition to the Board tab specifically.
The other three needed new epic homes:

**E58 — Dashboard Markdown Library.** Two of the four requests — a "Rapports" view and a
"Documentation" view — are genuinely net-new: no parser or route in `project/app/api` today exposes
full content for `project/rapports/*` (only a 300-char-truncated summary via `/v1/history`),
`project/documentation/{summaries,plans}`, `project/ideas.md`, `project/PROJECT_SUMMARY.md`,
`README.md`, `project/documentation/STRATEGY.md` (moved there from `docs/STRATEGY.md` by E34_S07, legacy fallback retained), or `project/documentation/examples/*`. Both requests share the same
shape ("browse categorized markdown artifacts, click to see full content") but were confirmed during
brainstorm to be conceptually distinct — Rapports is process/history artifacts (110+ files under
`problems/` alone), Documentation is curated reference material — and ship as **two separate tabs**
sharing backend/UI infrastructure (`E58_S01`), not one combined view. `E58_S02` (Rapports) explicitly
includes client-side title search and pagination in v1, given the realistic multi-hundred-file volume
once `documentation/{summaries,plans}` (per-task files) are included.

**E59 — Dashboard Mobile Responsive Rollout.** The dashboard has zero `@media` queries anywhere in
`ui/src/` — fully greenfield. Per explicit user instruction ("incremental per tab, but be smart about
it... if you create global, reusable styles and variables then I should not be as hard"), this epic
splits into a small, early foundation story (`E59_S01`: CSS breakpoint/spacing tokens plus a
mobile-usable app shell/nav) sequenced before or alongside the two brand-new `E58` tabs, and four
independent per-tab retrofit stories (`E59_S02`–`E59_S05`: Board, Kanban, History, Architecture) for
the *existing* tabs that have no tokens to reach for today. `E58`'s new tabs are deliberately **not**
retrofit targets — they're built mobile-ready from day one against `E59_S01`'s tokens, since building
correctly once is cheaper than a later retrofit.

**E06_S07 — Board Item Content Overlay** (new story under the existing `E06` epic). Clicking a board
item's title (Backlog: `EpicCard`/`StoryCard`/`TaskCard`; Kanban: `KanbanCard`) opens a content
overlay showing everything below its frontmatter, extending the existing `EntryDetailPanel.jsx`
pattern already used for commit-history items rather than forking a new component — no backend
change needed, since `GET /v1/board` already returns full `_content` per item. `E06_S04`'s original
acceptance criteria (collapse/expand is "the only interactive affordance added") was amended in the
same session to explicitly permit this overlay as a second, compatible affordance.

## Playbook Type Descriptors & Runtime Verification (E62)
Filed via `/j-deep-dive` then `/j-brainstorm` (2026-09-19); design documents co-located at
`project/documentation/plans/systemwide-type-declaration-system.md` (plus its scrutiny and
solution-assessment companions). The originating request was a *systemwide* object type declaration
policy generalized from playbook `output_types`. Scrutiny rated the full three-layer proposal
CRITICAL (3/10 feasibility) and the scope was deliberately cut to what is verifiable and
deterministic.

**What the investigation established.** Three defects, each verified against code rather than
assumed: (1) `grep -rn "input_types"` returns **0 hits** repo-wide — no skill declares what it
*accepts*, so `load-playbooks.sh` can only check that a `forward_from` source declares *something*
(`:1054`), never that the two ends are compatible; (2) `run-playbook-step.sh` stores a step's typed
output verbatim (`:723-726`) and contains **zero** references to `output_types` or any classifier
resolution, so nothing verifies a declared type against the real value; (3)
`templates/playbook-types.json` — the "canonical type vocabulary" — is **parsed by nothing**,
appearing in a single comment line, so `output_types: banana` loads cleanly today.

**The shape that survived.** Each registry type gains a **descriptor** (optional `verify` rule,
optional `normalize` list of named transforms), making the registry load-bearing for the first time
while keeping type addition a **data-only** edit. `E62_S01` builds the descriptors, a deterministic
validator, the `input_types` field, and the load-time compatibility check; `E62_S02` wires
verification into the runner at the `advance … passed` chokepoint. Both land as **one scope** — the
split is decomposition, not phasing.

**Key design decision — conditional types need no new plumbing.** The runner never needs to know
which `{when, type}` branch fired, only whether the value satisfies **at least one** declared branch.
This designs out the confirmed-missing classifier-resolution work that was the largest cost driver in
the original proposal.

**What was rejected, and why it matters.** The user's original "type skill as formatter/converter/
verifier" was cut to *verifier* only. LLM-driven **auto-convert was rejected**: repairing
`text` → `id_list` is semantic extraction, which would put non-determinism exactly where correctness
matters most and would make a declared type an aspiration enforced by a corrector rather than an
honest producer claim — reversing `E53_S11`. **Warn-and-continue was rejected** (normalization of
deviance), which in turn removed the need for a **dev/prod primitive** that does not exist anywhere in
`project/configs/` and is ambiguous for an npm-distributed framework. `E53_S11`'s honesty-over-breadth
policy is **kept**, scoped to `output_types`; `input_types` may be broadly declared because an input
declaration cannot disarm the forward-source check. `text` is a verification **no-op** but explicitly
**not** an `any` in the compatibility lattice.

**Deliberately deferred**, each requiring its own ratification: sender objects, queue trigger records,
`events.json` entries, rapports, and board frontmatter — the other boundary objects with hand-rolled,
unshared validation. `templates/` beyond the registry itself is out of scope, its population being
largely unreachable by a frontmatter-first approach. The epic is committed to with its near-term blast
radius understood: the entire `forward_from` surface in the repo today is **one edge**
(`j-reconcile` → `j-todo` in `board-hygiene.json`).


## Service Connect — MCP and CLI Setup (E65)
Filed via `/j-brainstorm` (2026-10-01), second step of the `idea-to-committed` playbook. A `j.connect` skill
that guides users through setting up third-party MCP and CLI services in their project: detect, install
the CLI, authenticate, register the MCP server, and independently verify. **Architecture decision:** ONE
generic skill plus per-service data descriptors executed by shared scripts, modeled on `j.cloud-connect`
(`E60_S01`) — adding a service is a data-only change, not a new skill. Stories: `E65_S01` descriptor
schema, shared runner scripts, and the MCP settings-location decision (`.claude/settings.json` vs
`.mcp.json`, reconciled with `E16_S04_T04`/`E26`'s reverted `.agents/settings.json` dual-write; gates all
others); `E65_S02` the `j.connect` skill shell; `E65_S03` GitHub auth (`gh auth`) as the shared
prerequisite hub; `E65_S04` Supabase and `E65_S05` DigitalOcean (priority services); `E65_S06` Figma and
Expo (DEFERRED, P5; check for an already-connected Figma MCP before duplicating). Cross-cutting
constraints: no stale hardcoded install commands (link official docs, verify by running the tool);
secrets as env-var names only, never values, with a pre-write `.gitignore` check; deterministic steps in
scripts; undeterminable platform falls back to official instructions. **Out of scope:** App Store Connect
and Play Console, handed off to `j.publish` (`mobile-ios` target) — no story created for them. All items
`Pending`.

## Skill Catalog Defect Remediation (E74)

Filed 2026-10-14 as the follow-up to `E64` (which closed `Passed with remarks`). `E64`'s smoke test found 5 genuine
critical defects in four existing skills; `E64` did not edit them, so `/j-smoke-test` exits 1 on this repository and
`tests/smoke-test-skills.bats` tolerates them through a `KNOWN_DEFECTS` list. `E74_S01` fixes them and makes the
harness a green gate: `E74_S01_T01` `j-deep-dive` (`prefered_agent: scrum-master`, real description), `T02` `j-btw`
(`../j-pi-plan/assets/...`), `T03` `jenga` (`skills/j-do/assets/sender_template.json`), `T04` `j-mirror-public`
(retired `generate-j-alias.sh` prose; the `rewrite_orphaned_twin_names` section is live and stays), `T05` replace
`KNOWN_DEFECTS` with a zero-critical assertion (depends on `T01`-`T04`), `T06` a decision task on whether
prose-only dangling references should rate below critical. `T01`-`T04` and `T06` are `inline`, `T05` is `task`.
A sixth critical finding, `skills/train/`, exists only as an untracked pre-E50 leftover in the main working tree
(no `SKILL.md`, nothing tracked): not a repo defect, local cleanup only, no task. All items `Pending`.

## Await-Answer Marker for Delegated Conversations (E84)

Filed 2026-10-22 via `/j-error`, from an upstream change request raised by the **Kazi** project (`../agent-gui`,
a graphical front end that runs Jenga skills in headless sessions) against `@jenga-ai/agent` 4.3.0. A skill that
hands its conversation to a sub-agent has no machine-readable way to say "this needs a user answer before it can
continue", so a headless driver must infer it from prose. Verified against this repo: `skills/j-brainstorm/SKILL.md`
step 1 says only "Invoke the `scrum-master` agent", `agents/scrum-master.md:498` Brainstorm Mode asks in prose, and
`requires_user_answer`/`awaits_agent` exist nowhere, including `templates/SKILL_TEMPLATE.md` and the field table at
`project/documentation/skill-authoring.md:436`. `E84_S01` adds the two frontmatter fields, has Brainstorm Mode wrap
each question batch in `[JENGA:AWAIT_ANSWER:<skill>:<id>]`/`[JENGA:END_QUESTION:<id>]` (same grammar as
`[JENGA:SESSION_END:<skill>]`), tells `j-brainstorm`'s main agent to relay unchanged / end its turn / pass the reply
back unchanged, and documents the grammar in `JENGA_PROTOCOL.md`.

**Two corrections to the upstream request, recorded so the implementer does not do dead work.** Its hook bullet
asks that the session-end hook stop stripping the marker: unnecessary, because `hooks/session_end_watcher.sh:5` and
`hooks/session_end_helper.js:7` match `SESSION_END` only — an `AWAIT_ANSWER` line never matches — and because
neither script is registered in `settings.json` at all (only `WorktreeCreate`, `WorktreeRemove`, `SessionEnd` and
`PreToolUse` are), both still carrying the `E11_S04` router `TODO`. Nothing strips any marker today, which also
means the existing `SESSION_END` marker already reaches a driver's stream. Its inheriting-skills list is also
incomplete: **two** playbooks chain `j-brainstorm`, `idea-to-committed` and `brainstorm-to-mirror`, not one. The
story carries a regression guard for the hook behaviour instead of a fix, and explicitly excludes wiring the
watcher. One story, no tasks yet; the headless acceptance criterion is verifiable only in the requester's harness
and must be recorded as unverified rather than silently ticked if they cannot run it.

## Conventions
- Board items use `E##_S##_T##` naming convention
- Story format requires `## Acceptance Criteria` and `## Definition of Done` with `- [ ]` checkboxes
- Agent communication uses queue files in `project/queue/`
- All skills are Markdown files in `skills/` and are invoked via `/skill-name`

### Known Gaps
- Root `AGENT.md`/`AGENTS.md` still carry a stale, older `/jenga` description ("Gather project description and goals from the user; define initial epics in PROJECT_SUMMARY.md") that predates `/jenga` becoming the board orchestrator — `CLAUDE.md` carried the same stale text until E45_S03_T02 corrected it there (scope: `CLAUDE.md`, `README.md` only; `AGENT.md`/`AGENTS.md` deliberately left untouched since they don't make the "zero-prompt" claim that task was fixing). Same drift pattern already flagged under Launch & Discoverability (E41) as a proven failure mode. Follow-up: sync `AGENT.md`/`AGENTS.md`'s `/jenga` row to match `CLAUDE.md`'s corrected three-mode description. Not yet filed as a board item.
- `project/.wiki/documentation.md` and `project/documentation/documentation.md` each still carry ~41 bare `/skill-name` invocation references, now stale relative to the `j:<name>` canonical form adopted in E50_S01 across `CLAUDE.md`, `README.md`, and `project/documentation/skill-authoring.md` (flagged by a doc-sync report scoped to E50_S01_T05, which deliberately left these two files untouched since its task frontmatter pinned scope to the three files above). Same drift-pattern class as the `AGENT.md`/`AGENTS.md` gap above. Follow-up: a small task to bring both wiki-doc copies' invocation forms in line with the `j:` convention — note E38_S01's still-pending consolidation of the two files onto one canonical copy should probably land first or alongside, to avoid fixing the same drift twice. Not yet filed as a board item.
- `scripts/validate-story-format.sh` (added E17_S01, 2026-06-06) hard-requires every story to carry a `## Definition of Done` section, but at least 17 pre-existing stories authored before that date lack one entirely (e.g. `E03_S01`-`S03`, `E15_S01`-`S03`, `E16_S01`, `E16_S02`, `E16_S03`, `E23_S01`-`S05`, `E29_S03`, `E29_S04`, `E33_S06`, `E53_S02`). Surfaced by the tester on `E16_S03` (`project/rapports/problems/E16_S03-story-format-invalid.md`, 2026-09-07), since the tester workflow now runs this validator as a mandatory gate before any `Passed` status — `E16_S03` retrofitted its own DoD inline to clear the gate, but the other ~16 stories remain unretrofitted and will hit the same blocker whenever they're next touched. Follow-up: a Maintenance task to retrofit `## Definition of Done` sections onto the remaining pre-existing stories. Not yet filed as a board item.
- `/reconcile` can promote a task/story to `Passed`/`Done` based on a light-scope commit alone while a light-scope-failure fallback to the full worktree+developer+tester pipeline is already in flight for that exact task ID (observed on `E40_S01_T05`, 2026-09-23: main HEAD `5730a453` marked the task `Passed` and the story `Done` from commit `0c16ead0` alone, before the fallback pipeline's tester found — and the developer fixed — a real classification bug in `aa57d899`; the fix briefly existed only on a detached-HEAD worktree with no branch pointer, one `git worktree remove` away from being lost entirely). Follow-up: scrum-master's next `/reconcile` pass should check whether a task ID has an in-flight fallback-pipeline dispatch (e.g. a recent `implementation_assignment`/fallback trigger without a matching completed handoff) before promoting it to a terminal status from light-scope evidence alone. Full incident, reproduction, and resolution: `project/rapports/problems/E40_S01_T05-premature-main-reconcile-vs-worktree-fix.md` (merged into main at `69b59c78`). Not yet filed as a board item.
