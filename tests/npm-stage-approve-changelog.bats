#!/usr/bin/env bats
#
# Regression coverage for skills/j-publish/scripts/npm_stage_inspect.sh's
# cmd_approve changelog wiring (E22_S09_T08).
#
# Why this file exists
# ---------------------
# publish_deploy.sh's deploy path runs generate_release_notes.sh +
# finalize_changelog.sh after a successful deploy, so CHANGELOG.md always
# gains an entry. npm_stage_inspect.sh's cmd_approve (the `stage`->approve
# path used for staged npm releases, including the web-UI-approve fallback)
# never touched CHANGELOG.md at all -- confirmed live: CHANGELOG.md's last
# entry was v1.1.1 from 2026-08-28 while package.json was already at 3.5.0.
# This suite pins the fix: cmd_approve now reuses the same two scripts,
# unmodified, after a confirmed successful `npm stage approve`.
#
# Every test runs against a throwaway git repo under $BATS_TEST_TMPDIR that
# carries real, unmodified copies of npm_stage_inspect.sh and its sibling
# scripts (publish_common.sh, generate_release_notes.sh,
# finalize_changelog.sh, write_ledger_entry.sh) -- never this repository's
# own CHANGELOG.md or publish-history.json. A fake `npm` on PATH (pattern
# borrowed from tests/dashboard-launch.bats) fakes `stage view --json` and
# `stage approve` so these tests don't require a real npm staged release.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPTS_SRC="$REPO_ROOT/skills/j-publish/scripts"
TEMPLATE_SRC="$REPO_ROOT/templates/CHANGELOG_TEMPLATE.md"

STAGE_ID="stage-fixture-001"
PKG_VERSION="9.9.9"

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  TMP_REPO="$(cd "$BATS_TEST_TMPDIR/repo" && pwd -P)"

  mkdir -p "$TMP_REPO/skills/j-publish/scripts" "$TMP_REPO/templates" "$TMP_REPO/project/logs"
  for f in npm_stage_inspect.sh publish_common.sh generate_release_notes.sh finalize_changelog.sh write_ledger_entry.sh; do
    cp "$SCRIPTS_SRC/$f" "$TMP_REPO/skills/j-publish/scripts/$f"
    chmod +x "$TMP_REPO/skills/j-publish/scripts/$f"
  done
  cp "$TEMPLATE_SRC" "$TMP_REPO/templates/CHANGELOG_TEMPLATE.md"
  cp "$TEMPLATE_SRC" "$TMP_REPO/CHANGELOG.md"

  git -C "$TMP_REPO" init -q
  git -C "$TMP_REPO" config user.email test@example.com
  git -C "$TMP_REPO" config user.name "Test"
  git -C "$TMP_REPO" add -A
  git -C "$TMP_REPO" commit -q -m "chore: seed fixture repo"

  INSPECT="$TMP_REPO/skills/j-publish/scripts/npm_stage_inspect.sh"

  # Fake `npm` placed ahead of the real one on PATH -- logs its args instead
  # of calling the real staged-publishing registry API, so these tests don't
  # require a real npm >= 11.15.0 staged release. Fakes exactly the two
  # sub-commands cmd_approve issues: `stage view --json` and `stage approve`.
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
  : > "$NPM_LOG"
  FAKE_VIEW_JSON="$BATS_TEST_TMPDIR/view.json"
  cat > "$FAKE_VIEW_JSON" <<EOF
{"name":"fixture-pkg","version":"$PKG_VERSION"}
EOF
  APPROVE_FAIL_FLAG="$BATS_TEST_TMPDIR/approve-should-fail"
  rm -f "$APPROVE_FAIL_FLAG"

  cat > "$FAKE_BIN/npm" <<EOF
#!/usr/bin/env bash
echo "ARGS:\$*" >> "$NPM_LOG"
case "\$1 \$2" in
  "stage view")
    cat "$FAKE_VIEW_JSON"
    exit 0
    ;;
  "stage approve")
    if [ -f "$APPROVE_FAIL_FLAG" ]; then
      echo "npm ERR! stage approve failed (fixture)" >&2
      exit 1
    fi
    echo "+ approved (fixture)"
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$FAKE_BIN/npm"
  export PATH="$FAKE_BIN:$PATH"
  export NPM_LOG APPROVE_FAIL_FLAG

  HISTORY_FILE="$TMP_REPO/project/logs/publish-history.json"
}

