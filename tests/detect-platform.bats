#!/usr/bin/env bats
#
# Coverage for skills/j-connect/scripts/detect-platform.sh (E65_S02_T01).
#
# Stub executables only: a throwaway PATH holds fake `brew`, `npm`, `uname`.
# For the "no package manager" cases the PATH is an isolated directory of
# symlinks to the few coreutils the scripts need, so a real brew/npm on the
# developer's machine can never be seen. No real package manager is invoked.

bats_require_minimum_version 1.5.0
load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
DETECT="$REPO_ROOT/skills/j-connect/scripts/detect-platform.sh"
RUN="$REPO_ROOT/skills/j-connect/scripts/run-descriptor.sh"
FX="$REPO_ROOT/tests/fixtures/connect"
FAKESERVICE="$FX/e2e/fakeservice.json"
DOCS_URL="https://example.invalid/fakeservice/install"

setup() {
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"      # stubs
  ISO="$BATS_TEST_TMPDIR/iso"           # isolated coreutils (no brew/npm)
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$FAKE_BIN" "$ISO" "$PROJ"
  git -C "$PROJ" init -q .
  local t p
  for t in bash sh jq tr uname dirname basename sed grep awk cat mktemp rm mv cp head tail sort wc paste date cut env git mkdir touch find xargs sleep chmod ln ls tee; do
    p="$(command -v "$t" 2>/dev/null)" || continue
    case "$p" in /*) ln -sf "$p" "$ISO/$t" ;; esac
  done
  unset JENGA_CONNECT_PLATFORM
  export PATH="$FAKE_BIN:$ISO"
}

stub() { printf '#!/bin/sh\necho "%s $*" >> "%s/calls.log"\nexit 0\n' "$1" "$BATS_TEST_TMPDIR" > "$FAKE_BIN/$1"; chmod +x "$FAKE_BIN/$1"; }
stub_uname() { printf '#!/bin/sh\necho "%s"\n' "$1" > "$FAKE_BIN/uname"; chmod +x "$FAKE_BIN/uname"; }
detect() { run --separate-stderr bash "$DETECT" "$@"; }
no_calls() { [ ! -e "$BATS_TEST_TMPDIR/calls.log" ]; }

@test "prints exactly one JSON line with the five keys, darwin via override" {
  JENGA_CONNECT_PLATFORM=darwin detect
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(jq -r 'keys_unsorted | join(",")' <<<"$output")" = "os,package_managers,status,method,fallback_docs_url" ]
  [ "$(jq -r .os <<<"$output")" = "darwin" ]
  [ "$(jq -r .method <<<"$output")" = "null" ]
  [ "$(jq -r .fallback_docs_url <<<"$output")" = "null" ]
}

@test "linux via override and via stub uname" {
  JENGA_CONNECT_PLATFORM=Linux detect
  [ "$(jq -r .os <<<"$output")" = "linux" ]
  stub_uname Linux
  detect
  [ "$status" -eq 0 ]
  [ "$(jq -r .os <<<"$output")" = "linux" ]
  [ "$(jq -r .status <<<"$output")" = "ok" ]
}

@test "darwin via stub uname" {
  stub_uname Darwin
  detect
  [ "$(jq -r .os <<<"$output")" = "darwin" ]
}

@test "package_managers lists only the managers found on PATH, in a stable order" {
  stub npm; stub brew
  JENGA_CONNECT_PLATFORM=darwin detect
  [ "$(jq -c .package_managers <<<"$output")" = '["brew","npm"]' ]
  rm "$FAKE_BIN/brew"
  JENGA_CONNECT_PLATFORM=darwin detect
  [ "$(jq -c .package_managers <<<"$output")" = '["npm"]' ]
  rm "$FAKE_BIN/npm"
  JENGA_CONNECT_PLATFORM=darwin detect
  [ "$(jq -c .package_managers <<<"$output")" = '[]' ]
  no_calls
}

@test "descriptor + stub brew under darwin: method is brew/fakecli, status ok, docs url null" {
  stub brew
  JENGA_CONNECT_PLATFORM=darwin detect --descriptor "$FAKESERVICE"
  [ "$status" -eq 0 ]
  [ "$(jq -c .method <<<"$output")" = '{"manager":"brew","package":"fakecli"}' ]
  [ "$(jq -r .status <<<"$output")" = "ok" ]
  [ "$(jq -r .fallback_docs_url <<<"$output")" = "null" ]
  no_calls
}

@test "descriptor + stub npm under linux picks the linux method" {
  stub npm
  JENGA_CONNECT_PLATFORM=linux detect --descriptor "$FAKESERVICE"
  [ "$(jq -c .method <<<"$output")" = '{"manager":"npm","package":"fakecli"}' ]
  [ "$(jq -r .status <<<"$output")" = "ok" ]
}

@test "unrecognised OS via override: unknown, null method, docs url, nothing executed" {
  stub brew; stub npm
  JENGA_CONNECT_PLATFORM=plan9 detect --descriptor "$FAKESERVICE"
  [ "$status" -eq 0 ]
  [ "$(jq -r .os <<<"$output")" = "unknown" ]
  [ "$(jq -r .status <<<"$output")" = "unknown" ]
  [ "$(jq -r .method <<<"$output")" = "null" ]
  [ "$(jq -r .fallback_docs_url <<<"$output")" = "$DOCS_URL" ]
  no_calls
}

@test "unrecognised OS via stub uname (FreeBSD): unknown with the docs url" {
  stub brew
  stub_uname FreeBSD
  detect --descriptor "$FAKESERVICE"
  [ "$status" -eq 0 ]
  [ "$(jq -r .os <<<"$output")" = "unknown" ]
  [ "$(jq -r .status <<<"$output")" = "unknown" ]
  [ "$(jq -r .method <<<"$output")" = "null" ]
  [ "$(jq -r .fallback_docs_url <<<"$output")" = "$DOCS_URL" ]
  no_calls
}

@test "unrecognised OS without a descriptor reports unknown with null url" {
  JENGA_CONNECT_PLATFORM=plan9 detect
  [ "$status" -eq 0 ]
  [ "$(jq -r .status <<<"$output")" = "unknown" ]
  [ "$(jq -r .fallback_docs_url <<<"$output")" = "null" ]
}

@test "known OS with no matching manager on PATH: unknown + docs url, not a guessed command" {
  # darwin needs brew; only npm is present
  stub npm
  JENGA_CONNECT_PLATFORM=darwin detect --descriptor "$FAKESERVICE"
  [ "$status" -eq 0 ]
  [ "$(jq -r .os <<<"$output")" = "darwin" ]
  [ "$(jq -r .status <<<"$output")" = "unknown" ]
  [ "$(jq -r .method <<<"$output")" = "null" ]
  [ "$(jq -r .fallback_docs_url <<<"$output")" = "$DOCS_URL" ]
  no_calls
}

@test "descriptor with no install.methods under a known OS: unknown + docs url" {
  JENGA_CONNECT_PLATFORM=darwin detect --descriptor "$FX/e2e/fake-prereq.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r .status <<<"$output")" = "unknown" ]
  [ "$(jq -r .fallback_docs_url <<<"$output")" = "https://example.invalid/fake-prereq/install" ]
}

@test "parity with run-descriptor.sh: ok iff the install step offers a package manager" {
  local cases=("darwin:brew" "darwin:" "linux:npm" "linux:brew" "plan9:brew")
  local c plat mgr verdict rmsg
  for c in "${cases[@]}"; do
    plat="${c%%:*}"; mgr="${c##*:}"
    rm -f "$FAKE_BIN/brew" "$FAKE_BIN/npm"
    [ -z "$mgr" ] || stub "$mgr"
    export JENGA_CONNECT_PLATFORM="$plat"
    run --separate-stderr bash "$DETECT" --descriptor "$FAKESERVICE"
    [ "$status" -eq 0 ]
    verdict="$(jq -r .status <<<"$output")"
    # fakecli is not installed in this PATH, so the install step has to decide.
    run --separate-stderr bash "$RUN" "$FAKESERVICE" --step install --project-root "$PROJ"
    rmsg="$(jq -r 'select(.step == "install") | .message' <<<"$output")"
    [ "$(jq -r 'select(.step == "install") | .status' <<<"$output")" = "needs-user-action" ]
    case "$rmsg" in
      "not installed. Re-run with --allow-install"*) [ "$verdict" = "ok" ] ;;
      *) [ "$verdict" = "unknown" ] ;;
    esac
  done
  no_calls
}

@test "invalid descriptor exits 2 with nothing on stdout" {
  JENGA_CONNECT_PLATFORM=darwin detect --descriptor "$FX/descriptors/invalid-missing-verify.json"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ -n "$stderr" ]
}

@test "unreadable / missing descriptor and usage errors exit 2 with nothing on stdout" {
  detect --descriptor "$BATS_TEST_TMPDIR/nope.json"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  detect --descriptor
  [ "$status" -eq 2 ]; [ -z "$output" ]
  detect --bogus
  [ "$status" -eq 2 ]; [ -z "$output" ]
  detect extra-positional
  [ "$status" -eq 2 ]; [ -z "$output" ]
  printf 'not json' > "$BATS_TEST_TMPDIR/bad.json"
  detect --descriptor "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]; [ -z "$output" ]
}

@test "output and messages never contain an install command string" {
  stub brew; stub npm
  local plat
  for plat in darwin linux plan9; do
    JENGA_CONNECT_PLATFORM="$plat" detect --descriptor "$FAKESERVICE"
    printf '%s\n%s\n' "$output" "$stderr" > "$BATS_TEST_TMPDIR/all.txt"
    run grep -E -i -e 'brew install|npm install|apt(-get)? install|curl |sudo ' "$BATS_TEST_TMPDIR/all.txt"
    [ "$status" -ne 0 ]
  done
  no_calls
}
