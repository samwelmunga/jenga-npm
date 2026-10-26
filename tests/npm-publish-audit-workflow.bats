#!/usr/bin/env bats
#
# Static checks for the dependency-audit gate in .github/workflows/npm-publish.yml (epic E85, story E85_S04,
# task E85_S04_T01).
#
# The workflow publishes the npm package. The task added one job, `audit`, and made `publish` depend on it
# (`needs: audit`) without changing anything else in the release path. It cannot be executed here (it needs the
# registry, OIDC and a GitHub runner), so this file pins what can be pinned by reading it: valid YAML; the audit
# job's least-privilege shape (job-level contents: read, no id-token, no secrets, no token, no registry-url);
# its actions pinned to a commit SHA; its fail-closed audit step; and, above all, that the release path itself
# is unchanged.
#
# Baseline of the release path. The pre-change text of the workflow-level header (comment, name, triggers,
# permissions), of the `publish` job (minus its single new line `needs: audit`) and of the `stage` job was
# recorded from `git show 00caa1c6:.github/workflows/npm-publish.yml` and is pinned below as sha256 digests of
# the text segment, trailing whitespace stripped. Any edit to the OIDC permissions, registry-url, the provenance
# flag, a publish step or the stage job changes a digest and fails the case. A deliberate future change to
# those parts must update the digest in the same commit, which is the point.
#
# No network, no npm, no writes. Nothing here runs the audit.
#
# Mirror rule (.publicignore header: "a test may never outlive its subject in the mirror"). The subjects, the
# workflow file, scripts/audit-deps.sh, project/configs/audit-config.json, .github/workflows/dependency-audit.yml
# and scripts/check-publicignore-match.sh, are all not blocklisted, so this file ships with them. The mirror
# surface case skips where .publicignore, rsync or the helper is absent rather than guess.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WF="$REPO_ROOT/.github/workflows/npm-publish.yml"
SIBLING="$REPO_ROOT/.github/workflows/dependency-audit.yml"
PUBLICIGNORE="$REPO_ROOT/.publicignore"
HELPER="$REPO_ROOT/scripts/check-publicignore-match.sh"

# sha256 of the pre-change text segments (see header).
BASE_HEADER="ca47beb1b7412acb37d0fddf5d7f76bd3e721f79a51b9351e240d41650e270b7"
BASE_PUBLISH="59ee2898b765a93e588dbe07ca4cb40dea1b2eddc6abe4ff87d969714005f197"
BASE_STAGE="3148b5f8b7e2db028dd09e24fede98216c8049db12610b0d296ec3e176260509"

setup() {
  [ -f "$WF" ] || { echo "workflow not found: $WF" >&2; return 1; }
}

# py <python-source>: run Python 3 with the parsed workflow and its text segments available.
#   wf       the parsed workflow         audit/publish/stage   the parsed jobs
#   seg      {"header", "audit", "publish", "stage"}: raw text segments (a job runs from its "  <name>:" line to
#            the next job line; "header" is everything before "jobs:"), trailing whitespace stripped
#   sha(s)   hex sha256 of a string      NL     a newline
# The source is passed as an argument and spliced into the heredoc unexpanded, so dollar signs in it are literal.
py() {
  command -v python3 >/dev/null 2>&1 || skip "python3 is not available"
  python3 -c 'import yaml' 2>/dev/null || skip "python3 has no yaml module"
  python3 - "$WF" <<PY
import sys, re, yaml, hashlib
WF = sys.argv[1]
text = open(WF).read()
wf = yaml.safe_load(text)
audit, publish, stage = wf["jobs"]["audit"], wf["jobs"]["publish"], wf["jobs"]["stage"]
NL = chr(10)
def sha(s):
    return hashlib.sha256(s.encode()).hexdigest()
lines = text.split(NL)
jobs_at = lines.index("jobs:")
seg = {"header": NL.join(lines[:jobs_at]).rstrip()}
starts = [(i, re.match(r"^  ([a-z]+):\$", l).group(1)) for i, l in enumerate(lines)
          if i > jobs_at and re.match(r"^  ([a-z]+):\$", l)]
for n, (i, name) in enumerate(starts):
    end = starts[n + 1][0] if n + 1 < len(starts) else len(lines)
    seg[name] = NL.join(lines[i:end]).rstrip()
$1
PY
}

@test "the workflow is valid YAML and defines the audit, publish and stage jobs" {
  py 'assert set(wf["jobs"]) == {"audit", "publish", "stage"}, sorted(wf["jobs"])'
}

