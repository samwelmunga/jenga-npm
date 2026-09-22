#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/validate-typed-object.sh
#
# The single deterministic answer to "does this value conform to this type?"
# for Epic E62's playbook type descriptors (E62_S01_T02). Consumed by
# E62_S01_T04 at playbook LOAD time and by E62_S02 at RUNTIME, which is why it
# lives in shared scripts/ rather than under skills/jenga/scripts/.
#
# ---------------------------------------------------------------------------
# NOTHING ABOUT THE TYPE SYSTEM IS HARDCODED HERE
# ---------------------------------------------------------------------------
# Every type name, every `verify` rule kind, and every `normalize` transform
# name is read out of templates/playbook-types.json on each invocation. Grep
# this file for `id_list`, `file_list` or `text` and you will find them only in
# comments. That is the whole point: the registry's own header asserts that
# "adding a TYPE is a DATA-ONLY edit and NEVER a code change", and a validator
# carrying its own copy of the type list would silently make that claim false.
#
# The registry's header is equally precise about the one exception, and this
# script implements exactly that line:
#
#   adding a TYPE   -> data only, works here with zero code change
#   adding a RULE   -> requires code, because something has to implement it
#   adding a TRANSFORM -> requires code, for the same reason
#
# So there are two distinct authorities, and they are deliberately not the same
# thing:
#
#   * the REGISTRY (`verify_rules`, `normalize_vocabulary`) is the authority on
#     what is ALLOWED to appear in a descriptor;
#   * the IMPLEMENTED_* constants below are the authority on what this script
#     can EXECUTE.
#
# A name present in one but not the other is a hard error in whichever
# direction it points, never a silent skip:
#
#   in a descriptor but not in the registry enumeration -> exit 6
#       (a hand-edit smuggled in something the closed vocabulary never admitted)
#   in the registry enumeration but not implemented here -> exit 6
#       (the registry is ahead of the validator; the code half of the extension
#        was not written)
#
# A silent skip on either path would turn "the format cannot express semantic
# extraction" back into a soft guideline, which is precisely what E62 rejected
# at epic level.
#
# ---------------------------------------------------------------------------
# OUT OF SCOPE — a hard boundary, not a preference
# ---------------------------------------------------------------------------
# No repair. No conversion between types. No LLM call. No network call. A value
# that still fails after `normalize` is simply NON-CONFORMING; producing "what
# the skill probably meant" is semantic extraction, rejected at epic level (see
# E62's "What was rejected, and why it matters"). The closed transform
# vocabulary exists so that this cannot creep back in later.
#
# Fully deterministic: identical inputs produce byte-identical output on every
# run. There is no clock, no randomness, no ordering that depends on the
# filesystem, and LC_ALL is pinned to C below so that POSIX character classes
# and ranges in a registry regex cannot vary with the caller's locale.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   scripts/validate-typed-object.sh [options] <type> <value>
#   scripts/validate-typed-object.sh [options] <type> -            # value on stdin
#   scripts/validate-typed-object.sh [options] --value-file <path> <type>
#
# Options:
#   --registry <path>    Type registry to read. Default: <script dir>/../
#                        templates/playbook-types.json, resolved relative to
#                        this script so the repo root and the .claude/ and
#                        .agents/ mirrors each use their own copy.
#   --value-file <path>  Read the value from a file instead of an argument.
#   -h, --help           Print this usage block and exit 0.
#
# Environment:
#   JENGA_PLAYBOOK_TYPES_FILE   Same as --registry (the flag wins if both are
#                               given). This is the test-injection hook, in the
#                               style of JENGA_PLAYBOOKS_TEST_ROOT.
#
# ---------------------------------------------------------------------------
# OUTPUT — one JSON object on stdout, on every path
# ---------------------------------------------------------------------------
#   {
#     "outcome": "conforming" | "normalized" | "non-conforming" | "error",
#     "type":    "<the type name as given>",
#     "raw":     "<the value exactly as supplied, before any transform>",
#     "value":   "<the value the caller should use>" | null,
#     "normalize_applied": ["<transform>", ...],
#     "reason":  "<why>" | null,
#     "error":   "<error kind>"        // present only when outcome is "error"
#   }
#
# `value` is the raw value on the conforming path, the normalized value on the
# normalized path, and null on the non-conforming and error paths. `reason` is
# null unless something went wrong.
#
# E62_S02 needs to distinguish "already fine" from "I had to fix it" so it can
# warn: that is `outcome` (conforming vs normalized), and equivalently the exit
# code (0 vs 2), so a shell consumer can branch without parsing JSON at all.
#
# The three OUTCOME paths write to stdout only — stderr stays empty, so a
# non-conforming value is not noise in a caller's log. The ERROR paths write a
# human-readable `validate-typed-object.sh: error: ...` line to stderr as well,
# matching the neighbouring shared helpers.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  conforming       — satisfies `verify` as given (or `verify` is null)
#   1  usage error      — bad arguments
#   2  normalized       — did not conform as given, but conforms after
#                         `normalize`; the normalized value is in `value`
#   3  non-conforming   — fails `verify` even after `normalize`
#   4  unknown type     — the type name is not a key of the registry's `types`
#   5  environment      — jq missing, registry missing / unreadable /
#                         unparseable / not a type registry
#   6  registry contract violation — a descriptor names a `verify` rule kind or
#                         a `normalize` transform that the closed vocabulary
#                         does not admit, or that this validator does not
#                         implement, or is otherwise malformed
#
# ---------------------------------------------------------------------------
# SEMANTICS
# ---------------------------------------------------------------------------
# A value is treated as a list of lines, per the registry header. The list is
# derived with ordinary POSIX line semantics: the empty value yields zero
# elements, and a single terminating newline is a terminator rather than an
# extra empty element ("a\n" is one element, "a\n\n" is two).
#
# Evaluation order is fixed:
#   1. validate the descriptor's contract (rule kinds, transform names) — this
#      happens BEFORE the value is looked at, so a malformed descriptor cannot
#      pass merely because the value happened to be conforming already;
#   2. `verify: null` short-circuits to conforming — always, unconditionally;
#   3. verify the value as given -> conforming;
#   4. otherwise apply `normalize` left to right and verify again ->
#      normalized, or non-conforming.
#
# `per_line` is the rule kind defined today: a POSIX ERE that every element of
# the list must match. Matching uses `grep -E`, NOT jq's `test()`, because the
# registry's patterns are POSIX ERE by deliberate choice ([0-9] and
# [^[:space:]], never \d or \S) precisely because the consumer is a shell
# script. A `verify` object carrying several rule kinds requires all of them to
# hold.
#
# KNOWN SEMANTIC EDGE, deliberately left literal: "every element matches" is
# vacuously TRUE of an empty list, so a value that normalizes down to nothing
# (e.g. "" or " , " for id_list) is reported conforming rather than
# non-conforming. That is the honest reading of the rule as the registry states
# it. The alternative — a non-empty requirement — is NOT invented here, because
# inventing it would mean hardcoding a rule the registry never expressed; the
# right way to express it is a new rule kind in the registry (a data edit plus
# its implementation), which is exactly the extension path the format provides.
# Flagged for E62_S02 rather than silently decided here.
# ---------------------------------------------------------------------------

