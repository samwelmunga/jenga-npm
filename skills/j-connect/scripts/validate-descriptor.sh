#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-connect/scripts/validate-descriptor.sh
#
# Deterministic validator for a j.connect service descriptor (E65_S01_T02).
# The format is documented in project/documentation/service-descriptor.md. Descriptors are JSON
# and are parsed with jq, which this repo's scripts already require.
#
# Checks (all problems are collected and reported, not just the first):
#   - required sections: id, name, docs, detect, install, auth, register_mcp,
#     verify. `register_mcp` may be {"supported": false} but never omitted.
#   - install carries a docs URL, never an authoritative hardcoded command or
#     a version-pinned package.
#   - verify/detect/auth.check are executed commands (argv arrays), never a
#     stored-string comparison.
#   - secrets are env-var NAMES only: no literal-secret-shaped strings, no
#     secret-named keys holding values, env-var names must look like names.
#   - cross-references: auth.env_var and register_mcp.env must be listed in
#     secrets.env_vars.
#
# Usage:   validate-descriptor.sh <descriptor-file>
# Exit:    0 valid; 1 invalid (messages on stderr, one `ERROR:` per problem);
#          2 usage error, unreadable file, or not valid JSON.
# Never prints the value of a field it flags as a suspected secret.
# -----------------------------------------------------------------------------
set -uo pipefail