@test "the audit job's uses: references are pinned to a 40-character commit SHA with a version comment" {
  py '
uses = [s["uses"] for s in audit["steps"] if "uses" in s]
assert len(uses) == 2, uses
for u in uses:
    assert re.match(r"^[A-Za-z0-9._/-]+@[0-9a-f]{40}$", u), "unpinned: " + u
n = 0
for line in seg["audit"].split(NL):
    if re.match(r"^[ -]*uses:", line):
        n += 1
        assert re.search(r"@[0-9a-f]{40} # v[0-9]+$", line), "no version comment: " + line
assert n == 2, n
'
}

@test "the audit job uses the same action SHAs as dependency-audit.yml" {
  [ -f "$SIBLING" ] || skip "dependency-audit.yml is absent"
  local act sha
  for act in actions/checkout actions/upload-artifact; do
    sha="$(grep -oE "${act}@[0-9a-f]{40}" "$SIBLING" | head -n 1)"
    [ -n "$sha" ] || { echo "no pinned $act in dependency-audit.yml" >&2; false; }
    grep -Fq -- "uses: $sha # v4" "$WF" || { echo "audit job does not use $sha" >&2; false; }
  done
}

@test "the audit job has job-level permissions contents: read only, no id-token and no write" {
  py '
assert audit.get("permissions") == {"contents": "read"}, audit.get("permissions")
assert "id-token" not in seg["audit"], "id-token in the audit job"
'
}

@test "the audit job holds no secret, token, registry-url or setup-node step" {
  py '
body = seg["audit"]
for needle in ("secrets.", "NODE_AUTH_TOKEN", "NPM_TOKEN", "registry-url", "setup-node", "GITHUB_TOKEN", "id-token"):
    assert needle not in body, needle + " in the audit job"
assert "env" not in audit and not any("env" in s for s in audit["steps"]), "audit job sets env"
'
}

@test "the audit job carries the same if: as publish and publish needs it" {
  py '
assert audit["if"] == publish["if"], (audit["if"], publish["if"])
assert publish["needs"] == "audit", publish.get("needs")
assert "needs" not in audit, "audit must not need another job"
'
}

@test "the publish job is unchanged apart from needs: audit" {
  py '
body = seg["publish"]
assert body.count("    needs: audit" + NL) == 1, "needs: audit not exactly once"
assert sha(body.replace("    needs: audit" + NL, "", 1)) == "'"$BASE_PUBLISH"'", "publish job text changed"
# Readable restatement of the parts that must never move.
assert publish["if"] == "${{ github.event.inputs.mode == " + chr(39) + "publish" + chr(39) + " || github.event.inputs.mode == " + chr(39) + chr(39) + " }}"
runs = [s.get("run", "") for s in publish["steps"]]
assert "npm publish --provenance --access public --tag latest" in runs
assert "npm ci" in runs and "npm ci --prefix project/app" in runs
setup = [s for s in publish["steps"] if str(s.get("uses", "")).startswith("actions/setup-node@")]
assert setup and setup[0]["with"]["registry-url"] == "https://registry.npmjs.org", setup
'
}

@test "the workflow-level header, triggers and OIDC permissions are unchanged" {
  py '
assert sha(seg["header"]) == "'"$BASE_HEADER"'", "workflow header text changed"
assert seg["header"].startswith("# Generated by /publish npm-ci pipeline"), seg["header"].split(NL)[0]
assert wf["permissions"] == {"id-token": "write", "contents": "write"}, wf["permissions"]
'
}

@test "the stage job is unchanged and has no needs" {
  py '
assert sha(seg["stage"]) == "'"$BASE_STAGE"'", "stage job text changed"
assert "needs" not in stage, "stage must stay ungated"
'
}

@test "the audit step runs scripts/audit-deps.sh --ci --json for . and project/app with no threshold of its own" {
  py '
runs = [s["run"] for s in audit["steps"] if "run" in s]
assert len(runs) == 1, runs
run = runs[0]
calls = [l for l in run.split(NL) if l.lstrip().startswith("bash scripts/audit-deps.sh")]
assert len(calls) == 1, calls
call = calls[0]
assert "--ci" in call and "--json" in call and "--dir" in call, call
assert "--threshold" not in run, "a second threshold in the workflow"
assert "--approved" not in run
assert ".:root" in run and "project/app:project-app" in run, "directories not both audited"
assert "|" not in call.replace("||", "") , "audit call is piped: " + call
assert "set -o pipefail" in run
'
}

