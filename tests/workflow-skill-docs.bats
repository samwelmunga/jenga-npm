#!/usr/bin/env bats
#
# Documentation-listing coverage for the j.workflow skill (E80_S05_T06).
#
# CLAUDE.md's skills table and README.md's skills reference are hand-maintained listings, and j.help
# lists from the skills directory. This file asserts all three name j.workflow, and that what the
# docs say matches the sub-commands skills/j-workflow/SKILL.md actually defines. Against this
# repository's real files, not synthetic ones. No npm install, no network.
#
# Kept apart from tests/workflow-skill-registration.bats (E80_S05_T05) so the two files can be
# edited independently.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HELP_SCAN="$REPO_ROOT/tests/helpers/help-scan.mjs"
SKILL_MD="$REPO_ROOT/skills/j-workflow/SKILL.md"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
README_MD="$REPO_ROOT/README.md"

# The sub-commands SKILL.md's description declares: "the sub-commands are run, status, list, resume, pause and cancel".
SUBCOMMANDS="run status list resume pause cancel"

@test "SKILL.md still declares the six sub-commands this file asserts against" {
  [ -f "$SKILL_MD" ]
  for sc in $SUBCOMMANDS; do
    grep -m1 '^description:' "$SKILL_MD" | grep -qw "$sc"
  done
}

@test "CLAUDE.md skills table has exactly one j.workflow row naming every sub-command" {
  run grep -c '^| `j\.workflow`' "$CLAUDE_MD"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  row="$(grep '^| `j\.workflow`' "$CLAUDE_MD")"
  for sc in $SUBCOMMANDS; do
    case "$row" in
      *"\`$sc\`"*) ;;
      *) echo "row does not mention sub-command $sc: $row"; return 1 ;;
    esac
  done
  case "$row" in *'project/.workflows/<id>.json'*) ;; *) echo "row omits the definitions path"; return 1 ;; esac
}

@test "README.md mentions j.workflow and every relative link in its paragraph resolves" {
  grep -q 'j\.workflow' "$README_MD"
  para="$(grep '^Need a chain with durable state' "$README_MD")"
  [ -n "$para" ]
  case "$para" in *'j.workflow'*) ;; *) echo "paragraph does not name j.workflow"; return 1 ;; esac
  links="$(printf '%s' "$para" | grep -o '](\([^)]*\))' | sed 's/^](//; s/)$//')"
  [ -n "$links" ]
  while IFS= read -r link; do
    case "$link" in
      http://*|https://*|'#'*) continue ;;
    esac
    target="${link%%#*}"
    if [ ! -e "$REPO_ROOT/$target" ]; then
      echo "dangling relative link in README j.workflow paragraph: $link"
      return 1
    fi
  done <<< "$links"
  # Every sub-command is named, consistent with SKILL.md.
  for sc in $SUBCOMMANDS; do
    case "$para" in *"\`$sc\`"*) ;; *) echo "README paragraph omits sub-command $sc"; return 1 ;; esac
  done
}

@test "the help scan lists j-workflow" {
  run node "$HELP_SCAN" list "$REPO_ROOT/skills"
  [ "$status" -eq 0 ]
  node -e 'const a=JSON.parse(process.argv[1]);process.exit(a.includes("j-workflow")?0:1)' "$output"
}
