# Ideas

<!-- Format: <idea text> (one line per idea; terminal tags PROMOTED / DISCARDED appended by /brainstorm, not by /idea) -->
Investigate concurrent-write race on project/queue/.session_handoff.json when multiple developer/tester sessions run in parallel (Origin: E35_S01_T03 — surfaced by tester during /jenga e35 rollout, one handoff clobbered another before on_session_end.sh could consume it) PROMOTED → E37_S01 (2026-08-25)
Replace /commit's narrative changed-file-detection for doc-sync's `source:` scoping with a single canonical script (similar to other skills' script-offload pattern) for determinism across agent sessions, and define a one-line prefix/header convention so doc-sync's folded report is visually distinguishable from /commit's own output (Origin: E28_S03_T02 — tester rapport project/rapports/problems/E28_S03_T02-changed-file-detection-narrative-and-no-report-format.md, both findings low severity/non-blocking, deferred rather than addressed in-task) (2026-08-25)
