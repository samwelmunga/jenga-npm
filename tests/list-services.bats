#!/usr/bin/env bats
#
# Coverage for skills/j-connect/scripts/list-services.sh (E65_S02_T02).
#
# Descriptors are copies of the throwaway fixtures under tests/fixtures/connect/
# placed in per-test temp dirs; nothing is ever written into
# skills/j-connect/descriptors/. Only jq and the validator run; no tool is
# executed from a descriptor.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
LIST="$REPO_ROOT/skills/j-connect/scripts/list-services.sh"
FX="$REPO_ROOT/tests/fixtures/connect"

setup() {
  D1="$BATS_TEST_TMPDIR/d1"; D2="$BATS_TEST_TMPDIR/d2"
  mkdir -p "$D1" "$D2"
  cp "$FX/e2e/fakeservice.json" "$D1/fakeservice.json"
  cp "$FX/e2e/fake-prereq.json" "$D1/fake-prereq.json"
  # valid-no-mcp.json ships with id "fakeservice"; give it its own id so the
  # filename stem equals the id (the convention the runner's `requires` relies on).
  jq '.id = "nomcp-svc"' "$FX/descriptors/valid-no-mcp.json" > "$D1/nomcp-svc.json"
}

list() { run --separate-stderr bash "$LIST" "$@"; }
ids() { jq -r '.services | map(.id) | join(",")' <<<"$output"; }

@test "lists the descriptors sorted by id with correct mcp and requires" {
  list --descriptors-dir "$D1"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(ids)" = "fake-prereq,fakeservice,nomcp-svc" ]
  [ "$(jq -c '.services | map(.mcp)' <<<"$output")" = "[false,true,false]" ]
  [ "$(jq -c '.services[1].requires' <<<"$output")" = '["fake-prereq"]' ]
  [ "$(jq -c '.services[0].requires' <<<"$output")" = '[]' ]
  [ "$(jq -r '.services[1].file' <<<"$output")" = "$(cd "$D1" && pwd)/fakeservice.json" ]
  [ "$(jq -c '.skipped' <<<"$output")" = "[]" ]
  [ "$(jq -c '.services[0] | keys_unsorted' <<<"$output")" = '["id","name","file","mcp","requires","unresolved_requires"]' ]
}

@test "the picker is dynamic: one more descriptor file adds exactly one entry, nothing else changes" {
  list --descriptors-dir "$D1"
  before="$(ids)"
  n_before="$(jq '.services | length' <<<"$output")"
  sum_before="$(shasum "$LIST" | cut -d' ' -f1)"
  jq '.id = "extra-svc"' "$FX/descriptors/valid.json" > "$D1/extra-svc.json"
  list --descriptors-dir "$D1"
  [ "$status" -eq 0 ]
  [ "$(jq '.services | length' <<<"$output")" -eq $((n_before + 1)) ]
  [ "$(ids)" = "extra-svc,fake-prereq,fakeservice,nomcp-svc" ]
  [ "$(shasum "$LIST" | cut -d' ' -f1)" = "$sum_before" ]
  [ -n "$before" ]
}

@test "an invalid descriptor is skipped with a reason and a stderr notice; exit stays 0" {
  cp "$FX/descriptors/invalid-missing-verify.json" "$D1/invalid-missing-verify.json"
  list --descriptors-dir "$D1"
  [ "$status" -eq 0 ]
  [ "$(ids)" = "fake-prereq,fakeservice,nomcp-svc" ]
  [ "$(jq '.skipped | length' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.skipped[0].file | split("/") | last' <<<"$output")" = "invalid-missing-verify.json" ]
  case "$(jq -r '.skipped[0].reason' <<<"$output")" in "failed validation: "*) ;; *) false ;; esac
  case "$stderr" in *"invalid-missing-verify.json"*"verify"*) ;; *) false ;; esac
}

@test "a non-JSON file is skipped, not a crash" {
  printf 'not json' > "$D1/garbage.json"
  list --descriptors-dir "$D1"
  [ "$status" -eq 0 ]
  [ "$(jq '.skipped | length' <<<"$output")" -eq 1 ]
  [ "$(ids)" = "fake-prereq,fakeservice,nomcp-svc" ]
}

@test "an id/filename mismatch is skipped with a reason naming both" {
  cp "$FX/e2e/fake-prereq.json" "$D1/wrong-name.json"
  list --descriptors-dir "$D1"
  [ "$status" -eq 0 ]
  [ "$(ids)" = "fake-prereq,fakeservice,nomcp-svc" ]
  reason="$(jq -r '.skipped[0].reason' <<<"$output")"
  case "$reason" in *"fake-prereq"*"wrong-name"*) ;; *) false ;; esac
}

