#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# npm-login-wait.sh - wait for the user to finish the npm web login started by
# npm-login-start.sh, and cancel the run if they do not.
#
# Polls `npm whoami` until it succeeds. On timeout it kills the login process
# recorded by npm-login-start.sh and exits non-zero, which fails the step and so
# cancels the workflow run before anything is staged.
#
# Usage: npm-login-wait.sh [<timeout-minutes>] [<poll-seconds>]   (defaults 60, 10)
#
# The caller must give the compute step a `timeout_seconds` larger than the timeout
# here (the workflow uses 3900 for 60 minutes), or run-compute.sh kills this script
# first and the failure reads as a timeout rather than as "not authenticated".
#
# Exit: 0 authenticated (stdout names the user); 1 the timeout elapsed; 2 npm missing
# or a bad argument.
# ---------------------------------------------------------------------------
set -uo pipefail

TIMEOUT_MINUTES="${1:-60}"
POLL_SECONDS="${2:-10}"

STATE_DIR="${TMPDIR:-/tmp}/jenga-deploy-stage"
PIDFILE="$STATE_DIR/login.pid"
LOG="$STATE_DIR/login.log"

die() { printf 'npm-login-wait: %s\n' "$1" >&2; exit "${2:-2}"; }

command -v npm >/dev/null 2>&1 || die "npm not installed"
case "$TIMEOUT_MINUTES" in ''|*[!0-9]*) die "timeout-minutes must be a whole number, got '$TIMEOUT_MINUTES'" ;; esac
case "$POLL_SECONDS" in ''|*[!0-9]*) die "poll-seconds must be a whole number, got '$POLL_SECONDS'" ;; esac
[ "$TIMEOUT_MINUTES" -gt 0 ] || die "timeout-minutes must be greater than 0"
[ "$POLL_SECONDS" -gt 0 ] || die "poll-seconds must be greater than 0"

DEADLINE_SECONDS=$((TIMEOUT_MINUTES * 60))
WAITED=0

while :; do
  if WHO="$(npm whoami 2>/dev/null)" && [ -n "$WHO" ]; then
    printf 'Authenticated to npm as "%s" after %ss.\n' "$WHO" "$WAITED"
    exit 0
  fi
  [ "$WAITED" -ge "$DEADLINE_SECONDS" ] && break
  sleep "$POLL_SECONDS"
  WAITED=$((WAITED + POLL_SECONDS))
  # Progress on stderr, which run-compute.sh passes straight through, so a long
  # wait is visible while it happens instead of only in the captured stdout.
  if [ $((WAITED % 300)) -lt "$POLL_SECONDS" ]; then
    printf 'npm-login-wait: still waiting for the npm sign-in (%s of %s minutes elapsed)\n' \
      "$((WAITED / 60))" "$TIMEOUT_MINUTES" >&2
  fi
done

if [ -s "$PIDFILE" ]; then
  LOGIN_PID="$(cat "$PIDFILE" 2>/dev/null)"
  case "$LOGIN_PID" in
    ''|*[!0-9]*) ;;
    *) kill "$LOGIN_PID" 2>/dev/null || true ;;
  esac
fi
rm -f "$PIDFILE"

printf 'Not authenticated after %s minutes. Cancelling: nothing was staged.\n' "$TIMEOUT_MINUTES"
[ -s "$LOG" ] && printf 'Last login output:\n%s\n' "$(tail -n 10 "$LOG" 2>/dev/null)"
die "npm sign-in did not complete within $TIMEOUT_MINUTES minutes - run cancelled" 1
