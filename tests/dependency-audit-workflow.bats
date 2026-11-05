#!/usr/bin/env bats
#
# Static checks for .github/workflows/dependency-audit.yml (epic E85, story E85_S01, task E85_S01_T08).
#
# The workflow is public-facing CI: it is mirrored to the public jenga-npm repository and runs there on a weekly
# schedule. It cannot be executed here (it needs the registry and a GitHub runner), so this file pins what can
# be pinned by reading it: valid YAML, every action pinned to a commit SHA, least-privilege permissions and no
# secrets, the three triggers, a complete and existing matrix, every leg going through scripts/audit-deps.sh
# --ci (never a bare `npm audit`), and the artifact upload.
#
# No network, no npm, no writes. Nothing here runs the audit.
#
# Mirror rule (.publicignore header: "a test may never outlive its subject in the mirror"). The subjects, the
# workflow file and scripts/audit-deps.sh, both ship, and so does .publicignore, so this file ships with them.
# The matrix-completeness case needs .publicignore to know which lockfile-bearing directories are private
# (mcp/router/ is absent from the mirror); where .publicignore is absent it skips rather than guess.
#
# Blocklist model (deliberately simple): a directory counts as blocklisted when a non-comment .publicignore
# line, minus one optional trailing slash, equals that directory or one of its parent directories. Patterns
# with wildcards, "+"/"-" filter prefixes and negations are not interpreted. That is sufficient for the
# directory-shaped lines the blocklist uses for package directories (e.g. "mcp/router/"); a glob that ever
# hides a lockfile-bearing directory would need this helper extended (the case then fails loudly, listing the
# directory, rather than silently passing).

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/dependency-audit.yml"
PUBLICIGNORE="$REPO_ROOT/.publicignore"

setup() {
  [ -f "$WF" ] || { echo "workflow not found: $WF" >&2; return 1; }
}

# py <python-source>: run Python 3 with the parsed workflow available as `wf`, the matrix directories as `dirs`
# and the workflow path as WF. Output is shown by bats when the case fails.
py() {
  command -v python3 >/dev/null 2>&1 || skip "python3 is not available"
  python3 -c 'import yaml' 2>/dev/null || skip "python3 has no yaml module"
  python3 - "$WF" <<PY
import sys, yaml
WF = sys.argv[1]
wf = yaml.safe_load(open(WF))
# PyYAML (YAML 1.1) reads the bare key "on" as boolean True.
triggers = wf.get("on", wf.get(True))
job = wf["jobs"]["audit"]
matrix = job.get("strategy", {}).get("matrix", {})
dirs = [i["dir"] for i in matrix.get("include", [])] + list(matrix.get("dir", []))
steps = job["steps"]
$1
PY
}

# is_blocklisted <relative-dir>: 0 when .publicignore blocklists the directory or a parent of it.
is_blocklisted() {
  local d="$1" line
  [ "$d" = "." ] && return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*|'+ '*|'- '*|'!'*) continue ;; esac
    line="${line%/}"
    case "$line" in *'*'*|*'?'*|*'['*) continue ;; esac
    [ "$d" = "$line" ] && return 0
    case "$d" in "$line"/*) return 0 ;; esac
  done < "$PUBLICIGNORE"
  return 1
}

@test "the workflow is valid YAML" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is not available"
  python3 -c 'import yaml' 2>/dev/null || skip "python3 has no yaml module"
  run python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$WF"
  [ "$status" -eq 0 ]
}

@test "every uses: reference is pinned to a 40-character commit SHA" {
  local n=0 line ref
  while IFS= read -r line; do
    n=$((n + 1))
    ref="${line#*uses:}"
    ref="${ref%%#*}"
    ref="$(printf '%s' "$ref" | tr -d ' ')"
    printf '%s' "$ref" | grep -Eq '^[A-Za-z0-9._/-]+@[0-9a-f]{40}$' || { echo "unpinned: $line" >&2; false; }
  done < <(grep -E '^[[:space:]-]*uses:' "$WF")
  [ "$n" -ge 2 ]
}

@test "permissions is contents: read only, with no job-level override, no secrets and no id-token" {
  py '
assert wf.get("permissions") == {"contents": "read"}, wf.get("permissions")
assert "permissions" not in job, "job-level permissions override"
'
  run grep -n 'secrets\.' "$WF"
  [ "$status" -eq 1 ]
  run grep -n 'id-token' "$WF"
  [ "$status" -eq 1 ]
}

@test "triggers are schedule (one cron), workflow_dispatch and pull_request limited to the manifest paths" {
  py '
assert set(triggers) == {"schedule", "workflow_dispatch", "pull_request"}, sorted(triggers)
assert len(triggers["schedule"]) == 1 and triggers["schedule"][0].get("cron"), triggers["schedule"]
assert sorted(triggers["pull_request"]["paths"]) == ["**/package-lock.json", "**/package.json"], triggers["pull_request"]
'
}