set -euo pipefail

# Pathname expansion off. Registry-sourced names are carried in arrays and
# expanded quoted, so nothing should reach a glob context — this is the belt to
# that braces. A registry entry of "*" reaching an unquoted expansion would glob
# against the caller's cwd, making the verdict depend on where the script was
# run from, which is the one thing it must never do.
set -f

# Pinned for determinism: character classes ([[:space:]]) and ranges in a
# registry regex must not depend on the caller's locale.
LC_ALL=C
export LC_ALL

SELF="$(basename "$0")"

# What this script can EXECUTE. See the header: this is NOT the vocabulary —
# the registry owns that — it is the implementation inventory, and the two are
# cross-checked against each other in both directions before any value is
# evaluated. Keep each list in step with its dispatcher below.
IMPLEMENTED_RULE_KINDS=("per_line")
IMPLEMENTED_TRANSFORMS=("split_on_comma" "trim" "drop_empty")

# The bare-identifier shape the registry header mandates for a transform name.
IDENTIFIER_ERE='^[a-z][a-z0-9_]*$'

TYPE_NAME=""
RAW_VALUE=""

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

usage() {
  cat <<'USAGE'
Usage:
  validate-typed-object.sh [options] <type> <value>
  validate-typed-object.sh [options] <type> -             # value on stdin
  validate-typed-object.sh [options] --value-file <path> <type>

Options:
  --registry <path>    Type registry (default: ../templates/playbook-types.json
                       relative to this script; JENGA_PLAYBOOK_TYPES_FILE also
                       sets it).
  --value-file <path>  Read the value from a file instead of an argument.
  -h, --help           Show this help.

Exit codes:
  0 conforming   1 usage   2 normalized   3 non-conforming
  4 unknown type   5 environment   6 registry contract violation
USAGE
}

