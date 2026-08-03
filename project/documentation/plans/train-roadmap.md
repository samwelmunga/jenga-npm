# `/train` Skill — Implementation Roadmap

## Context

The `/train` skill currently provides two subcommands:
- `/train new <type> <job-name>` — scaffolds a job from one of three templates (`classifiers`, `transformers`, `nlp`)
- `/train run <job-dir>` — runs a two-phase pipeline: `validate.py → train.py --smoke`

The templates are well-structured (config.yaml, training/main.py, checkpoints/, fine-tuned-models/), but the skill is largely hollow:
- `config.yaml` declares 5 workflow flags (`auto_run`, `auto_summarize`, `generate_start_sh`, `confirm_before_run`, `auto_iterate`) that are **all unimplemented**
- `train.py` (root stub) ignores config entirely and uses a hardcoded `LogisticRegression`
- `training/main.py` is the real training script but is **never called** by any skill command
- No full-training mode, no results surfacing, no experiment tracking, no dependency management

---

## Decisions

| # | Decision |
|---|---|
| 1 | **Users** — Developer convenience first → guided experience second → agent-compatible third |
| 2 | **Run lifecycle** — `/train run <job> --full` for three-phase pipeline: pre-flight → smoke → full |
| 3 | **Results** — Terminal summary + markdown report file (`auto_summarize` implemented) |
| 4 | **Experiment tracking** — Registry-level: `jobs/registry.json` + `/train list` + `/train history` |
| 5 | **`auto_iterate`** — Both staged: heuristic base first, AI overlay on top |
| 6 | **Dependencies** — Auto-install `requirements.txt` (with isolated per-job environments) |
| 7 | **Agent I/O** — `job.state.json` always written after every `/train` command |
| 8 | **Templates** — User-definable via `/train new custom <path> <name>` + manifest registration |

---

## Feature Dependency Map

```
LAYER 1 — Foundation (unblocked, fixes existing brokenness)
  ├── Define canonical execution contract: /train run ↔ train.py ↔ training/main.py
  ├── Publish versioned config contract (flag semantics, interaction modes, defaults)
  ├── Fix train.py → training/main.py disconnect (wire to actual training logic)
  ├── Add Phase C (full training) to /train run --full
  ├── Isolated per-job environments + auto-install with lock capture
  └── Always write job.state.json after every command

LAYER 2 — Observability (requires Layer 1)
  ├── Versioned template manifest schema (run profiles, entrypoints, metrics, capabilities)
  ├── auto_summarize: terminal metric summary + markdown report
  ├── Timestamped run folders (no more result overwrites)
  ├── jobs/registry.json — central job + run tracking (versioned JSON + atomic writes)
  └── /train list — browse registered jobs

LAYER 3 — History, Control & Reproducibility (requires Layer 2)
  ├── Explicit run state machine (created → env_ready → running → succeeded/failed/interrupted)
  ├── Minimum reproducibility metadata on every run (seed, dataset ref, env fingerprint, config hash)
  ├── Normalized core metrics schema + namespaced template extensions
  ├── /train history <job> — show run timeline + metrics
  ├── confirm_before_run with explicit interaction modes (interactive / non-interactive / fail-on-prompt)
  ├── generate_start_sh — emit start.sh artifact
  └── /train new custom <path> <name> — user-defined templates + security/trust declarations

LAYER 4 — Recommendation Iteration (requires Layer 3)
  └── auto_iterate (phase 1) — recommendation-only: suggest config changes from history, require approval

LAYER 5 — AI-Guided Iteration (requires Layer 4 + real usage data)
  └── auto_iterate (phase 2) — agent reads report, proposes config edits with reasoning + confidence
```

---

## Prioritized Feature Table

| Feature | Benefit | Effort | Priority |
|---|---|---|---|
| Canonical execution contract | 🔴 Critical — unblocks everything | Low (spec) | **P0** |
| Versioned config contract + interaction modes | 🔴 Critical — flags are live lies | Low-Medium | **P0** |
| Fix train.py → training/main.py | 🔴 Critical — training doesn't actually run | Low | **P0** |
| Three-phase pipeline + `--full` | High — unlocks real training | Medium | **P1** |
| Isolated env + lock capture | High — removes auto-install risk | Medium-High | **P1** |
| `job.state.json` | High — enables agent use | Low | **P1** |
| Template manifest schema (run profiles) | High — enables comparability | Medium | **P1** |
| `auto_summarize` + markdown report | High — makes results visible | Medium | **P1** |
| Registry + atomic writes + `/train list` | Medium — discoverability + durability | Medium | **P2** |
| Run state machine + rollback/recovery | High — resilience for stateful runs | High | **P2** |
| Reproducibility metadata per run | High — prerequisite for iteration | Medium-High | **P2** |
| Normalized core metrics schema | Medium — comparability across templates | Medium | **P2** |
| `/train history <job>` | Medium — experiment context | Low (after registry) | **P3** |
| `confirm_before_run` interaction modes | Medium — safety + automation-safe | Low | **P3** |
| `generate_start_sh` | Low-Medium | Low | **P3** |
| Trust model + capability declarations for custom templates | Medium — security hygiene | Medium | **P3** |
| `/train new custom <path> <name>` | Medium — extensibility | Medium | **P3** |
| `auto_iterate` recommendation-only | High — power feature, low risk | Medium | **P4** |
| `auto_iterate` AI overlay | Very High — differentiator | High | **P5** |

