#!/usr/bin/env bats
#
# Coverage for the catalog-wide skill smoke-test harness (E64_S01_T01):
# skills/j-smoke-test/scripts/smoke-test-skills.sh and its SKILL.md / registration.
#
# Two kinds of case:
#   - Synthetic skill trees built under BATS_TEST_TMPDIR with the harness's --root option. These cover each of the five
#     structural checks independently, the critical-versus-minor classification, the JSON-lines output and the exit
#     codes. Nothing here reads the real skills/ directory.
#   - Cases against the real catalog (run once, in setup_file), asserting the harness covers every skill directory and
#     reports no critical finding beyond the documented KNOWN_DEFECTS below.
#
# KNOWN_DEFECTS: genuine stale references in existing skills that the harness correctly reports. They are listed here
# rather than fixed in this task (they belong to other skills). A NEW critical finding on the real catalog fails the
# suite; fixing one of these makes it simply disappear (the check is "no critical outside this list", not equality), so
# remove the entry from the list when you fix the skill.

# shellcheck disable=SC2016
# SC2016: SKILL.md fixtures and jq programs hold literal $ and backticks, single-quoted on purpose.

bats_require_minimum_version 1.5.0

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
HARNESS="$REPO_ROOT/skills/j-smoke-test/scripts/smoke-test-skills.sh"
SKILL_DIR="$REPO_ROOT/skills/j-smoke-test"
SKILL_MD="$SKILL_DIR/SKILL.md"
ALLOW_LIST="$REPO_ROOT/lib/skill-allow-list.json"
BASH_BIN="$(command -v bash)"

# check|skill pairs that are known, genuine critical findings on the real catalog.
KNOWN_DEFECTS="
agent-unresolved|j-deep-dive
asset-missing|j-btw
asset-missing|jenga
script-missing|j-mirror-public
"

setup_file() {
  set +e
  "$BASH_BIN" "$HARNESS" > "$BATS_FILE_TMPDIR/real.jsonl" 2> "$BATS_FILE_TMPDIR/real.err"
  echo "$?" > "$BATS_FILE_TMPDIR/real.status"
  set -e
}

setup() {
  ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$ROOT/skills" "$ROOT/agents" "$ROOT/templates" "$ROOT/scripts"
  : > "$ROOT/agents/developer.md"
  : > "$ROOT/agents/scrum-master.md"
}

# --- helpers -------------------------------------------------------------------------------------------------------

# skill <dir>: writes skills/<dir>/SKILL.md from stdin.
skill() {
  mkdir -p "$ROOT/skills/$1"
  cat > "$ROOT/skills/$1/SKILL.md"
}

# healthy_skill <dir> <name>: a minimal, fully valid skill.
healthy_skill() {
  skill "$1" <<EOF
---
name: $2
description: A perfectly ordinary fixture skill.
---

# Fixture
EOF
}

# harness [args]: runs the harness over $ROOT; sets $status, $output (stdout, the findings) and $stderr (the summary).
harness() {
  run --separate-stderr "$BASH_BIN" "$HARNESS" --root "$ROOT" "$@"
}

# finding <check> <skill> <severity>: succeeds when the findings in $output hold exactly that finding.
finding() {
  printf '%s\n' "$output" | jq -e --arg c "$1" --arg s "$2" --arg v "$3" \
    'select(.check == $c and .skill == $s and .severity == $v)' > /dev/null
}

count_findings() {
  if [ -z "$output" ]; then echo 0; else printf '%s\n' "$output" | grep -c '^{'; fi
}

# --- a healthy tree ------------------------------------------------------------------------------------------------

@test "a healthy tree passes: exit 0, no findings, a PASS summary on stderr" {
  healthy_skill j-alpha j.alpha
  healthy_skill jenga j.jenga
  healthy_skill jenga-permission-level j.jenga-permission-level
  mkdir -p "$ROOT/skills/index/scripts"
  harness
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  assert_contains "$stderr" "Skills checked: 3 (1 exempt: not a skill)"
  assert_contains "$stderr" "Findings: 0 critical, 0 minor"
  assert_contains "$stderr" "Result: PASS"
}

