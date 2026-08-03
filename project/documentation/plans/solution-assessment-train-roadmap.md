# SOLUTION ASSESSMENT

**Subject:** Assessing viable solution paths for evolving the `/train` skill into a reliable ML training orchestration system.
**Input type:** Scrutiny assessment output

## 1. PROBLEM INVENTORY

All distinct problems from the scrutiny (assumptions, risks, blind spots). List all of them.

| # | Problem | Source | Severity |
|---|---------|--------|----------|
| 1 | The current skill architecture may not safely absorb orchestration, persistent state, reporting, template plugins, and iterative optimization without becoming brittle. | Assumption 1 / Risk register | High |
| 2 | Developer-convenience-first design may conflict with deterministic, machine-readable, agent-compatible behavior. | Assumption 2 | High |
| 3 | Declared config flags are underspecified behavioral contracts with unclear precedence, defaults, non-interactive behavior, and failure semantics. | Assumption 3 | High |
| 4 | Auto-installing dependencies mutates shared environments and introduces non-determinism, version drift, and network/runtime failure modes. | Assumption 4 / Risk register / Key question 4 | High |
| 5 | JSON-based job and registry tracking is vulnerable to concurrent writes, partial failure, schema drift, and corruption. | Assumption 5 / Risk register / Key question 5 | High |
| 6 | Heuristic or AI-driven auto-iteration lacks trustworthy metrics, objective functions, stop criteria, and reproducibility guarantees. | Assumption 6 / Risk register / Key question 6 | High |
| 7 | The execution contract between `/train run`, `train.py`, and `training/main.py` is undefined. | Key question 1 | High |
| 8 | Non-interactive behavior is unclear when confirmation controls such as `confirm_before_run` are enabled. | Key question 2 / Risk register | Medium-High |
| 9 | Success criteria for smoke runs versus full runs are not standardized across templates. | Key question 3 | Medium-High |
| 10 | Template authors lack a formal contract for declaring metrics, datasets, entrypoints, compatibility constraints, and required capabilities. | Key question 7 / Risk register | High |
| 11 | There is no rollback, resume, or recovery model for partially successful runs, interrupted runs, or desynchronized artifacts/state. | Key question 8 / Blind spots | High |
| 12 | Reproducibility requirements are missing: pinned dependencies, dataset versioning, random seeds, and environment capture. | Blind spots / Recommended next step 3 | High |
| 13 | Metrics are not normalized or made comparable across heterogeneous templates, weakening reporting and iteration quality. | Blind spots | Medium-High |
| 14 | Security and trust boundaries for custom templates are undefined. | Blind spots | High |

## 2. SOLUTION PATHS

### Problem [1]: Architecture scope mismatch and platform creep

#### Solution A: Establish a thin orchestrator with strict boundaries
**Description:** Define `/train` as a coordinator only: config loading, state transitions, execution dispatch, reporting hooks, and recovery. Keep model-specific logic inside template-owned runners. Explicitly exclude scheduling, distributed execution, dataset management, and experiment analytics beyond basic metadata.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Medium | Mostly design and refactor boundaries rather than deep new infrastructure |
| Time | 3-5 days | Spec, refactor, and enforcement points |
| Skill requirements | Solution architecture, Python/CLI design, workflow modeling | |
| Dependencies | Agreement on scope, canonical execution contract | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Boundary leaks over time | Medium | Medium | Add explicit non-goals and interface tests |
| Existing code may already couple concerns | Medium | Medium | Refactor incrementally behind stable wrappers |

**Viability verdict:** RECOMMENDED
**Rationale:** This contains scope early and makes later features additive rather than turning the skill into an accidental platform.

#### Solution B: Rebuild `/train` as a generic workflow engine
**Description:** Formalize the feature set as a reusable workflow runtime with pluggable steps, state machine, artifact handling, and reporting.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Very High | Large abstraction surface |
| Time | 3-6 weeks | Design, migration, testing |
| Skill requirements | Platform design, plugin systems, stateful workflow engineering | |
| Dependencies | Strong product commitment and broader roadmap | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Over-engineering | High | High | Time-box design; require clear multi-template demand |
| Delivery delay | High | High | Stage behind MVP milestones |

