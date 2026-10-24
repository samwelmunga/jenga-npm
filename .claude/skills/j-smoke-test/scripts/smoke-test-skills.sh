#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-smoke-test/scripts/smoke-test-skills.sh
#
# Catalog-wide STRUCTURAL smoke test (E64_S01_T01). For every canonical skill
# directory under <root>/skills/ it checks the things a skill cannot work at
# all without, and emits each problem as one JSON object per line.
#
# This is not scripts/smoke-harness.sh (which smoke-tests the diff of one
# in-flight inline task) and it is not tests/*.bats (which exercise behaviour).
# It answers one question: "does every skill in skills/ still hang together?"
#
# ---------------------------------------------------------------------------
# THE FIVE CHECKS
# ---------------------------------------------------------------------------
#   1. SKILL.md exists, its YAML frontmatter is well formed, and `name` and
#      `description` are present.
#   2. `name` is the canonical `j.<name>` identifier for the directory
#      `j-<name>` (CLAUDE.md "Canonical Naming Contract"). The permanent
#      exceptions `jenga`, `jenga-permission-level` and `jenga-config` keep their
#      bare directory and carry `j.jenga` / `j.jenga-permission-level` /
#      `j.jenga-config`. Any other directory
#      that is not `j-<name>` is itself a mismatch.
#   3. `metadata.prefered_agent`, when set, names a real <root>/agents/<x>.md.
#   4. Every shell script SKILL.md references exists and passes `bash -n`.
#   5. Every asset/template path SKILL.md references exists.
#   6. SKILL.md and the skill's scripts/ do not reach into a skill that never
#      ships to the public mirror (see project/documentation/public-mirror-content-parity.md).
#      A path into one is critical; a bare name is minor.
#
# `index` is the fourth permanent exception and is NOT a skill: it has no
# SKILL.md by design and is not part of routing. It is covered (counted and
# reported as exempt) but not held to checks 1-5. If it ever grows a SKILL.md
# it is checked like any other skill, and since a bare `index` is not in the
# j-<name> form that is itself reported as a name-dir-mismatch.
#
# ---------------------------------------------------------------------------
# SEVERITY BAR (binding; this is the line, written down rather than implied)
# ---------------------------------------------------------------------------
# A finding is `critical` when the skill, or one of its steps, cannot work AT
# ALL as written -- when running it would fail or silently route to the wrong
# place regardless of what the user asks:
#
#   skill-md-missing        no SKILL.md in a non-exempt skill directory
#   frontmatter-unparsable  frontmatter does not open on line 1, never closes,
#                           has a line that is no `key: value` pair, list item
#                           or indented continuation, or has a plain (unquoted)
#                           scalar containing ": " (a YAML mapping error)
#   name-missing            no `name`
#   name-dir-mismatch       `name` is not the canonical form of the directory
#   agent-unresolved        `metadata.prefered_agent` has no agents/<x>.md
#   script-missing          a path-qualified or $VAR-prefixed .sh reference
#                           resolves nowhere
#   script-syntax           a referenced, resolved script fails `bash -n`
#   asset-missing           an assets/ or templates/ reference resolves nowhere
#   never-public-path       a path into a never-shipped skill directory
#
# A finding is `minor` when the skill still works but is degraded or untidy:
#
#   description-missing     no `description` (skill loads; listings are blank)
#   description-trivial     `description` has fewer than 3 letters/digits
#                           (a placeholder such as ">." rather than a sentence)
#   script-unresolved-mention
#                           a BARE `name.sh` in prose that resolves nowhere.
#                           Prose can name a script of the user's project or an
#                           external tool, so it is not evidence of breakage.
#   never-public-mention    a `/name`, `j.name` or `j-name` reference to a skill
#                           that never ships. A prose mention is stale; a step
#                           that invokes it fails in a consumer install.
#
# Only `critical` findings feed the Feature | Error | Consequences table
# (E64_S01_T02). Nothing else is ever promoted to critical by volume.
#
# ---------------------------------------------------------------------------
# REFERENCE EXTRACTION (heuristic by nature, deliberately conservative)
# ---------------------------------------------------------------------------
# References are tokens found in SKILL.md's body (everything after the
# frontmatter). Skipped as dynamic: anything holding a <placeholder>, {braces},
# a glob `*`, `[brackets]`, an unresolved `$VAR` mid-path, an absolute or `~`
# path, or a URL. Normalised before lookup: a leading `./`, a leading `$VAR/` or
# `${VAR}/`, the consumer-install prefix `node_modules/@jenga-ai/agent/`, and
# the generated-mirror prefixes `.claude/` / `.agents/`. A reference is looked up
# relative to its own skill directory, then relative to <root>; a bare script
# name is also looked up in <root>/scripts/, <root>/hooks/ and every
# skills/*/scripts/. Never treated as references: paragraphs that say a script "no
# longer exists" / "was retired" (a retirement notice names a script precisely
# because it is gone), the placeholder stems foo, bar, baz, example, sample and
# myscript (illustrations, not real files), and a bare `.sh` extension.
#
# ---------------------------------------------------------------------------
# OUTPUT
# ---------------------------------------------------------------------------
# stdout: one JSON object per finding (JSONL), fields:
#   skill        directory name, e.g. "j-deep-dive"
#   check        the check id from the lists above
#   severity     "critical" | "minor"
#   feature      what is affected, e.g. "j-deep-dive: agent delegation"
#   error        what is wrong, concretely
#   consequences what breaks because of it
# Fields never contain a newline. stderr: a pass/fail summary. stdout stays
# empty when there are no findings, so it composes with render-error-table.sh.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   smoke-test-skills.sh [--root <dir>] [--critical-only]
#
#   --root <dir>      repository (or installed package) root holding skills/,
#                     agents/ and templates/. Default: three levels above this
#                     script, which is correct both in this repo and in
#                     node_modules/@jenga-ai/agent.
#   --critical-only   print only critical findings on stdout (the summary on
#                     stderr still counts both).
#
# Exit codes: 0 no critical finding; 1 at least one critical finding;
#             2 usage error or missing dependency (jq).
# Read-only: it never writes to the tree it inspects.
# ---------------------------------------------------------------------------

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
CRITICAL_ONLY=0