# emit_outcome <outcome> <exit-code> <value-json> <applied-json> <reason-json>
emit_outcome() {
  jq -n \
    --arg outcome "$1" \
    --arg type "$TYPE_NAME" \
    --arg raw "$RAW_VALUE" \
    --argjson value "$3" \
    --argjson applied "$4" \
    --argjson reason "$5" \
    '{outcome: $outcome, type: $type, raw: $raw, value: $value, normalize_applied: $applied, reason: $reason}'
  exit "$2"
}

# fail <exit-code> <error-kind> <message>
fail() {
  local code="$1" kind="$2" msg="$3"
  printf '%s: error: %s\n' "$SELF" "$msg" >&2
  # jq is how the JSON half of the contract gets written, so the one error that
  # cannot honour it is a missing jq. Every other error path does.
  if command -v jq > /dev/null 2>&1; then
    jq -n \
      --arg outcome "error" \
      --arg error "$kind" \
      --arg type "$TYPE_NAME" \
      --arg raw "$RAW_VALUE" \
      --arg reason "$msg" \
      '{outcome: $outcome, type: $type, raw: $raw, value: null, normalize_applied: [], reason: $reason, error: $error}'
  fi
  exit "$code"
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# list_contains <needle> [<candidate> ...]
#
# Membership is compared on WHOLE strings, never on whitespace-split tokens. A
# hand-edited registry entry such as "extract the ids the skill meant" has to be
# reported as that entry, in full — splitting it would report a verdict about
# the token "extract" and describe a registry the user does not have.
list_contains() {
  local needle="$1" candidate
  shift
  for candidate in "$@"; do
    if [ "$candidate" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

# read_lines_into <array-name> < <newline-delimited stream>
#
# One entry per line, read WHOLE — never split on whitespace. A registry is a
# JSON file a human can hand-edit, so an entry may legally contain spaces, and
# "extract the ids the skill meant" has to reach the identifier check intact to
# be rejected by name rather than by one of its tokens.
#
# A newline INSIDE an entry would defeat the line framing, so that case is ruled
# out up front instead: assert_no_newlines below rejects any such entry before
# it is ever read here.
read_lines_into() {
  local name="$1" item
  eval "$name=()"
  while IFS= read -r item; do
    eval "$name+=(\"\$item\")"
  done
}

# assert_no_newlines <jq-filter-yielding-strings> <what>
#
# Line framing above is only safe if no entry contains a newline. Rather than
# silently mis-framing such an entry into two, reject it as the malformed
# registry content it is.
assert_no_newlines() {
  jq -e --arg t "$TYPE_NAME" "$1 | all(type == \"string\" and (contains(\"\n\") | not))" \
    "$REGISTRY_FILE" > /dev/null 2>&1 \
    || fail 6 "malformed_registry_entry" "$2 in $REGISTRY_FILE contains an entry that is not a newline-free string"
}

# join_with_comma <item> [<item> ...]
join_with_comma() {
  local out="" item
  for item in "$@"; do
    if [ -z "$out" ]; then
      out="$item"
    else
      out="$out, $item"
    fi
  done
  printf '%s' "$out"
}

# Reads a whole file (or stdin, when $1 is "-") into RAW_VALUE without losing
# trailing newlines — command substitution strips them, hence the sentinel.
read_value_from() {
  local src="$1" buf
  if [ "$src" = "-" ]; then
    buf="$(cat; printf 'x')"
  else
    [ -r "$src" ] || fail 5 "value_file_unreadable" "value file not readable: $src"
    buf="$(cat -- "$src"; printf 'x')"
  fi
  RAW_VALUE="${buf%x}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

REGISTRY_FILE="${JENGA_PLAYBOOK_TYPES_FILE:-}"
VALUE_FILE=""
VALUE_GIVEN=0
POSITIONAL_COUNT=0
POS_TYPE=""
POS_VALUE=""

add_positional() {
  case "$POSITIONAL_COUNT" in
    0) POS_TYPE="$1" ;;
    1) POS_VALUE="$1" ;;
    *) fail 1 "usage" "unexpected extra argument: $1" ;;
  esac
  POSITIONAL_COUNT=$((POSITIONAL_COUNT + 1))
}

END_OF_OPTIONS=0
while [ "$#" -gt 0 ]; do
  if [ "$END_OF_OPTIONS" -eq 1 ]; then
    add_positional "$1"
    shift
    continue
  fi
  case "$1" in
    --registry)
      [ "$#" -ge 2 ] || fail 1 "usage" "--registry requires a path"
      REGISTRY_FILE="$2"
      shift 2
      ;;
    --registry=*)
      REGISTRY_FILE="${1#*=}"
      shift
      ;;
    --value-file)
      [ "$#" -ge 2 ] || fail 1 "usage" "--value-file requires a path"
      VALUE_FILE="$2"
      shift 2
      ;;
    --value-file=*)
      VALUE_FILE="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      END_OF_OPTIONS=1
      shift
      ;;
    -)
      add_positional "$1"
      shift
      ;;
    -*)
      fail 1 "usage" "unknown option: $1"
      ;;
    *)
      add_positional "$1"
      shift
      ;;
  esac
