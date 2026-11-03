#!/usr/bin/env bats
#
# E80_S01_T08: `project/.workflows/` is blocklisted in .publicignore (project-local workflow
# definitions are per-project, never shipped) and documented in the public-mirror parity doc,
# mirroring the `project/.playbooks/` treatment (E28_S14_T01).
#
# Revised by the user decision of 2026-11-01: the blocklist now carries ONE exception,
# `project/.workflows/deploy-stage.json` and `project/.workflows/scripts/`, because that workflow is
# the public repo's own release workflow and must travel there by the mirror (the mirror is one-way
# and rsyncs with --delete --delete-excluded, so a hand-placed public copy would be deleted on the
# next run). The default is unchanged: every other project-local workflow stays private.
#
# Read-only: asserts against the repository's real .publicignore and parity doc; writes nothing.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PUBLICIGNORE="$REPO_ROOT/.publicignore"
PARITY_DOC="$REPO_ROOT/project/documentation/public-mirror-content-parity.md"
MATCHER="$REPO_ROOT/scripts/check-publicignore-match.sh"

# Line number of an exact-match line in .publicignore, or empty.
ignore_line() {
  grep -Fxn -e "$1" "$PUBLICIGNORE" | cut -d: -f1 | head -n 1
}

@test ".publicignore excludes the project-local workflow directory's contents" {
  run grep -Fxc -e '- project/.workflows/**' "$PUBLICIGNORE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test ".publicignore carries the deploy-stage include rules exactly once each" {
  for rule in \
    '+ project/.workflows/' \
    '+ project/.workflows/deploy-stage.json' \
    '+ project/.workflows/scripts/' \
    '+ project/.workflows/scripts/check-release-ready.sh' \
    '+ project/.workflows/scripts/npm-login-start.sh' \
    '+ project/.workflows/scripts/npm-login-wait.sh' \
    '+ project/.workflows/scripts/stage-wait-ready.sh' \
    '+ project/.workflows/scripts/st-test-run.sh' \
    '+ project/.workflows/scripts/finalize-release.sh'
  do
    run grep -Fxc -e "$rule" "$PUBLICIGNORE"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
  done
}

@test ".publicignore uses no scripts/ wildcard, so a new helper is private until named" {
  # A wildcard would ship every project-local workflow helper, including the private
  # ones: deploy-public-prep.sh drives /mirror-public and references the never-public
  # skills/j-mirror-public/scripts/release-prep.sh.
  run grep -Fc -e 'project/.workflows/scripts/***' "$PUBLICIGNORE"
  [ "$status" -ne 0 ]
}

@test ".publicignore puts every include rule before the exclude (rsync: first match wins)" {
  exclude_at="$(ignore_line '- project/.workflows/**')"
  [ -n "$exclude_at" ]
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    at="$(ignore_line "$rule")"
    [ -n "$at" ]
    [ "$at" -lt "$exclude_at" ]
  done < <(grep -E '^\+ project/\.workflows/' "$PUBLICIGNORE")
}

@test ".publicignore entry is preceded by a comment block explaining it" {
  line="$(ignore_line '+ project/.workflows/')"
  [ -n "$line" ]
  prev="$(sed -n "$((line - 1))p" "$PUBLICIGNORE")"
  [[ "$prev" == '#'* ]]
  run grep -F '# `project/.workflows/` is per-project' "$PUBLICIGNORE"
  [ "$status" -eq 0 ]
  run grep -F '# ONE EXCEPTION, user decision 2026-11-01' "$PUBLICIGNORE"
  [ "$status" -eq 0 ]
}

@test ".publicignore does not blocklist the shipped templates/workflows/ builtins" {
  run grep -Ex '/?templates/workflows/?.*|/?templates/?' "$PUBLICIGNORE"
  [ "$status" -ne 0 ]
}

@test "the real rsync matcher ships deploy-stage and keeps other project workflows private" {
  [ -x "$MATCHER" ] || skip "scripts/check-publicignore-match.sh is not available"

  for public in \
    'project/.workflows/deploy-stage.json' \
    'project/.workflows/scripts/check-release-ready.sh' \
    'project/.workflows/scripts/st-test-run.sh' \
    'project/.workflows/scripts/finalize-release.sh'
  do
    run bash "$MATCHER" "$public"
    [ "$status" -eq 0 ]
    [[ "$output" == *PUBLIC* ]]
  done

  for private in \
    'project/.workflows/deploy-public.json' \
    'project/.workflows/scripts/deploy-public-prep.sh' \
    'project/.workflows/epic-wrap-up-framework.json' \
    'project/.workflows/some-future-local.json' \
    'project/.workflows/scripts/some-future-helper.sh'
  do
    run bash "$MATCHER" "$private"
    [[ "$output" == *BLOCKED* ]]
  done
}

@test "parity doc mentions project/.workflows/, the deploy-stage exception, and that templates/workflows/ ships" {
  run grep -F 'project/.workflows/' "$PARITY_DOC"
  [ "$status" -eq 0 ]
  run grep -F 'templates/workflows/' "$PARITY_DOC"
  [ "$status" -eq 0 ]
  run grep -F '## Project-local workflows are private: `project/.workflows/`' "$PARITY_DOC"
  [ "$status" -eq 0 ]
  run grep -F 'deploy-stage' "$PARITY_DOC"
  [ "$status" -eq 0 ]
}
