# SOLUTION ASSESSMENT

**Subject:** Assessing a proposed two-tier knowledge graph for agent context injection and impact analysis  
**Input type:** Scrutiny assessment output

---

## 1. PROBLEM INVENTORY

All distinct problems, issues, or scrutinized weaknesses being addressed.

| # | Problem | Source | Severity |
|---|---------|--------|----------|
| 1 | Static extraction may be materially inaccurate in dynamic or convention-heavy codebases, leading to wrong function relationships and impact edges. | Scrutiny Assumption #1 / Risk #1 | High |
| 2 | Commit-time indexing may be too slow or brittle for routine use, causing hook bypass and stale graph state. | Scrutiny Assumption #2 / Risk #2 | High |
| 3 | Agents may not reliably maintain provenance fields such as `affected_nodes` and `changed_edges` during normal work. | Scrutiny Assumption #3 | High |
| 4 | The draft → verified → stale lifecycle does not by itself guarantee semantic correctness or useful freshness semantics. | Scrutiny Assumption #4 | Med |
| 5 | The proposed Kuzu + git-tracked JSON architecture may add too much complexity too early. | Scrutiny Assumption #5 | High |
| 6 | There is no defined measurement framework for extraction accuracy, auditability, or task-outcome improvement. | Scrutiny Key Question #2 / Risk #5 | High |
| 7 | Symbol identity may be unstable across renames, moves, anonymous functions, overload-like patterns, and generated endpoints. | Scrutiny Key Question #4 | High |
| 8 | Function-level graphing may be the wrong initial granularity versus starting with file/module/service dependencies. | Scrutiny Key Question #6 | Med |
| 9 | Dual-source maintenance across `graph.json`, frontmatter, and Kuzu may cause synchronization drift and partial-update bugs. | Scrutiny Key Question #5 / Risk #3 | High |
| 10 | Recovery and reconciliation for corrupted, missing, or version-skewed database state across machines and branches is undefined. | Scrutiny Blind Spot | High |
| 11 | Merge conflicts, rebases, and parallel worktrees may break graph artifacts and status transitions. | Scrutiny Blind Spot | High |
| 12 | Security and privacy implications of storing richer structural and data-flow metadata are not addressed. | Scrutiny Blind Spot | Med |
| 13 | Extraction rules may become a long-term maintenance burden as languages, frameworks, and code patterns evolve. | Scrutiny Risk #4 | Med |
| 14 | The proposal may consume substantial engineering effort before proving measurable developer or agent benefit. | Scrutiny Risk #5 / Key Question #1 | High |

---

## 2. SOLUTION PATHS

For each problem in the inventory, list candidate solutions.

### Problem 1 — Extraction accuracy is unreliable

**Problem restatement:** Static analysis may produce incomplete or misleading fine-grained graphs, especially in dynamic stacks.

| Solution | Approach | Effort (S/M/L/XL) | Risk (Low/Med/High) | Viability |
|----------|----------|-------------------|---------------------|-----------|
| A | Limit fine-grained extraction to languages/frameworks with strong static analyzability and explicitly mark unsupported areas. | M | Low | Viable |
| B | Combine static extraction with runtime evidence, tests, and agent/user verification before promoting edges to trusted status. | L | Med | Viable |
| C | Keep only coarse file/module/service dependencies initially and defer function-level edges until accuracy targets are met. | M | Low | Viable |

**Recommended path:** B, with C as the rollout gate. Hybrid evidence improves correctness, while coarse topology provides a safe baseline when fine-grained confidence is low.

### Problem 2 — Commit-time indexing is too costly

**Problem restatement:** If indexing adds noticeable latency or fails often, contributors will bypass hooks.

| Solution | Approach | Effort (S/M/L/XL) | Risk (Low/Med/High) | Viability |
|----------|----------|-------------------|---------------------|-----------|
| A | Move heavy indexing off commit hooks into async post-commit/CI jobs, leaving only lightweight local checks. | M | Low | Viable |
| B | Use incremental diff-based indexing with strict time budgets and automatic fallback to stale markers when limits are exceeded. | L | Med | Viable |
| C | Keep full indexing in commit hooks for freshness. | S | High | Not recommended |

**Recommended path:** A plus B. Keep the developer path fast, and let freshness degrade explicitly rather than blocking commits.

### Problem 3 — Agent-written provenance is unreliable

**Problem restatement:** Agents may omit or misname semantic units when recording graph provenance during edits.

| Solution | Approach | Effort (S/M/L/XL) | Risk (Low/Med/High) | Viability |
|----------|----------|-------------------|---------------------|-----------|
| A | Derive provenance automatically from AST diffs and symbol mapping instead of relying on free-form agent reporting. | L | Med | Viable |
| B | Require structured agent outputs validated against known node IDs before acceptance. | M | Med | Conditional |
| C | Make provenance optional metadata used only for hints, not as authoritative graph updates. | S | Low | Viable |