done

[ "$POSITIONAL_COUNT" -ge 1 ] || { usage >&2; fail 1 "usage" "a type name is required"; }
TYPE_NAME="$POS_TYPE"

if [ -n "$VALUE_FILE" ]; then
  [ "$POSITIONAL_COUNT" -le 1 ] || fail 1 "usage" "--value-file and a positional value are mutually exclusive"
  read_value_from "$VALUE_FILE"
  VALUE_GIVEN=1
elif [ "$POSITIONAL_COUNT" -eq 2 ]; then
  if [ "$POS_VALUE" = "-" ]; then
    read_value_from "-"
  else
    RAW_VALUE="$POS_VALUE"
  fi
  VALUE_GIVEN=1
fi

# An absent value and an empty value are different questions, and only the
# first is a usage error. `validate-typed-object.sh id_list ""` is a legitimate
# thing to ask.
[ "$VALUE_GIVEN" -eq 1 ] || { usage >&2; fail 1 "usage" "a value is required (pass it as an argument, as '-' for stdin, or via --value-file)"; }

# ---------------------------------------------------------------------------
# Registry resolution and structural sanity
# ---------------------------------------------------------------------------

command -v jq > /dev/null 2>&1 || fail 5 "jq_missing" "jq is required but not found on PATH"

if [ -z "$REGISTRY_FILE" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REGISTRY_FILE="$SCRIPT_DIR/../templates/playbook-types.json"
fi

[ -r "$REGISTRY_FILE" ] || fail 5 "registry_unreadable" "type registry not readable: $REGISTRY_FILE"
jq -e 'type == "object"' "$REGISTRY_FILE" > /dev/null 2>&1 \
  || fail 5 "registry_unparseable" "type registry is not a JSON object: $REGISTRY_FILE"

jq -e '(.types | type) == "object"' "$REGISTRY_FILE" > /dev/null 2>&1 \
  || fail 5 "registry_malformed" "type registry has no 'types' object: $REGISTRY_FILE"
jq -e '(.verify_rules | type) == "array"' "$REGISTRY_FILE" > /dev/null 2>&1 \
  || fail 5 "registry_malformed" "type registry has no 'verify_rules' array: $REGISTRY_FILE"
jq -e '(.normalize_vocabulary | type) == "array"' "$REGISTRY_FILE" > /dev/null 2>&1 \
  || fail 5 "registry_malformed" "type registry has no 'normalize_vocabulary' array: $REGISTRY_FILE"

# The two enumerations, read from the registry. Never assumed, never defaulted.
assert_no_newlines '.verify_rules' "'verify_rules'"
assert_no_newlines '.normalize_vocabulary' "'normalize_vocabulary'"
REGISTRY_RULE_KINDS=()
REGISTRY_TRANSFORMS=()
read_lines_into REGISTRY_RULE_KINDS < <(jq -r '.verify_rules[]' "$REGISTRY_FILE")
read_lines_into REGISTRY_TRANSFORMS < <(jq -r '.normalize_vocabulary[]' "$REGISTRY_FILE")

# ---------------------------------------------------------------------------
# Type lookup
# ---------------------------------------------------------------------------

if ! jq -e --arg t "$TYPE_NAME" '.types | has($t)' "$REGISTRY_FILE" > /dev/null 2>&1; then
  KNOWN_TYPES="$(jq -r '.types | keys_unsorted | join(", ")' "$REGISTRY_FILE")"
  fail 4 "unknown_type" "unknown type '$TYPE_NAME' — not a key of 'types' in $REGISTRY_FILE (known types: $KNOWN_TYPES)"
fi

jq -e --arg t "$TYPE_NAME" '(.types[$t] | type) == "object"' "$REGISTRY_FILE" > /dev/null 2>&1 \
  || fail 6 "malformed_descriptor" "descriptor for type '$TYPE_NAME' is not an object"

# "a descriptor never carries any other key" — registry header.
EXTRA_KEYS="$(jq -r --arg t "$TYPE_NAME" '.types[$t] | keys_unsorted - ["verify", "normalize"] | join(", ")' "$REGISTRY_FILE")"
[ -z "$EXTRA_KEYS" ] \
  || fail 6 "malformed_descriptor" "descriptor for type '$TYPE_NAME' carries key(s) outside {verify, normalize}: $EXTRA_KEYS"

# ---------------------------------------------------------------------------
# Descriptor contract validation — BEFORE the value is looked at, so a
# malformed descriptor cannot slip through on a value that already conformed.
# ---------------------------------------------------------------------------

VERIFY_TYPE="$(jq -r --arg t "$TYPE_NAME" '.types[$t].verify | type' "$REGISTRY_FILE")"
case "$VERIFY_TYPE" in
  "null"|"object") : ;;
  *) fail 6 "malformed_descriptor" "type '$TYPE_NAME': 'verify' must be an object or null, got $VERIFY_TYPE" ;;
