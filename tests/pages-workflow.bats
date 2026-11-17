#!/usr/bin/env bats
# tests/pages-workflow.bats  (E70_S03_T01)
#
# Locks the shape of .github/workflows/pages.yml: it parses, it builds site/
# with Jekyll, it deploys with the official Pages actions, it grants the Pages
# permissions only to the deploy job, and it ships to the public mirror.
# Network-free: reads the YAML file and runs scripts/check-publicignore-match.sh.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/pages.yml"

yq_get() {
  python3 - "$WORKFLOW" "$1" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
# PyYAML parses the bare key `on` as boolean True.
if "on" not in doc and True in doc:
    doc["on"] = doc.pop(True)
val = eval("doc" + sys.argv[2])
print(val if not isinstance(val, (dict, list)) else __import__("json").dumps(val, sort_keys=True))
PY
}

@test "pages.yml parses as YAML" {
  run python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$WORKFLOW"
  [ "$status" -eq 0 ]
}

@test "triggers include workflow_dispatch and a push to main filtered to site/**" {
  run yq_get '["on"]'
  [[ "$output" == *'"workflow_dispatch"'* ]]
  run yq_get '["on"]["push"]["branches"]'
  [ "$status" -eq 0 ]
  [ "$output" = '["main"]' ]
  run yq_get '["on"]["push"]["paths"]'
  [[ "$output" == *'"site/**"'* ]]
}

@test "build job builds site/ with jekyll-build-pages and uploads the artifact" {
  run yq_get '["jobs"]["build"]["steps"]'
  [[ "$output" == *"actions/jekyll-build-pages@v1"* ]]
  [[ "$output" == *'"source": "./site"'* ]]
  [[ "$output" == *"actions/upload-pages-artifact@v3"* ]]
}

@test "deploy job uses deploy-pages and needs the build job" {
  run yq_get '["jobs"]["deploy"]["steps"]'
  [[ "$output" == *"actions/deploy-pages@v4"* ]]
  run yq_get '["jobs"]["deploy"]["needs"]'
  [ "$output" = "build" ]
}

@test "pages and id-token write permissions are granted to the deploy job only" {
  run yq_get '["jobs"]["deploy"]["permissions"]'
  [ "$output" = '{"id-token": "write", "pages": "write"}' ]
  run yq_get '["jobs"]["build"].get("permissions", "none")'
  [ "$output" = "none" ]
  run yq_get '["permissions"]'
  [ "$output" = '{"contents": "read"}' ]
}

@test "concurrency group is pages and never cancels an in-flight deploy" {
  run yq_get '["concurrency"]'
  [ "$output" = '{"cancel-in-progress": false, "group": "pages"}' ]
}

@test "the workflow file is not blocked by .publicignore (ships to the public mirror)" {
  [ -f "$REPO_ROOT/.publicignore" ]
  run bash "$REPO_ROOT/scripts/check-publicignore-match.sh" .github/workflows/pages.yml
  [ "$status" -eq 0 ]
  [[ "$output" == *"PUBLIC"*"pages.yml"* ]]
}
