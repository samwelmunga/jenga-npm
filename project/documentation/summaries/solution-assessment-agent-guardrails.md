# SOLUTION ASSESSMENT

**Subject:** Resolving the structural weaknesses in the five-part Developer guardrail system for the Jenga agentic workflow
**Input type:** Scrutiny assessment output (Mode B — chained)

---

## 1. PROBLEM INVENTORY

All distinct problems, issues, or scrutinised weaknesses being addressed.

| # | Problem | Source | Severity |
|---|---------|--------|----------|
| 1 | `developer_triggers.jsonl` is read by the Developer at session start independently of what `/do` passed — allowing multi-task processing regardless of the one-task-per-call guardrail | From scrutiny §1 (Assumption 1), §5 (Blind Spots), §6 (Required conditions) | High |
| 2 | The checkpoint loop assumes persistent in-memory state between turns; no checkpoint file schema exists; a fresh sub-agent invocation cannot reliably reconstruct mid-task context from disk | From scrutiny §1 (Assumption 5), §2 (Question 2), §5 (Blind Spots) | High |
| 3 | The scope boundary diff-check is self-policed by the agent it is designed to constrain; rogue rationalisation invalidates it as a mechanical control | From scrutiny §1 (Assumption 3), §3 (Risk Register) | High |
| 4 | `maxTurns: 40` is uncalibrated — turns count tool invocations uniformly regardless of complexity, producing false-positive halts on legitimate complex work and potentially interrupting the Tester's long-running test lifecycle | From scrutiny §1 (Assumption 4), §2 (Question 3), §3 (Risk Register) | High |
| 5 | The Tester agent — sole authority on board status writes — carries no equivalent guardrails (no turn cap, no scope declaration, no checkpoint requirement) | From scrutiny §2 (Question 4), §5 (Blind Spots) | Med |
| 6 | When the scope-violation check fires, the worktree is left in partial uncommitted state with no defined recovery path for the human, the Scrum Master, or a subsequent Developer invocation | From scrutiny §2 (Question 1), §5 (Blind Spots), §6 (Required conditions) | Med |
| 7 | The checkpoint rapport write is itself a tool call — if turn 40 is consumed by implementation work rather than housekeeping, the checkpoint mechanism fails silently with no rapport, no queue entry, and no visible error | From scrutiny §3 (Risk Register) | High |
| 8 | Scope pre-declaration by the agent produces a plausible but non-binding list; dynamic discoveries legitimately extend scope during implementation; overly broad declarations (e.g., `src/**`) defeat the diff check entirely | From scrutiny §1 (Assumption 2), §3 (Risk Register) | Med |

---

## 2. SOLUTION PATHS

---

### Problem 1: Queue bypass — `developer_triggers.jsonl` processed independently of invocation scope

**Problem statement:** The Developer agent definition instructs it to process all entries in `developer_triggers.jsonl` at session start. If the queue contains more than one `implementation_assignment` entry when a sub-agent is invoked, it will attempt all of them regardless of the single-task payload passed by `/do`. Guardrail 1 only constrains the invocation payload, not the queue read.

---

#### Solution A: Single-consume queue discipline in `developer.md`

**Description:** Amend the Developer agent definition to read exactly one trigger from `developer_triggers.jsonl` per invocation — the first unprocessed entry — and halt after completing it. The agent must not loop across multiple queue entries in a single session. Additionally, instruct the agent to mark the consumed trigger as processed (e.g., move it to `developer_triggers_processed.jsonl` or annotate it with `"status": "consumed"`) before beginning work, so a concurrent or subsequent invocation cannot claim the same entry.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Single targeted text change to `developer.md` |
| Time (rough order of magnitude) | Hours (2–4h) | Draft, review, test against a two-entry queue scenario |
| Skill requirements | Agent prompt engineering | No code changes required |
| Dependencies | None — standalone change | Should be done before any other guardrail is activated |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Agent rationalises looping as "processing the one assigned task requires context from adjacent tasks" | Med | Low | The instruction must explicitly say "process one trigger and halt" — not "focus on one task" |
| Consumed-trigger annotation not written before work begins, allowing re-processing on restart | Med | Med | Make the consume-and-annotate step the very first action, logged to `events.json` |
| Two concurrent `/do` invocations race to claim the same queue entry | Low | Low | Advisory: document that concurrent `/do` invocations on the same queue are unsupported; defer locking to a later phase |

**Viability verdict:** RECOMMENDED
**Rationale:** This is a targeted one-file text change that closes a known bypass route. It requires no new architecture and has no downstream dependencies. Deferring it makes every other one-task guardrail meaningless.

---

#### Solution B: Queue gating at `/do` skill level — pop-before-invoke