usage() {
  echo "Usage: $(basename "$0") [--root <dir>] [--critical-only]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      if [ $# -lt 2 ]; then usage; exit 2; fi
      ROOT="$2"; shift 2 ;;
    --critical-only) CRITICAL_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "smoke-test-skills: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "smoke-test-skills: jq is required but was not found" >&2
  exit 2
fi
if [ ! -d "$ROOT/skills" ]; then
  echo "smoke-test-skills: no skills/ directory under $ROOT" >&2
  exit 2
fi
ROOT="$(cd "$ROOT" && pwd)"

CRITICAL=0
MINOR=0
CHECKED=0
EXEMPT=0

# emit <severity> <check> <skill> <feature> <error> <consequences>
emit() {
  local sev="$1" check="$2" skill="$3" feature="$4" error="$5" cons="$6"
  if [ "$sev" = "critical" ]; then CRITICAL=$((CRITICAL + 1)); else MINOR=$((MINOR + 1)); fi
  if [ "$CRITICAL_ONLY" -eq 1 ] && [ "$sev" != "critical" ]; then return 0; fi
  jq -nc --arg skill "$skill" --arg check "$check" --arg sev "$sev" \
    --arg feature "$feature" --arg error "$error" --arg cons "$cons" \
    '{skill:$skill, check:$check, severity:$sev, feature:$feature, error:$error, consequences:$cons}'
}

