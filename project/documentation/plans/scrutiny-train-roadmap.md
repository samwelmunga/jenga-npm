# SCRUTINY ASSESSMENT

**Proposal:** A phased roadmap to turn the `/train` skill from a thin scaffolding-and-smoke-test utility into a stateful ML training orchestration system with reporting, tracking, template extensibility, and iterative optimization.

---

## 1. CORE ASSUMPTIONS

| # | Assumption | Challenge |
|---|------------|-----------|
| 1 | The current skill architecture can absorb orchestration, state management, reporting, registry tracking, template plugins, and iterative optimization without becoming brittle. | That may be false: this looks like a transition from a simple command wrapper into a workflow platform. If the underlying skill structure was not designed for persistent state and branching run logic, complexity may compound faster than planned. |
| 2 | “Developer convenience first” is the right prioritization for a training system that is also meant to become agent-compatible. | Convenience features can conflict with deterministic, machine-readable behavior. If agent compatibility is deferred too long, later retrofitting may force redesign of output formats, state transitions, and failure semantics. |
| 3 | Wiring the declared config flags is a low-effort foundation task. | Only superficially. The flags imply behavioral contracts, precedence rules, defaults, non-interactive behavior, and error handling. Implementing them safely is more than just reading YAML values. |
| 4 | Auto-installing `requirements.txt` on first run is a convenience win with limited downside. | It also introduces non-determinism, environment mutation, network dependency, version drift, and possible conflicts with the surrounding repo. In a shared agent environment, that is an operational risk, not just a convenience feature. |
| 5 | A registry JSON file is an adequate basis for experiment tracking. | It may suffice initially, but JSON registries often degrade under concurrent writes, schema drift, and partial failure. The proposal assumes single-user, low-volume, low-concurrency usage without stating that constraint. |
| 6 | Heuristic and AI-driven auto-iteration are a logical continuation of the roadmap. | Only if metrics, objective functions, stop criteria, and reproducibility are already robust. Otherwise iteration automates noise and can create a loop of arbitrary config churn rather than disciplined optimization. |

---

## 2. KEY QUESTIONS

1. What is the exact execution contract between `/train run`, `train.py`, and `training/main.py`, and which one is the canonical entrypoint after the redesign?
2. How will the system behave in non-interactive agent contexts when `confirm_before_run` is enabled?
3. What defines a successful smoke run versus a successful full run across different templates and model families?
4. How will dependency installation be isolated to avoid contaminating the repo or machine-wide environment?
5. What schema will `job.state.json` and `jobs/registry.json` follow, and how will schema evolution be handled over time?
6. What prevents `auto_iterate` from repeatedly mutating configs based on statistically weak or non-comparable metrics?
7. How will template authors declare required metrics, datasets, entrypoints, and compatibility constraints for custom templates?
8. What is the rollback story when a run partially succeeds—for example, training completes but state/report/registry writes fail?

---

## 3. RISK REGISTER

| Risk | Severity | Likelihood | Notes |
|---|---|---|---|
| Orchestration scope creep turns `/train` into an under-specified mini-ML platform | High | High | The roadmap adds state, reporting, history, templating, dependency management, and optimization loops. That is a large surface area for a skill originally built as a scaffold runner. |
| Non-deterministic environments from auto-installing dependencies | High | Medium-High | First-run installs can fail, drift, or break other jobs. This is especially risky in shared or agent-managed environments. |
| Registry/state corruption or inconsistency | Medium-High | Medium | JSON-based tracking is vulnerable to partial writes, concurrent updates, and schema mismatch unless atomic write discipline is enforced. |
| `auto_iterate` optimizes toward misleading metrics | High | Medium | If thresholds, validation rigor, and experiment comparability are weak, automatic retries can overfit or waste compute while appearing “smart.” |
| Interactive controls conflict with automation | Medium | High | `confirm_before_run` may be reasonable for humans but problematic for agents, CI, and scripted workflows unless explicit non-interactive semantics are designed. |
| Template extensibility increases support burden | Medium | Medium | User-defined templates sound flexible, but they multiply edge cases around manifests, entrypoints, dependencies, and validation. |

---

## 4. GENUINE STRENGTHS

- The roadmap correctly identifies the `train.py` / `training/main.py` disconnect as a foundational defect rather than a cosmetic issue.
- The layered build order is mostly sensible: it puts execution correctness and state persistence before history and automation.
- The proposal recognizes that currently declared config flags are credibility debt; implementing or removing them is necessary.
- `job.state.json` and timestamped runs are practical steps toward observability and recoverability.
- Deferring AI-guided iteration until after basic heuristics is a comparatively disciplined sequencing choice.

---

## 5. BLIND SPOTS

- The proposal does not define reproducibility requirements: pinned dependencies, dataset versioning, random seeds, and environment capture are barely addressed, yet they are central to any training system.
- It ignores failure-mode design in detail: interrupted runs, partial artifacts, corrupted reports, registry desynchronization, and resume/retry semantics.
- It does not specify how metrics are normalized across heterogeneous templates, which matters if history and auto-iteration are meant to be meaningful.
- It overlooks security and trust boundaries for custom templates, especially if arbitrary paths and install steps are allowed.

---

## 6. FEASIBILITY ASSESSMENT

**Score: 6 / 10**
**Rationale:** The early layers are feasible if the team narrows scope to execution correctness, explicit state, and minimal reporting. The later vision becomes much less credible unless the skill is re-framed as a controlled workflow engine with clear contracts for environments, metrics, and state transitions. As written, the roadmap is directionally coherent but under-specifies the hard operational parts.
**Required conditions:**
- Freeze a canonical execution model and state schema before adding more features.
- Define non-interactive/agent-safe behavior for every flag.
- Add reproducibility and failure-recovery requirements before implementing auto-iteration.
- Constrain dependency installation and custom templates with explicit safety rules.

---

## 7. VERDICT

**Overall judgment:** CAUTIOUS

> The roadmap is strongest where it fixes obvious architectural incoherence and adds basic observability. It becomes much weaker when it assumes that experiment tracking and automated iteration can be layered on cheaply without first solving reproducibility, state integrity, and execution contracts.

---

## 8. RECOMMENDED NEXT STEPS

1. Write a short technical spec for the canonical `/train` execution contract, including entrypoints, phases, flag semantics, and non-interactive behavior.
2. Define versioned schemas for `job.state.json` and `jobs/registry.json`, plus atomic write and recovery rules.
3. Introduce a reproducibility baseline—pinned dependencies, seed capture, dataset references, and run metadata—before building any auto-iteration feature.
