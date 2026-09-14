---
name: j.cloud-connect
description: Guided cloud storage setup wizard — installs rclone if missing, lets you pick any rclone-supported backend from a live provider list, runs that backend's own config/auth flow, and independently verifies the remote works.
keywords:
  - cloud connect
  - connect cloud storage
  - rclone setup
  - configure remote
  - cloud storage backend
  - google drive setup
examples:
  - "connect a cloud storage account"
  - "set up rclone"
  - "j.cloud-connect"
  - "configure a google drive remote"
  - "add a cloud storage backend"
---

# Cloud Connect — Guided rclone Setup Wizard

## Purpose

`E60_S01` builds a single guided flow for connecting a cloud storage backend via `rclone`: install
(or detect) `rclone`, pick a backend from rclone's own live provider list, run that backend's own
`rclone config create` prompts (surfacing any auth URL directly), wait for explicit user confirmation,
then independently verify the remote works. All of that behavior already lives in two standalone
scripts — `scripts/install-rclone.sh` (`E60_S01_T01`) and `scripts/configure-backend.sh`
(`E60_S01_T02`) — each fully self-contained, argument-driven, and independently tested. Per this
repo's "Scripts Over Inline Logic" principle (`CLAUDE.md`), this `SKILL.md` introduces **no new
install, selection, config, auth, or verification logic of its own** — it is a thin entry point that
sequences those two scripts and relays their output.

## Instructions

1. **Run the install/detect step first.** Invoke:

   ```
   bash skills/j-cloud-connect/scripts/install-rclone.sh
   ```

   Relay its stdout/stderr to the user as-is (it already produces clear, human-readable status —
   e.g. "rclone is already installed at ...", or an actionable error for an unsupported OS, a
   missing package manager, or a network failure). Do not reinterpret or summarize away its output.

   - **Exit 0:** `rclone` is confirmed on `PATH` and runnable (whether it was already present or was
     just installed). Proceed to step 2.
   - **Non-zero exit:** installation failed or could not be verified. Stop here — do not proceed to
     step 2 — and surface the script's error message to the user unchanged. It already names the
     specific cause (unsupported OS, missing Homebrew/curl/sudo, network failure, post-install
     verification failure) and, where applicable, a manual-install fallback URL.

2. **Run the backend selection/config/auth/verify step.** Invoke:

   ```
   bash skills/j-cloud-connect/scripts/configure-backend.sh
   ```

   with stdio fully inherited/interactive — this script prompts the user directly (backend number,
   remote name, an explicit yes/no confirmation once any backend auth flow has run, e.g. opening an
   OAuth URL) and must be allowed to do so; do not pre-supply answers or short-circuit its prompts.

   - If the user already stated a specific backend and remote name in their request (e.g. "connect
     my Google Drive as gdrive"), you may pass them positionally instead of relying on the
     interactive prompts: `bash skills/j-cloud-connect/scripts/configure-backend.sh <backend-type>
     <remote-name>` — the script validates `<backend-type>` against the live provider list itself
     and fails clearly if it doesn't match. If the requested backend name doesn't resolve, fall back
     to running the script with no arguments so the user can pick from the live menu.
   - If the user only wants to see what backends are available without configuring one yet, run
     `bash skills/j-cloud-connect/scripts/configure-backend.sh --list` instead and report the printed
     menu — it is a read-only, no-side-effect mode.
   - Relay all of the script's output to the user as-is, including any auth URL rclone's own
     `config create` flow prints — never paraphrase, hide, or re-derive that URL.
   - **Exit 0:** the script itself already printed a `PASS: remote '<name>' is configured and
     verified working.` line plus `rclone about` output — relay that verbatim as the final result.
   - **Non-zero exit:** the script already printed the specific failure reason (invalid backend
     selection, `rclone config create` failure, a declined confirmation, or a `FAIL:` verification
     line from `rclone about`) — relay it unchanged rather than guessing at the cause.

3. **Do not run step 2 if step 1 failed.** The wizard is a strict sequence: `configure-backend.sh`
   itself assumes `rclone` is already on `PATH` and will `die` immediately with a pointer back to
   `install-rclone.sh` if it isn't, so there is nothing to gain by invoking it after a failed
   install — surface the step 1 failure and stop.

## Out of Scope

- Any install, detection, or OS-specific package-manager logic — that is entirely
  `scripts/install-rclone.sh`'s scope (`E60_S01_T01`). Do not duplicate or reimplement any part of it
  here.
- Any backend menu sourcing, `rclone config create` invocation, auth-confirmation prompt, or
  post-confirmation `rclone about` verification — that is entirely `scripts/configure-backend.sh`'s
  scope (`E60_S01_T02`). Do not duplicate, hardcode a backend list, or reimplement any part of it
  here.
- Per-backend bespoke guidance (e.g. special-casing Google Drive's auth flow beyond what rclone's own
  `config create` already prints) — the story's acceptance criteria require the identical flow for
  every backend; any such special-casing belongs to neither script nor this `SKILL.md`.
