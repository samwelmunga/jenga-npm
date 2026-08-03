# SCRUTINY ASSESSMENT

**Proposal:** Add a single `/publish` skill to JengaAgent that configures deployment targets, generates release notes, runs configurable quality gates, executes platform-specific deployment flows, and records publish history.

---

## 1. CORE ASSUMPTIONS

What the proposal takes for granted — each directly challenged.

| # | Assumption | Challenge |
|---|------------|-----------|
| 1 | A single entry-point skill can cleanly cover setup, release-note generation, deployment orchestration, and history tracking. | That bundles distinct concerns with different failure modes, permissions, and user expectations. The result may become a large, stateful command that is harder to reason about, test, and secure than separate narrower skills or scripts. |
| 2 | Storing only environment-variable references in `publish.json` is sufficient secret hygiene. | It avoids hardcoding secrets, but it does not solve secret validation, rotation, missing-variable detection, shell leakage, CI portability, or the risk that logs or subprocesses expose secret values at runtime. |
| 3 | Interactive wizards are a suitable foundation for a workflow system that is explicitly multi-agent and automation-oriented. | Wizards are convenient for humans, but they are awkward for non-interactive runs, reproducibility, CI use, and agent handoffs. The proposal does not define a non-interactive contract, so the design may privilege demos over durable automation. |
| 4 | Configurable quality gates are enough to make deployments safe. | “Configurable” can just mean “easy to weaken.” Without strong defaults, required baselines, and clear ownership of gate definitions, the proposal risks turning safety checks into optional ceremony rather than real protection. |
| 5 | Loose scrum-board integration is harmless because deployment should not be blocked by process metadata. | Maybe, but then the board summary risks being decorative noise. If board state is never authoritative, why include it in the deploy flow at all, and what prevents release notes from drifting away from what was actually shipped? |
| 6 | Git tags plus `publish-history.json` provide adequate release recording. | That creates two sources of truth that can drift. Tags can be moved or omitted, history files can fail to append, and neither mechanism by itself defines rollback, reconciliation, or audit reliability across branches and worktrees. |

*(Minimum 3 assumptions)*

---

## 2. KEY QUESTIONS

Sharp, unanswered questions the proposer must be able to address before proceeding.

1. What is the exact non-interactive execution model for `/publish deploy` when the workflow is run by an agent, in CI, or from a scripted release process?
2. Who owns and maintains the platform-specific deployment templates, and how will template drift be prevented as Apple and Google release processes change?
3. How is the “last publish tag” determined when there are multiple targets, hotfix branches, failed publishes, or manual out-of-band releases?
4. What is the rollback or recovery path when deployment succeeds on one platform but fails on the other, or when tagging/history recording fails after a real publish has already happened?
5. How will release notes reconcile git history with board tasks when commit messages, task references, and board status data are incomplete or inconsistent?
6. Are quality gates target-specific only, or are there any mandatory global gates that cannot be disabled by configuration?
7. What prevents the setup wizard from becoming an unbounded rules engine for every deployment platform, store requirement, and edge case?
8. Where is the trust boundary for executing platform-specific commands defined, especially if wizard templates contain shell snippets or instructions that mutate release state?

*(Minimum 4 questions)*

---

## 3. RISK REGISTER

| Risk | Severity (Low / Med / High) | Likelihood (Low / Med / High) | Notes |
|------|-----------------------------|-------------------------------|-------|
| The skill becomes an oversized orchestration layer that is difficult to validate and maintain. | High | High | Setup, deployment, release-note generation, history, tagging, and platform logic are all being combined behind one command surface. |
| Interactive design blocks reliable automation and agent use. | High | High | The proposal repeatedly relies on prompts, review steps, and confirmation wizards but does not define machine-safe equivalents. |
| Secret handling fails operationally even if secrets are not stored in config. | High | Med | Missing env vars, accidental echoing, subprocess leaks, local `.env` divergence, and OS keychain portability remain unresolved. |
| Dual release records (`git tag` and `publish-history.json`) diverge. | Med | High | Partial failure is plausible and reconciliation rules are not specified. |
| Mobile-store complexity is underestimated. | High | Med | App Store and Play Store releases involve signing, metadata, phased rollout, review delays, store-specific failures, and manual steps that do not fit a simple linear pipeline. |
| Configurable quality gates are weakened to “make deploys pass.” | High | Med | When delivery pressure rises, optional gates are often the first thing users relax unless governance is explicit. |