if [ $# -ne 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: $(basename "$0") <descriptor-file>" >&2
  [ $# -eq 1 ] && exit 0
  exit 2
fi

FILE="$1"
if [ ! -f "$FILE" ]; then
  echo "ERROR: descriptor file not found: $FILE" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not found on PATH." >&2
  exit 2
fi
if ! jq -e 'type == "object"' "$FILE" >/dev/null 2>&1; then
  echo "ERROR: $FILE is not a JSON object." >&2
  exit 2
fi

ERRORS="$(jq -r '
  def isstr: type == "string" and length > 0;
  def isargv: type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
  def isurl: isstr and test("^https?://[^ ]+$");
  def envname: type == "string" and test("^[A-Z][A-Z0-9_]{0,63}$");
  # Strings that look like real credentials. Heuristic, deliberately not exhaustive.
  def secretlike:
    type == "string" and test(
      "(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]{10,}\\.|-----BEGIN [A-Z ]*PRIVATE KEY-----|[Bb]earer +[A-Za-z0-9._~+/=-]{20,}"
    );
  def secretkey: test("^(token|secret|password|passwd|api_?key|access_?key|private_?key|credentials?|auth_?token|client_?secret)$"; "i");

  . as $d |
  [
    # ---- required sections -------------------------------------------------
    (if ($d.id | isstr | not) then "id: missing or empty (required)"
     elif ($d.id | test("^[a-z0-9][a-z0-9-]*$") | not) then "id: must match ^[a-z0-9][a-z0-9-]*$"
     else empty end),
    (if ($d.name | isstr | not) then "name: missing or empty (required)" else empty end),
    (if ($d | has("docs") | not) then "docs: missing (required: list of official-docs URLs)"
     elif ($d.docs | type) != "array" or ($d.docs | length) == 0 then "docs: must be a non-empty array of URLs"
     elif ($d.docs | all(.[]; isurl) | not) then "docs: every entry must be an http(s) URL"
     else empty end),
    (if ($d | has("detect") | not) then "detect: missing (required)"
     elif ($d.detect.command | isargv | not) then "detect.command: must be a non-empty argv array of strings (an executed check)"
     else empty end),
    (if ($d | has("install") | not) then "install: missing (required)"
     elif ($d.install | type) != "object" then "install: must be an object"
     else
       ( (if ($d.install.docs_url | isurl | not) then "install.docs_url: missing or not an http(s) URL (install carries a docs URL, not a command)" else empty end),
         (($d.install | keys[]) as $k
            | select($k | test("^(command|commands|cmd|script|run|shell|exec)$"))
            | "install." + $k + ": hardcoded install command is not allowed; link the official docs URL in install.docs_url (a non-authoritative install.hint string is allowed)"),
         (if ($d.install | has("hint")) and ($d.install.hint | type) != "string" then "install.hint: must be a string" else empty end),
         (if ($d.install | has("methods")) then
            (if ($d.install.methods | type) != "array" then "install.methods: must be an array"
             else ($d.install.methods | to_entries[]
               | .key as $i | .value as $m
               | (if ($m | type) != "object" then "install.methods[\($i)]: must be an object"
                  else
                    (if ($m.platform | IN("darwin","linux") | not) then "install.methods[\($i)].platform: must be \"darwin\" or \"linux\"" else empty end),
                    (if ($m.manager | IN("brew","npm") | not) then "install.methods[\($i)].manager: must be a supported package manager (brew, npm)" else empty end),
                    (if ($m.package | isstr | not) then "install.methods[\($i)].package: missing or empty"
                     elif ($m.package | test("^@?[A-Za-z0-9._/-]+$") | not) then "install.methods[\($i)].package: must be a bare, unpinned package name (no version, no flags)"
                     else empty end)
                  end))
             end)
          else empty end)
       )
     end),
    (if ($d | has("auth") | not) then "auth: missing (required)"
     elif ($d.auth | type) != "object" then "auth: must be an object"
     else
       ( (if ($d.auth.type | IN("browser","env-token","none") | not) then "auth.type: must be one of browser, env-token, none" else empty end),
         (if ($d.auth.type // "") != "none" and ($d.auth.check.command | isargv | not) then "auth.check.command: required argv array (an authenticated no-op) unless auth.type is none" else empty end),
         (if ($d.auth.type // "") == "env-token" and ($d.auth.env_var | envname | not) then "auth.env_var: required env-var NAME for auth.type env-token" else empty end),
         (if ($d.auth | has("docs_url")) and ($d.auth.docs_url | isurl | not) then "auth.docs_url: must be an http(s) URL" else empty end)
       )
     end),
    (if ($d | has("register_mcp") | not) then "register_mcp: missing; it must be present or explicitly marked absent with {\"supported\": false}"
     elif ($d.register_mcp | type) != "object" or ($d.register_mcp.supported | type) != "boolean" then "register_mcp.supported: required boolean (use {\"supported\": false} when the service has no MCP server)"
     elif $d.register_mcp.supported == true then
       ( (if ($d.register_mcp.name | isstr | not) then "register_mcp.name: required when supported" else empty end),
         (if ($d.register_mcp.type // "stdio") == "stdio" then
            (if ($d.register_mcp.command | isstr | not) then "register_mcp.command: required for type stdio" else empty end)
          elif $d.register_mcp.type == "http" then
            (if ($d.register_mcp.url | isurl | not) then "register_mcp.url: required http(s) URL for type http" else empty end)
          else "register_mcp.type: must be stdio or http" end),
         (if ($d.register_mcp | has("args")) and (($d.register_mcp.args | type) != "array" or ($d.register_mcp.args | all(.[]; type == "string") | not)) then "register_mcp.args: must be an array of strings" else empty end),
         (if ($d.register_mcp | has("env")) and (($d.register_mcp.env | type) != "array" or ($d.register_mcp.env | all(.[]; envname) | not)) then "register_mcp.env: must be an array of env-var NAMES (e.g. FOO_TOKEN), never values" else empty end),
         (((($d.register_mcp.env // []) | if type == "array" then .[] else empty end) as $e
            | select(($e | envname) and ((($d.secrets.env_vars // []) | index($e)) == null))
            | "register_mcp.env: " + $e + " must also be listed in secrets.env_vars"))
       )
     else empty end),
    (if ($d | has("verify") | not) then "verify: missing (required)"
     elif ($d.verify.command | isargv | not) then "verify.command: must be a non-empty argv array of strings (an executed check)"
     else empty end),

    # ---- stored-string verification is rejected ----------------------------
    (["detect","verify"][] as $s
       | select($d[$s] | type == "object")
       | ($d[$s] | keys[]) as $k
       | select($k | test("^(expect|expected|equals|match|output|stdout|expect_output|expected_output|expect_stdout|version)"; "i"))
       | $s + "." + $k + ": comparing against a stored string is not allowed; verification is by executing the tool and judging its exit status"),

    # ---- requires / secrets -------------------------------------------------
    (if ($d | has("requires")) and (($d.requires | type) != "array" or ($d.requires | all(.[]; type == "string" and test("^[a-z0-9][a-z0-9-]*$")) | not)) then "requires: must be an array of descriptor ids" else empty end),
    (if ($d | has("secrets")) then
       (if ($d.secrets | type) != "object" then "secrets: must be an object"
        else
          ( (if ($d.secrets | has("env_vars")) and (($d.secrets.env_vars | type) != "array" or ($d.secrets.env_vars | all(.[]; envname) | not)) then "secrets.env_vars: must be an array of env-var NAMES (^[A-Z][A-Z0-9_]*$), never values" else empty end),
            (if ($d.secrets | has("env_file")) and ($d.secrets.env_file | isstr | not) then "secrets.env_file: must be a non-empty relative path string" else empty end),
            (if ($d.secrets.env_file // "") | startswith("/") or contains("..") then "secrets.env_file: must be a relative path inside the project" else empty end)
          )
        end)
     else empty end),
    (if ($d.auth.type // "") == "env-token" and ($d.auth.env_var | envname) and ((($d.secrets.env_vars // []) | index($d.auth.env_var)) == null) then "auth.env_var: " + $d.auth.env_var + " must also be listed in secrets.env_vars" else empty end),

    # ---- anything that looks like a secret VALUE anywhere (value never shown)
    ([paths(type == "string")] | .[] as $p
       | select(($d | getpath($p)) | secretlike)
       | "\($p | map(tostring) | join(".")): value looks like a literal secret/credential; reference the env-var NAME in secrets.env_vars instead"),
    ([paths(type == "string")] | .[] as $p
       | select(($p | last | type) == "string" and ($p | last | secretkey) and (($d | getpath($p)) | length) > 0)
       | "\($p | map(tostring) | join(".")): a secret-named key holding a value is not allowed; reference the env-var NAME in secrets.env_vars instead")
  ] | .[]
' "$FILE")"

if [ -n "$ERRORS" ]; then
  while IFS= read -r line; do
    echo "ERROR: $FILE: $line" >&2
  done <<< "$ERRORS"
  exit 1
fi
exit 0
