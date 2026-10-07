#!/usr/bin/env bash
# render-config-list.sh - list `jenga config` files or keys as a Jenga ranked_list (E68_S01_T04)
#
# Thin wrapper over lib/config/render.js, which holds all the logic; this mirrors scripts/render-ranked-list.sh as
# an entry point over a shared module. Output is the `ranked_list` object type from templates/playbook-types.json:
# 1-indexed "<n>. <id> — <text>" lines, no trailing menu or prompt line, deterministic order.
#
# Usage:
#   scripts/render-config-list.sh              list the config files (id, description, editable-key count)
#   scripts/render-config-list.sh <file-id>    list that file's keys; <file-id> is the config basename without .json
#
# A config file missing from the project is listed as "[not present]", one that does not parse as "[unreadable]".
# Listing the keys of such a file is refused (exit 6).
#
# Exit codes (the shared table in project/documentation/config-descriptors.md):
#   0  ok
#   1  descriptors invalid or absent (run scripts/validate-config-descriptors.sh --all), or node missing
#   2  usage error
#   3  unknown config file id
#   6  configs directory unresolvable (scripts/resolve-root.sh failed), or the requested config file is missing
#      or unreadable
#
# Environment:
#   JENGA_CONFIG_DESCRIPTORS_DIR  read descriptors from this directory instead of the package's (tests)
#   JENGA_PROJECT_ROOT            resolve the configs directory under this root (see scripts/resolve-root.sh)
#
# Works from this checkout and from node_modules/@jenga-ai/agent/: the module is located relative to this script.
# Compatible with macOS bash 3.2.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pkg_root="$(cd "$here/.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
  printf 'render-config-list.sh: node is required but was not found on PATH\n' >&2
  exit 1
fi

exec node "$pkg_root/lib/config/render.js" "$@"
