#!/usr/bin/env bats
#
# A consumer install has no skills/j-mirror-public/assets/config.json, because that skill never ships. The missing-config
# case must therefore be a clean skip (warning on stderr, exit 0, empty stdout) so that mark-deployed.sh reads it as
# "nothing to reconcile" rather than failing the deploy step.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
  FIXTURE="$BATS_TEST_TMPDIR/consumer"
  mkdir -p "$FIXTURE/scripts"
  git -C "$FIXTURE" init -q
  cp "$REPO_ROOT/scripts/compute-deploy-reconcile.sh" "$FIXTURE/scripts/"
}

@test "missing mirror config is a clean skip: warning on stderr, exit 0, empty stdout" {
  run --separate-stderr bash "$FIXTURE/scripts/compute-deploy-reconcile.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"config not found"* ]]
  [[ "$stderr" == *"nothing to reconcile"* ]]
}