@test "no live step runs npm audit directly" {
  py '
for s in audit["steps"]:
    run = s.get("run", "")
    for l in run.split(NL):
        assert not re.search(r"npm[ ]+(audit|a)([ ]|$)", l), "npm audit called: " + l
'
}

@test "the audit step fails closed: non-zero exit, unavailable, disabled, missing or unreadable JSON" {
  py '
run = [s["run"] for s in audit["steps"] if "run" in s][0]
assert "unavailable" in run and "disabled" in run, "status unavailable or disabled not handled"
assert ".status" in run, "the JSON status is not read"
assert "[ -s " in run, "a missing or empty JSON file is not handled"
assert "clean|findings)" in run, "only clean or findings may pass"
assert run.rstrip().endswith("exit " + chr(34) + "$failed" + chr(34)), "the step must end by exiting with the failure flag"
# one failing directory must not stop the loop before the other is audited
assert "set -e" not in run
'
}

@test "the audit step's exit handling, replayed against a stub audit-deps.sh, fails closed" {
  command -v python3 >/dev/null 2>&1 || skip "python3 is not available"
  python3 -c 'import yaml' 2>/dev/null || skip "python3 has no yaml module"
  command -v jq >/dev/null 2>&1 || skip "jq is not available"
  local work="$BATS_TEST_TMPDIR/replay"
  mkdir -p "$work/scripts"
  python3 - "$WF" "$work/step.sh" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
open(sys.argv[2], "w").write([s["run"] for s in wf["jobs"]["audit"]["steps"] if "run" in s][0])
PY
  stub() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$work/scripts/audit-deps.sh"; }
  replay() { (cd "$work" && bash -eo pipefail step.sh >/dev/null 2>&1); }

  stub 'echo "{\"status\":\"clean\",\"threshold\":\"high\",\"findings\":[]}"; exit 0'
  run replay; [ "$status" -eq 0 ]
  stub 'echo "{\"status\":\"findings\",\"threshold\":\"high\",\"findings\":[]}"; exit 1'
  run replay; [ "$status" -ne 0 ]
  stub 'echo "{\"status\":\"unavailable\",\"threshold\":\"high\"}"; exit 0'
  run replay; [ "$status" -ne 0 ]
  stub 'echo "{\"status\":\"disabled\",\"threshold\":\"high\"}"; exit 0'
  run replay; [ "$status" -ne 0 ]
  stub 'exit 4'
  run replay; [ "$status" -ne 0 ]
  stub 'echo "not json"; exit 0'
  run replay; [ "$status" -ne 0 ]
  stub 'exit 0'
  run replay; [ "$status" -ne 0 ]
  # the first directory failing must not hide the second one's JSON
  stub 'if [ "$2" = "." ]; then echo "{\"status\":\"findings\"}"; exit 1; fi; echo "{\"status\":\"clean\"}"; exit 0'
  run replay; [ "$status" -ne 0 ]
  [ -s "$work/audit-root.json" ]
  [ -s "$work/audit-project-app.json" ]
}

@test "the audit JSON is uploaded as an artifact even when the audit fails" {
  py '
ups = [s for s in audit["steps"] if str(s.get("uses", "")).startswith("actions/upload-artifact@")]
assert len(ups) == 1, ups
up = ups[0]
assert "always()" in str(up.get("if", "")), up.get("if")
assert up["with"].get("name"), up.get("with")
path = up["with"]["path"]
assert "audit-root.json" in path and "audit-project-app.json" in path, path
'
}

@test "mirror surface: the workflow, audit-deps.sh, audit-config.json and the helper are all PUBLIC" {
  [ -f "$PUBLICIGNORE" ] || skip ".publicignore is absent, so what ships cannot be told"
  [ -x "$HELPER" ] || [ -f "$HELPER" ] || skip "scripts/check-publicignore-match.sh is absent"
  command -v rsync >/dev/null 2>&1 || skip "rsync is not available"
  run bash "$HELPER" .github/workflows/npm-publish.yml .github/workflows/dependency-audit.yml \
    scripts/audit-deps.sh project/configs/audit-config.json scripts/check-publicignore-match.sh
  [ "$status" -eq 0 ]
  local p
  for p in .github/workflows/npm-publish.yml .github/workflows/dependency-audit.yml scripts/audit-deps.sh \
           project/configs/audit-config.json scripts/check-publicignore-match.sh; do
    printf '%s\n' "$output" | grep -Fxq "$(printf 'PUBLIC\t%s' "$p")" || { echo "not PUBLIC: $p" >&2; echo "$output" >&2; false; }
  done
}