# Seeds a passing stage_tested ledger entry for $STAGE_ID so the approve
# interlock (require_test_before_approve, defaulted true with no config)
# does not refuse the approve outright -- exercised by the success-path
# test only; the --force test deliberately leaves this unseeded.
seed_passing_test_ledger() {
  cat > "$HISTORY_FILE" <<EOF
[
  {"platform_state": "stage_tested", "stage_id": "$STAGE_ID", "result": "pass"}
]
EOF
}

@test "approve generates release notes and finalizes CHANGELOG.md after a successful npm stage approve" {
  seed_passing_test_ledger
  cd "$TMP_REPO" || return 1
  run "$INSPECT" approve "$STAGE_ID"
  [ "$status" -eq 0 ]

  changelog="$(cat "$TMP_REPO/CHANGELOG.md")"
  assert_contains "$changelog" "## [v$PKG_VERSION] —"
  assert_contains "$changelog" "chore: seed fixture repo"
  # A fresh, empty [Unreleased] section must be left above the finalized one.
  assert_contains "$changelog" "## [Unreleased]"

  run cat "$NPM_LOG"
  assert_output_contains "ARGS:stage view $STAGE_ID --json"
  assert_output_contains "ARGS:stage approve $STAGE_ID"
}

@test "approve writes an 'approved' ledger entry alongside the changelog finalization" {
  seed_passing_test_ledger
  cd "$TMP_REPO" || return 1
  run "$INSPECT" approve "$STAGE_ID"
  [ "$status" -eq 0 ]

  run jq -e --arg id "$STAGE_ID" \
    'any(.[]?; (.platform_state? // "") == "approved" and (.stage_id? // "") == $id)' \
    "$HISTORY_FILE"
  [ "$status" -eq 0 ]
}

@test "--dry-run leaves CHANGELOG.md and the ledger untouched" {
  seed_passing_test_ledger
  cd "$TMP_REPO" || return 1
  before="$(cat "$TMP_REPO/CHANGELOG.md")"
  ledger_before="$(cat "$HISTORY_FILE")"

  run "$INSPECT" approve "$STAGE_ID" --dry-run
  [ "$status" -eq 0 ]
  assert_output_contains "[dry-run] resolved command"

  after="$(cat "$TMP_REPO/CHANGELOG.md")"
  [ "$before" = "$after" ]
  ledger_after="$(cat "$HISTORY_FILE")"
  [ "$ledger_before" = "$ledger_after" ]

  # The real `npm stage approve` must never have been called under --dry-run.
  run cat "$NPM_LOG"
  assert_output_not_contains "stage approve"
}

@test "a failed npm stage approve does not touch CHANGELOG.md" {
  seed_passing_test_ledger
  : > "$APPROVE_FAIL_FLAG"
  cd "$TMP_REPO" || return 1
  before="$(cat "$TMP_REPO/CHANGELOG.md")"

  run "$INSPECT" approve "$STAGE_ID"
  [ "$status" -eq 3 ]
  assert_output_contains "npm stage approve failed"

  after="$(cat "$TMP_REPO/CHANGELOG.md")"
  [ "$before" = "$after" ]
}

@test "approve refuses without a passing test on record and no --force, leaving CHANGELOG.md untouched" {
  # No seed_passing_test_ledger call -- no passing stage_tested entry exists.
  cd "$TMP_REPO" || return 1
  before="$(cat "$TMP_REPO/CHANGELOG.md")"

  run "$INSPECT" approve "$STAGE_ID"
  [ "$status" -eq 4 ]
  assert_output_contains "approve refused"

  after="$(cat "$TMP_REPO/CHANGELOG.md")"
  [ "$before" = "$after" ]
  run cat "$NPM_LOG"
  assert_output_not_contains "stage approve"
}

@test "--force <reason> still approves and still finalizes CHANGELOG.md with no passing test on record" {
  # No seed_passing_test_ledger call -- --force must bypass the interlock,
  # not the changelog step, per this task's acceptance criteria.
  cd "$TMP_REPO" || return 1
  run "$INSPECT" approve "$STAGE_ID" --force "manual override for testing"
  [ "$status" -eq 0 ]

  changelog="$(cat "$TMP_REPO/CHANGELOG.md")"
  assert_contains "$changelog" "## [v$PKG_VERSION] —"

  run jq -e --arg id "$STAGE_ID" \
    'any(.[]?; (.platform_state? // "") == "approved" and (.stage_id? // "") == $id and (.reason? // "") == "manual override for testing")' \
    "$HISTORY_FILE"
  [ "$status" -eq 0 ]
}