esac

RULE_KINDS=()
if [ "$VERIFY_TYPE" = "object" ]; then
  assert_no_newlines '.types[$t].verify | keys_unsorted' "the 'verify' rule kinds of type '$TYPE_NAME'"
  read_lines_into RULE_KINDS < <(jq -r --arg t "$TYPE_NAME" '.types[$t].verify | keys_unsorted[]' "$REGISTRY_FILE")
  for kind in ${RULE_KINDS[@]+"${RULE_KINDS[@]}"}; do
    list_contains "$kind" ${REGISTRY_RULE_KINDS[@]+"${REGISTRY_RULE_KINDS[@]}"} \
      || fail 6 "unknown_rule_kind" "type '$TYPE_NAME': verify rule kind '$kind' is not a member of 'verify_rules' ($(join_with_comma ${REGISTRY_RULE_KINDS[@]+"${REGISTRY_RULE_KINDS[@]}"})) in $REGISTRY_FILE"
    list_contains "$kind" "${IMPLEMENTED_RULE_KINDS[@]}" \
      || fail 6 "unimplemented_rule_kind" "type '$TYPE_NAME': verify rule kind '$kind' is enumerated in 'verify_rules' but $SELF implements none of it — adding a rule kind requires code, not only a registry edit (implemented: $(join_with_comma "${IMPLEMENTED_RULE_KINDS[@]}"))"
  done