# parse_frontmatter <file>: prints TAB-separated records ERR/NAME/DESC/AGENT.
parse_frontmatter() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function unq(s,   q) {
      s = trim(s)
      q = substr(s, 1, 1)
      if ((q == "\"" || q == "\047") && length(s) >= 2 && substr(s, length(s), 1) == q) {
        return substr(s, 2, length(s) - 2)
      }
      if (q != "\"" && q != "\047") { sub(/[ \t]+#.*$/, "", s) }
      return s
    }
    { sub(/\r$/, "") }
    NR == 1 {
      if ($0 != "---") { err = "frontmatter does not open with a --- line on line 1"; done = 1; exit }
      state = 1; next
    }
    state == 1 {
      if ($0 == "---") { closed = 1; done = 1; exit }
      if ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*#/) next
      if ($0 ~ /^[A-Za-z_][A-Za-z0-9_.-]*:([ \t]|$)/) {
        key = $0; sub(/:.*$/, "", key)
        val = $0; sub(/^[^:]*:[ \t]*/, "", val)
        in_meta = (key == "metadata")
        block = (val ~ /^[|>][-+0-9]*[ \t]*(#.*)?$/)
        if (val != "" && val !~ /^["\047|>\[{&*!%@`]/) {
          plain = val; sub(/[ \t]+#.*$/, "", plain)
          if (plain ~ /: /) {
            if (err == "") err = "line " NR ": plain value of `" key "` contains \": \" (YAML mapping error); quote it"
          }
        }
        if (key == "name") name = unq(val)
        else if (key == "description") { desc = block ? "" : unq(val); in_desc = 1 }
        else if (key == "prefered_agent") agent = unq(val)
        if (key != "description") in_desc = 0
        next
      }
      if ($0 ~ /^[ \t]+/) {
        line = trim($0)
        if (in_desc) { desc = (desc == "" ? line : desc " " line) }
        if (in_meta && line ~ /^prefered_agent:/) { v = line; sub(/^prefered_agent:[ \t]*/, "", v); agent = unq(v) }
        next
      }
      if ($0 ~ /^-([ \t]|$)/) next
      if (err == "") err = "line " NR " is not a `key: value` pair, a list item or an indented continuation: " $0
      next
    }
    END {
      if (!done) { if (err == "") err = "frontmatter has no closing --- line" }
      else if (!closed && err == "") err = "frontmatter has no closing --- line"
      if (err != "") print "ERR\t" err
      print "NAME\t" name
      print "DESC\t" desc
      print "AGENT\t" agent
    }
  ' "$1"
}

# body_of <file>: everything after the frontmatter (or the whole file when there is none).
body_of() {
  awk '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 == "---") { infm = 1; next } else { plain = 1 } }
    plain { print; next }
    infm { if ($0 == "---") { infm = 0; after = 1 } ; next }
    after { print }
  ' "$1"
}

# extract_refs <file>: prints "sh<TAB>token" / "asset<TAB>token" for candidate references.
# shellcheck disable=SC2016  # the single-quoted sed program holds a literal $VAR on purpose
extract_refs() {
  body_of "$1" \
    | awk -v RS= -v ORS='\n\n' '$0 !~ /no longer exists?|was retired|retired by/' \
    | sed -E -e 's/\$\{[A-Za-z_][A-Za-z0-9_]*\}/$VAR/g' \
             -e 's/<[^<>[:space:]]*>/@@DYN@@/g' \
             -e 's/\{[^{}]*\}/@@DYN@@/g' \
    | tr '[:space:]`"'"'"'(),;|=<>&:' '\n' \
    | sed -E -e 's/^[*\\]+//' -e 's/[*.,\\]+$//' \
    | grep -E '\.sh$|(^|/)(assets|templates)/' \
    | sort -u \
    | while IFS= read -r tok; do
        stem="${tok##*/}"; stem="${stem%%.*}"
        case "$stem" in foo|bar|baz|example|sample|myscript) continue ;; esac
        case "$tok" in
          *@@DYN@@*|*'*'*|*'['*|*']'*|*'{'*|*'}'*|/*|'~'*|http*|-*) continue ;;
        esac
        case "$tok" in
          .sh|*/.sh) continue ;;
          *.sh) printf 'sh\t%s\n' "$tok" ;;
          *) printf 'asset\t%s\n' "$tok" ;;
        esac
      done
}

# normalise_ref <token>: sets REF (relative path) and VARPFX (1 when it came with a $VAR/ prefix);
# returns 1 when the token is dynamic or otherwise not checkable.
normalise_ref() {
  local t="$1"
  VARPFX=0
  t="${t#./}"
  if [[ "$t" =~ ^\$[A-Za-z_][A-Za-z0-9_]*/(.*)$ ]]; then
    t="${BASH_REMATCH[1]}"; VARPFX=1
  fi
  case "$t" in *'$'*) return 1 ;; esac
  t="${t#node_modules/@jenga-ai/agent/}"
  t="${t#@jenga-ai/agent/}"
  t="${t#jenga-ai/agent/}"
  t="${t#.claude/}"
  t="${t#.agents/}"
  t="${t#./}"
  [ -n "$t" ] || return 1
  REF="$t"
  return 0
}

