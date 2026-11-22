#!/usr/bin/env bash
# scripts/validate-settings-fragment.sh - validate settings fragment files (epic E100, task E100_S02_T02).
#
# Contract: the "Settings fragments (`E100_S02`)" section of project/documentation/skill-authoring.md (format, keys a
# fragment cannot declare, secrets rule, "Validator contract"), derived from
# project/documentation/client-settings-requirements.md ("the contract"). Where this script and that section disagree,
# the script wins and the section is corrected in the same change.
#
# Usage:
#   validate-settings-fragment.sh <fragment.json> [<fragment.json>...]
#   validate-settings-fragment.sh            (no path: every shipped fragment found under the package,
#                                             skills/*/settings-fragment.json and hooks/*.fragment.json)
#   validate-settings-fragment.sh --help
#
# Output: one line on stdout per valid fragment, "ok: <path> (<id>)". One line on stderr per problem, in the form
#   settings-fragment: <fragment-path>: <key-path>: <reason>
# Every problem of every fragment is reported before the script exits (it does not stop at the first one).
#
# Exit codes: 0 every fragment valid; 1 at least one fragment invalid (also when another could not be read);
#             2 usage error, or a fragment that cannot be read or is not valid JSON (so it could not be judged).
#
# Read-only: writes no file. Needs jq. The package root is found through skills/index/scripts/package-root.sh so the
# script works in this monorepo and in a consumer install (node_modules/@jenga-ai/agent/scripts/). bash 3.2 compatible.

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() { sed -n '2,/^$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
  echo "settings-fragment: jq is required but was not found on PATH" >&2
  exit 2
fi

# jq program: reads one fragment, prints "ID<US>value" then one "P<US>key-path<US>reason" per problem.
read -r -d '' JQ_PROG <<'JQ'
def secretname: ascii_downcase | test("secret|token|password|passwd|credential|private_key|api_key|apikey");
def secretval: test("^(sk-|ghp_|gho_|github_pat_|xoxb-|xoxp-|AKIA)") or contains("-----BEGIN")
  or test("^eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$");
def p($path; $reason): "P\u001f\($path)\u001f\($reason)";
def model: ["model","fallbackModel","modelPicker","availableModels","modelSettings"];
def outofcontract($k; $path):
  if ($k == "defaultMode") or (model | index($k)) then p($path; "not allowed in a fragment (contract section 1, keys Jenga never writes)")
  elif $k == "deny" or $k == "ask" then p($path; "not allowed in a fragment (contract section 1, keys Jenga never writes)")
  else p($path; "unknown key, not named by the contract (contract section 1)") end;

. as $f
| if ($f | type) != "object" then p("$"; "fragment must be a JSON object")
  else
    ( "ID\u001f\(if ($f.id|type) == "string" then $f.id else "" end)" ),
    ( if ($f | has("id") | not) then p("id"; "missing required key")
      elif ($f.id | type) != "string" or ($f.id | test("^[a-z0-9][a-z0-9-]*$") | not)
        then p("id"; "must be a string of lower-case letters, digits and - starting with a letter or digit")
      else empty end ),
    ( if ($f | has("version") | not) then p("version"; "missing required key")
      elif $f.version != 1 or ($f.version | type) != "number" then p("version"; "must be the integer 1")
      else empty end ),
    ( $f | keys_unsorted[] | select(IN("id","version","hooks","permissions","env") | not) as $k
      | outofcontract($k; $k) ),
    ( if ($f | has("hooks") or has("permissions") or has("env")) then empty
      else p("$"; "declares none of hooks, permissions, env") end ),
    ( if ($f | has("hooks")) then
        if ($f.hooks | type) != "object" or ($f.hooks | length) == 0 then p("hooks"; "must be a non-empty object keyed by hook event name")
        else $f.hooks | to_entries[] | . as $e | "hooks.\($e.key)" as $ep
          | if ($e.value | type) != "array" or ($e.value | length) == 0 then p($ep; "must be a non-empty list of hook entries")
            else $e.value | to_entries[] | . as $h | "\($ep)[\($h.key)]" as $hp
              | if ($h.value | type) != "object" then p($hp; "hook entry must be an object")
                else
                  ( $h.value | keys_unsorted[] | select(IN("matcher","hooks") | not) as $k | p("\($hp).\($k)"; "unknown key in a hook entry")),
                  ( if ($h.value | has("matcher")) and (($h.value.matcher | type) != "string") then p("\($hp).matcher"; "must be a string") else empty end ),
                  ( if ($h.value.hooks | type) != "array" or ($h.value.hooks | length) == 0 then p("\($hp).hooks"; "must be a non-empty list of handler objects")
                    else $h.value.hooks | to_entries[] | . as $x
                      | if ($x.value | type) != "object" or (($x.value.type? // null) | type) != "string"
                          then p("\($hp).hooks[\($x.key)]"; "handler must be an object with a string type")
                        else empty end
                    end )
                end
            end
        end
      else empty end ),
    ( if ($f | has("permissions")) then
        if ($f.permissions | type) != "object" then p("permissions"; "must be an object holding only allow")
        else
          ( $f.permissions | keys_unsorted[] | select(. != "allow") as $k | outofcontract($k; "permissions.\($k)") ),
          ( if ($f.permissions | has("allow")) then
              if ($f.permissions.allow | type) != "array" then p("permissions.allow"; "must be a list of {rule, optIn} objects")
              else $f.permissions.allow | to_entries[] | . as $r | "permissions.allow[\($r.key)]" as $rp
                | if ($r.value | type) != "object" then p($rp; "allow rule must be an object {rule, optIn: true}, not marked opt-in (contract section 4)")
                  else
                    ( if (($r.value.rule? // null) | type) != "string" or $r.value.rule == "" then p("\($rp).rule"; "must be a non-empty rule string") else empty end ),
                    ( if ($r.value | has("optIn") | not) then p("\($rp).optIn"; "allow rule is not marked opt-in, optIn must be true (contract section 4)")
                      elif $r.value.optIn != true then p("\($rp).optIn"; "must be the literal boolean true (contract section 4)") else empty end ),
                    ( $r.value | keys_unsorted[] | select(IN("rule","optIn") | not) as $k | p("\($rp).\($k)"; "unknown key in an allow rule") )
                  end
              end
            else empty end )
        end
      else empty end ),
    ( if ($f | has("env")) then
        if ($f.env | type) != "object" then p("env"; "must be an object of name to string value")
        else $f.env | to_entries[] | . as $e | "env.\($e.key)" as $ep
          | ( if ($e.key | test("^[A-Za-z_][A-Za-z0-9_]*$") | not) then p($ep; "not a well formed variable name") else empty end ),
            ( if ($e.key | secretname) then p($ep; "name looks like a secret, a fragment must not declare secrets (rename the variable)") else empty end ),
            ( if ($e.value | type) != "string" then p($ep; "value must be a string")
              elif ($e.value | secretval) then p($ep; "value looks like a secret, a fragment must not declare secrets") else empty end )
        end
      else empty end )
  end
JQ

US=$'\037'
files=()
if [ "$#" -gt 0 ]; then
  files=("$@")
else
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/../skills/index/scripts/package-root.sh" 2>/dev/null || true
  PACKAGE_ROOT=""
  if command -v jenga_package_root >/dev/null 2>&1; then
    PACKAGE_ROOT="$(jenga_package_root "$SCRIPT_DIR/../skills/index/scripts" 2>/dev/null)" || true
  fi
  [ -n "$PACKAGE_ROOT" ] || PACKAGE_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
  for f in "$PACKAGE_ROOT"/skills/*/settings-fragment.json "$PACKAGE_ROOT"/hooks/*.fragment.json; do
    [ -f "$f" ] && files+=("$f")
  done
  if [ "${#files[@]}" -eq 0 ]; then
    echo "no settings fragments found under $PACKAGE_ROOT"
    exit 0
  fi
fi

bad=0       # at least one invalid fragment
unread=0    # at least one unreadable / unparseable fragment
seen_ids=$'\n'
seen_by=()

for f in "${files[@]}"; do
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    echo "settings-fragment: $f: \$: cannot be read, so it could not be judged" >&2; unread=1; continue
  fi
  if ! jq -e . "$f" >/dev/null 2>&1; then
    echo "settings-fragment: $f: \$: not valid JSON, so it could not be judged" >&2; unread=1; continue
  fi
  out="$(jq -r "$JQ_PROG" "$f" 2>/dev/null)"
  id=""; problems=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      ID"$US"*) id="${line#ID"$US"}" ;;
      P"$US"*)
        rest="${line#P"$US"}"
        echo "settings-fragment: $f: ${rest%%"$US"*}: ${rest#*"$US"}" >&2
        problems=$((problems + 1)) ;;
    esac
  done <<EOT
$out
EOT
  if [ -n "$id" ]; then
    case "$seen_ids" in
      *$'\n'"$id"$'\n'*)
        echo "settings-fragment: $f: id: duplicate id '$id', already used by another fragment in this run" >&2
        problems=$((problems + 1)) ;;
      *) seen_ids="$seen_ids$id"$'\n' ;;
    esac
  fi
  if [ "$problems" -eq 0 ]; then
    echo "ok: $f ($id)"
  else
    bad=1
  fi
done

if [ "$bad" -eq 1 ]; then exit 1; fi
if [ "$unread" -eq 1 ]; then exit 2; fi
exit 0