fi

NORMALIZE_TYPE="$(jq -r --arg t "$TYPE_NAME" '.types[$t].normalize | type' "$REGISTRY_FILE")"
case "$NORMALIZE_TYPE" in
  "null"|"array") : ;;
  *) fail 6 "malformed_descriptor" "type '$TYPE_NAME': 'normalize' must be an array, got $NORMALIZE_TYPE" ;;
esac

TRANSFORMS=()
if [ "$NORMALIZE_TYPE" = "array" ]; then
  jq -e --arg t "$TYPE_NAME" '.types[$t].normalize | all(type == "string")' "$REGISTRY_FILE" > /dev/null 2>&1 \
    || fail 6 "malformed_descriptor" "type '$TYPE_NAME': every 'normalize' entry must be a string"
  assert_no_newlines '.types[$t].normalize' "the 'normalize' list of type '$TYPE_NAME'"
  read_lines_into TRANSFORMS < <(jq -r --arg t "$TYPE_NAME" '.types[$t].normalize[]' "$REGISTRY_FILE")
  for transform in ${TRANSFORMS[@]+"${TRANSFORMS[@]}"}; do
    # The identifier check runs FIRST and on the WHOLE entry. A hand-edited
    # "extract the ids the skill meant" must be rejected as that entry, by name,
    # rather than as some token inside it — which is what the registry header
    # means by the format being structurally incapable of carrying a semantic
    # instruction.
    printf '%s\n' "$transform" | grep -Eq -e "$IDENTIFIER_ERE" \
      || fail 6 "malformed_transform_name" "type '$TYPE_NAME': normalize entry '$transform' is not a bare identifier matching $IDENTIFIER_ERE — a free-text or semantic-extraction instruction is not representable in this format"
    list_contains "$transform" ${REGISTRY_TRANSFORMS[@]+"${REGISTRY_TRANSFORMS[@]}"} \
      || fail 6 "unknown_transform" "type '$TYPE_NAME': normalize transform '$transform' is not a member of 'normalize_vocabulary' ($(join_with_comma ${REGISTRY_TRANSFORMS[@]+"${REGISTRY_TRANSFORMS[@]}"})) in $REGISTRY_FILE"
    list_contains "$transform" "${IMPLEMENTED_TRANSFORMS[@]}" \
      || fail 6 "unimplemented_transform" "type '$TYPE_NAME': normalize transform '$transform' is enumerated in 'normalize_vocabulary' but $SELF has no implementation for it — adding a transform requires code, not only a registry edit (implemented: $(join_with_comma "${IMPLEMENTED_TRANSFORMS[@]}"))"
  done
fi

APPLIED_JSON="$(jq -c --arg t "$TYPE_NAME" '.types[$t].normalize // []' "$REGISTRY_FILE")"
EMPTY_JSON='[]'

# ---------------------------------------------------------------------------
# `verify: null` — always conforming, never failing. Short-circuits here, after
# the descriptor contract check above and before any line handling, because
# prose has no checkable shape and no transform could change that verdict.
# ---------------------------------------------------------------------------

if [ "$VERIFY_TYPE" = "null" ]; then
  emit_outcome "conforming" 0 "$(jq -n --arg v "$RAW_VALUE" '$v')" "$EMPTY_JSON" "null"
fi

# ---------------------------------------------------------------------------
# The value as a list of lines
# ---------------------------------------------------------------------------