# resolve_ref <skill_dir> <kind>: succeeds with FOUND set when REF exists somewhere sensible.
resolve_ref() {
  local sdir="$1" kind="$2" base cand
  FOUND=""
  for base in "$sdir" "$ROOT"; do
    cand="$base/$REF"
    if [ "$kind" = "sh" ]; then
      [ -f "$cand" ] && { FOUND="$cand"; return 0; }
    else
      [ -e "$cand" ] && { FOUND="$cand"; return 0; }
    fi
  done
  if [ "$kind" = "sh" ] && [[ "$REF" != */* ]]; then
    for cand in "$ROOT/scripts/$REF" "$ROOT/hooks/$REF"; do
      [ -f "$cand" ] && { FOUND="$cand"; return 0; }
    done
    for cand in "$ROOT"/skills/*/scripts/"$REF"; do
      [ -f "$cand" ] && { FOUND="$cand"; return 0; }
    done
  fi
  return 1
}

# canonical_name <dir>: prints the expected frontmatter name, or nothing when the directory is not canonical.
canonical_name() {
  case "$1" in
    j-*) printf 'j.%s\n' "${1#j-}" ;;
    jenga|jenga-permission-level|jenga-config) printf 'j.%s\n' "$1" ;;
  esac
}

check_skill() {
  local dir="$1" sdir="$ROOT/skills/$1" skill_md="$ROOT/skills/$1/SKILL.md"
  local key val fm_err="" name="" desc="" agent="" expected alnum
  local kind tok seen_syntax=""

  if [ ! -f "$skill_md" ]; then
    if [ "$dir" = "index" ]; then
      EXEMPT=$((EXEMPT + 1))
      return 0
    fi
    CHECKED=$((CHECKED + 1))
    emit critical skill-md-missing "$dir" "$dir: skill definition" \
      "skills/$dir/ has no SKILL.md" \
      "The skill cannot be loaded or invoked; its slash command and routing entry resolve to nothing."
    return 0
  fi
  CHECKED=$((CHECKED + 1))

  # Check 1: frontmatter parses; name and description present.
  while IFS=$'\t' read -r key val; do
    case "$key" in
      ERR) fm_err="$val" ;;
      NAME) name="$val" ;;
      DESC) desc="$val" ;;
      AGENT) agent="$val" ;;
    esac
  done < <(parse_frontmatter "$skill_md")

  if [ -n "$fm_err" ]; then
    emit critical frontmatter-unparsable "$dir" "$dir: frontmatter" \
      "SKILL.md frontmatter does not parse: $fm_err" \
      "The skill's name and description cannot be read, so it is not registered or routable."
  fi
  if [ -z "$name" ]; then
    emit critical name-missing "$dir" "$dir: skill name" \
      "SKILL.md frontmatter has no name" \
      "The skill has no identifier, so it cannot be invoked by name or allow-listed."
  fi
  if [ -z "$desc" ]; then
    emit minor description-missing "$dir" "$dir: skill description" \
      "SKILL.md frontmatter has no description" \
      "The skill loads, but listings and routing show a blank description."
  else
    alnum="$(printf '%s' "$desc" | tr -cd '[:alnum:]')"
    if [ "${#alnum}" -lt 3 ]; then
      emit minor description-trivial "$dir" "$dir: skill description" \
        "description is a placeholder, not a sentence: \"$desc\"" \
        "The skill loads, but listings and routing show a meaningless description."
    fi
  fi

  # Check 2: name matches the directory's canonical form.
  if [ -n "$name" ]; then
    expected="$(canonical_name "$dir")"
    if [ -z "$expected" ]; then
      emit critical name-dir-mismatch "$dir" "$dir: skill naming" \
        "directory skills/$dir/ is not in the canonical j-<name> form (and is not a permanent exception)" \
        "The directory-resolved slash form /$dir does not match any canonical identifier; the skill is stranded."
    elif [ "$name" != "$expected" ]; then
      emit critical name-dir-mismatch "$dir" "$dir: skill naming" \
        "frontmatter name is \"$name\" but directory skills/$dir/ requires \"$expected\"" \
        "The skill's invocation name and its directory disagree, so routing and the allow-list guard resolve it differently or not at all."
    fi
  fi

  # Check 3: prefered_agent resolves.
  if [ -n "$agent" ] && [ ! -f "$ROOT/agents/$agent.md" ]; then
    emit critical agent-unresolved "$dir" "$dir: agent delegation" \
      "metadata.prefered_agent is \"$agent\" but agents/$agent.md does not exist" \
      "Delegating execution to the preferred agent fails when the skill runs; it cannot hand off to its agent."
  fi

  # Checks 4 and 5: referenced scripts and assets.
  while IFS=$'\t' read -r kind tok; do
    [ -n "$tok" ] || continue
    normalise_ref "$tok" || continue
    if resolve_ref "$sdir" "$kind"; then
      if [ "$kind" = "sh" ]; then
        case "$seen_syntax" in *"|$FOUND|"*) continue ;; esac
        seen_syntax="$seen_syntax|$FOUND|"
        if ! bash -n "$FOUND" 2>/dev/null; then
          emit critical script-syntax "$dir" "$dir: script $REF" \
            "$REF fails bash -n (syntax error)" \
            "The script aborts before doing any work, so every step that calls it fails."
        fi
      fi
    else
      if [ "$kind" = "sh" ]; then
        if [[ "$REF" == */* ]] || [ "$VARPFX" -eq 1 ]; then
          emit critical script-missing "$dir" "$dir: script $REF" \
            "SKILL.md references $REF, which does not exist" \
            "Any step that calls this script fails at run time, so the skill cannot complete that step."
        else
          emit minor script-unresolved-mention "$dir" "$dir: script $REF" \
            "SKILL.md mentions $REF in prose, but no such script exists in the repository" \
            "None if it names a script of the user's project; otherwise a stale mention."
        fi
      else
        emit critical asset-missing "$dir" "$dir: asset $REF" \
          "SKILL.md references $REF, which does not exist" \
          "Any step that reads this file fails at run time, so the skill cannot produce its output from it."
      fi
    fi
  done < <(extract_refs "$skill_md" | sort -u)
}

# The never-public rule (name set, regexes, classification) lives in one shared script so check 6 and the
# mirror-time guard cannot disagree. Located in the repo (<root>/scripts), an installed .claude/.agents tree
# (sibling scripts/) or an npm install (node_modules/@jenga-ai/agent/scripts).
NEVER_PUBLIC_LIB=""
for _cand in "$SELF_DIR/../../../scripts/never-public-refs.sh" "$ROOT/scripts/never-public-refs.sh" \
             "$SELF_DIR/../../../node_modules/@jenga-ai/agent/scripts/never-public-refs.sh" \
             "$ROOT/node_modules/@jenga-ai/agent/scripts/never-public-refs.sh"; do
  if [ -f "$_cand" ]; then NEVER_PUBLIC_LIB="$_cand"; break; fi
done
if [ -z "$NEVER_PUBLIC_LIB" ]; then
  echo "smoke-test-skills: scripts/never-public-refs.sh not found" >&2
  exit 2
fi
# shellcheck source=/dev/null
. "$NEVER_PUBLIC_LIB"
never_public_load "$ROOT/.publicignore" "$ROOT/scripts/never-public-exemptions.conf"
# Fail closed on a malformed exemption file (E28_S21_T03), naming the entry.
if [ -n "$NEVER_PUBLIC_EXEMPT_ERROR" ]; then
  echo "smoke-test-skills: $NEVER_PUBLIC_EXEMPT_ERROR" >&2
  exit 2
fi

# Check 6. A skill that never ships is absent from every consumer install, so a
# shipped skill must not depend on one. Its own directory is not judged: it never
# ships, so nothing it says reaches a consumer.
check_never_public_refs() {
  local dir="$1" sdir="$ROOT/skills/$1" f rel hit lineno own_md
  [ -n "$NEVER_PUBLIC_NAMES" ] || return 0
  never_public_skill "$dir" && return 0
  while IFS= read -r f; do
    rel="${f#"$ROOT"/}"
    while IFS= read -r hit; do
      lineno="${hit%%:*}" text="${hit#*:}"
      # A declared exemption (scripts/never-public-exemptions.conf) silences a path hit only; the name loop below
      # is untouched.
      never_public_path_exempt "$rel" "$text" && continue
      own_md=0
      [ "$f" = "$sdir/SKILL.md" ] && own_md=1
      if [ "$(never_public_severity path "$text" "$own_md")" = minor ]; then
        emit minor never-public-mention "$dir" "$dir: never-public reference ($rel:$lineno)" \
          "$rel:$lineno is a comment that points into a skill directory that is never shipped" \
          "Comments do not run, so nothing breaks; the reference is stale documentation."
      else
        emit critical never-public-path "$dir" "$dir: never-public reference ($rel:$lineno)" \
          "$rel:$lineno points into a skill directory that is never shipped" \
          "The path does not exist in a consumer install, so any step that uses it fails."
      fi
    done < <(grep -InE "$NEVER_PUBLIC_PATH_RE" "$f" 2>/dev/null)
    while IFS= read -r hit; do
      lineno="${hit%%:*}"
      emit minor never-public-mention "$dir" "$dir: never-public reference ($rel:$lineno)" \
        "$rel:$lineno names a skill that is never shipped" \
        "A consumer has no such skill: a step that invokes it fails, while a prose mention is only stale."
    done < <(grep -InE "$NEVER_PUBLIC_NAME_RE" "$f" 2>/dev/null)
  done < <({ [ -f "$sdir/SKILL.md" ] && printf '%s\n' "$sdir/SKILL.md"; find "$sdir/scripts" -type f 2>/dev/null; })
}

for d in "$ROOT"/skills/*/; do
  [ -d "$d" ] || continue
  check_skill "$(basename "$d")"
  check_never_public_refs "$(basename "$d")"
done

RESULT="PASS"
[ "$CRITICAL" -eq 0 ] || RESULT="FAIL"
{
  echo "Skill Smoke Test"
  echo "================"
  echo "Skills checked: $CHECKED ($EXEMPT exempt: not a skill)"
  echo "Findings: $CRITICAL critical, $MINOR minor"
  echo "Result: $RESULT"
} >&2

[ "$CRITICAL" -eq 0 ]
