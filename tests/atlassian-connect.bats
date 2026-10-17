#!/usr/bin/env bats
#
# Coverage for the two Atlassian j.connect descriptors (E71_S01_T03):
#   skills/j-connect/descriptors/atlassian-cloud.json  (remote MCP server, registered in .mcp.json)
#   skills/j-connect/descriptors/atlassian-cli.json    (acli, API-token sign-in done by the user)
# and for the shared maintainer doc project/documentation/atlassian-connect.md.
#
# Three groups:
#   1. static checks with jq, the validator and list-services.sh (no tool is run);
#   2. runner checks against the REAL descriptors with STUBBED `claude` and `acli` on PATH
#      (run-descriptor.sh), in a throwaway git project. Argv, URLs, names and env-var names are
#      read from the descriptors with jq rather than copied here;
#   3. doc checks: the doc exists under project/documentation/, lists the descriptors' URLs, and its
#      "Could not verify" items match the "Not verified against a real account" labels in the
#      descriptors one to one.
#
# No network call, no Atlassian account, no token, no real ~/.claude.json and no real acli or claude
# is used. Installers are log-only stubs and must never be called. The stubs print a sentinel to
# stdout and stderr; it must never reach runner output, a project file or a descriptor.
#
# What a stub CANNOT prove, and is therefore NOT asserted here (see the doc's "Could not verify"):
#   - that the /v2/mcp endpoint accepts a real sign-in, that OAuth consent completes, or that the
#     Jira, Confluence and Bitbucket tools appear for a real site;
#   - the real exit status of `claude mcp get` for an unapproved project server, or of
#     `acli jira project list` when signed out. The stubs MODEL these as exit 0 / exit 1; the real
#     behaviour is a human check, not done by this file.

# Each @test runs in its own subshell, so per-test env changes are intentional.
# shellcheck disable=SC2030,SC2031
bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RUN="$REPO_ROOT/skills/j-connect/scripts/run-descriptor.sh"
VALIDATE="$REPO_ROOT/skills/j-connect/scripts/validate-descriptor.sh"
LIST="$REPO_ROOT/skills/j-connect/scripts/list-services.sh"
CLOUD="$REPO_ROOT/skills/j-connect/descriptors/atlassian-cloud.json"
CLI="$REPO_ROOT/skills/j-connect/descriptors/atlassian-cli.json"
DOC="$REPO_ROOT/project/documentation/atlassian-connect.md"
LABEL="not verified against a real account"
# A shape unlikely to match a real token or the validator's credential heuristics.
SENTINEL="FAKESENTINELATLASSIAN_0123456789abcdefABCDEF"
# Shapes of credentials that must appear in no descriptor and no doc.
CRED_RE='ATATT[A-Za-z0-9_=-]{10,}|figd_|gh[opsu]_[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\.|-----BEGIN|[Bb]earer [A-Za-z0-9]|(TOKEN|SECRET|PASSWORD|API_KEY)[A-Z_]*=[^ ]'

# "Could not verify" labels: one row per label, "<phrase in the descriptor hint>|<phrase in the doc item>",
# matched case-insensitively. The doc item ids are CV-CLOUD-<row> and CV-CLI-<row>.
CLOUD_LABELS=(
  "the registered endpoint accepts your sign-in|accepts a real sign-in"
  "the oauth consent screen completes for your site|oauth consent screen completes"
  "tools all appear for your site and workspace|tools all appear"
  "is picked up after you approve the project server in claude code|is picked up after the user approves"
  "reports a project-scoped server before it is approved|reports a project-scoped server before it is approved"
)
CLI_LABELS=(
  "the linux and windows install steps|linux and windows install steps"
  "which of jira, confluence and bitbucket the atlassian cloud mcp server serves|which of jira, confluence and bitbucket the atlassian cloud mcp server serves"
  "exit non-zero when you are not signed in|exit non-zero when the user is not signed in"
)