**Viability verdict:** NOT RECOMMENDED
**Rationale:** It solves the concern in theory but at a cost disproportional to the current maturity of the skill.

### Problem [2]: Convenience vs deterministic agent-compatible behavior

#### Solution A: Make machine-safe behavior the default, with optional human-friendly wrappers
**Description:** Define non-interactive deterministic output, exit codes, and state transitions as the core contract. Layer convenience features such as confirmations or pretty summaries on top when an interactive terminal is detected or explicitly requested.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Medium | Mostly contract design and output refactoring |
| Time | 2-4 days | Spec plus CLI adjustments |
| Skill requirements | CLI ergonomics, automation design | |
| Dependencies | Execution contract, flag semantics | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Backward behavior surprises | Medium | Medium | Add compatibility flags and migration notes |
| Dual-mode complexity | Medium | Low | Keep one core code path with two renderers |

**Viability verdict:** RECOMMENDED
**Rationale:** Agent compatibility is hardest to retrofit later; making it foundational reduces future redesign cost.

#### Solution B: Keep convenience-first now and add machine mode later
**Description:** Optimize for developer UX first, then introduce a strict automation mode after feature growth stabilizes.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low initially | Deferred cost accumulates |
| Time | 1-2 days now | But likely rework later |
| Skill requirements | CLI UX | |
| Dependencies | None immediate | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Expensive retrofit | High | High | None besides future redesign |
| Divergent semantics between modes | High | Medium | Hard to avoid once features proliferate |

**Viability verdict:** CONDITIONAL
**Rationale:** Only acceptable if the roadmap intentionally stops short of serious automation; otherwise it creates known future debt.

### Problem [3]: Underspecified config flag behavior

#### Solution A: Publish a versioned configuration contract
**Description:** Define each flag's type, default, precedence, interaction rules, non-interactive semantics, validation, and failure behavior in a schema-backed spec. Enforce it at load time.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Medium | Schema plus validation logic |
| Time | 3-5 days | Spec, validator, tests |
| Skill requirements | Schema design, config validation, CLI behavior design | |
| Dependencies | Canonical execution contract | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Schema churn | Medium | Medium | Version the schema from day one |
| Hidden legacy assumptions | Medium | Medium | Add migration warnings and compatibility tests |

**Viability verdict:** RECOMMENDED
**Rationale:** The flags are already part of the product surface; formalizing them is cheap compared with debugging undefined behavior later.

#### Solution B: Keep permissive parsing with ad hoc documentation
**Description:** Document expected behavior informally and implement only the currently needed combinations.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Fastest short-term path |
| Time | 1-2 days | Minimal implementation |
| Skill requirements | Basic CLI implementation | |
| Dependencies | None | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Edge-case explosions | High | High | None robust |
| Hard-to-reproduce bugs | High | Medium | Logging helps but does not solve contract gaps |

**Viability verdict:** NOT RECOMMENDED
**Rationale:** This directly preserves the ambiguity the scrutiny identified.

### Problem [4]: Dependency auto-install and environment mutation

#### Solution A: Require isolated per-job environments
**Description:** Run each job in its own virtual environment or container-like wrapper under the project tree, with explicit install step, lock capture, and opt-in network access. Store resolved package state in job metadata.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Medium-High | Environment lifecycle and path management |
| Time | 4-7 days | Creation, reuse, metadata capture, error handling |
| Skill requirements | Python packaging, environment isolation, CLI orchestration | |
| Dependencies | Python tooling availability, reproducibility design | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Larger disk/runtime overhead | Medium | Medium | Cache by lockfile hash |
| Cross-platform quirks | Medium | Medium | Start with one supported environment strategy |

**Viability verdict:** RECOMMENDED
**Rationale:** Isolation is the most direct way to remove shared-environment risk without blocking useful automation.

#### Solution B: Disable auto-install and require pre-provisioned environments
**Description:** Treat environment setup as an external prerequisite and fail fast if dependencies are missing.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Simple enforcement |
| Time | 1-2 days | Validation and messaging |
| Skill requirements | Basic CLI validation | |
| Dependencies | Clear documentation | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Worse UX | Medium | High | Add helper commands for explicit setup |
| Lower adoption | Medium | Medium | Provide template bootstrap docs |

