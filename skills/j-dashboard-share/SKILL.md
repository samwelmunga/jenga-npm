---
name: j.dashboard-share
description: Snapshot the project dashboard and upload it to a configured cloud storage remote in one step, by sequencing j-dashboard's snapshot script and E47_S05_T01's rclone upload script.
keywords:
  - dashboard share
  - share dashboard
  - upload dashboard
  - cloud share snapshot
  - dashboard to drive
  - snapshot upload
examples:
  - "share the dashboard snapshot to the cloud"
  - "upload a dashboard snapshot"
  - "j.dashboard-share"
  - "send the dashboard snapshot to my google drive"
  - "snapshot and upload the dashboard"
---

# Dashboard Share — Snapshot + Cloud Upload

## Purpose

`E47_S05` chains two already-implemented, independently-scoped capabilities into one step: capturing
a point-in-time dashboard snapshot and uploading it to a configured cloud storage remote. Both halves
already exist as standalone scripts — `skills/j-dashboard/scripts/snapshot.sh` (`E47_S04_T02`/`T03`,
capture + single-file bundle) and `skills/j-dashboard-share/scripts/upload-snapshot.sh`
(`E47_S05_T01`, templated-path `rclone copyto` upload). Per this repo's "Scripts Over Inline Logic"
principle (`CLAUDE.md`), this `SKILL.md` introduces **no new capture or upload logic of its own** — it
only sequences those two scripts and relays their output, plus the minimal remote-selection judgment
call described in step 2 below (interpreting `rclone listremotes` output and presenting a choice to
the user, not reimplementing any config/upload behavior).

This is **upload only** — this skill never runs `rclone link` or any other share-link-creating
command, matching the story's explicit, deliberate scope decision (see `E47_S05`'s Purpose section in
`PROJECT_SUMMARY.md`): upload and link-creation are two distinct actions with a real permission
consequence, and creating a public link stays a separate, manual, deliberate step the user takes on
their own, never something this skill chains automatically.

## Instructions

1. **Capture the snapshot.** Invoke:

   ```
   bash skills/j-dashboard/scripts/snapshot.sh [--out <path>]
   ```

   Forward `--out <path>` only if the user explicitly requested a specific local output path;
   otherwise let it default. Relay the script's own stdout/stderr as-is if it fails — do not
   reinterpret its error output. On success, read the local snapshot file's path from its documented
   `Snapshot dashboard written to: <path>` line (the exact line `snapshot.sh` emits on completion) —
   do not guess or re-derive the path any other way. If this step fails (non-zero exit), stop here;
   do not proceed to step 2 or 3.

2. **Determine which remote to upload to.** `upload-snapshot.sh` (step 3) requires an explicit
   `--remote <name>` naming an already-configured rclone remote — it does not pick one on its own.
   Resolve this before invoking it:
   - If the user's request already names a specific remote (e.g. "upload it to my gdrive remote"),
     use that name directly and skip straight to step 3.
   - Otherwise, run `rclone listremotes` to see what's currently configured (a plain read-only
     enumeration — not upload or config logic, so it stays within this repo's inline-judgment
     carve-out for interpreting output and presenting results to the user):
     - **Zero remotes configured:** tell the user to run `j.cloud-connect` first to configure one,
       and stop here — do not invoke `upload-snapshot.sh` at all in this case (it would only
       reproduce the same "not configured" message after the fact).
     - **Exactly one remote configured:** use it automatically, no prompt needed.
     - **More than one remote configured:** ask the user which one to use, following CLAUDE.md's
       standard Interaction Pattern (numbered list of the configured remote names, "Other" as the
       final option).

3. **Upload the snapshot.** Invoke:

   ```
   bash skills/j-dashboard-share/scripts/upload-snapshot.sh --file <path-from-step-1> --remote <name-from-step-2>
   ```

   Relay its stdout/stderr to the user as-is, including the final printed destination path on
   success (`JengaAI/<repo-directory-name>/<datetime>-board-snapshot.html` on the chosen remote) or
   its own actionable error message on failure (e.g. it independently re-checks the remote is
   configured and points at `j.cloud-connect` if not, in case that state changed between step 2's
   enumeration and this call). Do not reinterpret, summarize away, or suppress its output.

## Out of Scope

- Any new dashboard capture, HTML bundling, or single-file export logic — that is entirely
  `skills/j-dashboard/scripts/snapshot.sh`'s scope (`E47_S04`). Do not duplicate or reimplement any
  part of it here.
- Any new `rclone copyto` invocation, destination-path templating, or "remote not configured"
  detection logic — that is entirely `skills/j-dashboard-share/scripts/upload-snapshot.sh`'s scope
  (`E47_S05_T01`). This `SKILL.md` only decides *which* configured remote name to pass to it (step 2
  above); it never re-derives the destination path or re-implements the configured-remote check.
- Running `rclone link` or any other share-link-creating command, automatically or on request routed
  through this skill — that is a deliberate, permanent scope exclusion for `E47_S05` (see Purpose
  above), not a gap to close later.
- `rclone` installation, backend configuration, or OAuth authentication — that is entirely
  `j.cloud-connect`'s scope (`E60_S01`). This skill only points the user at it when no remote is
  configured; it does not run any part of that flow itself.
