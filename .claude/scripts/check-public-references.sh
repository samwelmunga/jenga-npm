#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/check-public-references.sh
#
# Parity audit for the public mirror. Lists every git-tracked skill definition
# and script that ships (classified PUBLIC by scripts/check-publicignore-match.sh)
# and that refers to something which never ships, such as a path into
# skills/j-convert/. Such a reference dangles in every consumer install.
#
# Scope (E28_S21_T05), deliberately asymmetric, the same as the mirror guard's:
#   PATH hits  every public file an npm consumer receives (scripts/npm-reach-files.sh, i.e. npm pack --dry-run),
#              so this report and the guard give the same path-hit verdict on the same tree.
#   NAME hits  SCOPE_RE below only: skills/*/SKILL.md, skills/*/scripts/, scripts/ and hooks/. A name mention cannot
#              be told from prose by a regex, so it is not widened. The router-MCP pattern is audit-only (not a
#              skill, so the guard has no equivalent) and stays on this same narrower scope.
# Tests are left to the test-subject audit (tests/*.bats name these skills as fixtures).
#
# THE RULE LIVES ELSEWHERE (E28_S19_T06). The never-public skill set, the three
# regexes that recognise a reference, and the critical-versus-minor
# classification all come from scripts/never-public-refs.sh, which derives the
# set from .publicignore at run time. This script must not re-derive any of
# them. Before T06 it carried its own
# NAMES='convert|mirror-public|self-sync|strategy|train' and built its own
# regexes from it; that literal had already drifted out of date (it was missing
# dev-done, so j-dev-done references went unaudited) which is precisely the
# failure a derived set cannot have. See the "Rule: a shipped file may not
# reference a skill that stays private" section of
# project/documentation/public-mirror-content-parity.md.
#
# Severity matches the mirror-time push gate, not check 6: this is the
# maintainer-side view of what a real push would refuse, so it calls
# never_public_severity with strict=1, exactly as
# check_never_public_refs_invariant in skills/j-mirror-public/scripts/mirror.sh
# does. Check 6 of j.smoke-test is the consumer-side equivalent and
# deliberately keeps name hits minor.
#
# Declared exemptions (E28_S21_T03): scripts/never-public-exemptions.conf lists the few files that legitimately name
# a blocked skill's path as their purpose. Path hits on those files (and their .claude/.agents copies) are skipped
# and counted; a malformed file stops the audit with exit 2, naming the entry.
#
# Report only: prints severity, file:line and subject for every hit, and exits
# 1 when there is any. Wired into no gate.
#
# Usage: scripts/check-public-references.sh [--scope all]
#   --scope all   scan every public tracked file for path AND name hits instead of the scopes above. This replaces
#                 the scratch-copy `sed` that the triage document's reproduction recipe used to widen SCOPE_RE; it
#                 re-derives the whole-tree inventory without editing this script. Not a gate.
# ---------------------------------------------------------------------------
set -u

SCOPE_ALL=0
case "${1:-}" in
  "") ;;
  --scope) [ "${2:-}" = all ] && [ "$#" -eq 2 ] && SCOPE_ALL=1 || { echo "usage: check-public-references.sh [--scope all]" >&2; exit 2; } ;;
  --scope=all) [ "$#" -eq 1 ] && SCOPE_ALL=1 || { echo "usage: check-public-references.sh [--scope all]" >&2; exit 2; } ;;
  *) echo "usage: check-public-references.sh [--scope all]" >&2; exit 2 ;;
esac

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || { echo "check-public-references.sh: error: not inside a git repository" >&2; exit 2; }
cd "$REPO_ROOT" || exit 2

if [ ! -f .publicignore ]; then
  echo "check-public-references.sh: no .publicignore at the repo root; nothing is classified as blocked" >&2
  exit 0
fi

LIB="$REPO_ROOT/scripts/never-public-refs.sh"
[ -r "$LIB" ] || { echo "check-public-references.sh: error: shared rule not found at $LIB" >&2; exit 2; }
# shellcheck source=/dev/null
. "$LIB"
never_public_load "$REPO_ROOT/.publicignore" "$REPO_ROOT/scripts/never-public-exemptions.conf"

