#!/usr/bin/env bats
#
# Fixture-based coverage for scripts/validate-typed-object.sh (E62_S01_T02) — the deterministic
# (type, value) -> conforming / normalized / non-conforming validator that E62_S01_T04 calls at
# playbook load time and E62_S02 will call at runtime.
#
# Fixture-tree convention (E43_S01_T01, as used by tests/load-playbooks-stepobject.bats): every
# case that needs a registry OTHER than the committed one writes its own JSON under
# $BATS_TEST_TMPDIR and points the validator at it via --registry or JENGA_PLAYBOOK_TYPES_FILE.
# The committed templates/playbook-types.json is never written to by this suite.
#
# THE PROPERTY THIS SUITE EXISTS TO PIN
# ------------------------------------
# T01's tester routed one binding finding here (see
# project/rapports/problems/E62_S01_T01-registry-comment-and-enforcement-gaps.md, Finding 2):
# the validator must READ verify_rules and normalize_vocabulary FROM the registry rather than
# hardcoding them, because that is what makes the registry's own claim — "adding a TYPE is a
# DATA-ONLY edit and NEVER a code change" — true rather than merely asserted. Three tests carry
# that weight directly:
#
#   * "a type the validator has never heard of works with ZERO code change"
#   * "no type name from the committed registry appears anywhere in the script's code"
#   * the four unknown/unimplemented transform and rule-kind cases, which prove the other half:
#     a new TRANSFORM or RULE KIND is a hard error, never a silent skip, because implementing one
#     genuinely does require code.

# `run --separate-stderr` (used throughout this file, see the run_real/run_fixture note below) is a
# bats >= 1.5.0 feature. Declaring the floor explicitly both documents the requirement and stops
# bats emitting BW02 ("flag used without bats_require_minimum_version") on every invocation.
bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/validate-typed-object.sh"
REAL_REGISTRY="$REPO_ROOT/templates/playbook-types.json"

# Exit codes, named so a failure message says what it means.
EXIT_CONFORMING=0
EXIT_USAGE=1
EXIT_NORMALIZED=2
EXIT_NON_CONFORMING=3
EXIT_UNKNOWN_TYPE=4
EXIT_ENVIRONMENT=5
EXIT_REGISTRY_CONTRACT=6

# Writes a registry fixture to $1 with the `types` map body given verbatim as $2. The two
# enumerations match the committed registry unless a test overrides them via write_registry_full.
write_registry() {
  local path="$1" types_json="$2"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
{
  "verify_rules": ["per_line"],
  "normalize_vocabulary": ["split_on_comma", "trim", "drop_empty"],
  "types": {$types_json}
}
EOF
}

# As above, but the caller supplies both enumerations too — for the "registry is ahead of the
# validator" cases, where a name IS admitted by the vocabulary but has no implementation.
write_registry_full() {
  local path="$1" rules_json="$2" vocab_json="$3" types_json="$4"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
{
  "verify_rules": [$rules_json],
  "normalize_vocabulary": [$vocab_json],
  "types": {$types_json}
}
EOF
}

# Runs the validator against the committed registry.
#
# THE STDERR IDIOM — READ BEFORE ADDING A `run` TO THIS FILE
# ---------------------------------------------------------
# The error paths write a human-readable line to stderr AS WELL AS the JSON object on stdout. By
# default bats folds both streams into $output, and the merged text is no longer parseable JSON, so
# every helper below that reads a field would die in jq.
#
# The fix is `run --separate-stderr`, which keeps stdout in $output (and $lines) and puts stderr in
# $stderr (and $stderr_lines). Do NOT write `run <cmd> 2> /dev/null`: `run` is a shell function that
# applies its own redirection internally, so a redirect written after it attaches to `run` itself
# rather than to the command it wraps and has no effect at all. That mistake silently defeated 12 of
# these tests once already — see
# project/rapports/problems/E62_S01_T02-bats-stderr-redirect-defeats-12-tests.md.
#
# The stderr half has its own dedicated tests near the bottom of this file.
run_real() {
  run --separate-stderr bash "$VALIDATOR" "$@"
}

