---
name: j.connect
description: Guided service setup — pick a service from the descriptors on disk, detect your platform, then install its CLI, authenticate, register its MCP server and independently verify, skipping whatever is already done and never handling a secret value.
keywords:
  - connect service
  - set up cli
  - register mcp server
  - connect third-party service
  - service setup
  - authenticate cli
examples:
  - "connect a service to my project"
  - "set up a vendor cli and mcp server"
  - "j.connect"
  - "register an mcp server for a service"
  - "authenticate a service cli"
---

# Connect — Guided Service Setup

## Purpose

`E65_S02` is the single entry point for wiring a third-party service into a project: install its CLI,
authenticate, register its MCP server where one exists, and independently verify the result. Everything
deterministic already lives in standalone scripts under `skills/j-connect/scripts/`, driven by per-service
**descriptors** (`project/documentation/service-descriptor.md`). Per this repo's "Scripts Over Inline Logic" principle
(`CLAUDE.md`), this `SKILL.md` holds **only judgment and presentation**: it sequences four scripts, asks the
user what to do at decision points, and relays their output. It contains no install, detection,
validation, registration or reporting logic of its own, and no service names or service list.

## Instructions

1. **List the services.** Invoke:

   ```
   bash skills/j-connect/scripts/list-services.sh
   ```

   It prints one JSON object: `services` (each with `id`, `name`, `file`, `mcp`, `requires`,
   `unresolved_requires`) and `skipped` (descriptors that failed validation). Relay any `skipped` entries
   to the user so a broken descriptor is visible. If `services` is empty, say that no service descriptors
   are installed yet, point at `project/documentation/service-descriptor.md` for how to add one, and stop.

2. **Resolve the service.** If the user already named a service, resolve it against `services` by `id`
   or `name`; never guess a match. Otherwise present the picker, built only from the `services` array
   in the order given, using the numbered-options format with free text as the final option:

   ```
   Which service would you like to connect?
   1. <name of first service>
   2. <name of second service>
   ...
   N. Other (type a service id)
   ```

   If the user types an id or name, resolve it against the list. An unknown value is not guessed at: say
   it is not available and show the picker again. Mention any `unresolved_requires` of the chosen service
   (a prerequisite descriptor that is not installed) before continuing, since the run will report it.

3. **Detect the platform.** Invoke, with the chosen entry's `file`:

   ```
   bash skills/j-connect/scripts/detect-platform.sh --descriptor <file>
   ```

   If `status` is `unknown`: say the platform (or a usable package manager) could not be determined and
   print `fallback_docs_url` as the official instructions for the user to follow themselves, then continue
   to step 4. The runner skips the install step when the CLI is already present, and otherwise reports it
   as `needs-user-action` with the same URL without running anything. Never guess, construct or suggest an
   install command.

4. **Run the setup.** Invoke:

   ```
   bash skills/j-connect/scripts/run-descriptor.sh <file>
   ```

   It prints one JSON line per step (`pass`, `fail`, `skipped`, `needs-user-action`) and stops at the first
   `fail` or `needs-user-action`. Relay each step to the user, and say plainly which steps were skipped
   because they were already satisfied (for example an already installed CLI or an already authenticated
   account). When the install step is reported `needs-user-action` and a usable package manager is
   available, ask:

   ```
   The CLI is not installed. How would you like to proceed?
   1. Install it now (re-run with --allow-install)
   2. I will install it myself from the official instructions
   3. Other (describe below)
   ```

   Re-run with `--allow-install` **only after the user explicitly picks option 1**; never pass it on your
   own initiative.

5. **Hand over human steps.** For any other `needs-user-action` (a browser sign-in, setting a token
   environment variable, approving the MCP server in Claude Code), relay the instruction verbatim, wait
   for the user to say they have done it, then re-run the same `run-descriptor.sh` command. It is
   idempotent and skips completed steps, so repeat until it stops asking. Secrets rules, with no exceptions:
   refer to environment variables by **name only**; never ask the user to paste a secret value, token or key
   into the chat; never read, print or echo the contents of a secrets or env file. If a secrets file is
   needed, the runner itself makes it git-ignored before creating it — do not create or edit one yourself.

6. **Report the result.** Pipe the final run's output through the report script, for example by saving the
   run's stdout to a results file and invoking:

   ```
   bash skills/j-connect/scripts/summarize-run.sh <results-file>
   ```

   Relay its output to the user **verbatim**. Claim success only when its last line starts with
   `VERIFIED:`; that line comes from the service's own independent verification. The user saying a step
   is done is never evidence of success. If the last line is `NOT VERIFIED`, report that, quote the step it
   names, and offer to re-run step 4 or stop.

## No session-end behaviour

This skill performs no session-end work: no handoff file, no queue write, no board or status update.
This matches `j.cloud-connect` and `j.dashboard-share`.

## Out of Scope

- Per-service logic of any kind. Adding a service is a descriptor-only change (a new `<id>.json` under
  `skills/j-connect/descriptors/`); this file never changes for it, and it holds no service list.
- Install, detection, authentication, MCP registration, git-ignore guardrails and verification — all of
  that is the scripts' scope (`E65_S01`, `E65_S02_T01`–`T03`). Do not duplicate or reimplement any part of
  it here, and do not run vendor commands directly.
- App Store Connect and Play Console credentials — handled by `j.publish` (`E65` epic scope note).