*(Minimum 3 risks)*

---

## 4. GENUINE STRENGTHS

Real strengths only — no flattery. If there are none worth noting, say so explicitly.

- The proposal correctly avoids storing raw secrets in project config.
- Separating setup, deploy, history, and release-note generation into sub-commands is at least a cleaner interface than a single opaque “do everything” action.
- Requiring a final confirmation before execution is sensible for a release operation with real-world side effects.
- Explicit wizard templates per deployment type acknowledge that deployment logic is domain-specific rather than pretending one generic flow fits all targets.

---

## 5. BLIND SPOTS

Things the proposal fails to consider, glosses over, or deliberately avoids.

- It barely addresses partial-success scenarios, which are common in multi-platform publishing: one platform succeeds, another fails, and local bookkeeping is now inconsistent with external reality.
- It treats release notes as if git log plus closed board tasks will be good enough, without confronting messy commit hygiene, cherry-picks, reverted work, or board items that were closed administratively rather than actually shipped.
- It says manual steps will be surfaced, but does not define whether the skill is an executor, a checklist generator, or a hybrid; that ambiguity matters for responsibility and auditability.
- It does not define ownership boundaries between Scrum Master, Developer, and Tester in a release action that cuts across planning data, build validation, and production-side effects.

*(Minimum 2)*

---

## 6. FEASIBILITY ASSESSMENT

**Score: 5 / 10**

**Rationale:** The narrow version of this idea is feasible: target configuration, release-note drafting, and a controlled wrapper around existing deploy commands could work. The broader version described here is much shakier because it mixes interactive setup, policy enforcement, mobile-store specifics, state recording, and cross-agent workflow concerns without a clearly defined execution contract. As written, the concept is plausible, but under-specified in the places where release tooling usually breaks.

**Required conditions for this to succeed:**
- Define a strict non-interactive execution contract alongside the interactive wizard flow.
- Reduce the first version to one deployment type and one clearly bounded publish path.
- Specify reconciliation rules for tags, publish history, failed publishes, and partial multi-platform success.
- Establish mandatory minimum quality gates that configuration cannot silently remove.
- Decide whether `/publish` is primarily an orchestrator of existing scripts or a framework for authoring new deployment pipelines.

---

## 7. VERDICT

**Overall judgment:** SKEPTICAL

> The proposal has a reasonable surface shape, but it is currently stronger as an interface sketch than as an operational design. Its biggest weakness is not ambition; it is ambiguity around automation, failure recovery, and responsibility boundaries in a workflow that would perform high-consequence actions.

---

## 8. RECOMMENDED NEXT STEPS

Concrete first steps to de-risk or validate the proposal, if the proposer wishes to proceed.

1. Write a short technical spec for a single target type (`mobile-cross-platform` is probably still too broad; start with one store or one platform flow if possible).
2. Define the non-interactive contract for every sub-command, especially deploy confirmation, release-note editing, and incomplete-config handling.
3. Model failure states explicitly: failed pre-gates, one-platform success, tagging failure, history-write failure, and post-deploy smoke-test failure.
4. Decide the system of record for publishes and document reconciliation if `git tag` and `publish-history.json` disagree.
5. Prototype release-note generation against real commit/task history to see whether the data quality is remotely good enough.
6. Freeze a minimum set of mandatory quality gates before making per-target gates configurable.