**Description:** Modify the `/do` skill to remove (or lock) the relevant trigger entry from `developer_triggers.jsonl` before invoking the Developer sub-agent, and pass the task exclusively via the invocation payload. The Developer receives no queue file to read and processes only what was passed at invocation time. The queue file becomes a staging area that `/do` manages, not the Developer.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med | Requires modifying the `/do` skill definition and potentially the queue write contract |
| Time (rough order of magnitude) | Days (1–2d) | Skill edit + integration testing + ensuring `on_session_end.sh` hook still writes correctly |
| Skill requirements | Agent prompt engineering + shell scripting | Hook interaction must be verified |
| Dependencies | Understanding of how `/do` currently populates the queue | Must not break the `SessionEnd` hook queue-write flow |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Developer agent definition still has queue-read instruction — both surfaces now conflict | High | High | Must be paired with Solution A's instruction change; cannot stand alone |
| Pop operation fails mid-session leaving queue in inconsistent state | Med | Low | Use atomic rename or a `_claimed` suffix rather than delete |

**Viability verdict:** CONDITIONAL
**Rationale:** Valid architectural improvement but must be paired with Solution A's agent-definition change; deploying either in isolation leaves the bypass partially open.

---

#### Solution C: Queue file lock + single-entry enforcement via pre-session script

**Description:** Introduce a shell script (invoked by `/do` before spawning the Developer sub-agent) that reads `developer_triggers.jsonl`, extracts exactly one entry, writes it to a dedicated `developer_active_task.json` file, and comments out or removes remaining entries. The Developer is instructed to read only `developer_active_task.json`, never the raw queue file.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med | New shell script + agent instruction update + hook coordination |
| Time (rough order of magnitude) | Days (2–3d) | Script authoring, testing edge cases (empty queue, malformed entries) |
| Skill requirements | Shell scripting + agent prompt engineering | |
| Dependencies | Solution A (agent instruction change) still required | The script alone is bypassable if agent still reads the queue directly |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Adds a new file contract that must be kept in sync with existing queue infrastructure | Med | Med | Document clearly in `AGENT.md` and agent definition |
| Script failure leaves `developer_active_task.json` absent — Developer has no task and silently does nothing | Med | Low | Script must exit non-zero on failure; `/do` must check for it |

**Viability verdict:** VIABLE
**Rationale:** More robust than instruction-only but adds infrastructure. Best deployed after Solution A is verified — use as a second layer, not a first.

---

### Problem 2: Stateless architecture mismatch — no checkpoint file contract

**Problem statement:** The proposed checkpoint loop assumes the Developer sub-agent can "suspend in-place" and resume from memory. In reality, `maxTurns` termination ends the invocation; resumption requires a brand-new sub-agent that must reconstruct all context from disk. No checkpoint file schema has been specified, making faithful resumption architecturally impossible as currently designed.

---

#### Solution A: Formal checkpoint file contract at a fixed path

**Description:** Define a mandatory checkpoint file schema at `project/queue/.developer_checkpoint.json`. The Developer agent definition must instruct the agent to write this file when its remaining turn budget drops below a defined threshold (e.g., at turn N-5, where N is `maxTurns`). Required fields: `task_id`, `story_id`, `epic_id`, `worktree_path`, `last_commit_sha`, `in_progress_file`, `completed_files[]`, `pending_files[]`, `next_planned_action` (human-readable string), `checkpoint_reason` (`"turn_budget"` | `"scope_violation"` | `"conflict_halt"`), `timestamp`. A fresh sub-agent invocation checks for this file at session start and resumes from its declared state if present. The file is deleted after successful task completion.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med | Schema design + agent instruction update + resumption path in agent definition |
| Time (rough order of magnitude) | Days (1–2d) | Schema authoring, instruction update, test with a simulated mid-task interrupt |
| Skill requirements | Agent prompt engineering + JSON schema design | |
| Dependencies | Problem 4 solution (calibrated `maxTurns`) must be resolved first — checkpoint threshold is meaningless without a stable ceiling | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Agent writes incomplete or incorrect `in_progress_file` / `next_planned_action` fields, producing a misleading checkpoint | Med | Med | Include a validation instruction: "verify checkpoint fields are accurate before writing" |
| Turn budget exhausted before checkpoint write (Problem 7) makes the contract unreachable | High | Med | Addressed jointly with Problem 7 solutions below |
| Checkpoint file from an abandoned session misleads a new invocation | Med | Low | Validate `last_commit_sha` against the actual worktree before trusting the checkpoint |

**Viability verdict:** RECOMMENDED
**Rationale:** This is the minimum viable implementation of the checkpoint loop. Without a specified schema, the loop is aspirational text. With it, a new sub-agent has a deterministic, verifiable starting point.

---

#### Solution B: Abort-and-requeue rather than checkpoint-and-resume