# Fail closed on a malformed exemption file (E28_S21_T03), naming the entry.
if [ -n "$NEVER_PUBLIC_EXEMPT_ERROR" ]; then
  echo "check-public-references.sh: error: $NEVER_PUBLIC_EXEMPT_ERROR" >&2
  exit 2
fi

if [ -z "$NEVER_PUBLIC_NAMES" ]; then
  echo "check-public-references.sh: .publicignore blocks no skills/j-<name>/ directory; nothing to audit" >&2
  exit 0
fi

# Private tooling that is NOT a skill, so the shared rule does not and should
# not cover it: never_public_load parses only ^skills/j-<name>/$ lines, and
# mcp/router/ is blocklisted private tooling (.publicignore:271-273). Kept as a
# separate, explicitly named pattern rather than injected into the shared skill
# set, so the two stay independently correct.
PRIVATE_TOOLING_RE='mcp/router([^A-Za-z0-9_-]|$)'

# Gates NAME hits (and the router pattern) only; path hits follow the npm-reach list. --scope all widens both.
SCOPE_RE='^(skills/[^/]+/SKILL\.md|skills/[^/]+/scripts/|scripts/|hooks/)'
[ "$SCOPE_ALL" = 1 ] && SCOPE_RE="."

ALL_PUBLIC_FILE="$(mktemp -t cpr-public.XXXXXX)" || { echo "check-public-references.sh: error: cannot create a temporary file" >&2; exit 2; }
REACH_FILE="$(mktemp -t cpr-reach.XXXXXX)" || { rm -f "$ALL_PUBLIC_FILE"; echo "check-public-references.sh: error: cannot create a temporary file" >&2; exit 2; }
SCAN_FILE="$(mktemp -t cpr-scan.XXXXXX)" || { rm -f "$ALL_PUBLIC_FILE" "$REACH_FILE"; echo "check-public-references.sh: error: cannot create a temporary file" >&2; exit 2; }
trap 'rm -f "$ALL_PUBLIC_FILE" "$REACH_FILE" "$SCAN_FILE"' EXIT

git ls-files -z | xargs -0 "$REPO_ROOT/scripts/check-publicignore-match.sh" \
  | awk -F'\t' '$1 == "PUBLIC" { print $2 }' >"$ALL_PUBLIC_FILE"

# The npm-reach list scopes PATH hits. Fail closed: a scope that cannot be computed is exit 2, never an empty scan.
# With --scope all it is not consulted, so the whole-tree inventory does not depend on npm.
if [ "$SCOPE_ALL" = 1 ]; then
  cp "$ALL_PUBLIC_FILE" "$REACH_FILE"
else
  REACH_SCRIPT="$REPO_ROOT/scripts/npm-reach-files.sh"
  [ -r "$REACH_SCRIPT" ] || { echo "check-public-references.sh: error: npm-reach script not found at $REACH_SCRIPT" >&2; exit 2; }
  if ! bash "$REACH_SCRIPT" "$REPO_ROOT" >"$REACH_FILE" || [ ! -s "$REACH_FILE" ]; then
    echo "check-public-references.sh: error: cannot compute the npm-reach list that scopes the path-hit scan" >&2
    exit 2
  fi
fi

# Tag every public file "NP<TAB>path": N = in the name scope, P = in the path scope (public AND reachable by npm).
SCOPE_RE_ENV="$SCOPE_RE" awk 'NR == FNR { reach[$0] = 1; next }
  { n = ($0 ~ ENVIRON["SCOPE_RE_ENV"]) ? 1 : 0; p = ($0 in reach) ? 1 : 0; if (n || p) printf "%d%d\t%s\n", n, p, $0 }' \
  "$REACH_FILE" "$ALL_PUBLIC_FILE" >"$SCAN_FILE"

RE_PATH="($NEVER_PUBLIC_PATH_RE)"
RE_NAME="($NEVER_PUBLIC_NAME_RE)|($NEVER_PUBLIC_BARE_RE)|($PRIVATE_TOOLING_RE)"
RE_ALL="$RE_PATH|$RE_NAME"