**Recommended path:** A, with C during early rollout. Automated derivation reduces operator variance and lowers the semantic burden on agents.

### Problem 4 — Lifecycle labels do not ensure quality

**Problem restatement:** Draft/verified/stale labels can signal process state without proving graph correctness.

| Solution | Approach | Effort (S/M/L/XL) | Risk (Low/Med/High) | Viability |
|----------|----------|-------------------|---------------------|-----------|
| A | Define promotion rules tied to evidence thresholds: test coverage, reviewer approval, extractor confidence, and age. | M | Low | Viable |
| B | Replace a single status with separate dimensions: confidence, recency, and evidence source. | M | Low | Viable |
| C | Keep the current labels and rely on manual interpretation. | S | High | Not recommended |

**Recommended path:** B, supported by A. Multi-dimensional quality signals are more truthful than a single lifecycle label.

### Problem 5 — Overall architecture may be over-complex

**Problem restatement:** The two-tier design may introduce synchronization and operational burden before value is proven.

| Solution | Approach | Effort (S/M/L/XL) | Risk (Low/Med/High) | Viability |
|----------|----------|-------------------|---------------------|-----------|
| A | Start with one canonical store and generate all derived views from it. | M | Low | Viable |
| B | Run a thin pilot using only git-tracked coarse topology artifacts, with no database dependency. | M | Low | Viable |
| C | Implement the full dual-store architecture immediately. | L | High | Conditional |

**Recommended path:** B first, then A if the pilot proves value. Complexity should follow demonstrated need.

### Problem 6 — No measurement framework exists

**Problem restatement:** The proposal lacks explicit accuracy metrics, auditing, and evidence that agent outcomes improve.

| Solution | Approach | Effort (S/M/L/XL) | Risk (Low/Med/High) | Viability |
|----------|----------|-------------------|---------------------|-----------|
| A | Define benchmark suites for extraction accuracy, impact-path precision/recall, and agent-task outcome deltas. | L | Low | Viable |
| B | Add periodic sampling and human audit workflows for graph correctness. | M | Low | Viable |
| C | Infer value anecdotally from user sentiment. | S | High | Not recommended |

**Recommended path:** A plus B. Without instrumentation, the project cannot justify its existence or guide improvements.

### Problem 7 — Symbol identity is unstable

**Problem restatement:** Nodes may drift across renames, moves, anonymous constructs, and generated surfaces.

| Solution | Approach | Effort (S/M/L/XL) | Risk (Low/Med/High) | Viability |
|----------|----------|-------------------|---------------------|-----------|
| A | Use stable synthetic IDs derived from symbol kind, file lineage, structural signature, and history-aware rename mapping. | L | Med | Viable |
| B | Treat unstable constructs as coarse nodes only, avoiding false precision for anonymous or generated symbols. | M | Low | Viable |
| C | Key nodes directly by current file path and symbol text. | S | High | Not recommended |

**Recommended path:** A with B as a safety valve. Stable identities are mandatory for credible history and diff mapping.

### Problem 8 — Initial granularity may be wrong

**Problem restatement:** Starting at function-level may be premature when file/module/service-level maps could solve most needs more cheaply.

| Solution | Approach | Effort (S/M/L/XL) | Risk (Low/Med/High) | Viability |
|----------|----------|-------------------|---------------------|-----------|
| A | Stage rollout: file/module graph first, then service/API graph, then function-level only where justified. | M | Low | Viable |
| B | Make graph granularity configurable per repo or language. | M | Med | Viable |
| C | Standardize on function-level for every project from day one. | S | High | Not recommended |

**Recommended path:** A. It minimizes cost while preserving an upgrade path when finer detail proves necessary.

### Problem 9 — Multi-store drift is likely

**Problem restatement:** `graph.json`, frontmatter, and Kuzu may diverge when updates succeed partially or fail mid-pipeline.

| Solution | Approach | Effort (S/M/L/XL) | Risk (Low/Med/High) | Viability |
|----------|----------|-------------------|---------------------|-----------|
| A | Choose a single canonical source and regenerate all other representations deterministically. | M | Low | Viable |
| B | Use transactional update orchestration with version stamps, idempotent retries, and divergence detection. | L | Med | Viable |
| C | Allow independent updates and fix drift manually. | S | High | Not recommended |

**Recommended path:** A. A canonical source sharply reduces state-space complexity; B is still useful if multiple stores remain unavoidable.

### Problem 10 — Recovery and reconciliation are undefined

**Problem restatement:** The design lacks a way to rebuild or reconcile graph state after corruption, missing files, or schema skew.

| Solution | Approach | Effort (S/M/L/XL) | Risk (Low/Med/High) | Viability |
|----------|----------|-------------------|---------------------|-----------|
| A | Make the database fully rebuildable from versioned source artifacts and code, with a one-command repair path. | M | Low | Viable |
| B | Add schema-version checks, migration tooling, and health checks on startup. | M | Low | Viable |
| C | Treat local graph state as disposable cache and avoid storing irreplaceable data there. | S | Low | Viable |