# Runs the validator against a fixture registry. Same stderr handling as run_real.
run_fixture() {
  local registry="$1"
  shift
  run --separate-stderr bash "$VALIDATOR" --registry "$registry" "$@"
}

# Asserts $status equals the expected code, printing the output when it does not — otherwise a
# wrong-code failure tells you nothing about why.
assert_status() {
  local expected="$1" label="$2"
  if [ "$status" -ne "$expected" ]; then
    echo "expected exit $expected ($label), got $status" >&2
    echo "stdout: $output" >&2
    # Populated only after `run --separate-stderr`; empty for the `bash -c`-wrapped call sites.
    echo "stderr: ${stderr:-}" >&2
    return 1
  fi
}

# Extracts one field from the JSON object on stdout.
field() {
  printf '%s' "$output" | jq -r "$1"
}

# -----------------------------------------------------------------------------
# The three outcomes, against the committed registry
# -----------------------------------------------------------------------------

@test "conforming: a value that already satisfies verify is reported conforming, unchanged" {
  run_real id_list "E62
E62_S01
E62_S01_T02"

  assert_status "$EXIT_CONFORMING" "conforming"
  [ "$(field .outcome)" = "conforming" ]
  # The caller gets the value back untouched, and is told nothing was applied.
  [ "$(field .value)" = "E62
E62_S01
E62_S01_T02" ]
  [ "$(field '.normalize_applied | length')" = "0" ]
  [ "$(field .reason)" = "null" ]
}

@test "normalized: a value that conforms only after normalize reports normalized AND the new value" {
  run_real id_list "  E62, E62_S01 ,, E62_S01_T02  "

  assert_status "$EXIT_NORMALIZED" "normalized"
  [ "$(field .outcome)" = "normalized" ]
  # split_on_comma -> trim -> drop_empty, in that order, left to right.
  [ "$(field .value)" = "E62
E62_S01
E62_S01_T02" ]
  # The raw value is preserved alongside it, so a caller can report both.
  [ "$(field .raw)" = "  E62, E62_S01 ,, E62_S01_T02  " ]
  [ "$(field '.normalize_applied | join(",")')" = "split_on_comma,trim,drop_empty" ]
}

@test "normalized is distinguishable from conforming — the property E62_S02 warns on" {
  run_real id_list "E62"
  local conforming_status="$status" conforming_outcome
  conforming_outcome="$(field .outcome)"

  run_real id_list "  E62  "
  local normalized_status="$status" normalized_outcome
  normalized_outcome="$(field .outcome)"

  # Both are successes in the sense that a usable value comes out, but a runtime consumer has to
  # be able to tell "already fine" from "I had to fix it" in order to warn. Both the exit code
  # and the outcome string must separate them.
  [ "$conforming_status" -ne "$normalized_status" ]
  [ "$conforming_outcome" != "$normalized_outcome" ]
  [ "$conforming_outcome" = "conforming" ]
  [ "$normalized_outcome" = "normalized" ]
}

@test "non-conforming: a value that fails even after normalize names type, rule and raw value" {
  run_real id_list "banana, kiwi"

  assert_status "$EXIT_NON_CONFORMING" "non-conforming"
  [ "$(field .outcome)" = "non-conforming" ]
  # No repaired value is offered. That is the epic-level boundary, not an oversight.
  [ "$(field .value)" = "null" ]

  local reason
  reason="$(field .reason)"
  assert_contains "$reason" "id_list"
  assert_contains "$reason" "per_line"
  assert_contains "$reason" "banana, kiwi"
}

@test "non-conforming reports the failing element, not just that something failed" {
  run_real id_list "E62
banana
E62_S01"

  assert_status "$EXIT_NON_CONFORMING" "non-conforming"
  assert_contains "$(field .reason)" "banana"
}

# -----------------------------------------------------------------------------
# `text` — verify: null
# -----------------------------------------------------------------------------

@test "text passthrough: prose is conforming and is returned byte-for-byte" {
  run_real text "Some prose, with commas,, and   ragged   spacing.
And a second line that is not an id at all."

  assert_status "$EXIT_CONFORMING" "conforming"
  [ "$(field .outcome)" = "conforming" ]
  [ "$(field .value)" = "$(field .raw)" ]
}

@test "text never fails, for any input we can throw at it" {
  local value
  for value in "" " " "E62" "banana" ",,,," "   leading and trailing   " "line one
line two"; do
    run_real text "$value"
    if [ "$status" -ne "$EXIT_CONFORMING" ]; then
      echo "text reported non-conforming for: [$value]" >&2
      echo "$output" >&2
      return 1
    fi
    if [ "$(field .outcome)" != "conforming" ]; then
      echo "text outcome was not 'conforming' for: [$value]" >&2
      return 1
    fi
  done
}

@test "text does not become a repair path — it never rewrites the value" {
  run_real text "  ragged , value  "

  [ "$(field .value)" = "  ragged , value  " ]
  [ "$(field '.normalize_applied | length')" = "0" ]
}

# -----------------------------------------------------------------------------
# Unknown type
# -----------------------------------------------------------------------------

@test "unknown type is a distinct error, not a silent pass" {
  run_real banana "anything"

  assert_status "$EXIT_UNKNOWN_TYPE" "unknown type"
  [ "$(field .outcome)" = "error" ]
  [ "$(field .error)" = "unknown_type" ]
  assert_output_contains "banana"
}

@test "unknown type's exit code is distinct from every conformance outcome" {
  # A caller must never confuse "this type does not exist" with "this value does not conform".
  [ "$EXIT_UNKNOWN_TYPE" -ne "$EXIT_CONFORMING" ]
  [ "$EXIT_UNKNOWN_TYPE" -ne "$EXIT_NORMALIZED" ]
  [ "$EXIT_UNKNOWN_TYPE" -ne "$EXIT_NON_CONFORMING" ]

  run_real "" "anything"
  assert_status "$EXIT_UNKNOWN_TYPE" "unknown type (empty type name)"
}

# -----------------------------------------------------------------------------
# THE FINDING: vocabulary is READ, not hardcoded
# -----------------------------------------------------------------------------

@test "a type the validator has never heard of works with ZERO code change (data-only extension)" {
  # This is the executable form of the registry's own claim. `sha_list` exists nowhere in the
  # repo; it is composed purely of the already-enumerated per_line rule and the already-enumerated
  # transforms. If the validator carried its own type list, this would fail as an unknown type.
  local reg="$BATS_TEST_TMPDIR/new-type/playbook-types.json"
  write_registry "$reg" '
    "sha_list": {
      "verify": { "per_line": "^[0-9a-f]{7,40}$" },
      "normalize": ["split_on_comma", "trim", "drop_empty"]
    }'

  run_fixture "$reg" sha_list "9f082bca
d68b717a"
  assert_status "$EXIT_CONFORMING" "conforming"

  run_fixture "$reg" sha_list "  9f082bca, d68b717a  "
  assert_status "$EXIT_NORMALIZED" "normalized"
  [ "$(field .value)" = "9f082bca
d68b717a" ]

  run_fixture "$reg" sha_list "not-a-sha"
  assert_status "$EXIT_NON_CONFORMING" "non-conforming"
}

@test "a new type needs no NEW transform or rule kind to be useful — all three outcomes work" {
  local reg="$BATS_TEST_TMPDIR/new-type-2/playbook-types.json"
  write_registry "$reg" '
    "upper_word_list": {
      "verify": { "per_line": "^[A-Z]+$" },
      "normalize": ["split_on_comma", "trim", "drop_empty"]
    },
    "loose": {
      "verify": null,
      "normalize": []
    }'

  run_fixture "$reg" upper_word_list "ALPHA, BETA"
  assert_status "$EXIT_NORMALIZED" "normalized"

  # A second null-verify type proves `text`'s behaviour is descriptor-driven too, not a special
  # case keyed on the name `text`.
  run_fixture "$reg" loose "anything at all, really"
  assert_status "$EXIT_CONFORMING" "conforming"
}

@test "no type name from the committed registry appears anywhere in the script's code" {
  local code offenders
  code="$(grep -vE '^[[:space:]]*#' "$VALIDATOR")"
  offenders="$(printf '%s\n' "$code" | grep -nE "id_list|file_list|['\"]text['\"]" || true)"

  if [ -n "$offenders" ]; then
    echo "A committed registry type name appears in the validator's CODE (comments are fine)." >&2
    echo "That would make 'adding a type is a data-only edit' false while the registry still" >&2
    echo "claims it. Read the name from templates/playbook-types.json instead." >&2
    echo "$offenders" >&2
    return 1
  fi
}

@test "the enumerations themselves are read from the registry, not assumed" {
  # A registry whose enumerations are EMPTY must reject a descriptor that uses per_line — which
  # can only happen if verify_rules is genuinely consulted rather than assumed to contain it.
  local reg="$BATS_TEST_TMPDIR/empty-vocab/playbook-types.json"
  write_registry_full "$reg" '' '' '
    "thing": { "verify": { "per_line": "^x$" }, "normalize": [] }'

  run_fixture "$reg" thing "x"
  assert_status "$EXIT_REGISTRY_CONTRACT" "registry contract violation"
  [ "$(field .error)" = "unknown_rule_kind" ]
}

# -----------------------------------------------------------------------------
# The other half: a new TRANSFORM or RULE KIND is a hard error, never a skip
# -----------------------------------------------------------------------------

@test "unknown transform: a normalize entry outside normalize_vocabulary is an error, not a skip" {
  local reg="$BATS_TEST_TMPDIR/unknown-transform/playbook-types.json"
  write_registry "$reg" '
    "smuggled": {
      "verify": { "per_line": "^E[0-9]+$" },
      "normalize": ["trim", "reverse_each_line"]
    }'

  run_fixture "$reg" smuggled "E62"

  assert_status "$EXIT_REGISTRY_CONTRACT" "registry contract violation"
  [ "$(field .outcome)" = "error" ]
  [ "$(field .error)" = "unknown_transform" ]
  assert_output_contains "reverse_each_line"
}

@test "unknown transform errors even when the value would have conformed anyway" {
  # The descriptor's contract is checked BEFORE the value is looked at. Otherwise a malformed
  # registry would sit undetected for as long as every value happened to be well-formed.
  local reg="$BATS_TEST_TMPDIR/unknown-transform-2/playbook-types.json"
  write_registry "$reg" '
    "smuggled": {
      "verify": { "per_line": "^E[0-9]+$" },
      "normalize": ["reverse_each_line"]
    }'

  run_fixture "$reg" smuggled "E62"

  assert_status "$EXIT_REGISTRY_CONTRACT" "registry contract violation"
  [ "$(field .error)" = "unknown_transform" ]
}

@test "a free-text normalize entry is rejected BY NAME, whole, not by one of its tokens" {
  # The exact shape the registry header calls structurally unrepresentable. Reporting a verdict
  # about the token "extract" would describe a registry the author does not have.
  local reg="$BATS_TEST_TMPDIR/free-text/playbook-types.json"
  write_registry "$reg" '
    "semantic": {
      "verify": { "per_line": "^E[0-9]+$" },
      "normalize": ["extract the ids the skill meant to return"]
    }'

  run_fixture "$reg" semantic "some prose about E62"

  assert_status "$EXIT_REGISTRY_CONTRACT" "registry contract violation"
  [ "$(field .error)" = "malformed_transform_name" ]
  assert_output_contains "extract the ids the skill meant to return"
}

@test "a transform the vocabulary admits but the validator cannot execute is an error" {
  # The registry is ahead of the code: "uppercase" is legitimately enumerated, so the vocabulary
  # check passes — but nothing implements it. Skipping it would silently apply a DIFFERENT
  # normalization than the registry describes.
  local reg="$BATS_TEST_TMPDIR/ahead-transform/playbook-types.json"
  write_registry_full "$reg" '"per_line"' '"trim", "uppercase"' '
    "shouty": { "verify": { "per_line": "^[A-Z]+$" }, "normalize": ["trim", "uppercase"] }'

  run_fixture "$reg" shouty "  alpha  "

  assert_status "$EXIT_REGISTRY_CONTRACT" "registry contract violation"
  [ "$(field .error)" = "unimplemented_transform" ]
  assert_output_contains "uppercase"
}

@test "a verify rule kind outside verify_rules is an error" {
  local reg="$BATS_TEST_TMPDIR/unknown-rule/playbook-types.json"
  write_registry "$reg" '
    "columnar": { "verify": { "per_column": "^x$" }, "normalize": [] }'

  run_fixture "$reg" columnar "x"

  assert_status "$EXIT_REGISTRY_CONTRACT" "registry contract violation"
  [ "$(field .error)" = "unknown_rule_kind" ]
  assert_output_contains "per_column"
}

@test "a rule kind the vocabulary admits but the validator cannot execute is an error" {
  local reg="$BATS_TEST_TMPDIR/ahead-rule/playbook-types.json"
  write_registry_full "$reg" '"per_line", "per_column"' '"trim"' '
    "columnar": { "verify": { "per_column": "^x$" }, "normalize": ["trim"] }'

  run_fixture "$reg" columnar "x"

  assert_status "$EXIT_REGISTRY_CONTRACT" "registry contract violation"
  [ "$(field .error)" = "unimplemented_rule_kind" ]
}

@test "a descriptor carrying a key outside {verify, normalize} is an error" {
  # The registry header: "a descriptor never carries any other key". A `repair` key quietly
  # ignored is exactly how the rejected auto-repair idea would creep back in.
  local reg="$BATS_TEST_TMPDIR/extra-key/playbook-types.json"
  write_registry "$reg" '
    "sneaky": { "verify": null, "normalize": [], "repair": "ask a model what was meant" }'

  run_fixture "$reg" sneaky "whatever"

  assert_status "$EXIT_REGISTRY_CONTRACT" "registry contract violation"
  [ "$(field .error)" = "malformed_descriptor" ]
  assert_output_contains "repair"
}

# -----------------------------------------------------------------------------
# Determinism, and the out-of-scope boundary
# -----------------------------------------------------------------------------

@test "deterministic: repeated runs on the same input are byte-identical" {
  local first second third case_value
  for case_value in "E62
E62_S01" "  E62, E62_S01  " "banana" "" "   "; do
    first="$(bash "$VALIDATOR" id_list "$case_value" 2>&1 || true)"
    second="$(bash "$VALIDATOR" id_list "$case_value" 2>&1 || true)"
    third="$(bash "$VALIDATOR" id_list "$case_value" 2>&1 || true)"
    if [ "$first" != "$second" ] || [ "$second" != "$third" ]; then
      echo "output differed across runs for: [$case_value]" >&2
      echo "--- 1 ---" >&2; echo "$first" >&2
      echo "--- 2 ---" >&2; echo "$second" >&2
      echo "--- 3 ---" >&2; echo "$third" >&2
      return 1
    fi
  done
}

@test "deterministic: the verdict does not depend on the caller's working directory" {
  local from_root from_tmp
  from_root="$(cd "$REPO_ROOT" && bash "$VALIDATOR" id_list "E62, E62_S01" 2>&1 || true)"
  from_tmp="$(cd "$BATS_TEST_TMPDIR" && bash "$VALIDATOR" id_list "E62, E62_S01" 2>&1 || true)"

  if [ "$from_root" != "$from_tmp" ]; then
    echo "the same input produced different output from different working directories." >&2
    echo "--- repo root ---" >&2; echo "$from_root" >&2
    echo "--- tmpdir ---" >&2; echo "$from_tmp" >&2
    return 1
  fi
}

@test "the script makes no network call and invokes no model" {
  local code offenders
  code="$(grep -vE '^[[:space:]]*#' "$VALIDATOR")"
  offenders="$(printf '%s\n' "$code" | grep -nEi "curl|wget|nc |ssh |http://|https://|openai|anthropic|claude|llm" || true)"

  if [ -n "$offenders" ]; then
    echo "The validator's code references a network or model call. It must be fully" >&2
    echo "deterministic and local — semantic extraction was rejected at epic level (E62)." >&2
    echo "$offenders" >&2
    return 1
  fi
}

@test "no repaired value is ever offered on the non-conforming path" {
  # If a future change started guessing at "what the skill probably meant", it would show up
  # here as a non-null value on a non-conforming verdict.
  local case_value
  for case_value in "banana" "E62 and also E01" "see epic 62"; do
    run_real id_list "$case_value"
    if [ "$status" -ne "$EXIT_NON_CONFORMING" ]; then
      echo "expected non-conforming for [$case_value], got exit $status" >&2
      echo "$output" >&2
      return 1
    fi
    if [ "$(field .value)" != "null" ]; then
      echo "a repaired value was offered for [$case_value]: $(field .value)" >&2
      return 1
    fi
  done
}

# -----------------------------------------------------------------------------
# Input modes, registry selection, and usage errors
# -----------------------------------------------------------------------------

@test "the value can be supplied on stdin" {
  run bash -c "printf 'E62\nE62_S01\n' | bash '$VALIDATOR' id_list - 2> /dev/null"

  assert_status "$EXIT_CONFORMING" "conforming"
  [ "$(field .outcome)" = "conforming" ]
}

@test "the value can be supplied from a file" {
  printf 'E62, E62_S01\n' > "$BATS_TEST_TMPDIR/value.txt"

  run --separate-stderr bash "$VALIDATOR" --value-file "$BATS_TEST_TMPDIR/value.txt" id_list

  assert_status "$EXIT_NORMALIZED" "normalized"
  [ "$(field .value)" = "E62
E62_S01" ]
}

@test "JENGA_PLAYBOOK_TYPES_FILE selects the registry, and --registry wins over it" {
  local env_reg="$BATS_TEST_TMPDIR/env/playbook-types.json"
  local flag_reg="$BATS_TEST_TMPDIR/flag/playbook-types.json"
  write_registry "$env_reg" '"only_in_env": { "verify": null, "normalize": [] }'
  write_registry "$flag_reg" '"only_in_flag": { "verify": null, "normalize": [] }'

  # `env` rather than an assignment prefix on `run`: `run` is a shell function, and a temporary
  # assignment in front of a function is not reliably exported to the processes it spawns.
  run --separate-stderr env "JENGA_PLAYBOOK_TYPES_FILE=$env_reg" bash "$VALIDATOR" only_in_env "x"
  assert_status "$EXIT_CONFORMING" "conforming (env registry)"

  run --separate-stderr env "JENGA_PLAYBOOK_TYPES_FILE=$env_reg" bash "$VALIDATOR" --registry "$flag_reg" only_in_flag "x"
  assert_status "$EXIT_CONFORMING" "conforming (flag registry wins)"

  run --separate-stderr env "JENGA_PLAYBOOK_TYPES_FILE=$env_reg" bash "$VALIDATOR" --registry "$flag_reg" only_in_env "x"
  assert_status "$EXIT_UNKNOWN_TYPE" "unknown type (flag registry wins)"
}

@test "a missing registry is an environment error, distinct from a conformance verdict" {
  run --separate-stderr bash "$VALIDATOR" --registry "$BATS_TEST_TMPDIR/does-not-exist.json" id_list "E62"

  assert_status "$EXIT_ENVIRONMENT" "environment error"
  [ "$(field .error)" = "registry_unreadable" ]
}

@test "an unparseable registry is an environment error, not a pass" {
  printf 'this is not json\n' > "$BATS_TEST_TMPDIR/broken.json"

  run --separate-stderr bash "$VALIDATOR" --registry "$BATS_TEST_TMPDIR/broken.json" id_list "E62"

  assert_status "$EXIT_ENVIRONMENT" "environment error"
}

@test "a missing value is a usage error — distinct from an empty value" {
  run --separate-stderr bash "$VALIDATOR" id_list
  assert_status "$EXIT_USAGE" "usage error"

  # An empty value is a legitimate question and must be answered, not refused.
  run --separate-stderr bash "$VALIDATOR" id_list ""
  if [ "$status" -eq "$EXIT_USAGE" ]; then
    echo "an explicitly empty value was treated as a missing argument" >&2
    return 1
  fi
}

@test "an unknown option is a usage error" {
  run --separate-stderr bash "$VALIDATOR" --repair id_list "banana"

  assert_status "$EXIT_USAGE" "usage error"
  [ "$(field .error)" = "usage" ]
}

# -----------------------------------------------------------------------------
# Output contract
# -----------------------------------------------------------------------------

@test "every path emits a single parseable JSON object on stdout" {
  # conforming / normalized / non-conforming / unknown type / usage
  run_real id_list "E62"
  printf '%s' "$output" | jq -e 'type == "object"' > /dev/null

  run_real id_list "  E62  "
  printf '%s' "$output" | jq -e 'type == "object"' > /dev/null

  run_real id_list "banana"
  printf '%s' "$output" | jq -e 'type == "object"' > /dev/null

  run --separate-stderr bash "$VALIDATOR" nosuchtype "x"
  printf '%s' "$output" | jq -e 'type == "object"' > /dev/null
}

@test "the JSON object always carries the full field set" {
  run_real id_list "  E62  "

  printf '%s' "$output" \
    | jq -e 'has("outcome") and has("type") and has("raw") and has("value") and has("normalize_applied") and has("reason")' \
    > /dev/null
}

@test "the three conformance outcomes keep stderr clean" {
  local err
  for err in "E62" "  E62  " "banana"; do
    run bash -c "bash '$VALIDATOR' id_list '$err' 2>&1 1>/dev/null"
    if [ -n "$output" ]; then
      echo "stderr was not empty for a conformance verdict on [$err]:" >&2
      echo "$output" >&2
      return 1
    fi
  done
}

@test "error paths also write a human-readable line to stderr" {
  run bash -c "bash '$VALIDATOR' nosuchtype 'x' 2>&1 1>/dev/null"

  assert_output_contains "validate-typed-object.sh: error:"
  assert_output_contains "nosuchtype"
}

# -----------------------------------------------------------------------------
# The committed registry itself
# -----------------------------------------------------------------------------

@test "every type in the committed registry resolves and evaluates without a contract error" {
  local type_name
  while IFS= read -r type_name; do
    run --separate-stderr bash "$VALIDATOR" "$type_name" "E62"
    case "$status" in
      "$EXIT_CONFORMING"|"$EXIT_NORMALIZED"|"$EXIT_NON_CONFORMING") : ;;
      *)
        echo "committed type '$type_name' did not produce a conformance verdict (exit $status)" >&2
        echo "$output" >&2
        return 1
        ;;
    esac
  done < <(jq -r '.types | keys_unsorted[]' "$REAL_REGISTRY")
}

@test "file_list accepts paths containing spaces and rejects blank lines after normalize" {
  run_real file_list "docs/skill-authoring.md
my dir/file name.md"
  assert_status "$EXIT_CONFORMING" "conforming"

  run_real file_list "  docs/skill-authoring.md

  my dir/file name.md  "
  assert_status "$EXIT_NORMALIZED" "normalized"
  [ "$(field .value)" = "docs/skill-authoring.md
my dir/file name.md" ]
}

@test "file_list does not split on commas — a comma is legal in a filename" {
  # id_list normalizes with split_on_comma; file_list deliberately does not. Pinning this stops
  # the transform lists being 'tidied' into one shared list later.
  run_real file_list "a,b.md"

  assert_status "$EXIT_CONFORMING" "conforming"
  [ "$(field .value)" = "a,b.md" ]
}

# -----------------------------------------------------------------------------
# Documented edge: a value that normalizes down to nothing
# -----------------------------------------------------------------------------

@test "a value normalizing to an empty list is reported conforming (vacuous truth), by design" {
  # "every element matches" is vacuously true of no elements. This is the literal reading of the
  # rule as the registry states it, and it is pinned here so that CHANGING it is a deliberate
  # decision rather than an accident. Expressing a non-empty requirement belongs in the registry
  # as a new rule kind, not as an unstated rule hardcoded in the validator — flagged to E62_S02.
  run_real id_list ""
  assert_status "$EXIT_CONFORMING" "conforming"

  run_real id_list "  ,  ,  "
  assert_status "$EXIT_NORMALIZED" "normalized"
  [ "$(field .value)" = "" ]
}
