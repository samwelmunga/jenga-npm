#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-connect/scripts/register-mcp.sh
#
# Idempotently registers ONE MCP server entry in the project's `.mcp.json`
# (E65_S01_T04). The target file is dictated by project/documentation/mcp-registration-decision.md
# (E65_S01_T01): project-root `.mcp.json`, top-level `mcpServers`. Not
# `.claude/settings.json` (Claude Code does not read mcpServers from it), never
# `.agents/settings.json`.
#
# Behaviour:
#   - Merge by server name. Absent -> `added`. Present and semantically
#     identical -> `unchanged` (the file is NOT rewritten, so it stays
#     byte-identical). Present but different -> only that one entry is replaced
#     in place -> `updated`.
#   - Other mcpServers entries and every other top-level key (hooks,
#     permissions, env, ...) are preserved (parsed and re-serialised by jq, so
#     their content is identical; insignificant whitespace may be normalised on
#     a write).
#   - Missing file is created. Unparseable JSON, or a non-object top level /
#     `mcpServers`, is an error: the file is left untouched.
#   - Written atomically (temp file in the same directory + mv).
#   - Secrets: env vars are written as `${NAME}` references from NAMES only. The
#     script never reads an environment variable's value, never accepts a
#     NAME=VALUE form, and refuses command/arg/url values that look like
#     literal credentials. `.mcp.json` therefore holds no secret value and does
#     not need the .gitignore guardrail (ensure-secret-safe.sh); the runner
#     applies that guardrail to files that can hold values, such as `.env`.
#
# Usage:
#   register-mcp.sh --name <server> --command <cmd> [--arg <a>]... \
#                   [--env-name <NAME>]... [--project-root <dir>]
#   register-mcp.sh --name <server> --type http --url <url> \
#                   [--env-name <NAME>]... [--project-root <dir>]
#
# Output (stdout): one JSON object
#   {"status":"added|unchanged|updated|error","file":"<path>","server":"<name>"[,"message":"..."]}
# Exit: 0 added/unchanged/updated; 1 runtime error (unparseable file, ...); 2 usage error.
# -----------------------------------------------------------------------------
set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo '{"status":"error","message":"jq is required but not found on PATH"}'
  exit 1
fi

NAME=""
TYPE="stdio"
COMMAND=""
URL=""
ROOT=""
ARGS_JSON='[]'
ENV_NAMES=()

emit_error() { # <exit> <message>
  jq -cn --arg s "${NAME:-}" --arg f "${TARGET:-}" --arg m "$2" \
    '{status:"error", file:$f, server:$s, message:$m}'
  echo "register-mcp: $2" >&2
  exit "$1"
}
TARGET=""

# Credential-shaped values are refused outright (value is never echoed).
looks_secret() {
  printf '%s' "$1" | grep -Eq '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{16,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.|-----BEGIN [A-Z ]*PRIVATE KEY-----|[Bb]earer +[A-Za-z0-9._~+/=-]{20,}'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --name)         [ $# -ge 2 ] || emit_error 2 "--name needs a value"; NAME="$2"; shift 2 ;;
    --type)         [ $# -ge 2 ] || emit_error 2 "--type needs a value"; TYPE="$2"; shift 2 ;;
    --command)      [ $# -ge 2 ] || emit_error 2 "--command needs a value"; COMMAND="$2"; shift 2 ;;
    --url)          [ $# -ge 2 ] || emit_error 2 "--url needs a value"; URL="$2"; shift 2 ;;
    --arg)          [ $# -ge 2 ] || emit_error 2 "--arg needs a value"
                    looks_secret "$2" && emit_error 2 "an --arg value looks like a literal credential; pass environment-variable NAMES via --env-name instead"
                    ARGS_JSON="$(jq -c --arg a "$2" '. + [$a]' <<<"$ARGS_JSON")"; shift 2 ;;
    --env-name)     [ $# -ge 2 ] || emit_error 2 "--env-name needs a value"
                    # Never echo the supplied value: it might be NAME=VALUE.
                    printf '%s' "$2" | grep -Eq '^[A-Z][A-Z0-9_]{0,63}$' || emit_error 2 "--env-name must be an environment-variable NAME like FOO_TOKEN (not a value, and not NAME=VALUE)"
                    ENV_NAMES+=("$2"); shift 2 ;;
    --project-root) [ $# -ge 2 ] || emit_error 2 "--project-root needs a value"; ROOT="$2"; shift 2 ;;
    -h|--help)      sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              emit_error 2 "unknown argument: $1" ;;
  esac
