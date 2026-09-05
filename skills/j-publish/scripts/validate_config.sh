#!/usr/bin/env bash
set -u

CONFIG_PATH="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_PATH="${SCRIPT_DIR}/../schemas/publish.schema.json"
EXIT_CONFIG_INVALID=4

fail() {
  printf 'publish config validation failed: %s\n' "$1" >&2
  exit "$EXIT_CONFIG_INVALID"
}

[[ -n "$CONFIG_PATH" ]] || fail "missing config path argument"
[[ -f "$CONFIG_PATH" ]] || fail "config file not found at '$CONFIG_PATH'"
[[ -f "$SCHEMA_PATH" ]] || fail "schema file not found at '$SCHEMA_PATH'"
command -v jq >/dev/null 2>&1 || fail "jq is required"

jq -e . "$SCHEMA_PATH" >/dev/null 2>&1 || fail "schema file is not valid JSON"
jq -e . "$CONFIG_PATH" >/dev/null 2>&1 || fail "config file is not valid JSON"

# shellcheck disable=SC2154  # $t, $cfg, $schema are jq variables inside the single-quoted program below, not shell variables.
ERRORS="$(
  jq -rn \
    --slurpfile cfg "$CONFIG_PATH" \
    --slurpfile schema "$SCHEMA_PATH" '
    ($cfg[0]) as $cfg
    | ($schema[0]) as $schema
    | def env_ref: type == "string" and test("^\\$\\{?[A-Z][A-Z0-9_]*\\}?$");
      def non_empty_string: type == "string" and length > 0;
      def string_gate_name: type == "string" and test("^[a-z0-9][a-z0-9-]*$");
      def gate_entry_valid:
        (string_gate_name)
        or (
          type == "object"
          and (
            (.name? | string_gate_name)
            or (.gate? | string_gate_name)
            or (.type? | string_gate_name)
          )
        );
      def gate_list_valid:
        type == "array" and all(.[]?; gate_entry_valid);
      def checks_valid:
        type == "object"
        and ((.pre? == null) or (.pre | gate_list_valid))
        and ((.post? == null) or (.post | gate_list_valid));
      def secrets_valid:
        type == "object"
        and (.app_store_connect_api_key_id? | env_ref)
        and (.app_store_connect_issuer_id? | env_ref)
        and (.app_store_connect_private_key_path? | env_ref)
        and (.code_sign_identity? | env_ref)
        and (.provisioning_profile_uuid? | env_ref);
      def ios_valid:
        type == "object"
        and (.scheme? | non_empty_string)
        and (.configuration? | non_empty_string)
        and (.archive_path? | non_empty_string)
        and (.export_path? | non_empty_string)
        and (((.export_method? // "") == "ad-hoc") or ((.export_method? // "") == "app-store"))
        and (.bundle_id? | non_empty_string)
        and (.team_id? | type == "string" and test("^[A-Z0-9]{6,}$"))
        and (.app_store_app_id? | type == "string" and test("^[0-9]+$"))
        and (((.project_path? // empty) | non_empty_string) or ((.workspace_path? // empty) | non_empty_string));
      def npm_secrets_valid:
        type == "object"
        and (
          (((.NPM_TOKEN? // null) != null) and (.NPM_TOKEN | env_ref))
          or (((.NODE_AUTH_TOKEN? // null) != null) and (.NODE_AUTH_TOKEN | env_ref))
        );
      def npm_valid:
        type == "object"
        and (.package_name? | non_empty_string)
        and (.package_name | test("^(?:@[a-z0-9][a-z0-9._-]*\\/)?[a-z0-9][a-z0-9._-]*$"))
        and ((.package_name | length) <= 214)
        and (((.access? // "") == "public") or ((.access? // "") == "restricted"))
        and (((.registry? // null) == null) or (.registry | non_empty_string))
        and (((.dist_tag? // null) == null) or (((.dist_tag | type) == "string") and (.dist_tag | test("^[a-z0-9][a-z0-9._-]*$"))));
      def npm_ci_valid:
        type == "object"
        and (.package_name? | non_empty_string)
        and (.package_name | test("^(?:@[a-z0-9][a-z0-9._-]*\\/)?[a-z0-9][a-z0-9._-]*$"))
        and ((.package_name | length) <= 214)
        and (((.access? // "") == "public") or ((.access? // "") == "restricted"))
        and (((.registry? // null) == null) or (.registry | non_empty_string))
        and (((.dist_tag? // null) == null) or (((.dist_tag | type) == "string") and (.dist_tag | test("^[a-z0-9][a-z0-9._-]*$"))));
      def ios_target_valid:
        type == "object"
        and (.name? | type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
        and (.type? == "mobile-ios")
        and (.platform? == "ios-app-store")
        and (.checks? | checks_valid)
        and (.secrets? | secrets_valid)
        and (.ios? | ios_valid);
      def npm_target_valid:
        type == "object"
        and (.name? | type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
        and (.type? == "npm")
        and (((.platform? // "") == "npm-registry") or ((.platform? // "") == "github-packages"))
        and (.checks? | checks_valid)
        and (.secrets? | npm_secrets_valid)
        and (.npm? | npm_valid)
        and ((.ios? // null) == null);
      def npm_ci_target_valid:
        type == "object"
        and (.name? | type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
        and (.type? == "npm-ci")
        and ((.github_repo? // "") | non_empty_string)
        and (.npm? | npm_ci_valid)
        and ((.ios? // null) == null);
      def target_valid: ios_target_valid or npm_target_valid or npm_ci_target_valid;
      def target_label: (.name? // "<unnamed>");
      def npm_diagnostics:
        . as $t
        | [
            (if (($t.npm? | type) != "object") then ("target \"" + ($t | target_label) + "\": npm block is required for npm targets") else empty end),
            (if ((($t.npm?.package_name? // "") | non_empty_string) | not) then ("target \"" + ($t | target_label) + "\": npm.package_name is required and must be a non-empty string") else empty end),
            (if ((($t.npm?.package_name? // "") | type) == "string" and (($t.npm.package_name | length) > 0) and ((($t.npm.package_name | test("^(?:@[a-z0-9][a-z0-9._-]*\\/)?[a-z0-9][a-z0-9._-]*$"))) | not)) then ("target \"" + ($t | target_label) + "\": npm.package_name must match npm naming rules") else empty end),
            (if (((($t.npm?.access? // "") == "public") or (($t.npm?.access? // "") == "restricted")) | not) then ("target \"" + ($t | target_label) + "\": npm.access must be \"public\" or \"restricted\"") else empty end),
            (if (($t.ios? // null) != null) then ("target \"" + ($t | target_label) + "\": ios block is not allowed on npm targets") else empty end),
            (if (((($t.platform? // "") == "npm-registry") or (($t.platform? // "") == "github-packages")) | not) then ("target \"" + ($t | target_label) + "\": platform must be \"npm-registry\" or \"github-packages\" for npm targets") else empty end),
            (if (($t.secrets? | npm_secrets_valid) | not) then ("target \"" + ($t | target_label) + "\": secrets must contain NPM_TOKEN or NODE_AUTH_TOKEN as an environment reference") else empty end)
          ] | .[];
      def npm_ci_diagnostics:
        . as $t
        | [
            (if (($t.github_repo? // "") | non_empty_string) then empty else ("target \"" + ($t | target_label) + "\": github_repo is required and must be a non-empty string") end),
            (if (($t.npm? | type) != "object") then ("target \"" + ($t | target_label) + "\": npm block is required for npm-ci targets") else empty end),
            (if ((($t.npm?.package_name? // "") | non_empty_string) | not) then ("target \"" + ($t | target_label) + "\": npm.package_name is required and must be a non-empty string") else empty end),
            (if ((($t.npm?.package_name? // "") | type) == "string" and (($t.npm.package_name | length) > 0) and ((($t.npm.package_name | test("^(?:@[a-z0-9][a-z0-9._-]*\\/)?[a-z0-9][a-z0-9._-]*$"))) | not)) then ("target \"" + ($t | target_label) + "\": npm.package_name must match npm naming rules") else empty end),
            (if (((($t.npm?.access? // "") == "public") or (($t.npm?.access? // "") == "restricted")) | not) then ("target \"" + ($t | target_label) + "\": npm.access must be \"public\" or \"restricted\"") else empty end),
            (if (($t.ios? // null) != null) then ("target \"" + ($t | target_label) + "\": ios block is not allowed on npm-ci targets") else empty end)
          ] | .[];
      def per_target_errors:
        . as $t
        | if target_valid then empty
          elif ($t.type? == "npm") then ($t | npm_diagnostics)
          elif ($t.type? == "npm-ci") then ($t | npm_ci_diagnostics)
          elif ($t.type? == "mobile-ios") then ("invalid target: " + ($t | target_label))
          else ("target \"" + ($t | target_label) + "\": type must be \"mobile-ios\", \"npm\", or \"npm-ci\"") end;
      [
        (if (($schema["$schema"] // "") | contains("draft-07")) then empty else "schema must declare draft-07" end),
        (if (($cfg | type) == "object") then empty else "root config must be an object" end),
        (if (($cfg.version? // null) == 1) then empty else "version must be 1" end),
        (if (($cfg.defaults? | type) == "object") then empty else "defaults must be an object" end),
        (if (($cfg.defaults.history_file? // "") | non_empty_string) then empty else "defaults.history_file must be a non-empty string" end),
        (if (($cfg.defaults.mandatory_checks? | type) == "array" and (($cfg.defaults.mandatory_checks | length) > 0) and all($cfg.defaults.mandatory_checks[]; string_gate_name)) then empty else "defaults.mandatory_checks must be a non-empty array of gate names" end),
        (if (($cfg.defaults.optional_checks? == null) or (($cfg.defaults.optional_checks | type) == "array" and all($cfg.defaults.optional_checks[]; string_gate_name))) then empty else "defaults.optional_checks must be an array of gate names when provided" end),
        (if (($cfg.targets? | type) == "array" and (($cfg.targets | length) > 0)) then empty else "targets must be a non-empty array" end),
        (if (($cfg.targets? | type) == "array") then ([$cfg.targets[] | per_target_errors] | .[]) else empty end)
      ] | map(select(. != null and . != "")) | .[]
  ' 2>/dev/null || true
)"

if [[ -n "$ERRORS" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && printf 'publish config validation failed: %s\n' "$line" >&2
  done <<< "$ERRORS"
  exit "$EXIT_CONFIG_INVALID"
fi

exit 0
