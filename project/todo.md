# Todo

<!-- Format: <mission title>: <E##_S##> (epic/story ref optional) -->

Foundation — Execution contract, config contract, full training pipeline, job isolation, job.state.json: E19_S01
Template manifest schema, run profiles, auto_summarize, registry, /train list: E19_S02
Run state machine, reproducibility metadata, normalized metrics schema, /train history: E19_S03
History UX, confirm_before_run, generate_start_sh, custom templates + trust model: E19_S04
Recommendation-only auto_iterate — heuristic suggestion engine with approval flow: E19_S05
AI-guided auto_iterate — agent overlay with reasoning, confidence, and guardrails: E19_S06
Schema, templates & coarse graph foundation — node/edge JSON schema, validate script, /init scaffold: E20_S01
Indexing pipeline — tree-sitter, ast-grep, Kuzu DB, stable IDs, non-blocking git hook: E20_S02
Agent integration — context injection, impact analysis, summary frontmatter, lib helpers: E20_S03
Lifecycle & reconciliation — session-end hook, stale detection, branch safety, schema versioning: E20_S04
Quality & measurement — benchmarks, multi-dimensional node quality, audit workflow: E20_S05
DB migration job — export Kuzu → Neo4j/Postgres, dry-run, idempotent, no hardcoded creds: E20_S06
Deferred extensions — MCP server, Mermaid visualization, cross-project graphs, language detection: E20_S07

Implement /clearify skill with /wtf alias — ambiguity detection + clarification for confused users: E21_S01

Handoff document schema & Developer agent rolling checkpoint: E23_S01
/handoff skill — explicit handoff trigger for when tokens run low: E23_S02
/pickup skill — agent resumption after manual work with Tester validation: E23_S03
/continue enhancement — handoff-aware session start, surface interrupted tasks: E23_S04
Handoff lifecycle management & /reconcile integration: E23_S05

Frontmatter last_update provenance resolution and fallback behavior: E24_S05
/doc integration, distribution, authoring docs, and validation coverage: E24_S06

<!-- RECONCILED: Setup wizard & secrets guide (mobile-ios wizard template + production secrets guide): E22_S02 ✅ -->

<!-- RECONCILED: npm pipeline scripts (npm_pipeline.sh + validate_npm_env.sh): E26_S05 ✅ -->

Improve automatic handoff reliability between process steps (developer→tester routing races on .session_handoff.json; missed post-task steps: worktree merge/cleanup, board status updates, wrong-branch merges). Investigate current mechanism, hook firing, per-task handoff files, post-merge reconcile pass, who owns merges.

Update publish SKILL.md with npm examples and metadata: E26_S07_T01
