#!/usr/bin/env bash
#
# run-config.sh - the deterministic entry point for `/jenga-config` (E68_S04_T01).
#
# Every `jenga config ...` invocation from the skill goes through here, so the CLI is resolved the same way every
# time, without a global install:
#
#   1. a `jenga` already on PATH wins: `exec jenga config "$@"`. A present jenga is never upgraded or replaced;
#   2. otherwise the pinned @jenga-ai/agent is installed into a per-user cache prefix (never the global npm prefix):
#        npm install --prefix "$CACHE" --ignore-scripts --no-audit --no-fund @jenga-ai/agent@<pinned>
#      --ignore-scripts skips the package's postinstall (`npm run ui:build`), which `jenga config` does not need.
#      Install runs only when the cached bin is absent, so a populated cache costs no npm call;
#   3. the cached bin is run with the same arguments as the PATH run: `exec node <cached bin> config "$@"`.
#
# Contract:
#   - never `cd`: the config command resolves the project from the caller's cwd (scripts/resolve-root.sh), so the
#     cwd must reach the subcommand unchanged;
#   - the subcommand's exit code is passed through unchanged (lib/config/exit-codes.js: 0, 2, 3, 4, 5, 6);
#   - install progress and npm output go to stderr only, so stdout belongs to the subcommand alone;
#   - an install failure prints a message to stderr and exits 7 WITHOUT running the subcommand.
#
# Environment:
#   JENGA_CLI_CACHE   overrides the cache directory (default: ${XDG_CACHE_HOME:-$HOME/.cache}/jenga-cli).

# Single pinned version constant. Bump deliberately, with the package's own release.
JENGA_CLI_VERSION="4.2.0"

# Exit code for "the CLI could not be installed". Deliberately outside lib/config/exit-codes.js (0, 2-6).
EXIT_INSTALL_FAILED=7

if [ -n "${JENGA_CLI_CACHE:-}" ]; then
  CACHE="$JENGA_CLI_CACHE"
elif [ -n "${XDG_CACHE_HOME:-}" ]; then
  CACHE="$XDG_CACHE_HOME/jenga-cli"
elif [ -n "${HOME:-}" ]; then
  CACHE="$HOME/.cache/jenga-cli"
else
  echo "jenga-config: cannot choose a cache directory: set JENGA_CLI_CACHE, XDG_CACHE_HOME or HOME." >&2
  exit "$EXIT_INSTALL_FAILED"
fi

CACHED_BIN="$CACHE/node_modules/@jenga-ai/agent/bin/jenga.js"

if command -v jenga >/dev/null 2>&1; then
  exec jenga config "$@"
fi

if [ ! -f "$CACHED_BIN" ]; then
  echo "jenga-config: the jenga CLI is not on PATH; installing @jenga-ai/agent@$JENGA_CLI_VERSION into $CACHE" >&2
  if ! npm install --prefix "$CACHE" --ignore-scripts --no-audit --no-fund "@jenga-ai/agent@$JENGA_CLI_VERSION" >&2; then
    echo "jenga-config: the jenga CLI could not be installed (npm install failed). The config command was not run." >&2
    exit "$EXIT_INSTALL_FAILED"
  fi
  if [ ! -f "$CACHED_BIN" ]; then
    echo "jenga-config: the jenga CLI could not be installed ($CACHED_BIN is missing after npm install). The config command was not run." >&2
    exit "$EXIT_INSTALL_FAILED"
  fi
fi

exec node "$CACHED_BIN" config "$@"