@test "the three permanent exceptions are covered: index is exempt, jenga and jenga-permission-level are checked" {
  healthy_skill jenga j.jenga
  healthy_skill jenga-permission-level j.jenga-permission-level
  mkdir -p "$ROOT/skills/index"
  harness
  [ "$status" -eq 0 ]
  assert_contains "$stderr" "Skills checked: 2 (1 exempt: not a skill)"
  # A wrong name on an exception is still caught: they are covered, not skipped.
  healthy_skill jenga j.something-else
  harness
  [ "$status" -eq 1 ]
  finding name-dir-mismatch jenga critical
}

@test "index is exempt only while it has no SKILL.md; once it has one it is checked, and flagged as non-canonical" {
  skill index <<'EOF'
---
name: j.index
description: An index that grew a SKILL.md.
---
EOF
  harness
  [ "$status" -eq 1 ]
  assert_contains "$stderr" "Skills checked: 1 (0 exempt: not a skill)"
  finding name-dir-mismatch index critical
}

# --- check 1: SKILL.md, frontmatter, name, description -------------------------------------------------------------

@test "check 1: a directory with no SKILL.md is critical" {
  mkdir -p "$ROOT/skills/j-empty"
  harness
  [ "$status" -eq 1 ]
  finding skill-md-missing j-empty critical
}

@test "check 1: frontmatter that does not open on line 1 is critical" {
  skill j-nofm <<'EOF'
# No frontmatter at all
name: j.nofm
EOF
  harness
  [ "$status" -eq 1 ]
  finding frontmatter-unparsable j-nofm critical
  assert_output_contains "does not open with a --- line"
}

@test "check 1: frontmatter that never closes is critical" {
  skill j-open <<'EOF'
---
name: j.open
description: Never closed.
EOF
  harness
  [ "$status" -eq 1 ]
  finding frontmatter-unparsable j-open critical
  assert_output_contains "no closing --- line"
}

@test "check 1: a frontmatter line that is no key, list item or continuation is critical" {
  skill j-junk <<'EOF'
---
name: j.junk
this line is not yaml at all
description: Has junk above.
---
EOF
  harness
  [ "$status" -eq 1 ]
  finding frontmatter-unparsable j-junk critical
  assert_output_contains "line 3"
}

@test "check 1: an unquoted scalar containing a colon-space (YAML mapping error) is critical, a quoted one is fine" {
  skill j-colon <<'EOF'
---
name: j.colon
description: Does a thing: and then another thing.
---
EOF
  skill j-quoted <<'EOF'
---
name: j.quoted
description: "Does a thing: and then another thing."
---
EOF
  harness
  [ "$status" -eq 1 ]
  finding frontmatter-unparsable j-colon critical
  [ "$(count_findings)" -eq 1 ]
}

@test "check 1: block scalars, lists and nested metadata parse cleanly" {
  skill j-rich <<'EOF'
---
name: j.rich
description: >
  A folded description that
  runs over several lines.
metadata:
  prefered_agent: developer
keywords:
  - "one phrase"
  - another
examples:
  - "an example: with a colon, quoted"
---

# Rich
EOF
  harness
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check 1: a missing name is critical" {
  skill j-noname <<'EOF'
---
description: Has a description but no name.
---
EOF
  harness
  [ "$status" -eq 1 ]
  finding name-missing j-noname critical
}

@test "check 1: a missing description is minor, not critical, and does not fail the run" {
  skill j-nodesc <<'EOF'
---
name: j.nodesc
---
EOF
  harness
  [ "$status" -eq 0 ]
  finding description-missing j-nodesc minor
  assert_contains "$stderr" "Findings: 0 critical, 1 minor"
  assert_contains "$stderr" "Result: PASS"
}

@test "check 1: a placeholder description (fewer than 3 letters or digits) is minor" {
  skill j-placeholder <<'EOF'
---
name: j.placeholder
description: ">."
---
EOF
  harness
  [ "$status" -eq 0 ]
  finding description-trivial j-placeholder minor
}

# --- check 2: name versus directory --------------------------------------------------------------------------------

@test "check 2: the doubled j.j-<name> form is a critical mismatch" {
  healthy_skill j-beta j.j-beta
  harness
  [ "$status" -eq 1 ]
  finding name-dir-mismatch j-beta critical
  assert_output_contains 'requires \"j.beta\"'
}