@test "the matrix does not fail fast" {
  py 'assert job["strategy"]["fail-fast"] is False'
}

@test "every matrix directory exists and holds a package.json and a package-lock.json" {
  local out d
  out="$(py 'print("\n".join(dirs))')"
  [ -n "$out" ]
  while IFS= read -r d; do
    [ -d "$REPO_ROOT/$d" ] || { echo "missing directory: $d" >&2; false; }
    [ -f "$REPO_ROOT/$d/package.json" ] || { echo "no package.json: $d" >&2; false; }
    [ -f "$REPO_ROOT/$d/package-lock.json" ] || { echo "no package-lock.json: $d" >&2; false; }
  done <<< "$out"
}

@test "every lockfile-bearing, non-blocklisted package directory is in the matrix" {
  [ -f "$PUBLICIGNORE" ] || skip ".publicignore is absent, so which directories are private cannot be told"
  local listed d found missing=""
  listed="$(py 'print("\n".join(dirs))')"
  found="$(cd "$REPO_ROOT" && find . \( -name node_modules -o -name .claude -o -name .agents \
      -o -name .mirror-worktrees -o -name .tmp -o -name .git \) -prune \
      -o -name package-lock.json -print | sed -e 's|^\./||' -e 's|/\{0,1\}package-lock\.json$||' -e 's|^$|.|' | sort)"
  [ -n "$found" ]
  while IFS= read -r d; do
    is_blocklisted "$d" && continue
    printf '%s\n' "$listed" | grep -Fxq -- "$d" || missing="$missing $d"
  done <<< "$found"
  [ -z "$missing" ] || { echo "lockfile-bearing directories missing from the matrix:$missing" >&2; false; }
}

@test "no matrix directory is blocklisted in .publicignore" {
  [ -f "$PUBLICIGNORE" ] || skip ".publicignore is absent, so which directories are private cannot be told"
  local d
  while IFS= read -r d; do
    if is_blocklisted "$d"; then echo "blocklisted directory in the matrix: $d" >&2; false; fi
  done < <(py 'print("\n".join(dirs))')
}

@test "every leg audits through scripts/audit-deps.sh with --ci and --json, without masking its exit code" {
  py '
runs = [s["run"] for s in steps if "run" in s and "audit-deps.sh" in s["run"]]
assert runs, "no step invokes scripts/audit-deps.sh"
for r in runs:
    for line in r.splitlines():
        if "audit-deps.sh" not in line:
            continue
        assert "--ci" in line, line
        assert "--json" in line, line
        assert "--dir" in line, line
        assert "|" not in line and "|| true" not in line and "; true" not in line, "exit code masked: " + line
'
}

@test "no step runs npm audit directly" {
  # Comments may mention it; only live (non-comment) lines count.
  run bash -c "grep -vE '^[[:space:]]*#' \"\$1\" | grep -nE 'npm[[:space:]]+(audit|a)([[:space:]]|\$)'" _ "$WF"
  [ "$status" -eq 1 ]
}

@test "the audit JSON is uploaded as an artifact even when the leg fails" {
  py '
ups = [s for s in steps if str(s.get("uses", "")).startswith("actions/upload-artifact@")]
assert len(ups) == 1, ups
up = ups[0]
assert "always()" in str(up.get("if", "")), up.get("if")
assert up["with"].get("name") and up["with"].get("path"), up.get("with")
assert ".json" in up["with"]["path"], up["with"]["path"]
'
}