**Description:** Remove the checkpoint-resume model entirely. Instead, when the Developer's remaining turn budget drops below the threshold, it commits whatever is complete, writes a structured partial-completion rapport to `project/rapports/problems/`, sets the task status to `In Progress` (not `Blocked`), and halts. The `on_session_end.sh` hook detects the rapport, writes a trigger to the queue, and the Scrum Master reviews on the next session — deciding whether to re-dispatch or split the task. There is no attempt to resume from an intermediate state; each invocation is a complete unit of work.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Leverages existing rapport and queue infrastructure |
| Time (rough order of magnitude) | Hours (3–6h) | Agent instruction update + rapport template addition |
| Skill requirements | Agent prompt engineering | No new files or schemas required |
| Dependencies | `on_session_end.sh` already handles rapport detection — no hook changes needed | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Partial implementation left in worktree creates ambiguity for the re-dispatched invocation | Med | Med | Instruct agent to commit all in-progress work (even partial) before halting, so worktree is clean |
| Scrum Master session may not run promptly, stalling the pipeline | Low | Low | Acceptable — this is already the normal async flow for `Blocked` tasks |
| Large tasks repeatedly halt and re-queue, never completing | Med | Low | Calibrating `maxTurns` (Problem 4) reduces frequency; Scrum Master can split the task |

**Viability verdict:** RECOMMENDED
**Rationale:** Architecturally honest — it works with the stateless execution model rather than against it. Lower implementation risk than Solution A and requires no new file contracts. Preferred as the primary mechanism; Solution A's checkpoint contract can be added on top later for richer resumption fidelity.

---

#### Solution C: Two-phase invocation — plan phase then implement phase

**Description:** Restructure `/do` to invoke the Developer twice per task: first a short planning invocation (capped low, e.g., `maxTurns: 15`) that reads context and writes a structured execution plan to `project/queue/.developer_plan.json`, then a second implementation invocation that reads the plan and executes it. The plan file serves as a de facto checkpoint contract between the two invocations. Turn budget is split across predictable phases rather than consumed uniformly.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | High | Requires `/do` skill refactor, new file contract, two agent instruction modes |
| Time (rough order of magnitude) | Weeks (1–2w) | Design + implementation + integration testing across simple/medium/complex tasks |
| Skill requirements | Agent prompt engineering + `/do` skill authoring | |
| Dependencies | Requires stable plan file schema; plan quality determines implementation quality | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Plan phase underestimates implementation scope, producing an inaccurate execution plan | High | Med | Plan phase must include a "confidence" field and a flag for tasks requiring human approval before proceeding |
| Doubles invocation overhead for every task | Med | High | Acceptable for complex tasks; for simple tasks the planning invocation is very short |
| Significant rework of existing workflow | High | High | This is a redesign, not a patch |

**Viability verdict:** CONDITIONAL
**Rationale:** Architecturally sound for complex task classes but represents a significant workflow redesign. Defer to a later phase after Problems 1–4 are resolved.

---

### Problem 3: Self-policing scope check

**Problem statement:** The diff-based scope boundary check runs in the same agent context as the reasoning that may have produced the out-of-scope changes. An agent that rationalised implementing five tasks will apply equally motivated reasoning to the scope check, producing justifications for why all changes were "required." Text-level rules do not constitute a mechanical barrier when the rule enforcer and the rule violator are the same context.

---

#### Solution A: Externalise the diff check to a pre-commit hook