**Viability verdict:** VIABLE
**Rationale:** This is safer than implicit installs and may be preferable if isolation is too costly in the near term.

### Problem [5]: JSON registry/state fragility

#### Solution A: Use versioned JSON with atomic writes, append-safe updates, and recovery rules
**Description:** Keep JSON initially, but add schemas, write-to-temp-in-project-then-rename atomicity, journaling or backup snapshots, lock discipline, and recovery on read failure.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Medium | Manageable if concurrency stays low |
| Time | 3-5 days | Schema, writer utility, recovery logic |
| Skill requirements | File I/O correctness, schema design | |
| Dependencies | State model definition | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Locking edge cases | Medium | Medium | Single-writer policy and retries |
| Limited long-term scalability | Medium | Medium | Set migration threshold triggers |

**Viability verdict:** RECOMMENDED
**Rationale:** It addresses immediate failure modes cheaply while preserving a migration path if usage grows.

#### Solution B: Move state tracking to SQLite immediately
**Description:** Store jobs, runs, artifacts, and iteration history in a local SQLite database with migrations and transactional updates.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Medium-High | Better integrity, more upfront work |
| Time | 1-2 weeks | Schema, migrations, access layer |
| Skill requirements | SQLite schema design, migration handling | |
| Dependencies | Stable domain model | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Premature storage complexity | Medium | Medium | Restrict schema to core entities |
| Migration burden during churn | Medium | Medium | Delay until domain stabilizes slightly |

**Viability verdict:** VIABLE
**Rationale:** Stronger technically, but only justified if concurrent or frequent runs are expected soon.

### Problem [6]: Unsafe auto-iteration logic

#### Solution A: Gate auto-iteration behind reproducibility and statistical safeguards
**Description:** Allow iteration only when templates declare objective metrics, baseline windows, minimum delta thresholds, max iteration counts, and reproducible seeds/data snapshots. Default to suggestion-only mode until those conditions are met.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | High | Requires reporting and reproducibility plumbing |
| Time | 1-2 weeks | Contract, guards, history comparison |
| Skill requirements | ML experimentation, metrics design, orchestration | |
| Dependencies | Reproducibility baseline, template contract, metrics schema | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| False confidence from weak thresholds | High | Medium | Conservative defaults, human review mode |
| Template inconsistency | Medium | Medium | Require capability declarations |

**Viability verdict:** CONDITIONAL
**Rationale:** Viable only after baseline experiment integrity exists; otherwise it should remain disabled.

#### Solution B: Replace auto-execution with recommendation-only iteration
**Description:** Compute candidate next-step suggestions from prior metrics but require explicit user or agent approval before mutating configs or launching another run.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Medium | Avoids autonomous mutation loop |
| Time | 3-5 days | Heuristic engine plus reporting |
| Skill requirements | Metrics interpretation, CLI/reporting | |
| Dependencies | Comparable metrics and run history | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Suggestion quality may still be weak | Medium | Medium | Mark as advisory and expose evidence |
| Users may overtrust recommendations | Medium | Low | Show confidence and rationale |

**Viability verdict:** RECOMMENDED
**Rationale:** It preserves roadmap value while avoiding the highest-risk autonomous behavior.

### Problem [7]: Undefined execution contract

#### Solution A: Write a canonical execution contract and enforce adapter interfaces
**Description:** Specify inputs, outputs, lifecycle states, exit codes, artifact locations, and invocation responsibilities for `/train run`, `train.py`, and `training/main.py`. Add adapter shims so templates implement one stable interface.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Medium | Mostly architectural clarification |
| Time | 3-4 days | Spec plus wrapper adjustments |
| Skill requirements | Interface design, Python CLI integration | |
| Dependencies | Agreement on state model and reporting basics | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Existing templates may not conform | Medium | Medium | Provide compatibility adapter layer |
| Spec may miss edge cases | Medium | Medium | Pilot against 2-3 templates first |

**Viability verdict:** RECOMMENDED
**Rationale:** This is the highest-leverage prerequisite because many other fixes depend on a stable execution boundary.