setup() {
  STUB="$BATS_TEST_TMPDIR/stub"
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$STUB" "$FAKE_BIN" "$PROJ"
  git -C "$PROJ" init -q .

  # claude: `--version` succeeds unless $STUB/no-claude exists. `mcp get <name>` succeeds iff the
  # project .mcp.json holds that server (models "configured"). It never writes: any add/remove/reset
  # call is recorded in claude-write.log, which must stay absent.
  cat > "$FAKE_BIN/claude" <<EOS
#!/bin/sh
echo "claude \$*" >> "$STUB/claude.log"
echo "token: $SENTINEL"; echo "token: $SENTINEL" >&2
if [ "\$1" = "--version" ]; then
  [ -e "$STUB/no-claude" ] && exit 1
  exit 0
fi
if [ "\$1" = "mcp" ]; then
  case "\$2" in
    get)
      [ -f "$PROJ/.mcp.json" ] && jq -e --arg n "\$3" '.mcpServers[\$n]' "$PROJ/.mcp.json" >/dev/null 2>&1 && exit 0
      exit 1 ;;
    add|remove|reset) echo "claude \$*" >> "$STUB/claude-write.log"; exit 0 ;;
  esac
fi
exit 0
EOS
  # acli: `--version` succeeds iff $STUB/installed exists; `jira project list ...` succeeds iff
  # $STUB/signedin exists. Any `jira auth ...` call is recorded in acli-auth.log, which must stay
  # absent (an agent never signs in for the user).
  cat > "$FAKE_BIN/acli" <<EOS
#!/bin/sh
echo "acli \$*" >> "$STUB/acli.log"
echo "token: $SENTINEL"; echo "token: $SENTINEL" >&2
if [ "\$1" = "--version" ]; then
  [ -e "$STUB/installed" ] && exit 0
  exit 1
fi
if [ "\$1" = "jira" ] && [ "\$2" = "auth" ]; then echo "acli \$*" >> "$STUB/acli-auth.log"; exit 0; fi
if [ "\$1" = "jira" ] && [ "\$2" = "project" ] && [ "\$3" = "list" ]; then
  [ -e "$STUB/signedin" ] && exit 0
  exit 1