**Description:** Implement the scope boundary check as a git pre-commit hook (`hooks/pre-commit`) rather than an agent instruction. The hook reads the declared scope from `project/queue/.developer_plan.json` (or `developer_active_task.json` from Problem 1's Solution C) and compares it against `git diff --name-only --cached`. If any staged file is not in the declared list, the hook exits non-zero, blocking the commit. The agent receives the hook's error output and is instructed to report it as a scope violation and halt — it cannot override the hook.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med | Shell script authoring + hook installation + file contract for scope declaration |
| Time (rough order of magnitude) | Days (1–2d) | Script + testing against both in-scope and out-of-scope staging scenarios |
| Skill requirements | Shell scripting + git hooks | |
| Dependencies | A machine-readable scope declaration file must exist (links to Problem 8 solution and Problem 1's Solution C) | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Scope declaration is too broad (e.g., `src/**`) — hook passes everything, defeating the control | Med | Med | Hook must reject wildcard patterns; scope must be file-level, not directory-level globs |
| Agent bypasses hook by using `git commit --no-verify` | High | Low | Instruct the agent that `--no-verify` is prohibited; monitor `events.json` for its use |
| Hook fires on legitimate dynamic scope extensions, blocking valid commits | Med | Med | Provide a structured "scope amendment request" path: agent writes amended scope to plan file, user approves before proceeding |

**Viability verdict:** RECOMMENDED
**Rationale:** The only candidate that places enforcement outside the agent's own reasoning context. A process-level hook is a genuine mechanical barrier. Dependent on a machine-readable scope file but that dependency is shared with other improvements.

---

#### Solution B: Post-commit diff audit by an independent sub-agent invocation

**Description:** After the Developer commits, `/do` invokes a lightweight, single-purpose "Scope Auditor" sub-agent with a minimal context: the declared scope file and the `git diff HEAD~1 --name-only` output. The auditor has no access to the Developer's reasoning history and assesses only whether the committed files match the declared scope. Its output is a pass/fail report written to `events.json`. The Tester is instructed to check this report before accepting the Developer's work.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med | New sub-agent definition + `/do` skill change + Tester instruction update |
| Time (rough order of magnitude) | Days (2–3d) | Agent definition + integration test + Tester instruction update |
| Skill requirements | Agent prompt engineering | |
| Dependencies | Tester must be updated to gate on auditor output | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Audit happens post-commit — out-of-scope changes are already in the worktree history | Med | High | Use as a detection + escalation mechanism, not a prevention mechanism; pair with Solution A for pre-commit prevention |
| Adds a third sub-agent invocation per task, increasing latency | Low | High | Auditor invocation is very short (minimal context); overhead is small |

**Viability verdict:** VIABLE
**Rationale:** Better than self-policing but is a post-commit detection tool, not a pre-commit prevention tool. Best deployed as a complement to Solution A, not a replacement.

---

#### Solution C: Instruct the Tester to perform the scope audit during validation

**Description:** Add a scope audit step to the Tester's validation lifecycle. The Tester (already an independent invocation from the Developer) reads the Developer's declared scope file and runs `git diff <commit_sha> --name-only` to compare. Any discrepancy causes the Tester to set the task status to `Rejected` and write a rapport before running any tests.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Tester instruction update only |
| Time (rough order of magnitude) | Hours (2–4h) | |
| Skill requirements | Agent prompt engineering | |
| Dependencies | Scope declaration file must exist at a predictable path | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Audit happens after implementation and commit — worktree and commit history already contain the violation | Med | High | Acceptable as a detection layer; combine with pre-commit hook (Solution A) for prevention |
| Tester may also exhibit motivated reasoning if it inherits context from the Developer's rapport | Low | Low | Tester invocations are stateless; they receive only the sender object, not the Developer's session history |

**Viability verdict:** VIABLE
**Rationale:** Low effort and structurally sounder than self-policing (different agent, different invocation). Best used as a fallback detection layer after the pre-commit hook (Solution A) is the primary prevention mechanism.

---

### Problem 4: Uncalibrated `maxTurns: 40`

**Problem statement:** `maxTurns: 40` was set without calibration against real task data. Tool invocations vary enormously in semantic weight: reading a file, running a shell command, and writing a 200-line module each cost one turn. A flat ceiling will produce false-positive halts on legitimately complex tasks while remaining a meaningful ceiling only for simple ones. Applying the same ceiling to the Tester (which runs Playwright suites, SAST tools, and coverage pipelines) is structurally incorrect.

---

#### Solution A: Empirical calibration exercise + role-differentiated ceilings

**Description:** Replay three representative past Developer sessions (one simple/one-file, one medium/multi-file, one complex/multi-module) and count the actual tool-call turns consumed. Do the same for one representative Tester session (including full e2e + coverage run). Set Developer `maxTurns` at the 90th-percentile observed value for Developer sessions. Set Tester `maxTurns` separately and significantly higher, or remove it for Tester until a failure case justifies a ceiling. Document the rationale for chosen values in `.claude/settings.json` as a comment or companion file.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Data collection from existing logs + arithmetic; no code changes |
| Time (rough order of magnitude) | Hours (4–8h) | Log review for 3–4 past sessions + analysis + settings update |
| Skill requirements | Log analysis; no specialised skills | `project/logs/events.json` and session logs are the data source |
| Dependencies | Enough past session data to be representative (appears to exist given the task history visible in `summaries/`) | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Past sessions are not representative of future task complexity distribution | Med | Med | Re-calibrate after each quarter or after a task class change (e.g., adding e2e tests to the Developer's scope) |
| Small sample size produces a noisy 90th-percentile estimate | Med | Med | Use the absolute maximum observed + 20% buffer as a conservative ceiling |

**Viability verdict:** RECOMMENDED
**Rationale:** The only path to a defensible number. Running the calibration before enforcing `maxTurns` in production takes one working session and prevents chronic false-positive halts that would erode trust in the mechanism.

---

#### Solution B: Task-complexity-aware turn budget passed at invocation time

**Description:** Extend the sender object passed by `/do` to include an estimated `turn_budget` field, calculated based on task metadata (e.g., estimated story points, number of acceptance criteria, number of declared scope files). The Developer sub-agent reads this field and uses it as its effective `maxTurns` hint. `/do` enforces a floor and ceiling on the field (e.g., minimum 20, maximum 120). The system-level `maxTurns` in `settings.json` becomes an absolute backstop, not the primary control.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | High | Requires story-point estimation in the scrum board, `/do` budget calculation logic, and Developer instruction update |
| Time (rough order of magnitude) | Weeks (1–2w) | Design + estimation model + integration testing |
| Skill requirements | Agent prompt engineering + board schema design | |
| Dependencies | Story point estimates must exist on board tasks; currently not confirmed present | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Budget estimation is itself an LLM task — subject to the same over-optimism as scope pre-declaration | Med | Med | Use a conservative estimation model with a fixed multiplier |
| Adds complexity to every `/do` invocation | Med | High | The marginal complexity per task is low once the model is defined |

**Viability verdict:** CONDITIONAL
**Rationale:** The right long-term solution for a mature workflow but premature at this stage. Start with Solution A; introduce dynamic budgets after the workflow stabilises.

---

#### Solution C: Turn-budget warnings rather than hard stops

**Description:** Rather than terminating the invocation at `maxTurns`, configure the system to emit a structured warning at turn N-10 (e.g., `maxTurns: 60` with a warning instruction at turn 50). The agent's instruction set includes a turn-awareness rule: at 10 turns remaining, write a progress summary to the checkpoint file and continue; at 5 turns remaining, commit in-progress work and write a partial-completion rapport. The invocation still terminates at `maxTurns` but the agent has two opportunities to produce structured output before it does.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med | Requires agent instruction update + checkpoint file contract (Problem 2) |
| Time (rough order of magnitude) | Days (1–2d) | Instruction authoring + testing at simulated turn thresholds |
| Skill requirements | Agent prompt engineering | |
| Dependencies | Problem 2's checkpoint file contract must exist for the turn-N-10 write to have a target | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Agent cannot reliably track its own turn count from within the session context | Med | Med | The agent does not need to count turns — it should be instructed to write the progress summary "when approaching the turn limit" as a best-effort action, not a turn-precise one |
| Raises the effective ceiling without providing new calibration data | Low | Med | Pair with Solution A's calibration exercise |

**Viability verdict:** VIABLE
**Rationale:** Pragmatic complement to Solution A. After calibrating the ceiling (Solution A), add the graduated warning pattern to maximise the probability that the agent produces output before termination. This directly mitigates Problem 7 as a side effect.

---

### Problem 5: Tester agent unguarded

**Problem statement:** The Tester is the highest-trust agent in the Jenga workflow — it is the sole writer of board statuses and can mark tasks `Passed` without running tests. It has no mechanical turn ceiling, no scope declaration requirement, no checkpoint protocol, and no equivalent of any of the five Developer guardrails. A rogue or misconfigured Tester causes irreversible board corruption.

---

#### Solution A: Apply minimum viable guardrails to `tester.md` — turn cap + scope constraint

**Description:** Add a `maxTurns` setting for the Tester (separately calibrated from the Developer, to accommodate Playwright/SAST/coverage runs — estimated at 80–120 turns based on a representative test session). Add an instruction that the Tester must declare the test types it will run (unit / integration / e2e / SAST) in its session-start log entry to `events.json` before executing any test. Undeclared test types require re-invocation. This does not require new architecture — only a `settings.json` entry and an instruction amendment.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | `settings.json` update + `tester.md` instruction amendment |
| Time (rough order of magnitude) | Hours (3–5h) | Calibration data review + settings update + instruction authoring |
| Skill requirements | Agent prompt engineering | |
| Dependencies | Tester calibration data (representative past session turn counts) | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Tester `maxTurns` set too low — interrupts a Playwright suite mid-run, leaving board status at `In Progress` | High | Med | Set conservatively high initially (2x the observed maximum); reduce after validation |
| Test-type declaration is a soft control — still instruction-level, still policed by the agent | Med | Med | Acceptable as a first layer; the declaration creates an audit trail even if imperfectly enforced |

**Viability verdict:** RECOMMENDED
**Rationale:** Closes the symmetrical trust gap with low effort. The Tester's existing instruction set (validate sender, log to `events.json`, require user approval for SAST) already shows the pattern; extending it is incremental.

---

#### Solution B: Separate the status-write step into a dedicated micro-invocation

**Description:** Restructure the Tester's responsibility so that running tests and writing board status are separate invocations. The Tester runs tests and writes its results to a structured `test_results.json` file. A second, minimal invocation — the "Status Writer" — reads `test_results.json` and applies the status update to the board. The Status Writer has a very low `maxTurns` (e.g., 10 turns), reads only the results file and the board file, and has no access to test tooling. Board corruption via a rogue Status Writer is almost impossible at this scope.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | High | New agent definition + new file contract + `/do` skill changes + Tester instruction refactor |
| Time (rough order of magnitude) | Weeks (1–2w) | Full redesign of the Tester's output contract |
| Skill requirements | Agent prompt engineering + workflow design | |
| Dependencies | All existing Tester callers must be updated; `on_session_end.sh` integration must be validated | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Increases total invocation count per task by one | Low | High | Invocation is minimal; overhead is small |
| `test_results.json` schema must be stable and complete enough for the Status Writer to produce all required board entries | Med | Med | Define the schema explicitly before implementation |

**Viability verdict:** CONDITIONAL
**Rationale:** Architecturally correct for a mature system but over-engineered for the current stage. Implement Solution A first; revisit this if a Tester runaway incident occurs.

---

#### Solution C: Tester scope constraint — test-config.json as the authoritative source

**Description:** The Tester already has `project/configs/test-config.json` as the authoritative configuration for test types and tooling. Extend this contract: the Tester must read `test-config.json` at session start, declare which configured test types it will execute, and log this to `events.json`. Any test type not present in `test-config.json` requires a user approval step before execution (this is already partially implemented for SAST). This makes `test-config.json` the mechanical scope constraint for the Tester — analogous to the scope declaration file proposed for the Developer.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | `tester.md` instruction update + `test-config.json` schema extension if needed |
| Time (rough order of magnitude) | Hours (2–4h) | |
| Skill requirements | Agent prompt engineering | |
| Dependencies | `test-config.json` must be present and user-approved (already the case per AGENT.md) | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Tester rationalises out-of-config test execution as "required for coverage" | Med | Low | The same self-policing concern applies — mitigated by the `events.json` audit trail and user-approval gate that already exists for SAST |

**Viability verdict:** RECOMMENDED (as a complement to Solution A)
**Rationale:** Leverages an existing approved artefact as a scope boundary. Very low effort and consistent with the Tester's existing SAST approval pattern. Combine with the `maxTurns` ceiling from Solution A for full minimum viable guardrail coverage.

---

### Problem 6: No scope-violation halt recovery protocol

**Problem statement:** When the scope boundary check fires (whether via pre-commit hook or self-check), the worktree is left in partial state: staged files may have been removed, but out-of-scope modifications remain in the working tree. No protocol exists for the human, the Scrum Master, or a subsequent Developer invocation to determine what to discard, what to preserve, and how to re-queue the original task.

---

#### Solution A: Structured scope-violation rapport template + human runbook

**Description:** Define a mandatory scope-violation rapport template that the Developer writes to `project/rapports/problems/<task_id>-scope-violation.md` before halting. Required fields: `task_id`, `worktree_path`, `committed_shas[]` (work completed before the violation), `in_scope_staged_files[]`, `out_of_scope_files[]` (with a one-line justification for why each was touched), `recommended_action` (`"discard"` | `"promote_to_new_task"` | `"human_review"`). Separately, write a one-page human runbook in `project/documentation/` covering: how to inspect the diff, how to discard out-of-scope changes (`git checkout -- <file>`), how to promote out-of-scope changes to a new task via `/todo`, and how to re-queue the original task. The Scrum Master is instructed to process scope-violation rapports on next session.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Template authoring + agent instruction update + runbook authoring |
| Time (rough order of magnitude) | Hours (4–6h) | |
| Skill requirements | Technical writing + agent prompt engineering | |
| Dependencies | Scope violation detection mechanism (Problem 3 solution) must exist to trigger the rapport write | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Agent writes an incomplete or misleading rapport before halting | Med | Med | Rapport template validation: Scrum Master should verify all required fields are present before processing |
| Human reads the runbook incorrectly and discards legitimate work | Low | Low | Runbook must include a "when in doubt, preserve" instruction and recommend creating a new task for out-of-scope changes |

**Viability verdict:** RECOMMENDED
**Rationale:** Low effort, high value. Without this, every scope-violation halt becomes a manual archaeology exercise. The rapport template is reusable across all halt types (turn-budget halt, conflict halt, scope-violation halt).

---

#### Solution B: Automated worktree reset script invoked by the Developer before halting

**Description:** Provide a shell script (`scripts/reset-worktree.sh`) that the Developer invokes before writing the scope-violation rapport. The script: (1) copies out-of-scope modified files to a stash directory (`project/stash/<task_id>/<timestamp>/`), (2) runs `git checkout -- <out_of_scope_files>` to restore them to HEAD, (3) writes a manifest of stashed files to `project/queue/.scope_stash_manifest.json`. A subsequent human or Scrum Master can inspect the stash and decide whether to promote stashed changes to a new task.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Med | Shell script + stash directory convention + manifest schema + agent instruction update |
| Time (rough order of magnitude) | Days (1–2d) | Script authoring + testing against dirty worktree scenarios |
| Skill requirements | Shell scripting | |
| Dependencies | Problem 3's scope detection mechanism must produce a machine-readable list of out-of-scope files for the script to act on | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Script fails on binary files or files with complex merge state | Low | Low | Handle with `cp` rather than `git stash`; log failures to `events.json` |
| Stash directory accumulates abandoned stashes over time | Low | Med | Scrum Master session cleanup step: remove stash entries older than 30 days |

**Viability verdict:** VIABLE
**Rationale:** More automated than Solution A but adds a shell script dependency. Best deployed after Solution A's rapport template is validated — the script is a quality-of-life improvement, not a safety requirement.

---

#### Solution C: Worktree destruction and full re-queue on scope violation

**Description:** Treat scope violations as unrecoverable in the current worktree. On halt, the Developer commits only the files that are in-scope and complete, removes the worktree (`git worktree remove --force`), writes a rapport noting what was not completed, and re-queues the remaining work as a new trigger. The next Developer invocation starts with a clean worktree. Out-of-scope changes are permanently discarded — not stashed or promoted.

**Effort estimate:**
| Dimension | Estimate | Notes |
|-----------|----------|-------|
| Complexity | Low | Agent instruction update only — leverages existing `WorktreeRemove` hook |
| Time (rough order of magnitude) | Hours (2–3h) | |
| Skill requirements | Agent prompt engineering | |
| Dependencies | `WorktreeRemove` hook must be confirmed functional | |

**Risks of this solution:**
| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Out-of-scope changes that represent legitimate incidental work are permanently discarded | Med | Med | Only acceptable if out-of-scope changes are never legitimate; document this policy explicitly |
| Re-queue adds latency to task completion | Low | High | Acceptable — scope violations should be rare if Problem 8 is also addressed |

**Viability verdict:** CONDITIONAL
**Rationale:** Acceptable for a strict policy environment but loses potentially useful incidental work. Prefer Solution A + Solution B unless the policy decision is explicit: "out-of-scope means discard."

---

## 3. COMPARATIVE SUMMARY

| Problem | Best Solution | Effort | Risk Level | Confidence |
|---------|--------------|--------|------------|------------|
| P1 — Queue bypass | A: Single-consume discipline in `developer.md` | Low | Low | High |
| P2 — Stateless architecture mismatch | B: Abort-and-requeue with partial-completion rapport | Low | Low | High |
| P3 — Self-policing scope check | A: Pre-commit hook externalises enforcement | Med | Med | High |
| P4 — Uncalibrated `maxTurns` | A: Empirical calibration + role-differentiated ceilings | Low | Low | High |
| P5 — Tester unguarded | A+C: `maxTurns` ceiling + `test-config.json` scope constraint | Low | Low | High |
| P6 — No halt recovery protocol | A: Scope-violation rapport template + human runbook | Low | Low | High |
| P7 — Checkpoint silent failure *(subsumed by P2+P4)* | P4-C: Graduated turn warnings + P2-B: abort-and-requeue | Low–Med | Med | Med |
| P8 — Illusory scope pre-declaration *(subsumed by P3)* | P3-A: File-level hook enforcement, reject globs | Med | Med | Med |

---

## 4. OVERALL EFFORT ASSESSMENT

**Total effort to resolve all problems** (assuming recommended solutions):

| Scenario | Effort Estimate | Assumptions |
|----------|----------------|-------------|
| Optimistic | 3–4 days | P1 text change goes cleanly; calibration data is available and clean; hook implementation has no git edge cases |
| Realistic | 6–8 days | Some rework on the pre-commit hook (glob rejection edge cases); calibration requires replaying more sessions; rapport template needs iteration |
| Pessimistic | 2–3 weeks | Hook conflicts with existing git workflow; calibration data is insufficient (too few past sessions); P5 Tester changes expose unexpected test-lifecycle issues |

**Biggest effort drivers:**
- Pre-commit hook implementation (Problem 3, Solution A) — shell scripting against real worktree scenarios with glob rejection and scope-amendment path
- Empirical calibration (Problem 4, Solution A) — requires manual review of past session logs and is blocked until sufficient session history exists
- Rapport template standardisation (Problem 6, Solution A) — requires coordination across Developer and Tester halt paths to avoid schema divergence

**Biggest risk drivers:**
- `maxTurns` calibration for the Tester (Problem 5) — setting it too low interrupts a running Playwright suite and leaves the board in `In Progress` permanently; there is no safe fallback
- Pre-commit hook glob rejection (Problem 3) — if the hook is too strict, it blocks legitimate dynamic scope extension; if too permissive, it defeats the control entirely
- Checkpoint silent failure (Problem 7) — the abort-and-requeue solution (P2-B) mitigates but does not eliminate this if `on_session_end.sh` fails to detect the partial-completion rapport

---

## 5. UNRESOLVED PROBLEMS

| Problem | Reason Unresolved | Recommended Action |
|---------|------------------|--------------------|
| P8 — Scope pre-declaration is illusory | No solution exists that makes LLM-generated file lists genuinely binding without external enforcement. The pre-commit hook (P3-A) provides enforcement once a list exists, but the quality of the list remains agent-dependent. | Accept — treat scope declarations as audit-trail artefacts, not prevention mechanisms; rely on the hook for actual enforcement |
| Concurrent `/do` invocations | Not in the six primary problems but noted in the scrutiny blind spots. No locking mechanism exists for concurrent Developer invocations on the same story. | Descope — document as unsupported; address if it becomes a real usage pattern |

---

## 6. RECOMMENDED RESOLUTION SEQUENCE

1. **Problem 1 — Queue bypass** — Fix first. Every other guardrail is bypassable while the Developer can self-assign multiple tasks from the queue. This is a single targeted text change to `developer.md` with zero dependencies. Complete in one session.

2. **Problem 4 — Calibrate `maxTurns`** — Fix second, before enforcing the ceiling. Running the calibration exercise while the queue-bypass fix is validated provides clean single-task session data. Produces the role-differentiated ceilings needed by Problems 2, 5, and 7.

3. **Problem 2 — Checkpoint architecture (abort-and-requeue)** — Fix third. Once `maxTurns` is calibrated and the queue bypass is closed, replace the "suspend in-place" model with the abort-and-requeue protocol. This converts checkpoint failures from silent to structured. Depends on Problem 4's calibration being in place.

4. **Problem 6 — Halt recovery protocol** — Fix fourth (in parallel with Problem 2). Write the rapport template and human runbook. These are documents, not code — they can be drafted while Problem 2 is being implemented. The template is needed before Problems 3 and 5 produce halt events.

5. **Problem 5 — Tester guardrails** — Fix fifth. Once Developer guardrails are operational and stable, apply the minimum viable set to the Tester (`maxTurns` + `test-config.json` scope constraint). Doing this before the Developer guardrails are stable risks calibrating the Tester against an unstable baseline.

6. **Problem 3 — Externalise scope check to pre-commit hook** — Fix last. This is the highest-effort item and depends on a machine-readable scope declaration file, which in turn depends on the abort-and-requeue protocol producing clean plan artefacts. It is also the least urgent fix given that the queue-bypass closure and turn ceiling together already prevent the most severe runaway scenarios.

---

## 7. OVERALL APPROACH VIABILITY

### On instruction-level vs. tooling/config-level enforcement

The scrutiny correctly identifies that four of the five original guardrails are instruction-level constraints applied to an agent that already had instructions it violated. Adding more text to a context that over-generalised its mandate does not change the failure mode — it adds overhead to normal operations while providing uncertain protection against rogue behaviour.

**The correct architectural principle for this workflow:**

> Mechanical enforcement belongs at the layer that the agent cannot reason its way around. Instruction-level rules are policy; tooling-level rules are law.

Applied to this workflow:

| Control | Correct Layer | Why |
|---------|--------------|-----|
| One task per session | Agent instruction (P1-A) + queue gating (P1-B) | Instruction is necessary; queue gating adds mechanical backing |
| Scope boundary | Pre-commit hook (P3-A) | Must be outside the agent's reasoning context |
| Turn ceiling | `settings.json` `maxTurns` field | Already tooling-level — correct layer, just needs calibration |
| Checkpoint / resumption | Abort-and-requeue rapport (P2-B) | Works with the stateless execution model, not against it |
| Board status writes | Tester-only enforcement (existing) + `maxTurns` ceiling | Turn ceiling adds the only missing mechanical layer |

**Verdict on instruction-only approach:** Insufficient as a standalone strategy. The `maxTurns` ceiling (already tooling-level) is the highest-value guardrail and should be the anchor. Every other control should be implemented at the lowest possible layer: git hooks for scope, queue files for single-task discipline, `settings.json` for turn ceilings. Instruction-level rules are acceptable for intent-signalling and audit-trail generation but must not be the primary control for any safety-critical constraint.

---

**Resolvability:** TRACTABLE

| Range | Meaning |
|-------|---------|
| STRAIGHTFORWARD | Clear solutions, low effort, low risk |
| TRACTABLE | Solutions exist, moderate effort, manageable risk |
| CHALLENGING | Solutions exist but require significant effort or carry meaningful risk |
| VERY DIFFICULT | Solutions are expensive, uncertain, or high-risk |
| INTRACTABLE | No viable solution identified, or cost/risk clearly prohibitive |

> The six problems are resolvable within one to two weeks of focused work. The highest-impact items (queue-bypass fix, `maxTurns` calibration, abort-and-requeue model) are individually low-effort and low-risk, and their combined effect closes the most dangerous failure modes without requiring architectural redesign. The one genuine structural gap — scope pre-declaration as a binding constraint — has no perfect solution given LLM behaviour, but the pre-commit hook provides mechanical enforcement that reduces the gap to an acceptable residual. Resolution is worth pursuing in the sequence given above; the full set of recommended solutions converts the guardrail system from instruction-layer theatre into a layered defence with at least one mechanical control at each trust boundary.
