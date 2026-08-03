# SCRUTINY ASSESSMENT

**Proposal:** Introduce a per-project two-tier knowledge graph, combining a git-tracked coarse topology map with an automatically generated fine-grained function graph, to support agent context injection and impact analysis.

---

## 1. CORE ASSUMPTIONS

What the proposal takes for granted — each directly challenged.

| # | Assumption | Challenge |
|---|------------|-----------|
| 1 | Static analysis can reliably extract function-level relationships, data flows, and impact edges from the target codebase. | For JS/TS in particular, dynamic dispatch, reflection, framework conventions, code generation, and runtime wiring often make static extraction incomplete or misleading. If the graph is materially wrong, agents may become more confident and less correct. |
| 2 | Running the indexing pipeline on every commit is cheap enough to be routine. | Commit-time hooks are where developers are least tolerant of latency and flakiness. If indexing is slow, brittle, or noisy, people will bypass hooks, disable them, or accumulate stale graph state. |
| 3 | Agents can accurately maintain provenance fields like `affected_nodes` and `changed_edges` during normal task execution. | This assumes agents consistently identify the right semantic units, name them deterministically, and avoid omission. That is a high bar, especially for refactors, cross-cutting edits, and partially understood legacy code. |
| 4 | The draft → verified → stale lifecycle will keep graph quality high. | Status labels do not by themselves solve semantic correctness. A node can be "verified" against incomplete tests or superficial review, and "stale" may over-trigger when code moves or extraction rules change. |
| 5 | Kuzu plus a git-tracked JSON layer is the right complexity level for the expected payoff. | This introduces dual storage, synchronization logic, schema evolution, tooling dependencies, and hook orchestration before demonstrating that simpler indexes or file-level maps are insufficient. |

---

## 2. KEY QUESTIONS

Sharp, unanswered questions the proposer must be able to address before proceeding.

1. What concrete agent failures today are caused by missing topology or impact context, and how often do they occur?
2. How will extraction accuracy be measured, audited, and regressed over time, rather than assumed?
3. What is the expected commit-time overhead, and what is the fallback behavior when parsing, diff mapping, or DB upserts fail?
4. How are symbol identities kept stable across renames, moves, overload-like patterns, anonymous functions, and framework-generated endpoints?
5. What prevents divergence between `graph.json`, summary frontmatter, and the Kuzu database when one update succeeds and another fails?
6. Why is function-level graphing the right initial granularity instead of starting with file/module/service dependencies only?

---

## 3. RISKS

| # | Risk | Severity (Low/Med/High) | Likelihood (Low/Med/High) |
|---|------|------------------------|--------------------------|
| 1 | The graph becomes partially incorrect, causing agents to inject misleading context or miss real impact paths. | High | High |
| 2 | Commit hooks slow down or fail frequently enough that contributors bypass them, undermining graph freshness. | High | Med |
| 3 | Dual-source maintenance (frontmatter + JSON + Kuzu) creates synchronization bugs and hard-to-debug state drift. | High | High |
| 4 | Extraction rules become a long-term maintenance burden whenever languages, frameworks, or coding patterns evolve. | Med | High |
| 5 | The proposal consumes substantial engineering effort without proving that task outcomes measurably improve. | High | Med |

---

## 4. BLIND SPOTS

Things the proposal appears not to have considered at all.

- A recovery and reconciliation strategy for corrupted, missing, or version-skewed Kuzu state across machines and branches.
- How merge conflicts, rebases, and parallel worktrees affect `graph.json`, provenance frontmatter, and stale/draft status transitions.
- Security and privacy implications of storing richer code structure and data-flow metadata if projects later include sensitive domains or third-party code.

---

## 5. STRENGTHS

What the proposal gets right — briefly and without embellishment.

- It separates a human-inspectable coarse model from a machine-queryable fine-grained model.
- It explicitly defines schemas, statuses, lifecycle hooks, and non-goals instead of leaving the system conceptually vague.
- It ties graph updates to task summaries, which at least attempts provenance rather than treating extraction as context-free.

