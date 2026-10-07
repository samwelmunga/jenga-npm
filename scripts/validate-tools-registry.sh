#!/usr/bin/env bash
# Validate a preferred-tools registry file (E66_S01_T02).
#
# Implements the schema in project/documentation/preferred-tools-registry.md.
#
# Usage: validate-tools-registry.sh <file>
#
# Exit codes:
#   0  valid
#   1  invalid (one specific message per failure on stderr; every failure is reported)
#   2  usage error (wrong argument count, file not found or unreadable)
#   3  jq is not installed
#
# Environment:
#   JENGA_DESCRIPTORS_DIR  directory holding j-connect service descriptors
#                          (default: skills/j-connect/descriptors/ relative to this script)
#
# Compatible with macOS bash 3.2.

set -u

SELF="validate-tools-registry.sh"

usage() {
  printf 'usage: %s <file>\n' "$SELF" >&2
}

if ! command -v jq >/dev/null 2>&1; then
  printf '%s: jq is required but was not found on PATH; install jq (e.g. brew install jq)\n' "$SELF" >&2
  exit 3
fi

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi

FILE="$1"

if [ ! -f "$FILE" ] || [ ! -r "$FILE" ]; then
  printf '%s: cannot read file: %s\n' "$SELF" "$FILE" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESC_DIR="${JENGA_DESCRIPTORS_DIR:-$SCRIPT_DIR/../skills/j-connect/descriptors}"

if ! jq -e . "$FILE" >/dev/null 2>&1; then
  printf '%s: malformed JSON (file does not parse)\n' "$FILE" >&2
  exit 1
fi

# Existing descriptor ids, as a JSON array of strings.
if [ -d "$DESC_DIR" ]; then
  DESCRIPTORS="$(find "$DESC_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null |
    sed -e 's|.*/||' -e 's|\.json$||' | LC_ALL=C sort | jq -R . | jq -s -c .)"
else
  DESCRIPTORS='[]'
fi

# shellcheck disable=SC2016  # $-names below are jq variables, not shell expansions
JQ_PROGRAM='
def blank: type != "string" or (gsub("^\\s+|\\s+$"; "") | length == 0);
def vc_ok: type == "string" and test("^(\\*|(>=|<=|>|<|=|\\^|~)?[0-9]+(\\.[0-9]+){0,2}( +(>=|<=|>|<|=|\\^|~)?[0-9]+(\\.[0-9]+){0,2})*)$");

if type != "object" then
  ["top level must be a JSON object"]