ELEMS=()

split_into_lines() {
  local s="$1" line
  ELEMS=()
  # The empty value is zero elements, per POSIX line semantics.
  [ -n "$s" ] || return 0
  # A single terminating newline terminates the last line; it does not add an
  # empty one. "a\n" -> [a]; "a\n\n" -> [a, ""].
  s="${s%$'\n'}"
  while :; do
    case "$s" in
      *$'\n'*)
        line="${s%%$'\n'*}"
        ELEMS+=("$line")
        s="${s#*$'\n'}"
        ;;
      *)
        ELEMS+=("$s")
        break
        ;;
    esac
  done
}

join_elems() {
  local out="" i=0
  if [ "${#ELEMS[@]}" -eq 0 ]; then
    printf '%s' ""
    return 0
  fi
  while [ "$i" -lt "${#ELEMS[@]}" ]; do
    if [ "$i" -eq 0 ]; then
      out="${ELEMS[$i]}"
    else
      out="$out
${ELEMS[$i]}"
    fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Transforms — the closed vocabulary, implemented exactly as the registry
# header describes it. The `*)` arm is unreachable: an unimplemented name was
# already rejected above. It stays as a guard against the two lists drifting.
# ---------------------------------------------------------------------------

transform_split_on_comma() {
  local i=0 rest part
  local -a out
  out=()
  while [ "$i" -lt "${#ELEMS[@]}" ]; do
    rest="${ELEMS[$i]}"
    while :; do
      case "$rest" in
        *,*)
          part="${rest%%,*}"
          out+=("$part")
          rest="${rest#*,}"
          ;;
        *)
          out+=("$rest")
          break
          ;;
      esac
    done
    i=$((i + 1))
  done
  ELEMS=()
  if [ "${#out[@]}" -gt 0 ]; then
    ELEMS=("${out[@]}")
  fi
}

# Strips leading and trailing whitespace from one element.
trim_one() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

transform_trim() {
  local i=0
  local -a out
  out=()
  while [ "$i" -lt "${#ELEMS[@]}" ]; do
    out+=("$(trim_one "${ELEMS[$i]}")")
    i=$((i + 1))
  done
  ELEMS=()
  if [ "${#out[@]}" -gt 0 ]; then
    ELEMS=("${out[@]}")
  fi
}

# "removes elements that are empty after trimming" — registry header. It drops
# whitespace-only elements without itself rewriting the survivors, so its
# behaviour does not depend on whether `trim` happened to run before it.
transform_drop_empty() {
  local i=0
  local -a out
  out=()
  while [ "$i" -lt "${#ELEMS[@]}" ]; do
    if [ -n "$(trim_one "${ELEMS[$i]}")" ]; then
      out+=("${ELEMS[$i]}")
    fi
    i=$((i + 1))
  done
  ELEMS=()
  if [ "${#out[@]}" -gt 0 ]; then
    ELEMS=("${out[@]}")
  fi
}

apply_transform() {
  case "$1" in
    split_on_comma) transform_split_on_comma ;;
    trim) transform_trim ;;
    drop_empty) transform_drop_empty ;;
    *) fail 6 "unimplemented_transform" "internal: no implementation dispatched for transform '$1'" ;;
  esac
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

FAIL_KIND=""
FAIL_RULE=""
FAIL_INDEX=""
FAIL_ELEMENT=""

# Compiled once per rule kind, so an uncompilable pattern is reported as the
# registry contract violation it is rather than as a failed match.
assert_ere_compiles() {
  local kind="$1" pattern="$2" rc=0
  printf '' | grep -Eq -e "$pattern" || rc=$?
  if [ "$rc" -gt 1 ]; then
    fail 6 "uncompilable_pattern" "type '$TYPE_NAME': verify rule '$kind' pattern does not compile as a POSIX ERE (grep -E exited $rc): $pattern"
  fi
}

