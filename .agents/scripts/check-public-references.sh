#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/check-public-references.sh
#
# Parity audit for the public mirror. Lists every git-tracked skill definition
# and script that ships (classified PUBLIC by scripts/check-publicignore-match.sh)
# and that refers to something which never ships, such as a path into
# skills/j-convert/. Such a reference dangles in every consumer install.
#
# Scope: skills/*/SKILL.md, skills/*/scripts/, scripts/ and hooks/. Tests are
# left to the test-subject audit (tests/*.bats name these skills as fixtures).
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
# Usage: scripts/check-public-references.sh
# ---------------------------------------------------------------------------
set -u

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

SCOPE_RE='^(skills/[^/]+/SKILL\.md|skills/[^/]+/scripts/|scripts/|hooks/)'

PUBLIC_FILES="$(git ls-files -z | xargs -0 "$REPO_ROOT/scripts/check-publicignore-match.sh" \
  | awk -F'\t' '$1 == "PUBLIC" { print $2 }' | grep -E "$SCOPE_RE" || true)"

RE_ALL="($NEVER_PUBLIC_PATH_RE)|($NEVER_PUBLIC_NAME_RE)|($NEVER_PUBLIC_BARE_RE)|($PRIVATE_TOOLING_RE)"

never_names=()
# Split explicitly rather than relying on word splitting, so this keeps working
# if a caller has set a custom IFS.
IFS="|" read -r -a never_names <<<"$NEVER_PUBLIC_NAMES"

REPORT=""
critical_count=0
minor_count=0
scanned=0
exempt_count=0

while IFS= read -r path; do
  [ -n "$path" ] || continue
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

  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    lineno="${hit%%:*}"
    text="${hit#*:}"

    # Identify what the line refers to, and whether it is a path or a name.
    kind=name
    subject=""
    if grep -qE "$PRIVATE_TOOLING_RE" <<<"$text"; then
      kind=path
      subject="mcp/router"
    else
      for n in "${never_names[@]}"; do
        path_re="${NEVER_PUBLIC_PATH_RE//"$NEVER_PUBLIC_NAMES"/$n}"
        name_re="${NEVER_PUBLIC_NAME_RE//"$NEVER_PUBLIC_NAMES"/$n}"
        bare_re="${NEVER_PUBLIC_BARE_RE//"$NEVER_PUBLIC_NAMES"/$n}"
        if grep -qE "$path_re" <<<"$text"; then
          kind=path; subject="j-$n"; break
        elif grep -qE "$name_re" <<<"$text" || grep -qE "$bare_re" <<<"$text"; then
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
  done < <(grep -InE -e "$RE_ALL" -- "$path" 2>/dev/null || true)
done <<<"$PUBLIC_FILES"

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