else
  . as $doc
  | (if (.categories | type) == "array"
       then [.categories[] | select(type == "string" and test("^[A-Za-z][A-Za-z0-9_-]*$")) | . as $c
                      | select(($base | map(ascii_downcase) | index($c | ascii_downcase)) == null)]
       else [] end) as $ext
  | ($base + $ext) as $allowed
  | [
      # --- envelope ---
      (if has("registry_version") | not then "missing field: registry_version"
       elif .registry_version != 1 then
         "registry_version must be 1 (got \(.registry_version | tojson))"
       else empty end),

      (if has("categories") then
         (if (.categories | type) != "array" then "categories must be an array"
          else
            (.categories | to_entries[]
             | .key as $i | .value as $c
             | if ($c | type) != "string" or ($c | test("^[A-Za-z][A-Za-z0-9_-]*$") | not) then
                 "categories[\($i)]: invalid category name \($c | tojson) (must match ^[A-Za-z][A-Za-z0-9_-]*$)"
               elif ($base | map(ascii_downcase) | index($c | ascii_downcase)) != null then
                 "categories[\($i)]: \($c | tojson) duplicates a base category (base: \($base | join(", ")))"
               else empty end)
          end)
       else empty end),

      (if has("suppress") then
         (if (.suppress | type) != "array" then "suppress must be an array"
          else
            (.suppress | to_entries[]
             | select(.value | blank)
             | "suppress[\(.key)]: must be a non-empty string (got \(.value | tojson))")
          end)
       else empty end),

      # --- tools ---
      (if has("tools") | not then "missing field: tools"
       elif (.tools | type) != "array" then "tools must be an array"
       else
         (.tools | to_entries[]
          | .key as $i | .value as $t
          | ("tools[\($i)]" + (if ($t | type) == "object" and ($t.name | type) == "string"
                                 then " (\($t.name))" else "" end)) as $at
          | if ($t | type) != "object" then
              "\($at): must be an object"
            else
              (
                (["name", "category", "enforcement", "rationale", "alternatives", "version", "install_hint"][]
                 | select(. as $k | $t | has($k) | not)
                 | "\($at): missing field: \(.)"),

                (if ($t | has("name")) and ($t.name | blank)
                   then "\($at): name must be a non-empty string" else empty end),

                (if $t | has("category") then
                   (if ($t.category | type) != "string" or (($allowed | index($t.category)) == null)
                      then "\($at): unknown category \($t.category | tojson) (allowed: \($allowed | join(", ")))"
                      else empty end)
                 else empty end),

                (if $t | has("enforcement") then
                   (if ($t.enforcement == "required" or $t.enforcement == "recommended") | not
                      then "\($at): bad enforcement value \($t.enforcement | tojson) (must be \"required\" or \"recommended\")"
                      else empty end)
                 else empty end),

                (if ($t | has("rationale")) and ($t.rationale | blank)
                   then "\($at): rationale must be a non-empty string" else empty end),

                (if $t | has("alternatives") then
                   (if ($t.alternatives | type) != "array"
                      then "\($at): alternatives must be an array"
                      else
                        ($t.alternatives | to_entries[]
                         | .key as $j | .value as $a
                         | if ($a | type) != "object" then
                             "\($at): alternatives[\($j)] must be an object with name and why_not"
                           else
                             (("name", "why_not")
                              | . as $f
                              | select(($a | has($f) | not) or ($a[$f] | blank))
                              | "\($at): alternatives[\($j)].\($f) must be a non-empty string")
                           end)
                      end)
                 else empty end),

                (if $t | has("version") then
                   (if ($t.version | vc_ok) | not
                      then "\($at): malformed version constraint \($t.version | tojson) (expected e.g. \">=1.5\", \"^20\", \"1.2.3\", \">=18 <22\" or \"*\")"
                      else empty end)
                 else empty end),

                (if $t | has("install_hint") then
                   (if ($t.install_hint | type) != "object"
                      then "\($at): install_hint must be an object"
                      else
                        ($t.install_hint) as $h
                        | (if ($h | has("descriptor") or has("text")) | not
                             then "\($at): install_hint needs a descriptor and/or text" else empty end),
                          (if $h | has("descriptor") then
                             (if ($h.descriptor | type) != "string"
                                 or ($h.descriptor | test("^[a-z0-9][a-z0-9-]*$") | not)
                                then "\($at): install_hint.descriptor must be a service id matching ^[a-z0-9][a-z0-9-]*$ (got \($h.descriptor | tojson))"
                              elif ($descriptors | index($h.descriptor)) == null
                                then "\($at): install_hint.descriptor \($h.descriptor | tojson) names no file under skills/j-connect/descriptors/"
                              else empty end)
                           else empty end),
                          (if ($h | has("text")) and ($h.text | blank)
                             then "\($at): install_hint.text must be a non-empty string" else empty end)
                      end)
                 else empty end)
              )
            end)
       end),

      (if (.tools | type) == "array" then
         ([.tools[] | select(type == "object" and (.name | type) == "string") | .name]
          | group_by(.)[] | select(length > 1)
          | "duplicate tool name \(.[0] | tojson) (\(length) entries in this file)")
       else empty end)
    ]
end
| .[]
'

ERRORS="$(jq -r --argjson base '["runtime","testing","lint","CI","infra"]' \
  --argjson descriptors "$DESCRIPTORS" "$JQ_PROGRAM" "$FILE" 2>&1)"
JQ_STATUS=$?

if [ "$JQ_STATUS" -ne 0 ]; then
  printf '%s: internal validator error: %s\n' "$FILE" "$ERRORS" >&2
  exit 1
fi

if [ -n "$ERRORS" ]; then
  printf '%s\n' "$ERRORS" | while IFS= read -r line; do
    printf '%s: %s\n' "$FILE" "$line" >&2
  done
  exit 1
fi

exit 0
