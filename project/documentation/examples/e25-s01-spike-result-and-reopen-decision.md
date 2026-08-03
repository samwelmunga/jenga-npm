# E25_S01 Spike — What It Is, What It Found, and What Must Be Decided

---

## 1. What it is

A **measurement spike** is a throwaway investigation whose only deliverable is *data*. It produces no production code — only a number that replaces a guess so that future architectural decisions rest on evidence.

E25_S01 was the gate story for Epic E25 (Board Index Substrate). Before any real library code was written, the spike asked: *"How fast is a live filesystem walk over the board?"*

---

## 2. Why it exists

The plan for E25 proposed a **"live walk" architecture**: no cache, no persisted graph — just read `project/*` fresh on every call. The plan estimated this would take ~50–200ms and called that "fast enough."

That was a guess. The scrutiny assessment flagged it as **Assumption A1 / Risk 4**:

> *"If measured cold latency > 150ms, revisit the persistence-as-optional-cache decision before S02 opens."*

Without the spike, S02–S07 would have been designed around an untested assumption. If the assumption was wrong, the entire library architecture would need reworking mid-epic — expensive to undo.

---

## 3. How it worked

The spike ran in three tasks:

```
T01 — Throwaway extractor
      Walks project/board/, project/documentation/, project/todo.md
      Parses frontmatter, derives edges, emits JSON to stdout

T02 — Synthetic 10× board + hyperfine
      Generated ~4,811 files (vs real board's 484)
      Used hyperfine (10 runs, cold cache flush) to benchmark both

T03 — Measurement report + plan doc update
      Wrote the numbers, issued the DECISION line, updated §7
```

**Results:**

| Board | Median | p95 |
|---|---|---|
| Real board (484 files) | 126ms | **166ms** |
| Synthetic 10× (4,811 files) | 949ms | 1,011ms |

**The gate was 150ms p95 on the real board. The measured p95 was 166ms. Gate breached → `DECISION: REOPEN`.**

Profiling identified *why*: frontmatter parsing accounts for ~79% of latency (47ms for board files + 25ms for doc files). Directory walking, edge derivation, and JSON serialization are negligible.

---

## 4. The decision that must be resolved

Before S02 can open, one question must be answered:

> **Should E25 proceed with the live-walk architecture, or introduce a persistence/caching layer?**

Two paths:

**Path A — Proceed anyway (accept the 166ms)**
- p95 is 166ms — only 16ms over the gate
- The gate (150ms) was a soft guideline, not a hard SLA
- If `/status` is the primary consumer and runs interactively, 166ms is imperceptible
- Risk: if the board grows (more stories, more plans), latency scales — the 10× synthetic board hit ~950ms median

**Path B — Introduce an optional cache**
- On first call (or on `/commit`), serialise the walked graph to `project/.board-index-cache.json`
- Subsequent calls read the cache; cache is invalidated on any board file change
- Eliminates the frontmatter parse cost on warm calls
- Cost: added complexity in S02 (cache write, invalidation logic, stale detection)

The plan's original framing was "persistence-as-optional-cache" — meaning the cache is a *performance optimisation*, not the primary architecture. Path B keeps the live-walk as the source of truth but adds a warm-path shortcut.

**Decision rule:**
- If p95 ≤ 150ms on real board → Path A (proceed, no cache)
- If p95 > 150ms on real board → Path B (reopen, design cache before S02 opens)

The spike returned 166ms. The recommendation is **Path B** — but the decision belongs to the epic owner before S02 is decomposed.

---

## 5. Concrete before/after

**Before the spike** (S02 would have opened with this assumption):
```markdown
## §7 Persistence & Freshness
No persisted artifact. The library walks project/* on every call.
Small board (~100s of files) → fast enough (~50–200ms).
```

**After the spike** (§7 now reads):
```markdown
## §7 Persistence & Freshness
No persisted artifact. The library walks project/* on every call.
The E25_S01 measurement spike recorded **126ms median** and **166ms p95**
on the current board across 10 hyperfine runs (synthetic 10×: 949ms median,
1,011ms p95). Because the real-board p95 exceeded the 150ms gate, the
persistence-as-optional-cache decision reopens before S02.
See ./board-index-substrate-measurement.md.
```

The spike turned a guess into a traceable, dated, reproducible measurement.
