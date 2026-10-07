#!/usr/bin/env bash
# Merge the shipped, user and project preferred-tools registries (E66_S01_T03).
#
# Implements the layering rules in project/documentation/preferred-tools-registry.md:
#   - precedence project over user over shipped
#   - a same-name entry in a higher layer replaces the lower entry whole
#   - a layer's `suppress` removes matching entries from LOWER layers only
#   - every output entry carries a `layer` field (shipped | user | project)
#   - merged `categories` is the union of the layers' extension lists
#
# Usage: merge-tools-registry.sh <shipped> <user> <project>
#   Each argument is a path; an empty string or a non-existent file means that
#   layer is absent and is skipped. A present layer is validated with
#   validate-tools-registry.sh and an invalid one aborts the merge.
#
# Output: one JSON document on stdout:
#   {"registry_version": 1, "categories": [...], "tools": [...]}
#
# Exit codes:
#   0  merged document written to stdout
#   2  usage error (wrong argument count)
#   3  jq is not installed
#   4  a present layer is invalid (layer and file named on stderr; nothing on stdout)
#
# Compatible with macOS bash 3.2.

set -u

SELF="merge-tools-registry.sh"

if ! command -v jq >/dev/null 2>&1; then
  printf '%s: jq is required but was not found on PATH; install jq (e.g. brew install jq)\n' "$SELF" >&2
  exit 3
fi

if [ "$#" -ne 3 ]; then
  printf 'usage: %s <shipped> <user> <project>\n' "$SELF" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/validate-tools-registry.sh"

EMPTY_LAYER='{"categories":[],"suppress":[],"tools":[]}'

# Prints the normalised JSON of one layer, or aborts the script with exit 4.
# $1 = layer name, $2 = path (possibly empty or non-existent => absent layer).
load_layer() {
  local layer="$1" path="$2"
  if [ -z "$path" ] || [ ! -e "$path" ]; then
    printf '%s' "$EMPTY_LAYER"
    return 0
  fi
  if ! "$VALIDATOR" "$path" >&2; then
    printf '%s: invalid %s layer: %s\n' "$SELF" "$layer" "$path" >&2
    return 1
  fi
  jq -c '{categories: (.categories // []), suppress: (.suppress // []), tools: .tools}' "$path"
}

SHIPPED_JSON="$(load_layer shipped "$1")" || exit 4
USER_JSON="$(load_layer user "$2")" || exit 4
PROJECT_JSON="$(load_layer project "$3")" || exit 4

# shellcheck disable=SC2016  # $-names below are jq variables, not shell expansions
jq -n \
  --argjson shipped "$SHIPPED_JSON" \
  --argjson user "$USER_JSON" \
  --argjson project "$PROJECT_JSON" '
  [ {name: "shipped", doc: $shipped},
    {name: "user", doc: $user},
    {name: "project", doc: $project} ] as $layers
  | reduce $layers[] as $l ({tools: [], categories: []};
      ($l.doc.suppress) as $sup
      | ($l.doc.tools | map(.name)) as $own
      # lower entries: drop suppressed names and names this layer redefines
      | .tools |= map(select((.name as $n | ($sup | index($n)) == null and ($own | index($n)) == null)))
      | .tools += ($l.doc.tools | map(. + {layer: $l.name}))
      | .categories += $l.doc.categories)
  | {registry_version: 1,
     categories: (.categories | unique),
     tools: (.tools | sort_by([.category, .name]))}
'