### Problem [8]: Interactive confirmation breaks automation

#### Solution A: Introduce explicit interaction modes (`interactive`, `non-interactive`, `fail-on-prompt`)
**Description:** Make confirmation behavior mode-aware: prompt only in interactive mode, auto-fail or require explicit override in non-interactive mode, and record the decision path in state metadata.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low-Medium | Small but important behavioral branch |
| Time | 1-2 days | Mode plumbing and tests |
| Skill requirements | CLI state handling | |
| Dependencies | Config contract | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Silent unexpected skips | Medium | Low | Emit explicit exit codes/messages |
| Mode confusion | Low | Medium | Keep defaults simple and documented |

**Viability verdict:** RECOMMENDED
**Rationale:** This resolves a specific high-likelihood automation failure with minimal implementation cost.

### Problem [9]: Undefined smoke vs full run success criteria

#### Solution A: Add template-declared run profiles with required checks
**Description:** Each template declares `smoke` and `full` profiles including max duration hints, required steps, required artifacts, and success checks. `/train` validates profile outputs consistently.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Medium | Requires template contract addition |
| Time | 3-4 days | Profile schema and validator |
| Skill requirements | Contract design, test strategy | |
| Dependencies | Template manifest format, execution contract | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Template authors under-specify checks | Medium | Medium | Provide required minimum fields |
| Cross-template inconsistency | Medium | Medium | Add core mandatory validations |

**Viability verdict:** RECOMMENDED
**Rationale:** Standardized profiles preserve flexibility while making run results machine-comparable.

#### Solution B: Hardcode global smoke/full semantics
**Description:** Define one universal smoke and full behavior for all templates.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Simple to implement |
| Time | 1-2 days | Minimal changes |
| Skill requirements | Basic orchestration | |
| Dependencies | None | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Poor fit for heterogeneous templates | High | High | Add many exceptions, defeating simplicity |
| Misleading run outcomes | High | Medium | None robust |

**Viability verdict:** NOT RECOMMENDED
**Rationale:** Template diversity makes universal semantics too brittle.

### Problem [10]: Missing template author contract

#### Solution A: Introduce a versioned template manifest schema
**Description:** Require each template to ship a manifest defining entrypoints, supported profiles, required metrics, datasets, environment needs, compatibility version, and optional iteration capability.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Medium | Single source of truth for template capabilities |
| Time | 4-6 days | Schema, validator, migration of existing templates |
| Skill requirements | Schema and plugin contract design | |
| Dependencies | Execution contract, run profiles | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Manifest authoring burden | Medium | Medium | Provide scaffolding/default generators |
| Schema churn | Medium | Medium | Version and deprecate gradually |

**Viability verdict:** RECOMMENDED
**Rationale:** A manifest is the cleanest way to keep extensibility manageable and machine-readable.

#### Solution B: Infer template capabilities from file conventions
**Description:** Detect entrypoints and metrics heuristically from template structure and known filenames.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Medium | Appears simple but becomes brittle |
| Time | 2-4 days initially | Hidden maintenance cost |
| Skill requirements | File inspection heuristics | |
| Dependencies | Strong naming discipline | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| False detection | High | High | Fallback prompts or overrides |
| Opaque failures | High | Medium | Extensive logging |

**Viability verdict:** NOT RECOMMENDED
**Rationale:** Heuristics increase support burden and weaken contract clarity.

### Problem [11]: No rollback, resume, or recovery model

#### Solution A: Implement explicit run state machine with checkpoints and compensating actions
**Description:** Model runs as states such as `created`, `env_ready`, `running`, `succeeded`, `failed`, `interrupted`, `rolled_back`. Persist checkpoints, artifact manifests, and cleanup/rollback steps so interrupted runs can resume or fail safely.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | High | Requires disciplined lifecycle design |
| Time | 1-2 weeks | State machine, persistence, recovery tests |
| Skill requirements | Workflow/state-machine design, robust file handling | |
| Dependencies | State schema, execution contract, artifact conventions | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| State machine over-complexity | Medium | Medium | Keep first version minimal |
| Incomplete rollback for custom steps | High | Medium | Support rollback hooks as optional, fail safe otherwise |