**Recommended path:** A plus C. Rebuildability is the strongest defense against skew and corruption.

### Problem 11 — Branching and worktree workflows are unhandled

**Problem restatement:** Rebases, merges, and parallel worktrees can produce frequent artifact conflicts and ambiguous status transitions.

| Solution | Approach | Effort (S/M/L/XL) | Risk (Low/Med/High) | Viability |
|----------|----------|-------------------|---------------------|-----------|
| A | Store only merge-friendly source artifacts in git and regenerate derived state per branch/worktree. | M | Low | Viable |
| B | Add explicit reconciliation commands after merge/rebase that recompute stale/draft/verified transitions. | M | Low | Viable |
| C | Hand-merge database-backed graph state. | S | High | Not recommended |

**Recommended path:** A with B. Derived state should be recomputed, not merged manually.

### Problem 12 — Security and privacy implications are unaddressed

**Problem restatement:** Richer structural metadata may expose sensitive internals or create retention problems.

| Solution | Approach | Effort (S/M/L/XL) | Risk (Low/Med/High) | Viability |
|----------|----------|-------------------|---------------------|-----------|
| A | Classify graph data, define retention/access rules, and allow projects to disable sensitive edge types. | M | Low | Viable |
| B | Redact or hash selected identifiers in persisted artifacts while keeping reversible local-only views where needed. | L | Med | Conditional |
| C | Ignore security concerns because the source code already exists in the repo. | S | High | Not recommended |

**Recommended path:** A. Governance is cheaper than retrofitting controls after sensitive adoption.

### Problem 13 — Extractor maintenance may become a burden

**Problem restatement:** Supporting changing languages and frameworks can turn extractor logic into a permanent cost center.

| Solution | Approach | Effort (S/M/L/XL) | Risk (Low/Med/High) | Viability |
|----------|----------|-------------------|---------------------|-----------|
| A | Narrow supported stacks and publish clear support tiers and failure modes. | M | Low | Viable |
| B | Build a plugin architecture with contract tests per language/framework adapter. | L | Med | Viable |
| C | Depend on ad hoc rule updates in the core pipeline. | M | High | Not recommended |

**Recommended path:** A first, then B if adoption expands. Scope control is the most practical maintenance strategy.

### Problem 14 — ROI is unproven

**Problem restatement:** The project may absorb significant effort without measurable gains in agent quality or developer speed.

| Solution | Approach | Effort (S/M/L/XL) | Risk (Low/Med/High) | Viability |
|----------|----------|-------------------|---------------------|-----------|
| A | Run a time-boxed pilot with explicit success criteria tied to agent task quality, speed, and rework reduction. | M | Low | Viable |
| B | Roll out the full system broadly and evaluate later. | L | High | Not recommended |
| C | Compare cheaper alternatives first, such as repo maps, dependency indexes, or file-level impact summaries. | M | Low | Viable |

**Recommended path:** A plus C. The proposal should beat simpler baselines before earning full implementation.

---

## 3. CROSS-CUTTING CONCERNS

Issues that affect multiple problems simultaneously.

| Concern | Affected Problems | Mitigation |
|---------|-------------------|------------|
| Canonical-source design | #5, #9, #10, #11 | Pick one authoritative representation; regenerate all derived artifacts and caches deterministically. |
| Progressive rollout by granularity | #1, #5, #8, #14 | Start with coarse topology, validate value, then add fine-grained layers only where metrics justify it. |
| Strong instrumentation and audits | #1, #4, #6, #14 | Define accuracy, freshness, and task-outcome metrics; add benchmark suites and recurring human review. |
| Automation over agent self-reporting | #3, #7, #9 | Derive provenance and identities from code and history rather than relying on manual/agent assertions. |
| Fast-fail, non-blocking developer workflow | #2, #10, #11 | Keep local hooks lightweight; shift expensive work to async/CI paths with clear degraded-mode behavior. |
| Explicit support boundaries | #1, #13 | Publish which stacks and patterns are supported, partial, or unsupported to avoid false confidence. |
| Security governance | #12, #5 | Classify graph data, constrain persistence/access, and disable sensitive metadata where warranted. |

---

## 4. SUMMARY & RECOMMENDED SEQUENCE

First, do not implement the full two-tier architecture. Start with a narrow pilot: one canonical git-tracked coarse topology map, no mandatory Kuzu dependency, and no commit-blocking full indexing. In parallel, define benchmarks for extraction accuracy, freshness, and actual agent-task improvement. Next, add rebuildable derived storage and branch-safe regeneration workflows. Only after the coarse layer proves useful should function-level graphing be introduced, and then only for supported stacks with stable symbol IDs, automated provenance derivation, and explicit confidence scoring. Defer richer persistence, wider language coverage, and sensitive metadata until value, operability, and governance are demonstrated.