done

[ -n "$NAME" ] || emit_error 2 "--name is required"
printf '%s' "$NAME" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || emit_error 2 "--name may only contain letters, digits, '.', '_' and '-'"
case "$TYPE" in
  stdio) [ -n "$COMMAND" ] || emit_error 2 "--command is required for type stdio"
         [ -z "$URL" ] || emit_error 2 "--url is only valid with --type http"
         looks_secret "$COMMAND" && emit_error 2 "--command looks like a literal credential" ;;
  http)  [ -n "$URL" ] || emit_error 2 "--url is required for type http"
         [ -z "$COMMAND" ] || emit_error 2 "--command is only valid with --type stdio"
         printf '%s' "$URL" | grep -Eq '^https?://[^ ]+$' || emit_error 2 "--url must be an http(s) URL"
         looks_secret "$URL" && emit_error 2 "--url looks like it embeds a literal credential" ;;
  *)     emit_error 2 "--type must be stdio or http" ;;
esac

if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
[ -d "$ROOT" ] || emit_error 2 "project root does not exist: $ROOT"
ROOT="$(cd "$ROOT" && pwd)"
TARGET="$ROOT/.mcp.json"

# ---- build the desired entry (env vars as ${NAME} references only) ---------
ENV_JSON='{}'
if [ "${#ENV_NAMES[@]}" -gt 0 ]; then
  for n in "${ENV_NAMES[@]}"; do
    ref="\${${n}}"
    ENV_JSON="$(jq -c --arg k "$n" --arg v "$ref" '. + {($k): $v}' <<<"$ENV_JSON")"
  done
fi
if [ "$TYPE" = "stdio" ]; then
  ENTRY="$(jq -cn --arg c "$COMMAND" --argjson a "$ARGS_JSON" --argjson e "$ENV_JSON" \
    '{type:"stdio", command:$c, args:$a} + (if ($e|length) > 0 then {env:$e} else {} end)')"
else
  ENTRY="$(jq -cn --arg u "$URL" '{type:"http", url:$u}')"
fi

result() { jq -cn --arg st "$1" --arg f "$TARGET" --arg s "$NAME" '{status:$st, file:$f, server:$s}'; }

# ---- read the existing file (never clobber) --------------------------------
EXISTING='{}'
HAD_FILE=0
if [ -e "$TARGET" ]; then
  HAD_FILE=1
  if ! jq -e 'type == "object"' "$TARGET" >/dev/null 2>&1; then
    emit_error 1 "$TARGET is not a valid JSON object; refusing to modify it"
  fi
  if ! jq -e '(.mcpServers == null) or (.mcpServers | type == "object")' "$TARGET" >/dev/null 2>&1; then
    emit_error 1 "$TARGET has a non-object mcpServers; refusing to modify it"
  fi
  EXISTING="$(cat "$TARGET")"
fi

CURRENT="$(jq -c --arg n "$NAME" '.mcpServers[$n] // null' <<<"$EXISTING")"
if [ "$CURRENT" = "null" ]; then
  STATUS="added"
elif [ "$(jq -cS . <<<"$CURRENT")" = "$(jq -cS . <<<"$ENTRY")" ]; then
  result "unchanged"
  exit 0
else
  STATUS="updated"
fi

NEW="$(jq --indent 2 --arg n "$NAME" --argjson e "$ENTRY" '.mcpServers = ((.mcpServers // {}) | .[$n] = $e)' <<<"$EXISTING")" \
  || emit_error 1 "failed to build the updated document"

# ---- atomic write -----------------------------------------------------------
mkdir -p "$(dirname "$TARGET")" || emit_error 1 "cannot create $(dirname "$TARGET")"
TMP="$(mktemp "$(dirname "$TARGET")/.mcp.json.register-mcp.XXXXXX")" || emit_error 1 "cannot create a temp file next to $TARGET"
trap 'rm -f "$TMP"' EXIT
if [ "$HAD_FILE" -eq 1 ]; then cp -p "$TARGET" "$TMP"; else chmod 644 "$TMP"; fi
printf '%s\n' "$NEW" > "$TMP" || emit_error 1 "cannot write the temp file"
mv "$TMP" "$TARGET" || emit_error 1 "cannot replace $TARGET"
result "$STATUS"
exit 0