**Viability verdict:** RECOMMENDED
**Rationale:** Partial-failure handling is essential once persistent state and environment mutation exist.

#### Solution B: Limit scope to fail-fast plus manual cleanup guidance
**Description:** On failure, mark the run terminal and emit clear cleanup instructions instead of supporting resume/rollback.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low-Medium | Minimal automation |
| Time | 2-3 days | Terminal state handling and docs |
| Skill requirements | CLI/reporting | |
| Dependencies | State logging | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Operational burden on users | Medium | High | Keep artifacts isolated and easy to remove |
| Poor resilience | High | Medium | Acceptable only for early phases |

**Viability verdict:** VIABLE
**Rationale:** Reasonable for early phases if orchestration remains simple, but it will not scale to richer stateful behavior.

### Problem [12]: Missing reproducibility baseline

#### Solution A: Enforce minimum reproducibility metadata on every run
**Description:** Capture dependency lock state, dataset identifier/version, seed values, code revision, environment fingerprint, and effective config in run metadata before reporting success.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Medium-High | Cross-cutting but conceptually clear |
| Time | 4-7 days | Metadata capture, validation, reporting |
| Skill requirements | ML ops basics, environment introspection | |
| Dependencies | State schema, environment handling | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Some templates cannot provide full dataset lineage | Medium | Medium | Start with required identifiers and allow unknowns only with warnings |
| Added friction | Medium | Medium | Auto-capture what can be derived |

**Viability verdict:** RECOMMENDED
**Rationale:** Reproducibility is foundational for trustworthy reporting and any future optimization loop.

### Problem [13]: Metrics comparability across templates

#### Solution A: Separate core reporting metrics from template-specific metrics
**Description:** Define a small normalized core set (status, duration, loss/score directionality, artifact presence, run profile, dataset id, seed) and allow templates to add custom metrics under namespaced keys.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Medium | Reporting schema and adapters |
| Time | 3-5 days | Metric taxonomy and conversion hooks |
| Skill requirements | Metrics modeling, schema design | |
| Dependencies | Template manifests, reporting/state schema | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Over-normalization | Medium | Medium | Keep core set intentionally small |
| Inconsistent metric directionality | Medium | Medium | Require templates to declare objective direction |

**Viability verdict:** RECOMMENDED
**Rationale:** This gives enough comparability for dashboards and iteration without forcing unrealistic uniformity.

### Problem [14]: Undefined security and trust boundaries for custom templates

#### Solution A: Treat templates as trusted code but enforce explicit trust model and capability declarations
**Description:** Document that templates are executable code with project-level trust, require manifests to declare network, filesystem, and install needs, and block hidden dependency installation or unsafe defaults unless explicitly allowed.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Medium | Mostly policy and guardrails |
| Time | 3-4 days | Manifest additions, enforcement, docs |
| Skill requirements | Security design, CLI policy enforcement | |
| Dependencies | Template manifest, environment policy | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| False sense of security | High | Medium | Be explicit that this is policy, not sandboxing |
| User friction | Medium | Medium | Allow explicit opt-ins |

**Viability verdict:** RECOMMENDED
**Rationale:** Full sandboxing is costly, but explicit trust boundaries and capability gating materially reduce accidental risk.

#### Solution B: Sandbox template execution
**Description:** Execute templates inside strict containers or restricted runtimes with limited network/filesystem access.
**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Very High | Cross-platform isolation and operational overhead |
| Time | 2-4 weeks | Runtime, image strategy, permission model |
| Skill requirements | Systems security, container/runtime engineering | |
| Dependencies | Container tooling, host compatibility | |

**Risks:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Major implementation drag | High | High | Restrict to later roadmap phase |
| Poor developer experience | Medium | Medium | Provide opt-out for trusted local runs |

**Viability verdict:** CONDITIONAL
**Rationale:** Stronger security, but too heavy for the current phase unless untrusted templates are a core requirement.

## 3. COMPARATIVE SUMMARY

