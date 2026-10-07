#!/usr/bin/env bash
# validate-config-descriptors.sh - validate `jenga config` descriptors (E68_S01_T02)
#
# Thin wrapper over lib/config/descriptors.js, which holds all the logic (loader, schema-driven validator and the
# comparison against the real config files). Format contract: templates/config-descriptor-schema.json and
# project/documentation/config-descriptors.md.
#
# Usage:
#   scripts/validate-config-descriptors.sh --all                 every shipped descriptor against the real configs
#   scripts/validate-config-descriptors.sh <descriptor-file>...  one or more descriptor files
#
# stdout: "PASS <file>" or "FAIL <file>" per descriptor. stderr: one "<file>: <message>" line per problem (and a
# NOTE line when a config file is not present so its cross-check was skipped). Every problem is reported, not just
# the first.
#
# Exit codes:
#   0  every descriptor given is valid
#   1  at least one descriptor is invalid; or --all found no descriptors (never a silent pass); or the configs
#      directory could not be resolved; or node is missing
#   2  usage error
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
  printf 'validate-config-descriptors.sh: node is required but was not found on PATH\n' >&2
  exit 1
fi

exec node "$pkg_root/lib/config/descriptors.js" "$@"
