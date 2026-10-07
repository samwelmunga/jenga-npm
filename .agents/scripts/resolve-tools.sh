#!/usr/bin/env bash
# Resolve the effective preferred-tools list (E66_S02_T02).
#
# Locates the three registry layers, merges them with merge-tools-registry.sh
# (precedence project over user over shipped, suppression, per-entry `layer`),
# optionally filters by category, and prints the result. The layering rules and
# the output shape are documented in project/documentation/preferred-tools-registry.md.
#
# Usage: resolve-tools.sh [--category <name>] [--format json|text]
#
#   --category <name>   only entries of that category (base vocabulary plus any
#                       category declared by a present layer)
#   --format json|text  json (default): {"registry_version","categories","tools"}
#                       text: one tab-separated line per entry:
#                       category, name, enforcement, layer, version, rationale
#
# Layers:
#   shipped  <package root>/skills/j-tools/assets/shipped-tools.json, where the
#            package root is the parent of this script's directory, so it works
#            in this repo and under node_modules/@jenga-ai/agent/
#   user     ${JENGA_USER_TOOLS_FILE:-$HOME/.jenga/tools.json}
#   project  <configs path from resolve-root.sh>/preferred-tools.json
# A missing user or project file is normal and skipped. An invalid layer is an
# error and is never dropped silently.
#
# Exit codes:
#   0  effective list written to stdout (possibly empty for a known category)
#   2  usage error, or unknown --category (valid categories listed on stderr)
#   3  jq is not installed
#   4  a present layer is invalid (passed through from merge-tools-registry.sh;
#      the layer and file are named on stderr)
#   5  the project configs path could not be resolved (resolve-root.sh failed)
#
# Compatible with macOS bash 3.2.

set -u

SELF="resolve-tools.sh"

usage() {
  printf 'usage: %s [--category <name>] [--format json|text]\n' "$SELF" >&2
}

if ! command -v jq >/dev/null 2>&1; then
  printf '%s: jq is required but was not found on PATH; install jq (e.g. brew install jq)\n' "$SELF" >&2
  exit 3
fi

CATEGORY=""
HAVE_CATEGORY=0
FORMAT="json"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --category)
      if [ "$#" -lt 2 ]; then
        printf '%s: --category needs a value\n' "$SELF" >&2
        usage
        exit 2
      fi
      CATEGORY="$2"
      HAVE_CATEGORY=1
      shift 2
      ;;
    --category=*)
      CATEGORY="${1#--category=}"
      HAVE_CATEGORY=1
      shift
      ;;
    --format)
      if [ "$#" -lt 2 ]; then
        printf '%s: --format needs a value\n' "$SELF" >&2
        usage
        exit 2
      fi
      FORMAT="$2"
      shift 2
      ;;
    --format=*)
      FORMAT="${1#--format=}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf '%s: unexpected argument: %s\n' "$SELF" "$1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$FORMAT" in
  json | text) ;;
  *)
    printf '%s: unknown --format %s (expected json or text)\n' "$SELF" "$FORMAT" >&2
    exit 2
    ;;
esac

if [ "$HAVE_CATEGORY" -eq 1 ] && [ -z "$CATEGORY" ]; then
  printf '%s: --category needs a non-empty value\n' "$SELF" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SHIPPED_FILE="$PACKAGE_ROOT/skills/j-tools/assets/shipped-tools.json"
USER_FILE="${JENGA_USER_TOOLS_FILE:-}"
if [ -z "$USER_FILE" ] && [ -n "${HOME:-}" ]; then
  USER_FILE="$HOME/.jenga/tools.json"
fi

# resolve-root.sh runs in the caller's working directory so its upward search
# for the working-file tree starts where the caller is.
if ! CONFIGS_DIR="$(bash "$SCRIPT_DIR/resolve-root.sh" get configs)"; then
  printf '%s: could not resolve the project configs path via resolve-root.sh\n' "$SELF" >&2
  exit 5
fi
PROJECT_FILE="$CONFIGS_DIR/preferred-tools.json"

MERGED="$(bash "$SCRIPT_DIR/merge-tools-registry.sh" "$SHIPPED_FILE" "$USER_FILE" "$PROJECT_FILE")"
MERGE_STATUS=$?
if [ "$MERGE_STATUS" -ne 0 ]; then
  # merge-tools-registry.sh has already named the layer and file on stderr.
  exit "$MERGE_STATUS"
fi

if [ "$HAVE_CATEGORY" -eq 1 ]; then
  # Base vocabulary mirrors validate-tools-registry.sh; layers may extend it.
  VALID="$(printf '%s' "$MERGED" | jq -r '(["runtime","testing","lint","CI","infra"] + .categories) | join(", ")')"
  if ! printf '%s' "$MERGED" | jq -e --arg c "$CATEGORY" \
    '(["runtime","testing","lint","CI","infra"] + .categories) | index($c) != null' >/dev/null; then
    printf '%s: unknown category %s (valid categories: %s)\n' "$SELF" "$CATEGORY" "$VALID" >&2
    exit 2
  fi
  MERGED="$(printf '%s' "$MERGED" | jq --arg c "$CATEGORY" '.tools |= map(select(.category == $c))')"
fi

if [ "$FORMAT" = "json" ]; then
  printf '%s\n' "$MERGED"
else
  printf '%s' "$MERGED" |
    jq -r '.tools[] | [.category, .name, .enforcement, .layer, .version, .rationale] | @tsv'
fi