| Problem | Best solution | Effort | Risk level | Confidence |
|---------|---------------|--------|------------|------------|
| 1. Architecture scope mismatch | Thin orchestrator with strict boundaries | Medium | Medium | High |
| 2. Convenience vs determinism | Machine-safe core with optional UX wrappers | Medium | Medium | High |
| 3. Config flag ambiguity | Versioned configuration contract | Medium | Medium | High |
| 4. Dependency auto-install risk | Isolated per-job environments | Medium-High | Medium | Medium-High |
| 5. Registry/state fragility | Versioned JSON + atomic writes + recovery | Medium | Medium | Medium-High |
| 6. Unsafe auto-iteration | Recommendation-only iteration first | Medium | Medium | High |
| 7. Undefined execution contract | Canonical execution contract + adapters | Medium | Low-Medium | High |
| 8. Interactive confirmation conflict | Explicit interaction modes | Low-Medium | Low | High |
| 9. Undefined smoke/full semantics | Template-declared run profiles | Medium | Medium | High |
| 10. Missing template author contract | Versioned template manifest schema | Medium | Medium | High |
| 11. No rollback/recovery model | Explicit run state machine with checkpoints | High | Medium | Medium |
| 12. Missing reproducibility baseline | Enforce minimum reproducibility metadata | Medium-High | Medium | High |
| 13. Metrics comparability gap | Core normalized metrics + namespaced extensions | Medium | Medium | Medium-High |
| 14. Security/trust gap | Explicit trust model + capability declarations | Medium | Medium | Medium-High |

## 4. OVERALL EFFORT ASSESSMENT

| Scenario | Effort estimate | Assumptions |
| Optimistic | 3-4 weeks | Existing code is clean, few templates exist, low concurrency, JSON storage remains acceptable, no sandboxing |
| Realistic | 5-7 weeks | Moderate refactoring needed, 2-4 templates to migrate, reproducibility and state handling implemented properly, limited iteration support |
| Pessimistic | 8-12 weeks | Architecture is tightly coupled, templates vary widely, environment isolation is messy, rollback/state recovery needs significant redesign |

Biggest effort drivers and biggest risk drivers.

**Biggest effort drivers:** execution-contract refactor, template manifest migration, state machine/recovery design, isolated environment management, reproducibility plumbing.

**Biggest risk drivers:** uncontrolled scope expansion, hidden coupling in current `/train` implementation, weak template discipline, and premature autonomous iteration.

## 5. UNRESOLVED PROBLEMS

- Full sandboxing of untrusted templates has no low-cost solution; capability declarations reduce risk but do not create hard isolation.
- Robust autonomous auto-iteration remains cost-sensitive and should likely stay disabled until reproducibility, metric comparability, and statistical guardrails are proven.
- If concurrent multi-user execution becomes a hard requirement, JSON state may stop being cost-effective and force a storage migration.

## 6. RECOMMENDED RESOLUTION SEQUENCE

1. Write the canonical execution contract for `/train run`, `train.py`, and `training/main.py`.
2. Define the thin-orchestrator scope and explicit non-goals to prevent platform creep.
3. Publish the versioned configuration contract, including interaction-mode semantics.
4. Introduce a versioned template manifest schema with run profiles (`smoke`, `full`) and capability declarations.
5. Define versioned schemas for `job.state.json` and `registry.json`, then implement atomic writes, recovery, and single-writer rules.
6. Enforce minimum reproducibility metadata capture on every run.
7. Add isolated per-job environment handling or, if deferred, disable implicit auto-install and require explicit setup.
8. Implement the explicit run state machine with checkpointed failure and recovery behavior.
9. Normalize core reporting metrics while preserving template-specific extensions.
10. Add recommendation-only iteration based on comparable historical runs.
11. Reassess whether autonomous `auto_iterate` is justified after real usage data exists.
12. Consider SQLite or sandboxing only if scale, concurrency, or trust requirements materially increase.

## 7. VERDICT

**Resolvability:** CHALLENGING

> The roadmap is viable, but only if `/train` is deliberately constrained into a small orchestration layer with explicit contracts, schemas, and reproducibility guarantees. The highest-risk items are not the visible features themselves, but the hidden platform behaviors they imply: state integrity, environment isolation, and trustworthy iteration logic. Build those foundations first, and defer autonomy-heavy features until the underlying execution model is stable.