fi
exit 0
EOS
  # Installers only record that they were called.
  local t
  for t in brew npm apt apt-get dnf yum pacman snap scoop curl wget sudo; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/installer.log"\nexit 0\n' "$t" "$STUB" > "$FAKE_BIN/$t"
  done
  chmod +x "$FAKE_BIN"/*

  export PATH="$FAKE_BIN:$PATH"
  export JENGA_CONNECT_PLATFORM=darwin
}

# go <descriptor> [runner args...]
go() { local d="$1"; shift; run --separate-stderr bash "$RUN" "$d" --project-root "$PROJ" "$@"; }
step_status() { jq -r --arg s "$1" 'select(.step == $s) | .status' <<<"$output" | head -n1; }
step_message() { jq -r --arg s "$1" 'select(.step == $s) | .message' <<<"$output" | head -n1; }
step_detail() { jq -r --arg s "$1" 'select(.step == $s) | .detail // empty' <<<"$output" | head -n1; }
step_count() { jq -r --arg s "$1" 'select(.step == $s) | .status' <<<"$output" | wc -l | tr -d ' '; }
summary_status() { jq -r 'select(.summary == true) | .status' <<<"$output"; }
# project_files: every file in the project besides .git
project_files() { find "$PROJ" -path "$PROJ/.git" -prune -o -type f -print | sed "s|$PROJ/||"; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ---------------------------------------------------------------------------------------------
# 1. static checks
# ---------------------------------------------------------------------------------------------

@test "both descriptors exist, carry their ids and pass the descriptor validator" {
  [ -f "$CLOUD" ]
  [ -f "$CLI" ]
  [ "$(jq -r '.id' "$CLOUD")" = "atlassian-cloud" ]
  [ "$(jq -r '.id' "$CLI")" = "atlassian-cli" ]
  run bash "$VALIDATE" "$CLOUD"
  [ "$status" -eq 0 ]
  run bash "$VALIDATE" "$CLI"
  [ "$status" -eq 0 ]
}

@test "list-services.sh lists both, once each, with the right mcp flag, none skipped or unresolved" {
  run --separate-stderr bash "$LIST"
  [ "$status" -eq 0 ]
  [ "$(jq '[.services[] | select(.id == "atlassian-cloud")] | length' <<<"$output")" -eq 1 ]
  [ "$(jq '[.services[] | select(.id == "atlassian-cli")] | length' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.services[] | select(.id == "atlassian-cloud") | .mcp' <<<"$output")" = "true" ]
  [ "$(jq -r '.services[] | select(.id == "atlassian-cli") | .mcp' <<<"$output")" = "false" ]
  [ "$(jq '[.services[] | select(.id | startswith("atlassian")) | .unresolved_requires | length] | add' <<<"$output")" -eq 0 ]
  [ "$(jq '[(.skipped // [])[] | tostring | select(test("atlassian"))] | length' <<<"$output")" -eq 0 ]
}

@test "the two transports are as designed: cloud registers the http MCP server, cli registers none" {
  [ "$(jq -r '.register_mcp.supported' "$CLOUD")" = "true" ]
  [ "$(jq -r '.register_mcp.type' "$CLOUD")" = "http" ]
  [ "$(jq -r '.register_mcp.name' "$CLOUD")" = "atlassian" ]
  [ "$(jq -r '.register_mcp.url | test("^https://mcp\\.atlassian\\.com/")' "$CLOUD")" = "true" ]
  [ "$(jq -c '.verify.command' "$CLOUD")" = '["claude","mcp","get","atlassian"]' ]
  [ "$(jq -c '.register_mcp' "$CLI")" = '{"supported":false}' ]
  [ "$(jq -r '.detect.command[0]' "$CLI")" = "acli" ]
  [ "$(jq -c '.verify.command' "$CLI")" = "$(jq -c '.auth.check.command' "$CLI")" ]
}

@test "neither descriptor declares an authoritative install command, method or script" {
  local f
  for f in "$CLOUD" "$CLI"; do
    [ "$(jq '.install | has("methods")' "$f")" = "false" ]
    [ "$(jq '[.install | .. | objects | keys[] | select(. == "command" or . == "script" or . == "run")] | length' "$f")" -eq 0 ]
    [ "$(jq -r '.install.docs_url | test("^https://(support|developer)\\.atlassian\\.com/")' "$f")" = "true" ]
    run grep -Eq 'brew (tap|install)|npm (i|install)|apt(-get)? install|curl |wget |\| *(ba)?sh' "$f"
    [ "$status" -eq 1 ]
  done
}

@test "secrets guardrail: cloud declares no secrets; cli declares env-var NAMES only; no credential-looking value in either file" {
  [ "$(jq 'has("secrets")' "$CLOUD")" = "false" ]
  [ "$(jq -r '.auth.type' "$CLOUD")" = "none" ]
  [ "$(jq '.auth | has("env_var")' "$CLOUD")" = "false" ]
  # cli: the only key under secrets is env_vars, and every entry is an upper-snake NAME
  [ "$(jq -c '.secrets | keys' "$CLI")" = '["env_vars"]' ]
  [ "$(jq '.secrets.env_vars | length' "$CLI")" -ge 1 ]
  [ "$(jq '[.secrets.env_vars[] | select(test("^[A-Z][A-Z0-9_]*$") | not)] | length' "$CLI")" -eq 0 ]
  # no default / value / example anywhere in either file
  local f
  for f in "$CLOUD" "$CLI"; do
    [ "$(jq '[.. | objects | keys[] | select(. == "default" or . == "value" or . == "example" or . == "token" or . == "env_file")] | length' "$f")" -eq 0 ]
    run grep -Eq "$CRED_RE" "$f"
    [ "$status" -eq 1 ]
  done
  # the token name the user is told to set is a name, not a value
  [ "$(jq -r '.secrets.env_vars | index("ATLASSIAN_API_TOKEN") != null' "$CLI")" = "true" ]
}

@test "each descriptor carries the label 'not verified against a real account' exactly once in its install hint" {
  local f hint n
  for f in "$CLOUD" "$CLI"; do
    hint="$(lower "$(jq -r '.install.hint' "$f")")"
    assert_contains "$hint" "$LABEL"
    n="$(printf '%s' "$hint" | grep -o "$LABEL" | wc -l | tr -d ' ')"
    [ "$n" -eq 1 ]
  done
  # the cli also repeats it where the user is asked to sign in
  assert_contains "$(lower "$(jq -r '.auth.instructions' "$CLI")")" "$LABEL"
}

@test "free text states product coverage: Jira, Confluence and Bitbucket, and where a transport does not cover them" {
  local cloud cli
  cloud="$(jq -r '.name + " " + .install.hint' "$CLOUD")"
  cli="$(jq -r '.name + " " + .install.hint' "$CLI")"
  assert_contains "$cloud" "Jira"
  assert_contains "$cloud" "Confluence"
  assert_contains "$cloud" "Bitbucket Cloud"
  assert_contains "$cloud" "linked to an Atlassian organization"
  assert_contains "$cloud" "Data Center"
  assert_contains "$cli" "Jira is covered"
  assert_contains "$cli" "Confluence and Bitbucket are NOT covered"
}

# ---------------------------------------------------------------------------------------------
# 2. runner checks with stubbed claude / acli
# ---------------------------------------------------------------------------------------------

@test "cloud, claude present and nothing configured: registers the descriptor's http entry in .mcp.json, verify passes, exit 0" {
  go "$CLOUD"
  [ "$status" -eq 0 ]
  [ "$(step_status detect)" = "pass" ]
  [ "$(step_detail detect)" = "present" ]
  [ "$(step_status install)" = "skipped" ]
  [ "$(step_status auth)" = "skipped" ]
  [ "$(step_status register_mcp)" = "pass" ]
  [ "$(step_detail register_mcp)" = "added" ]
  [ "$(step_status verify)" = "pass" ]
  [ "$(summary_status)" = "pass" ]
  name="$(jq -r '.register_mcp.name' "$CLOUD")"
  url="$(jq -r '.register_mcp.url' "$CLOUD")"
  [ "$(jq -c '.mcpServers | keys' "$PROJ/.mcp.json")" = "[\"$name\"]" ]
  [ "$(jq -c --arg n "$name" '.mcpServers[$n]' "$PROJ/.mcp.json")" = "{\"type\":\"http\",\"url\":\"$url\"}" ]
  [ "$(project_files)" = ".mcp.json" ]
  # the runner never asked claude to add/remove/reset anything, and no installer ran
  [ ! -e "$STUB/claude-write.log" ]
  [ ! -e "$STUB/installer.log" ]
}

@test "cloud: a second run changes nothing (register_mcp skipped, .mcp.json byte-identical) and other servers are preserved" {
  printf '%s\n' '{"mcpServers":{"other":{"type":"stdio","command":"/usr/bin/true","args":[]}},"someTopLevelKey":{"keep":true}}' > "$PROJ/.mcp.json"
  go "$CLOUD"
  [ "$status" -eq 0 ]
  [ "$(step_detail register_mcp)" = "added" ]
  [ "$(jq -c '.mcpServers.other' "$PROJ/.mcp.json")" = '{"type":"stdio","command":"/usr/bin/true","args":[]}' ]
  [ "$(jq -c '.someTopLevelKey' "$PROJ/.mcp.json")" = '{"keep":true}' ]
  sum="$(cksum < "$PROJ/.mcp.json")"
  go "$CLOUD"
  [ "$status" -eq 0 ]
  [ "$(step_status register_mcp)" = "skipped" ]
  [ "$(step_detail register_mcp)" = "unchanged" ]
  [ "$(cksum < "$PROJ/.mcp.json")" = "$sum" ]
  [ ! -e "$STUB/claude-write.log" ]
}

@test "cloud verify runs its probe independently: with the server not configured it fails (exit 1), and it runs the descriptor's argv" {
  go "$CLOUD" --step verify
  [ "$status" -eq 1 ]
  [ "$(step_status verify)" = "fail" ]
  [ "$(step_count detect)" -eq 0 ]
  [ "$(step_count register_mcp)" -eq 0 ]
  [ "$(summary_status)" = "fail" ]
  probe="$(jq -r '.verify.command | join(" ")' "$CLOUD")"
  [ "$(grep -cFx "$probe" "$STUB/claude.log")" -eq 1 ]
  [ ! -e "$PROJ/.mcp.json" ]
}

@test "cloud, claude missing: stops at install with needs-user-action (exit 3) and the docs URL; no installer, no write, even with --allow-install" {
  : > "$STUB/no-claude"
  docs="$(jq -r '.install.docs_url' "$CLOUD")"
  go "$CLOUD"
  [ "$status" -eq 3 ]
  [ "$(step_detail detect)" = "absent" ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "$docs"
  [ "$(step_count register_mcp)" -eq 0 ]
  [ "$(summary_status)" = "needs-user-action" ]
  go "$CLOUD" --allow-install
  [ "$status" -eq 3 ]
  assert_contains "$(step_message install)" "$docs"
  [ -z "$(project_files)" ]
  [ ! -e "$STUB/installer.log" ]
  [ ! -e "$STUB/claude-write.log" ]
}

@test "cli, acli not installed: needs-user-action (exit 3) with the docs URL; no installer even with --allow-install; nothing written" {
  docs="$(jq -r '.install.docs_url' "$CLI")"
  go "$CLI"
  [ "$status" -eq 3 ]
  [ "$(step_status detect)" = "pass" ]
  [ "$(step_detail detect)" = "absent" ]
  [ "$(step_status install)" = "needs-user-action" ]
  assert_contains "$(step_message install)" "$docs"
  [ "$(step_count auth)" -eq 0 ]
  [ "$(step_count verify)" -eq 0 ]
  [ "$(summary_status)" = "needs-user-action" ]
  go "$CLI" --allow-install
  [ "$status" -eq 3 ]
  assert_contains "$(step_message install)" "$docs"
  [ ! -e "$STUB/installer.log" ]
  [ -z "$(project_files)" ]
}

@test "cli, installed but signed out: auth is needs-user-action naming the env-var NAMES, acli auth is never run; --continue ends in verify fail" {
  : > "$STUB/installed"
  go "$CLI"
  [ "$status" -eq 3 ]
  [ "$(step_detail detect)" = "present" ]
  [ "$(step_status install)" = "skipped" ]
  [ "$(step_status auth)" = "needs-user-action" ]
  msg="$(step_message auth)"
  assert_contains "$msg" "yourself"
  while IFS= read -r name; do
    assert_contains "$msg" "$name"
  done < <(jq -r '.secrets.env_vars[]' "$CLI")
  [ "$(step_count register_mcp)" -eq 0 ]
  [ "$(step_count verify)" -eq 0 ]

  go "$CLI" --continue
  [ "$status" -eq 1 ]
  [ "$(step_status register_mcp)" = "skipped" ]
  assert_contains "$(step_message register_mcp)" "no MCP server"
  [ "$(step_status verify)" = "fail" ]
  # no sign-in was attempted, nothing was written, no installer ran
  [ ! -e "$STUB/acli-auth.log" ]
  [ ! -e "$STUB/installer.log" ]
  [ -z "$(project_files)" ]
  [ ! -e "$PROJ/.mcp.json" ]
}

@test "cli, installed and signed in: exit 0, auth skipped as already authenticated, register skipped, verify passes with the descriptor's argv" {
  : > "$STUB/installed"
  : > "$STUB/signedin"
  go "$CLI"
  [ "$status" -eq 0 ]
  [ "$(step_status detect)" = "pass" ]
  [ "$(step_status install)" = "skipped" ]
  [ "$(step_status auth)" = "skipped" ]
  assert_contains "$(step_message auth)" "already authenticated"
  [ "$(step_status register_mcp)" = "skipped" ]
  [ "$(step_status verify)" = "pass" ]
  [ "$(summary_status)" = "pass" ]
  # the probe (auth.check and verify share one argv) ran exactly twice, as the descriptor says
  probe="$(jq -r '.verify.command | join(" ")' "$CLI")"
  [ "$(grep -cFx "$probe" "$STUB/acli.log")" -eq 2 ]
  [ ! -e "$STUB/acli-auth.log" ]
  [ -z "$(project_files)" ]
}

@test "no token leak: the sentinel printed by the stubs and set in the environment never reaches runner output, project files or the descriptors" {
  export ATLASSIAN_API_TOKEN="$SENTINEL"
  : > "$STUB/installed"
  go "$CLI" --continue
  [ -f "$STUB/acli.log" ]
  run grep -F "$SENTINEL" <<<"$output"
  [ "$status" -eq 1 ]
  run grep -F "$SENTINEL" <<<"$stderr"
  [ "$status" -eq 1 ]

  go "$CLOUD" --continue
  [ -f "$STUB/claude.log" ]
  run grep -F "$SENTINEL" <<<"$output"
  [ "$status" -eq 1 ]
  run grep -F "$SENTINEL" <<<"$stderr"
  [ "$status" -eq 1 ]

  run grep -rF "$SENTINEL" "$PROJ"
  [ "$status" -eq 1 ]
  run grep -F "$SENTINEL" "$CLOUD" "$CLI"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------------------------
# 3. the shared doc
# ---------------------------------------------------------------------------------------------

@test "the doc lives under project/documentation/, not docs/" {
  [ -f "$DOC" ]
  [ ! -e "$REPO_ROOT/docs/atlassian-connect.md" ]
}

@test "the doc lists every official URL the two descriptors carry (docs, install.docs_url, auth.docs_url)" {
  local f url doc
  doc="$(cat "$DOC")"
  for f in "$CLOUD" "$CLI"; do
    while IFS= read -r url; do
      [ -n "$url" ]
      assert_contains "$doc" "$url"
    done < <(jq -r '[.docs[]?, .install.docs_url?, .auth.docs_url?] | map(select(. != null)) | unique[]' "$f")
  done
}

@test "the doc states what each transport covers among Jira, Confluence and Bitbucket, and where it does not" {
  doc="$(cat "$DOC")"
  assert_contains "$doc" "## Transports and coverage"
  assert_contains "$doc" "| Jira |"
  assert_contains "$doc" "| Confluence |"
  assert_contains "$doc" "| Bitbucket |"
  assert_contains "$doc" "Bitbucket Cloud only"
  assert_contains "$doc" "**Not covered**"
  assert_contains "$doc" "Data Center and Server are not covered"
  # the acli column says Confluence and Bitbucket are not covered
  [ "$(grep -E '^\| (Confluence|Bitbucket) \|' "$DOC" | grep -c '\*\*Not covered\*\*')" -eq 2 ]
}

@test "the doc's Could-not-verify items match the descriptors' labels one to one" {
  local row hint_phrase doc_phrase i section
  # the doc section, from its heading to the next level-2 heading
  section="$(awk '/^## Could not verify$/{f=1;next} /^## /{f=0} f' "$DOC")"
  [ -n "$section" ]
  # collapse whitespace so a hard-wrapped doc sentence still matches a phrase
  section="$(lower "$section" | tr -s '[:space:]' ' ')"
  local cloud_hint cli_hint
  cloud_hint="$(lower "$(jq -r '.install.hint' "$CLOUD")" | tr -s '[:space:]' ' ')"
  cli_hint="$(lower "$(jq -r '.install.hint' "$CLI")" | tr -s '[:space:]' ' ')"

  # item counts in the doc equal the number of labels in this table (so a label added to a
  # descriptor, or an item added to the doc, without the table being updated fails here)
  # (count matches with grep -o: the section is whitespace-collapsed onto a single line)
  [ "$(printf '%s\n' "$section" | grep -o '\*\*cv-cloud-[0-9]*\.\*\*' | wc -l | tr -d ' ')" -eq "${#CLOUD_LABELS[@]}" ]
  [ "$(printf '%s\n' "$section" | grep -o '\*\*cv-cli-[0-9]*\.\*\*' | wc -l | tr -d ' ')" -eq "${#CLI_LABELS[@]}" ]

  i=0
  for row in "${CLOUD_LABELS[@]}"; do
    i=$((i + 1))
    hint_phrase="${row%%|*}"
    doc_phrase="${row#*|}"
    assert_contains "$cloud_hint" "$hint_phrase"
    assert_contains "$section" "**cv-cloud-$i.**"
    assert_contains "$section" "$doc_phrase"
  done
  i=0
  for row in "${CLI_LABELS[@]}"; do
    i=$((i + 1))
    hint_phrase="${row%%|*}"
    doc_phrase="${row#*|}"
    assert_contains "$cli_hint" "$hint_phrase"
    assert_contains "$section" "**cv-cli-$i.**"
    assert_contains "$section" "$doc_phrase"
  done
  # the label itself is explained, and the cli's extra auth.instructions label is mentioned
  assert_contains "$section" "$LABEL"
  assert_contains "$section" "auth.instructions"
}

@test "the doc has placeholder headings for the marker/gate (E71_S02_T03) and the link script (E71_S04_T03), after the sections above them" {
  grep -q '^## Marker and gate$' "$DOC"
  grep -q '^## Link script$' "$DOC"
  assert_contains "$(cat "$DOC")" "E71_S02_T03"
  assert_contains "$(cat "$DOC")" "E71_S04_T03"
  m="$(grep -n '^## Marker and gate$' "$DOC" | cut -d: -f1)"
  l="$(grep -n '^## Link script$' "$DOC" | cut -d: -f1)"
  c="$(grep -n '^## Could not verify$' "$DOC" | cut -d: -f1)"
  [ "$c" -lt "$m" ]
  [ "$m" -lt "$l" ]
}

@test "the doc contains no secret value (only env-var NAMES)" {
  run grep -Eq "$CRED_RE" "$DOC"
  [ "$status" -eq 1 ]
  run grep -F "$SENTINEL" "$DOC"
  [ "$status" -eq 1 ]
  assert_contains "$(cat "$DOC")" "ATLASSIAN_API_TOKEN"
}

# ---------------------------------------------------------------------------------------------
# 4. the marker and the gate (E71_S02_T03)
#
# The descriptors cannot write the marker themselves (rapport E71_S02_T03-descriptor-cannot-write-marker:
# argv only, no shell strings, no way to resolve the writer's path or supply the site URL), so the flow
# modelled here is the documented one: run the real descriptor through run-descriptor.sh with stubs, then
# run scripts/atlassian-write-marker.sh, then ask scripts/atlassian-configured.sh. The scratch project
# is $PROJ, selected with JENGA_PROJECT_ROOT, so the real project marker is never touched.
# ---------------------------------------------------------------------------------------------

WRITER="$REPO_ROOT/scripts/atlassian-write-marker.sh"
GATE="$REPO_ROOT/scripts/atlassian-configured.sh"

# scratch_marker_env: point the marker scripts at the scratch project and give it a configs dir.
scratch_marker_env() {
  mkdir -p "$PROJ/project/configs"
  printf '{"paths":{"configs":"project/configs"}}\n' > "$PROJ/project/configs/workflow.json"
  export JENGA_PROJECT_ROOT="$PROJ"
  MARKER="$PROJ/project/configs/atlassian.json"
}

# acli_auth_stub: an acli whose `auth status` / `jira auth status` succeed iff $STUB/signedin exists (the
# setup() stub answers every other subcommand with 0), so the gate's confirmation can fail.
acli_auth_stub() {
  cat > "$FAKE_BIN/acli" <<EOS
#!/bin/sh
echo "acli \$*" >> "$STUB/acli.log"
if [ "\$1" = "--version" ]; then [ -e "$STUB/installed" ] && exit 0; exit 1; fi
if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then [ -e "$STUB/signedin" ] && exit 0; exit 1; fi
if [ "\$1" = "jira" ] && [ "\$2" = "auth" ] && [ "\$3" = "status" ]; then [ -e "$STUB/signedin" ] && exit 0; exit 1; fi
if [ "\$1" = "jira" ] && [ "\$2" = "project" ] && [ "\$3" = "list" ]; then [ -e "$STUB/signedin" ] && exit 0; exit 1; fi
exit 0
EOS
  chmod +x "$FAKE_BIN/acli"
}

run_gate() { run --separate-stderr bash "$GATE"; }

@test "marker flow, cloud: a passing descriptor run then the writer leaves a marker the gate reports configured over mcp" {
  scratch_marker_env
  go "$CLOUD"
  [ "$status" -eq 0 ]
  [ "$(step_status verify)" = "pass" ]
  [ ! -e "$MARKER" ]
  run --separate-stderr bash "$WRITER" --transport mcp --deployment cloud --site https://example.atlassian.net --products jira,confluence
  [ "$status" -eq 0 ]
  [ "$(jq -S -c . "$MARKER")" = '{"deployment":"cloud","enabled":true,"products":["jira","confluence"],"site_base_url":"https://example.atlassian.net","transport":"mcp"}' ]
  run_gate
  [ "$status" -eq 0 ]
  [ "$(jq -r '.configured' <<<"$output")" = "true" ]
  [ "$(jq -r '.transport' <<<"$output")" = "mcp" ]
  [ -z "$stderr" ]
  # the marker holds no secret and the sentinel the stubs print never reached it
  run grep -F "$SENTINEL" "$MARKER"
  [ "$status" -eq 1 ]
}

@test "marker flow, cloud: a failed verify (server not registered) leaves no marker and the writer refuses with exit 3" {
  scratch_marker_env
  go "$CLOUD" --step verify
  [ "$status" -eq 1 ]
  [ "$(step_status verify)" = "fail" ]
  run --separate-stderr bash "$WRITER" --transport mcp --deployment cloud --site https://example.atlassian.net --products jira
  [ "$status" -eq 3 ]
  [ ! -e "$MARKER" ]
  [ -z "$(find "$PROJ/project/configs" -name '.atlassian.json.*')" ]
  run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.configured' <<<"$output")" = "false" ]
}

@test "marker flow, cli: a passing descriptor run then the writer leaves a marker the gate reports configured over cli" {
  scratch_marker_env
  acli_auth_stub
  : > "$STUB/installed"
  : > "$STUB/signedin"
  go "$CLI"
  [ "$status" -eq 0 ]
  [ "$(step_status verify)" = "pass" ]
  [ ! -e "$MARKER" ]
  run --separate-stderr bash "$WRITER" --transport cli --deployment cloud --site https://example.atlassian.net --products jira
  [ "$status" -eq 0 ]
  [ "$(jq -S -c . "$MARKER")" = '{"deployment":"cloud","enabled":true,"products":["jira"],"site_base_url":"https://example.atlassian.net","transport":"cli"}' ]
  run_gate
  [ "$status" -eq 0 ]
  [ "$(jq -r '.configured' <<<"$output")" = "true" ]
  [ "$(jq -r '.transport' <<<"$output")" = "cli" ]
}

@test "marker flow, cli: a failed verify (signed out) leaves no marker and the writer refuses with exit 3" {
  scratch_marker_env
  acli_auth_stub
  : > "$STUB/installed"
  go "$CLI" --step verify
  [ "$status" -eq 1 ]
  [ "$(step_status verify)" = "fail" ]
  run --separate-stderr bash "$WRITER" --transport cli --deployment cloud --site https://example.atlassian.net --products jira
  [ "$status" -eq 3 ]
  [ ! -e "$MARKER" ]
  run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.configured' <<<"$output")" = "false" ]
}

@test "marker flow: drift is reported after the connection is removed (marker enabled, MCP entry gone) with the remedy named" {
  scratch_marker_env
  go "$CLOUD"
  run --separate-stderr bash "$WRITER" --transport mcp --deployment cloud --site https://example.atlassian.net --products jira
  [ "$status" -eq 0 ]
  rm -f "$PROJ/.mcp.json"
  run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.configured' <<<"$output")" = "false" ]
  assert_contains "$(jq -r '.reason' <<<"$output")" "drift"
  assert_contains "$(jq -r '.reason' <<<"$output")" "re-run j.connect for Atlassian"
}

@test "gate, nothing configured, no .mcp.json and network tools unavailable: exit 1, configured false, and nothing on stderr" {
  scratch_marker_env
  local t net="$BATS_TEST_TMPDIR/netbin"
  mkdir -p "$net"
  for t in curl wget nc ncat telnet ssh scp ftp dig nslookup host ping; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/network-was-called"\nexit 1\n' "$t" "$BATS_TEST_TMPDIR" > "$net/$t"
    chmod +x "$net/$t"
  done
  PATH="$net:$PATH"
  [ ! -e "$PROJ/.mcp.json" ]
  run_gate
  [ "$status" -eq 1 ]
  [ "$(jq -r '.configured' <<<"$output")" = "false" ]
  [ -z "$stderr" ]
  [ ! -e "$BATS_TEST_TMPDIR/network-was-called" ]
  [ ! -e "$MARKER" ]
}

@test "the doc's Marker and gate section covers the schema, exit codes, JSON shape, verify-before-claim, drift with remedy, and no hand edits" {
  local section
  section="$(awk '/^## Marker and gate$/{f=1;next} /^## /{f=0} f' "$DOC" | tr -s '[:space:]' ' ')"
  [ -n "$section" ]
  local f
  for f in enabled products deployment site_base_url transport; do
    assert_contains "$section" "| \`$f\` |"
  done
  assert_contains "$section" "Do not edit the marker by hand"
  assert_contains "$section" "Verify before claiming"
  assert_contains "$section" "--check-transport"
  assert_contains "$section" '"configured":true'
  assert_contains "$section" '"configured":false'
  assert_contains "$section" "| \`0\` | Configured |"
  assert_contains "$section" "| \`1\` | Not configured"
  assert_contains "$section" "### Drift"
  assert_contains "$section" "**Remedy:**"
  assert_contains "$section" "re-run \`j.connect\` for Atlassian"
  assert_contains "$section" "E71_S02_T03-descriptor-cannot-write-marker"
  # the sections above it are untouched in order and name
  grep -q '^## Could not verify$' "$DOC"
  grep -q '^## Official sources consulted$' "$DOC"
}