@test "check 2: a name that belongs to a different directory is a critical mismatch" {
  healthy_skill j-gamma j.delta
  harness
  [ "$status" -eq 1 ]
  finding name-dir-mismatch j-gamma critical
}

@test "check 2: a bare, non-exception directory is not canonical and is critical" {
  healthy_skill stranded j.stranded
  harness
  [ "$status" -eq 1 ]
  finding name-dir-mismatch stranded critical
  assert_output_contains "not in the canonical j-<name> form"
}

@test "check 2: j.<name> in a j-<name> directory is clean" {
  healthy_skill j-ok j.ok
  harness
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- check 3: prefered_agent ---------------------------------------------------------------------------------------

@test "check 3: a prefered_agent naming a real agents file is clean" {
  skill j-agented <<'EOF'
---
name: j.agented
description: Delegates to a real agent.
metadata:
  prefered_agent: developer
---
EOF
  harness
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check 3: a prefered_agent with no agents file is critical, including the scrum_master underscore spelling" {
  skill j-ghost <<'EOF'
---
name: j.ghost
description: Delegates to an agent that is not there.
metadata:
  prefered_agent: scrum_master
---
EOF
  harness
  [ "$status" -eq 1 ]
  finding agent-unresolved j-ghost critical
  assert_output_contains 'agents/scrum_master.md does not exist'
}

@test "check 3: a skill with no prefered_agent is not checked for one" {
  healthy_skill j-plain j.plain
  harness
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- check 4: referenced scripts -----------------------------------------------------------------------------------

@test "check 4: a path-qualified script that exists and passes bash -n is clean" {
  mkdir -p "$ROOT/skills/j-run/scripts"
  printf '#!/usr/bin/env bash\necho hi\n' > "$ROOT/skills/j-run/scripts/go.sh"
  skill j-run <<'EOF'
---
name: j.run
description: Runs its own script.
---

Run `bash skills/j-run/scripts/go.sh` and then `$RUN_DIR/go.sh`.
EOF
  harness
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check 4: a path-qualified script that does not exist is critical" {
  skill j-lost <<'EOF'
---
name: j.lost
description: References a deleted script.
---

Run `bash skills/j-lost/scripts/deleted.sh` first.
EOF
  harness
  [ "$status" -eq 1 ]
  finding script-missing j-lost critical
  assert_output_contains "skills/j-lost/scripts/deleted.sh"
}

@test "check 4: a \$VAR-prefixed script that exists nowhere is critical; one in the skill's own scripts/ is clean" {
  mkdir -p "$ROOT/skills/j-var/scripts"
  printf '#!/usr/bin/env bash\ntrue\n' > "$ROOT/skills/j-var/scripts/present.sh"
  skill j-var <<'EOF'
---
name: j.var
description: Uses a variable-prefixed script path.
---

```bash
bash "$VAR_DIR/present.sh"
bash "$VAR_DIR/absent.sh"
```
EOF
  harness
  [ "$status" -eq 1 ]
  finding script-missing j-var critical
  assert_output_contains "absent.sh"
  assert_output_not_contains "present.sh"
}

@test "check 4: a referenced script with a syntax error is critical (bash -n)" {
  mkdir -p "$ROOT/skills/j-broken/scripts"
  printf '#!/usr/bin/env bash\nif then fi (\n' > "$ROOT/skills/j-broken/scripts/bad.sh"
  skill j-broken <<'EOF'
---
name: j.broken
description: Ships a script that does not parse.
---

Run `bash skills/j-broken/scripts/bad.sh`.
EOF
  harness
  [ "$status" -eq 1 ]
  finding script-syntax j-broken critical
}

@test "check 4: an unreferenced script with a syntax error is not this check's business" {
  mkdir -p "$ROOT/skills/j-quiet/scripts"
  printf 'if then fi (\n' > "$ROOT/skills/j-quiet/scripts/unused.sh"
  healthy_skill j-quiet j.quiet
  harness
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check 4: a bare script name in prose that resolves nowhere is minor, not critical" {
  skill j-prose <<'EOF'
---
name: j.prose
description: Mentions a script of the user's own project.
---

Then run your project's own start.sh.
EOF
  harness
  [ "$status" -eq 0 ]
  finding script-unresolved-mention j-prose minor
}

@test "check 4: a bare name is resolved in the repo scripts/, so a shared script is found" {
  printf '#!/usr/bin/env bash\ntrue\n' > "$ROOT/scripts/shared.sh"
  skill j-shared <<'EOF'
---
name: j.shared
description: Uses a shared script.
---

Run `shared.sh`.
EOF
  harness
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check 4: the node_modules/@jenga-ai/agent/ consumer prefix and the .claude/ mirror prefix are stripped before lookup" {
  printf '#!/usr/bin/env bash\ntrue\n' > "$ROOT/scripts/helper.sh"
  skill j-consumer <<'EOF'
---
name: j.consumer
description: Uses the consumer-install fallback path.
---

Run `bash "$([ -f scripts/helper.sh ] && echo scripts/helper.sh || echo node_modules/@jenga-ai/agent/scripts/helper.sh)"` or `.claude/scripts/helper.sh`.
EOF
  harness
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check 4: dynamic references are skipped: placeholders, globs, braces, absolute paths and example stems" {
  skill j-dynamic <<'EOF'
---
name: j.dynamic
description: Holds many things that only look like script references.
---

- `scripts/<name>.sh` and `skills/j-{x}/scripts/run.sh` and `scripts/*.sh`
- `/usr/local/bin/tool.sh` and `~/bin/mine.sh`
- if the task says create `scripts/foo.sh`, verify it exists
- an extension alone, such as `.sh`
EOF
  harness
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check 4: a paragraph announcing a script was retired is not a reference to it" {
  skill j-retired <<'EOF'
---
name: j.retired
description: Carries a retirement notice.
---

> `scripts/gone-generator.sh` was retired and no longer exists. Nothing to run.

Real content follows here.
EOF
  harness
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check 4: ... but the same script named in a paragraph that does not say so is still caught" {
  skill j-stale <<'EOF'
---
name: j.stale
description: Cites a deleted script as live.
---

> `scripts/gone-generator.sh` was retired and no longer exists.

This file is generated by `scripts/gone-generator.sh` on every release.
EOF
  harness
  [ "$status" -eq 1 ]
  finding script-missing j-stale critical
}

# --- check 5: referenced assets ------------------------------------------------------------------------------------

@test "check 5: an asset in the skill's own assets/ and a template at the repo root are clean" {
  mkdir -p "$ROOT/skills/j-assets/assets"
  : > "$ROOT/skills/j-assets/assets/format.md"
  : > "$ROOT/templates/THING_TEMPLATE.md"
  skill j-assets <<'EOF'
---
name: j.assets
description: Reads its assets.
---

Use `assets/format.md`, `skills/j-assets/assets/format.md` and `templates/THING_TEMPLATE.md`.
EOF
  harness
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check 5: an asset that does not exist is critical" {
  skill j-noasset <<'EOF'
---
name: j.noasset
description: Reads a file that is gone.
---

Read `assets/missing-format.md` for the layout.
EOF
  harness
  [ "$status" -eq 1 ]
  finding asset-missing j-noasset critical
  assert_output_contains "assets/missing-format.md"
}

@test "check 5: a template that does not exist is critical" {
  skill j-notemplate <<'EOF'
---
name: j.notemplate
description: Reads a template that is gone.
---

Fill in `templates/NOT_THERE_TEMPLATE.md`.
EOF
  harness
  [ "$status" -eq 1 ]
  finding asset-missing j-notemplate critical
}

@test "check 5: a relative ../j-other/assets path resolves against the skill's own directory, a stale ../other/ one does not" {
  mkdir -p "$ROOT/skills/j-other/assets"
  : > "$ROOT/skills/j-other/assets/shared.json"
  healthy_skill j-other j.other
  skill j-sibling <<'EOF'
---
name: j.sibling
description: Borrows a sibling skill's asset.
---

Use `../j-other/assets/shared.json` and the stale `../other/assets/shared.json`.
EOF
  harness
  [ "$status" -eq 1 ]
  [ "$(count_findings)" -eq 1 ]
  finding asset-missing j-sibling critical
  assert_output_contains '../other/assets/shared.json'
  assert_output_not_contains '../j-other/assets/shared.json'
}

# --- severity classification and structured output -----------------------------------------------------------------

@test "severity: minor findings alone never fail the run; a critical one does" {
  skill j-minor <<'EOF'
---
name: j.minor
---
EOF
  harness
  [ "$status" -eq 0 ]
  [ "$(count_findings)" -eq 1 ]
  mkdir -p "$ROOT/skills/j-major"
  harness
  [ "$status" -eq 1 ]
  [ "$(count_findings)" -eq 2 ]
  assert_contains "$stderr" "Findings: 1 critical, 1 minor"
  assert_contains "$stderr" "Result: FAIL"
}

@test "severity: --critical-only prints only critical findings but the summary still counts both" {
  skill j-minor <<'EOF'
---
name: j.minor
---
EOF
  mkdir -p "$ROOT/skills/j-major"
  harness --critical-only
  [ "$status" -eq 1 ]
  [ "$(count_findings)" -eq 1 ]
  finding skill-md-missing j-major critical
  assert_contains "$stderr" "Findings: 1 critical, 1 minor"
}

@test "output: every line is one JSON object with exactly skill, check, severity, feature, error, consequences" {
  mkdir -p "$ROOT/skills/j-major"
  healthy_skill j-beta j.j-beta
  skill j-minor <<'EOF'
---
name: j.minor
---
EOF
  harness
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '')" -eq 3 ]
  printf '%s\n' "$output" | jq -e -s '
    all(.[];
      ((keys | sort) == ["check","consequences","error","feature","severity","skill"])
      and (.severity == "critical" or .severity == "minor")
      and ([.feature, .error, .consequences] | all(type == "string" and length > 0))
      and ([.feature, .error, .consequences] | all(test("[|]") | not)))' > /dev/null
}

@test "output: the harness is read-only, the inspected tree is byte-identical afterwards" {
  mkdir -p "$ROOT/skills/j-run/scripts"
  printf '#!/usr/bin/env bash\ntrue\n' > "$ROOT/skills/j-run/scripts/go.sh"
  skill j-run <<'EOF'
---
name: j.run
description: Fixture.
---
Run `skills/j-run/scripts/go.sh`.
EOF
  local before after
  before="$(cd "$ROOT" && find . -type f -exec cksum {} + | sort)"
  harness
  after="$(cd "$ROOT" && find . -type f -exec cksum {} + | sort)"
  [ "$before" = "$after" ]
}

@test "usage: an unknown argument, a root with no skills/ and a dangling --root all exit 2 with a message" {
  run --separate-stderr "$BASH_BIN" "$HARNESS" --bogus
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "unknown argument"
  run --separate-stderr "$BASH_BIN" "$HARNESS" --root "$BATS_TEST_TMPDIR/nowhere"
  [ "$status" -eq 2 ]
  assert_contains "$stderr" "no skills/ directory"
  run --separate-stderr "$BASH_BIN" "$HARNESS" --root
  [ "$status" -eq 2 ]
}

# --- the real catalog ----------------------------------------------------------------------------------------------

@test "real catalog: completes with a pass/fail summary on stderr whose verdict matches the exit code" {
  [ -s "$BATS_FILE_TMPDIR/real.err" ]
  local err
  err="$(cat "$BATS_FILE_TMPDIR/real.err")"
  assert_contains "$err" "Skill Smoke Test"
  assert_contains "$err" "Skills checked:"
  assert_contains "$err" "Findings:"
  if [ "$(cat "$BATS_FILE_TMPDIR/real.status")" -eq 0 ]; then
    assert_contains "$err" "Result: PASS"
  else
    assert_contains "$err" "Result: FAIL"
  fi
}

@test "real catalog: every directory under skills/ is covered, the three bare-name exceptions included" {
  local dirs err checked exempt
  dirs="$(find "$REPO_ROOT/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  err="$(cat "$BATS_FILE_TMPDIR/real.err")"
  checked="$(printf '%s\n' "$err" | sed -n 's/^Skills checked: \([0-9]*\) (.*/\1/p')"
  exempt="$(printf '%s\n' "$err" | sed -n 's/^Skills checked: [0-9]* (\([0-9]*\) exempt.*/\1/p')"
  [ "$((checked + exempt))" -eq "$dirs" ]
  [ -d "$REPO_ROOT/skills/jenga" ]
  [ -d "$REPO_ROOT/skills/jenga-permission-level" ]
  [ -d "$REPO_ROOT/skills/index" ]
  # index has no SKILL.md and is the one exempt directory; the other two exceptions are checked.
  [ ! -f "$REPO_ROOT/skills/index/SKILL.md" ]
  [ "$exempt" -eq 1 ]
}

@test "real catalog: no critical finding beyond the documented known defects (no false positives against healthy skills)" {
  local found pair unexpected=""
  # In the public mirror skills/j-mirror-public is absent, so j-publish's reference to its mirror.sh cannot resolve there.
  if [ ! -d "$REPO_ROOT/skills/j-mirror-public" ]; then
    KNOWN_DEFECTS="$KNOWN_DEFECTS
script-missing|j-publish"
  fi
  found="$(jq -r 'select(.severity == "critical") | .check + "|" + .skill' "$BATS_FILE_TMPDIR/real.jsonl" | sort -u)"
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    if ! printf '%s\n' "$KNOWN_DEFECTS" | grep -qxF "$pair"; then
      unexpected="$unexpected $pair"
    fi
  done <<< "$found"
  if [ -n "$unexpected" ]; then
    echo "unexpected critical findings:$unexpected" >&2
    return 1
  fi
}

@test "real catalog: the harness's own skill and healthy neighbours report nothing critical" {
  run jq -e -s '[.[] | select(.severity == "critical") | .skill] | (index("j-smoke-test") == null) and (index("j-test") == null) and (index("j-commit") == null)' "$BATS_FILE_TMPDIR/real.jsonl"
  [ "$status" -eq 0 ]
}

@test "real catalog: every finding has the full structured shape" {
  run jq -e -s 'all(.[]; has("skill") and has("check") and has("severity") and has("feature") and has("error") and has("consequences"))' "$BATS_FILE_TMPDIR/real.jsonl"
  [ "$status" -eq 0 ]
}

# --- the skill and its registration --------------------------------------------------------------------------------

frontmatter() {
  awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside { print }' "$SKILL_MD"
}

@test "SKILL.md exists with name j.smoke-test, a description, keywords and examples" {
  [ -f "$SKILL_MD" ]
  local fm
  fm="$(frontmatter)"
  assert_contains "$fm" "name: j.smoke-test"
  assert_contains "$fm" "description: "
  assert_contains "$fm" "keywords:"
  assert_contains "$fm" "examples:"
  assert_not_contains "$fm" "j.j-smoke-test"
}

@test "the directory j-smoke-test, the frontmatter name j.smoke-test and the allow-listed identifier smoke-test agree" {
  [ -d "$REPO_ROOT/skills/j-smoke-test" ]
  run jq -e '.skills | index("smoke-test") != null' "$ALLOW_LIST"
  [ "$status" -eq 0 ]
  run jq -e '.skill_count == (.skills | length)' "$ALLOW_LIST"
  [ "$status" -eq 0 ]
}

@test "SKILL.md sequences the harness script and keeps the logic in the script" {
  local body
  body="$(cat "$SKILL_MD")"
  assert_contains "$body" "smoke-test-skills.sh"
  assert_contains "$body" "Structural, not functional"
  run grep -E '^(case|if \[|for [a-z]+ in)' "$SKILL_MD"
  [ "$status" -eq 1 ]
}

@test "CLAUDE.md, README.md, AGENTS.md and the site reference each carry the j-smoke-test entry once" {
  run grep -c '^| `j\.smoke-test` |' "$REPO_ROOT/CLAUDE.md"
  [ "$output" = "1" ]
  run grep -c '^| `j\.smoke-test` |' "$REPO_ROOT/README.md"
  [ "$output" = "1" ]
  run grep -c '^| `/j-smoke-test` |' "$REPO_ROOT/AGENTS.md"
  [ "$output" = "1" ]
  run grep -c '^#### `/j-smoke-test`' "$REPO_ROOT/site/reference/skills.md"
  [ "$output" = "1" ]
}

@test "the harness is executable, passes bash -n, and states its severity bar in the header" {
  [ -x "$HARNESS" ]
  run "$BASH_BIN" -n "$HARNESS"
  [ "$status" -eq 0 ]
  local header
  header="$(sed -n '1,/^set -/p' "$HARNESS")"
  assert_contains "$header" "SEVERITY BAR"
  assert_contains "$header" "critical"
  assert_contains "$header" "minor"
}
