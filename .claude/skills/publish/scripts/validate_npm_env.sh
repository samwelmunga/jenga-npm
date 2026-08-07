#!/usr/bin/env bash
set -u

EXIT_ENV_INVALID=4

fail() {
  printf 'npm env validation failed: %s\n' "$1" >&2
  exit "$EXIT_ENV_INVALID"
}

if ! command -v npm >/dev/null 2>&1; then
  fail "'npm' was not found on PATH. Install Node.js (which provides npm) from https://nodejs.org/ or via your package manager, then re-run."
fi

NPM_TOKEN_VALUE="$(printenv NPM_TOKEN 2>/dev/null || true)"
NODE_AUTH_TOKEN_VALUE="$(printenv NODE_AUTH_TOKEN 2>/dev/null || true)"

if [[ -z "$NPM_TOKEN_VALUE" && -z "$NODE_AUTH_TOKEN_VALUE" ]]; then
  fail "no npm auth token found. Set NPM_TOKEN (or NODE_AUTH_TOKEN) in the environment before publishing, e.g. 'export NPM_TOKEN=<your-npm-automation-token>'. Generate a token at https://www.npmjs.com/settings/<user>/tokens."
fi

exit 0