rule_per_line() {
  local pattern="$1" i=0 rc
  while [ "$i" -lt "${#ELEMS[@]}" ]; do
    rc=0
    printf '%s\n' "${ELEMS[$i]}" | grep -Eq -e "$pattern" || rc=$?
    if [ "$rc" -gt 1 ]; then
      fail 6 "uncompilable_pattern" "type '$TYPE_NAME': verify rule 'per_line' pattern does not compile as a POSIX ERE (grep -E exited $rc): $pattern"
    fi
    if [ "$rc" -ne 0 ]; then
      FAIL_KIND="per_line"
      FAIL_RULE="$pattern"
      FAIL_INDEX="$i"
      FAIL_ELEMENT="${ELEMS[$i]}"
      return 1
    fi
    i=$((i + 1))
  done
  return 0
}

# Returns 0 when every rule in the descriptor's `verify` object holds.
verify_current() {
  local kind pattern value_type
  FAIL_KIND=""
  FAIL_RULE=""
  FAIL_INDEX=""
  FAIL_ELEMENT=""
  for kind in ${RULE_KINDS[@]+"${RULE_KINDS[@]}"}; do
    value_type="$(jq -r --arg t "$TYPE_NAME" --arg k "$kind" '.types[$t].verify[$k] | type' "$REGISTRY_FILE")"
    case "$kind" in
      per_line)
        [ "$value_type" = "string" ] \
          || fail 6 "malformed_rule" "type '$TYPE_NAME': verify rule 'per_line' must be a string pattern, got $value_type"
        pattern="$(jq -r --arg t "$TYPE_NAME" --arg k "$kind" '.types[$t].verify[$k]' "$REGISTRY_FILE")"
        assert_ere_compiles "$kind" "$pattern"
        if ! rule_per_line "$pattern"; then
          return 1
        fi
        ;;
      *)
        fail 6 "unimplemented_rule_kind" "internal: no implementation dispatched for verify rule kind '$kind'"
        ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# The three outcomes
# ---------------------------------------------------------------------------

split_into_lines "$RAW_VALUE"

if verify_current; then
  emit_outcome "conforming" 0 "$(jq -n --arg v "$RAW_VALUE" '$v')" "$EMPTY_JSON" "null"
fi

# Remember the as-given failure: it, not the post-normalize one, is the more
# useful thing to report if normalization does not rescue the value.
PRE_FAIL_KIND="$FAIL_KIND"
PRE_FAIL_RULE="$FAIL_RULE"
PRE_FAIL_INDEX="$FAIL_INDEX"
PRE_FAIL_ELEMENT="$FAIL_ELEMENT"

if [ "${#TRANSFORMS[@]}" -gt 0 ]; then
  for transform in "${TRANSFORMS[@]}"; do
    apply_transform "$transform"
  done

  if verify_current; then
    emit_outcome "normalized" 2 "$(jq -n --arg v "$(join_elems)" '$v')" "$APPLIED_JSON" "null"
  fi
fi

# Non-conforming. The reason names the type, the failing rule, the element that
# failed it, and the raw pre-normalization value — everything a caller needs to
# report the failure without re-deriving any of it.
if [ "${#TRANSFORMS[@]}" -gt 0 ]; then
  REASON="type '$TYPE_NAME': value does not satisfy verify rule '$FAIL_KIND' (/$FAIL_RULE/) even after normalize [$(join_with_comma "${TRANSFORMS[@]}")]; element $FAIL_INDEX of the normalized value is '$FAIL_ELEMENT' (as given, element $PRE_FAIL_INDEX was '$PRE_FAIL_ELEMENT'); raw value: '$RAW_VALUE'"
else
  REASON="type '$TYPE_NAME': value does not satisfy verify rule '$PRE_FAIL_KIND' (/$PRE_FAIL_RULE/) and the type declares no normalize transforms; element $PRE_FAIL_INDEX is '$PRE_FAIL_ELEMENT'; raw value: '$RAW_VALUE'"
fi

emit_outcome "non-conforming" 3 "null" "$APPLIED_JSON" "$(jq -n --arg r "$REASON" '$r')"