@test "a duplicate id across two dirs keeps the first dir's entry and skips the later one" {
  cp "$FX/e2e/fakeservice.json" "$D2/fakeservice.json"
  list --descriptors-dir "$D1" --descriptors-dir "$D2"
  [ "$status" -eq 0 ]
  [ "$(jq '[.services[] | select(.id == "fakeservice")] | length' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.services[] | select(.id == "fakeservice") | .file' <<<"$output")" = "$(cd "$D1" && pwd)/fakeservice.json" ]
  [ "$(jq '.skipped | length' <<<"$output")" -eq 1 ]
  [ "$(jq -r '.skipped[0].file' <<<"$output")" = "$(cd "$D2" && pwd)/fakeservice.json" ]
  case "$(jq -r '.skipped[0].reason' <<<"$output")" in *"duplicate"*) ;; *) false ;; esac
}

@test "descriptors from several dirs are merged and sorted" {
  jq '.id = "aaa-svc"' "$FX/descriptors/valid.json" > "$D2/aaa-svc.json"
  list --descriptors-dir "$D1" --descriptors-dir "$D2"
  [ "$status" -eq 0 ]
  [ "$(ids)" = "aaa-svc,fake-prereq,fakeservice,nomcp-svc" ]
}

@test "unresolved_requires reports a prerequisite with no descriptor present; resolved ones are empty" {
  rm "$D1/fake-prereq.json"
  list --descriptors-dir "$D1"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.services[] | select(.id == "fakeservice") | .unresolved_requires' <<<"$output")" = '["fake-prereq"]' ]
  # the entry is still listed
  [ "$(ids)" = "fakeservice,nomcp-svc" ]
  cp "$FX/e2e/fake-prereq.json" "$D2/fake-prereq.json"
  list --descriptors-dir "$D1" --descriptors-dir "$D2"
  [ "$(jq -c '.services[] | select(.id == "fakeservice") | .unresolved_requires' <<<"$output")" = '[]' ]
}

@test "a prerequisite whose descriptor is invalid still counts as unresolved" {
  jq 'del(.verify)' "$FX/e2e/fake-prereq.json" > "$D1/fake-prereq.json"
  list --descriptors-dir "$D1"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.services[] | select(.id == "fakeservice") | .unresolved_requires' <<<"$output")" = '["fake-prereq"]' ]
}

@test "default dir is resolved from the script location, not the cwd; empty or missing default yields an empty result" {
  S="$BATS_TEST_TMPDIR/mirror/skills/j-connect"
  mkdir -p "$S"
  cp -R "$REPO_ROOT/skills/j-connect/scripts" "$S/scripts"
  # missing default dir
  cd "$BATS_TEST_TMPDIR"
  run --separate-stderr bash "$S/scripts/list-services.sh"
  [ "$status" -eq 0 ]
  [ "$output" = '{"services":[],"skipped":[]}' ]
  # empty default dir (only .gitkeep)
  mkdir -p "$S/descriptors"; : > "$S/descriptors/.gitkeep"
  run --separate-stderr bash "$S/scripts/list-services.sh"
  [ "$status" -eq 0 ]
  [ "$output" = '{"services":[],"skipped":[]}' ]
  # descriptor next to the script is found regardless of cwd
  cp "$FX/e2e/fake-prereq.json" "$S/descriptors/fake-prereq.json"
  cd /
  run --separate-stderr bash "$S/scripts/list-services.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.services | map(.id) | join(",")' <<<"$output")" = "fake-prereq" ]
}

@test "the canonical descriptors directory exists in the repo" {
  [ -d "$REPO_ROOT/skills/j-connect/descriptors" ]
  [ -f "$REPO_ROOT/skills/j-connect/descriptors/.gitkeep" ]
}

@test "a nonexistent explicit --descriptors-dir exits 2 with nothing on stdout" {
  list --descriptors-dir "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  list --descriptors-dir "$D1" --descriptors-dir "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "usage errors exit 2" {
  list --descriptors-dir
  [ "$status" -eq 2 ]
  list --bogus
  [ "$status" -eq 2 ]
  list positional
  [ "$status" -eq 2 ]
}

@test "output carries only id, name, file, mcp, requires, unresolved_requires; no secret names or values" {
  list --descriptors-dir "$D1"
  [ "$status" -eq 0 ]
  run grep -c -E 'FAKESERVICE_TOKEN|TOKEN=' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "the script hardcodes no service or vendor name" {
  run grep -i -E 'supabase|digitalocean|github|figma|expo|fakeservice|fake-prereq' "$LIST"
  [ "$status" -ne 0 ]
}