---

## Recommended Build Sequence

1. **Write the execution contract** — canonical spec for `/train run`, `train.py`, `training/main.py` entrypoints, phases, exit codes, artifact locations
2. **Define thin-orchestrator scope** — explicit non-goals to prevent platform creep
3. **Publish versioned config contract** — flag types, defaults, precedence, interaction modes (`--interactive`, `--non-interactive`)
4. **Versioned template manifest schema** — run profiles (`smoke`, `full`), capability declarations, required metrics
5. **Versioned state schemas + atomic writes** — `job.state.json` and `registry.json` with recovery rules
6. **Reproducibility metadata** — seed capture, dataset ref, env fingerprint, config hash on every run
7. **Environment isolation** — per-job venv or isolated install with lockfile; if deferred, disable implicit auto-install
8. **Run state machine** — explicit lifecycle states with checkpoint/recovery for interrupted runs
9. **Normalized metrics schema** — small core set + namespaced template extensions
10. **Recommendation-only iteration** — advisory suggestions from history, explicit approval required
11. **Reassess autonomous `auto_iterate`** — only after real usage data and proven reproducibility
12. **Sandboxing** — only if untrusted templates or multi-user concurrency become hard requirements

---

## Effort Estimates

| Scenario | Estimate | Assumptions |
|----------|----------|-------------|
| **Optimistic** | 3–4 weeks | Clean existing code, few templates, JSON storage acceptable, no sandboxing |
| **Realistic** | 5–7 weeks | Moderate refactor, 2–4 templates to migrate, reproducibility + state handled properly |
| **Pessimistic** | 8–12 weeks | Tight coupling, template diversity, environment isolation complexity, state recovery redesign |

**Biggest effort drivers:** execution-contract refactor, template manifest migration, state machine + recovery design, isolated environment management, reproducibility plumbing.

**Biggest risk drivers:** uncontrolled scope expansion, hidden coupling in current implementation, weak template discipline, premature autonomous iteration.

---

## 🔍 Deep Dive Synthesis

### Scrutiny Findings
The scrutiny rated the roadmap **6/10 — CAUTIOUS**. Key concerns:
- Architecture scope creep is a **High/High** risk — the roadmap adds 5+ distinct concerns to what was a simple wrapper
- Auto-install is an **operational hazard** in shared or agent-managed environments (non-determinism, version drift, environment mutation)
- JSON registry fragility under partial writes or concurrent access
- `auto_iterate` can automate noise if reproducibility and metric integrity aren't established first
- Critical blind spots: no reproducibility story, no failure-mode design, no metrics normalization, no template security model

→ Full assessment: `./scrutiny-train-roadmap.md`

### Solution Paths
The solution assessor rated overall resolvability as **CHALLENGING**. Recommended paths:
- **Thin orchestrator with strict boundary enforcement** (not a generic platform) — RECOMMENDED
- **Machine-safe behavior as default** with optional human UX wrappers — RECOMMENDED
- **Versioned config + template manifest schemas** — RECOMMENDED before any flag wiring
- **Recommendation-only `auto_iterate`** (not autonomous execution) until reproducibility is proven — RECOMMENDED
- **Atomic JSON writes + recovery** as near-term state solution; SQLite only if concurrency demands it
- **Explicit trust model + capability declarations** for custom templates (not full sandboxing)

→ Full assessment: `./solution-assessment-train-roadmap.md`

### Open Decisions
- **Environment isolation strategy**: full per-job venv (recommended, more effort) vs. fail-fast with pre-provisioned envs (simpler, less friendly)
- **Storage backend**: stay with hardened JSON vs. migrate to SQLite (defer until concurrency is a real constraint)
- **Sandbox scope**: capability declarations only vs. container-based isolation (defer unless untrusted templates are in scope)
- **`auto_iterate` timeline**: only enable after reproducibility metadata and metric comparability are validated in production
