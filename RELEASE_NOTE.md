# Epic: Workflow Hardening

**Purpose:** Address critical gaps, structural weaknesses, security concerns, and workflow improvements identified in the multi-agent workflow. Deliver a reliable, secure, and clearly-contracted system where every agent has an unambiguous role, consistent logging, and a defined communication protocol.

**Definition of Done:**
- All scrum board items have a defined schema that every agent reads and writes to consistently
- Session-end hooks use a supported trigger mechanism with sanitized inputs
- Every agent logs all incoming sender objects to `events.json` without exception
- Developer and tester have an explicit, documented communication contract
- Rapport state is tracked by manifest, not timestamp
- Conflict escalation has a defined human ceiling
- `PROJECT_SUMMARY.md` has a single owner (scrum master)
- Analytics baselines are persisted to file
- Epic/story rollup logic exists and is owned
- The tester skips `.IGNORE.md` rapports
- Security: secrets guidance, SAST audit trail, and `Rejected` notification gate are all in place
- A `/status` skill exists for human-readable board overview
- `/init` scaffolds all required directories and config files

---

## S01 · Scrum Board Schema & Shared Constants

**Story:** As any agent in the workflow, I need a single defined schema for all scrum board items so that I read and write files consistently without drift or ambiguity.

- [x] Create `templates/SCRUM_BOARD_SCHEMA.md` — defines filename conventions, frontmatter fields, status enum, and linking format for epics, stories, and tasks
- [x] Update `/init` skill — scaffold `project/configs/workflow.json` (shared constants), `project/board/`, `project/queue/`, and `project/data/` on project setup
- [x] Update `scrum-master.md` — reference the schema for all board item creation and amendment
- [x] Update `developer.md` — reference the schema when reading task/story context
- [x] Update `tester.md` — reference the schema when reading board items and writing status updates

---

## S02 · Session-End Hook Reliability

**Story:** As the workflow system, I need the session-end hook to use a supported trigger mechanism so that the scrum master is reliably invoked after sessions end without relying on a non-existent CLI flag.

- [x] Replace `claude --agent scrum-master --message "..."` with a trigger queue write (`project/queue/scrum_triggers.jsonl`) — the scrum master processes the queue at its next session start
- [x] Replace timestamp-based rapport tracker (`.rapport_state`) with a manifest-based tracker (`.rapport_manifest.json`) — diff current files against known files to detect new rapports
- [x] Sanitize rapport file paths — pass paths as JSON array (never interpolated into shell strings) to eliminate prompt injection risk
- [x] Update `scrum-master.md` — add queue processing step at session start (reads and clears `scrum_triggers.jsonl`)

---

## S03 · Consistent Event Logging

**Story:** As the workflow system, I need every agent to log all incoming sender objects to `events.json` so that there is a complete, auditable record of inter-agent communication.

- [x] Update `developer.md` — add explicit event-logging step at task intake (log sender object before doing any work)
- [x] Update `tester.md` — add explicit event-logging step at session start (log sender object from every invocation)
- [x] Update `scrum-master.md` — add explicit event-logging step when processing queue triggers and any direct invocations

---

## S04 · Developer–Tester Communication Contract

**Story:** As the developer and tester agents, we need an explicit, versioned communication contract so that every tester invocation carries the exact information the tester needs and nothing is ambiguous.

- [x] Update `developer.md` — define the exact payload sent to the tester: sender object fields + commit SHAs (as `paths`) + implementation summary
- [x] Update `tester.md` — define the exact fields validated on intake (task_id, story_id, epic_id, worktree path, commit SHAs) and the rejection path if any are missing

---

## S05 · Conflict Resolution Escalation Ceiling

**Story:** As the workflow system, I need the developer's three-attempt conflict resolution to have a defined human escalation ceiling so that a task cannot loop back to the developer indefinitely.

- [x] Update `developer.md` — after three failed resolution attempts, write the rapport, set the task status to `Blocked`, and halt; the human must intervene — no automatic re-assignment back to the developer

---

## S06 · Scrum Board Concurrency Control

**Story:** As the workflow system, I need a basic concurrency control mechanism on scrum board files so that parallel agents do not corrupt shared board items.

- [x] Update `developer.md` — add advisory file-lock protocol (create `<file>.lock` before writing, check and respect existing locks, remove lock after write)
- [x] Update `scrum-master.md` — same advisory file-lock protocol for all board writes
- [x] Update `tester.md` — same advisory file-lock protocol for all board status updates

---

## S07 · PROJECT\_SUMMARY.md Ownership

**Story:** As the workflow system, I need a single agent to own `PROJECT_SUMMARY.md` so that it does not drift into inconsistency as multiple agents write to it in parallel.

- [x] Update `scrum-master.md` — establish exclusive ownership of `PROJECT_SUMMARY.md`; scrum master is the only agent that writes to it directly
- [x] Update `developer.md` — remove direct-write permission; developer submits proposed updates to `project/queue/project_summary_updates.jsonl`
- [x] Update `tester.md` — same: submit proposed updates, do not write directly

---

## S08 · Security Hardening

**Story:** As the workflow system, I need defined security controls so that secrets are never committed, SAST approvals are auditable, and the `Rejected` status cannot be written without user notification.

- [x] Update `developer.md` — add Secrets Management section (no `.env` commits, never log credentials, surface `.gitignore` requirements)
- [x] Update `tester.md` — add SAST/vulnerability approval audit trail (log approval to `events.json` with sender object before running); add `Rejected` notification gate (notify user and wait for confirmation before writing `Rejected` to the board)

---

## S09 · Analytics Baseline Persistence

**Story:** As the tester agent, I need a persistent baselines file so that analytics comparisons survive context resets and every session has a meaningful historical baseline.

- [x] Update `tester.md` — read from and write to `project/data/baselines.json` for all analytics baselines; establish the file on first run if it does not exist

---

## S10 · Epic/Story Completion Rollup

**Story:** As the workflow system, I need a defined rollup check so that when all tasks under a story are complete — and all stories under an epic — the parent item's status is automatically updated.

- [x] Update `tester.md` — after every status write, check if all sibling tasks under the parent story are `Passed` or `Passed with remarks`; if so, write a status-review trigger to the queue
- [x] Update `scrum-master.md` — as part of queue processing, check story and epic rollup; update parent status when all children are complete

---

## S11 · IGNORE.md Awareness in Tester

**Story:** As the tester agent, I need to treat `.IGNORE.md` rapports as resolved so that I do not re-flag findings the developer has explicitly decided to ignore.

- [x] Update `tester.md` — skip any rapport file matching `*.IGNORE.md` during test runs and rapport scanning

---

## S12 · /status Skill

**Story:** As a user, I want a `/status` command that prints a human-readable summary of the entire scrum board — all epics, stories, tasks, their statuses, and any open rapports — so that I can understand project state without reading raw files.

- [x] Create `skills/status/SKILL.md`

---

## S13 · /do Skill Alignment

**Story:** As the developer agent, I need the `/do` skill to align with the scrum board schema and communication contracts so that task execution is consistent with the rest of the workflow.

- [x] Update `skills/do/SKILL.md` — resolve todo items to full scrum board context; pass proper sender object to developer agent; enforce the developer–tester communication contract

---

## S14 · Onboarding Flow

**Story:** As a new user of this workflow, I want a defined, ordered onboarding sequence so that project setup is deterministic and every required file and folder is in place before any agent starts working.

- [x] Update `/init` skill — include ordered setup sequence: git init → scaffold dirs → create `PROJECT_SUMMARY.md` → create `workflow.json` → create `test-config.json` stub → prompt to run `/jenga`