never_names=()
# Split explicitly rather than relying on word splitting, so this keeps working
# if a caller has set a custom IFS.
IFS="|" read -r -a never_names <<<"$NEVER_PUBLIC_NAMES"

REPORT=""
critical_count=0
minor_count=0
scanned=0
exempt_count=0

while IFS=$'\t' read -r flags path; do
  [ -n "$path" ] || continue
  name_scope="${flags:0:1}"
  path_scope="${flags:1:1}"
  # The blocklist file defines the set, so it necessarily names every member. This skip is the whole of the
  # .publicignore handling here; the decision not to route it through the exemption file is stated once in the
  # "Declared exemptions" section of project/documentation/public-mirror-content-parity.md.
  [ "$path" = ".publicignore" ] && continue
  [ -f "$path" ] && [ ! -L "$path" ] || continue
  scanned=$((scanned + 1))

  # Markdown has no comment lines: a leading # is a heading, so no line of a
  # *.md file may be discounted as a comment.
  own_md=0
  case "$path" in *.md) own_md=1 ;; esac

  # Hit kinds this file is scanned for: path hits when it is in the npm-reach set, name, bare and router hits when
  # it is in the name scope. grep gets only the regexes its scope allows.
  re_file="$RE_ALL"
  if [ "$path_scope" = 1 ] && [ "$name_scope" != 1 ]; then re_file="$RE_PATH"
  elif [ "$path_scope" != 1 ]; then re_file="$RE_NAME"
  fi

  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    lineno="${hit%%:*}"
    text="${hit#*:}"

    # Identify what the line refers to, and whether it is a path or a name.
    kind=name
    subject=""
    if [ "$name_scope" = 1 ] && grep -qE "$PRIVATE_TOOLING_RE" <<<"$text"; then
      kind=path
      subject="mcp/router"
    else
      for n in "${never_names[@]}"; do
        path_re="${NEVER_PUBLIC_PATH_RE//"$NEVER_PUBLIC_NAMES"/$n}"
        name_re="${NEVER_PUBLIC_NAME_RE//"$NEVER_PUBLIC_NAMES"/$n}"
        bare_re="${NEVER_PUBLIC_BARE_RE//"$NEVER_PUBLIC_NAMES"/$n}"
        if [ "$path_scope" = 1 ] && grep -qE "$path_re" <<<"$text"; then
          kind=path; subject="j-$n"; break
        elif [ "$name_scope" = 1 ] && { grep -qE "$name_re" <<<"$text" || grep -qE "$bare_re" <<<"$text"; }; then
          subject="j-$n"; break
        fi
      done
    fi
    [ -n "$subject" ] || subject="?"

    # A declared exemption (scripts/never-public-exemptions.conf) silences a blocked-skill PATH hit only: never a
    # name hit, and never the private-tooling pattern above (it is not a skill).
    if [ "$kind" = path ] && [ "$subject" != "mcp/router" ] && never_public_path_exempt "$path" "$text"; then
      exempt_count=$((exempt_count + 1))
      continue
    fi

    sev="$(never_public_severity "$kind" "$text" "$own_md" 1)"
    if [ "$sev" = critical ]; then
      critical_count=$((critical_count + 1))
    else
      minor_count=$((minor_count + 1))
    fi
    REPORT="${REPORT}${sev}	${path}:${lineno}	${subject} (${kind})"$'\n'
  done < <(grep -InE -e "$re_file" -- "$path" 2>/dev/null || true)
done <"$SCAN_FILE"

if [ "$exempt_count" -gt 0 ]; then
  echo "check-public-references.sh: $exempt_count path hit(s) exempted by scripts/never-public-exemptions.conf (each entry carries its reason there)" >&2
fi

if [ -z "$REPORT" ]; then
  echo "check-public-references.sh: PASS -- $scanned public file(s) scanned, none refers to a never-public subject" >&2
  exit 0
fi

printf '%s' "$REPORT"
echo "check-public-references.sh: FAIL -- $critical_count critical, $minor_count minor across $scanned public file(s) (listed above). Severity follows the mirror push gate; see project/documentation/public-mirror-content-parity.md" >&2
exit 1
