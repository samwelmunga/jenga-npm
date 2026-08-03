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
      def target_valid:
        type == "object"
        and (.name? | type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
        and (.type? == "mobile-ios")
        and (.platform? == "ios-app-store")
        and (.checks? | checks_valid)
        and (.secrets? | secrets_valid)
        and (.ios? | ios_valid);
      [
        (if (($schema["$schema"] // "") | contains("draft-07")) then empty else "schema must declare draft-07" end),
        (if (($cfg | type) == "object") then empty else "root config must be an object" end),
        (if (($cfg.version? // null) == 1) then empty else "version must be 1" end),
        (if (($cfg.defaults? | type) == "object") then empty else "defaults must be an object" end),
        (if (($cfg.defaults.history_file? // "") | non_empty_string) then empty else "defaults.history_file must be a non-empty string" end),
        (if (($cfg.defaults.mandatory_checks? | type) == "array" and (($cfg.defaults.mandatory_checks | length) > 0) and all($cfg.defaults.mandatory_checks[]; string_gate_name)) then empty else "defaults.mandatory_checks must be a non-empty array of gate names" end),
        (if (($cfg.defaults.optional_checks? == null) or (($cfg.defaults.optional_checks | type) == "array" and all($cfg.defaults.optional_checks[]; string_gate_name))) then empty else "defaults.optional_checks must be an array of gate names when provided" end),
        (if (($cfg.targets? | type) == "array" and (($cfg.targets | length) > 0)) then empty else "targets must be a non-empty array" end),
        (if (($cfg.targets? | type) == "array") then ([$cfg.targets[] | if target_valid then empty else ("invalid target: " + (.name // "<unnamed>")) end] | .[]) else empty end)
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
