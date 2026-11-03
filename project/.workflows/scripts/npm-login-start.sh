#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# npm-login-start.sh - start an npm web login and print its sign-in URL, so the
# workflow's next (confirm) step can forward that link to the user.
#
# Why a separate start/wait pair: run-compute.sh captures a step's stdout and only
# hands it to the agent once the step has finished, so a single script that both
# printed the URL and then waited an hour would deliver the link an hour too late.
# This script therefore returns in seconds with the URL; npm-login-wait.sh does the
# waiting afterwards.
#
# The `npm login` process must outlive this step: it is what completes the OAuth
# callback and writes the token to .npmrc. run-compute.sh KILLs the step's whole
# process group when the step ends, so the login is started in a NEW SESSION
# (POSIX setsid via perl, falling back to python3) and is therefore not in that
# group. A last-resort plain background start is used if neither interpreter is
# present; on that path the login may not survive, and the printed text says so.
#
# State shared with npm-login-wait.sh, under ${TMPDIR:-/tmp}/jenga-deploy-stage/:
#   login.log   the login process's combined output (the URL is parsed from it)
#   login.pid   its pid, so the wait step can kill it on timeout
#
# Usage: npm-login-start.sh [<seconds-to-wait-for-the-url>]   (default 45)
#
# Exit: 0 either already authenticated or a login was started (stdout says which);
#       1 npm is too old for `npm stage`, or the URL never appeared;
#       2 npm not installed.
# ---------------------------------------------------------------------------
set -uo pipefail

URL_WAIT="${1:-45}"
MIN_NPM_MAJOR=11
MIN_NPM_MINOR=19

STATE_DIR="${TMPDIR:-/tmp}/jenga-deploy-stage"
LOG="$STATE_DIR/login.log"
PIDFILE="$STATE_DIR/login.pid"

die() { printf 'npm-login-start: %s\n' "$1" >&2; exit "${2:-2}"; }

command -v npm >/dev/null 2>&1 || die "npm not installed"
mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"

NPM_VERSION="$(npm --version 2>/dev/null)" || die "npm --version failed"
NPM_MAJOR="${NPM_VERSION%%.*}"
NPM_REST="${NPM_VERSION#*.}"
NPM_MINOR="${NPM_REST%%.*}"
case "$NPM_MAJOR$NPM_MINOR" in
  *[!0-9]*) die "cannot parse the npm version '$NPM_VERSION'" ;;
esac
if [ "$NPM_MAJOR" -lt "$MIN_NPM_MAJOR" ] || { [ "$NPM_MAJOR" -eq "$MIN_NPM_MAJOR" ] && [ "$NPM_MINOR" -lt "$MIN_NPM_MINOR" ]; }; then
  printf 'npm %s is too old for the `npm stage` family; %s.%s or later is required (11.4.2 and 11.11.0 fail with Unknown command: "stage").\n' \
    "$NPM_VERSION" "$MIN_NPM_MAJOR" "$MIN_NPM_MINOR"
  die "npm $NPM_VERSION < $MIN_NPM_MAJOR.$MIN_NPM_MINOR - upgrade npm before staging" 1
fi

if WHO="$(npm whoami 2>/dev/null)" && [ -n "$WHO" ]; then
  printf 'Already authenticated to npm as "%s" (npm %s). No sign-in URL is needed; nothing to forward.\n' "$WHO" "$NPM_VERSION"
  exit 0
fi

rm -f "$LOG" "$PIDFILE"
: > "$LOG"

start_detached() {
  if command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die' -- npm login --auth-type=web >>"$LOG" 2>&1 &
    printf '%s' "$!" > "$PIDFILE"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' npm login --auth-type=web >>"$LOG" 2>&1 &
    printf '%s' "$!" > "$PIDFILE"
    return 0
  fi
  npm login --auth-type=web >>"$LOG" 2>&1 &
  printf '%s' "$!" > "$PIDFILE"
  return 1
}

DETACHED=1
start_detached || DETACHED=0

URL=""
WAITED=0
while [ "$WAITED" -lt "$URL_WAIT" ]; do
  URL="$(grep -Eo 'https://[^[:space:]]+' "$LOG" 2>/dev/null | head -n 1)"
  [ -n "$URL" ] && break
  sleep 1
  WAITED=$((WAITED + 1))
done

if [ -z "$URL" ]; then
  printf 'No sign-in URL appeared in %ss. Ask the user to run `npm login --auth-type=web` in their own terminal and to send back the "Login at:" URL.\nLast output from the attempt:\n%s\n' \
    "$URL_WAIT" "$(tail -n 20 "$LOG" 2>/dev/null)"
  die "no sign-in URL after ${URL_WAIT}s (see $LOG)" 1
fi

printf 'npm sign-in required (npm %s, not logged in).\n' "$NPM_VERSION"
printf 'Open this URL and complete the login, including 2FA:\n  %s\n' "$URL"
if [ "$DETACHED" -eq 0 ]; then
  printf 'Note: neither perl nor python3 was available, so the login process could not be put in its own session and may be killed when this step ends. If the wait step times out, run `npm login --auth-type=web` manually.\n'
fi
printf 'Waiting is the next step; it polls `npm whoami` and gives up after the configured number of minutes.\n'
