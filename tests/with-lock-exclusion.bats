#!/usr/bin/env bats
#
# Regression coverage for E77_S05_T02: scripts/with-lock.sh must stay exclusive when `mkdir` lies.
#
# Why this file exists
# --------------------
# with-lock.sh used to treat the exit status of `mkdir "$LOCK_DIR"` as proof that the caller owns the lock.
# That holds for the mkdir(2) syscall but not for every mkdir PROGRAM: uutils coreutils (the default on Ubuntu 25.10
# and 26.04) re-stats the path after EEXIST and exits 0 for an existing directory. Two racing callers could then both
# "win", and a read-modify-write under the lock lost an update (E77_S05_T01 has the strace evidence).
#
# These tests do not depend on the host's mkdir. They put a stub mkdir first in PATH that behaves like uutils on a lost
# race (exit 0 when the target is already a directory) so the defect is caught on macOS and GNU/Linux too. Against the
# pre-fix script, the "held lock" test and the counter test both fail deterministically.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WL="$REPO_ROOT/scripts/with-lock.sh"
  T="$(mktemp -d)"
  TARGET="$T/board-file.md"
  REAL_MKDIR="$(command -v mkdir)"
  mkdir -p "$T/stub"
  # Behaves like uutils mkdir on a lost race: success for an existing directory, the real mkdir otherwise.
  cat > "$T/stub/mkdir" <<STUB
#!/bin/sh
for a in "\$@"; do
  if [ -d "\$a" ]; then exit 0; fi
done
exec "$REAL_MKDIR" "\$@"
STUB
  chmod +x "$T/stub/mkdir"
  export WITH_LOCK_POLL_SECONDS=0.05
}

teardown() {
  rm -rf "$T"
}

@test "stub sanity: the stub mkdir exits 0 for an existing directory, like uutils on a lost race" {
  "$REAL_MKDIR" "$T/exists"
  run "$T/stub/mkdir" "$T/exists"
  [ "$status" -eq 0 ]
  run "$T/stub/mkdir" "$T/fresh"
  [ "$status" -eq 0 ]
  [ -d "$T/fresh" ]
}

@test "a lock held by a live holder is not granted when mkdir reports success for the existing directory" {
  "$REAL_MKDIR" "$TARGET.lock.d"
  echo "99999" > "$TARGET.lock.d/pid"
  PATH="$T/stub:$PATH" WITH_LOCK_TIMEOUT_SECONDS=1 run "$WL" "$TARGET" -- touch "$T/ran"
  [ "$status" -eq 2 ]
  [ ! -e "$T/ran" ]
  # the holder's lock is untouched
  [ "$(cat "$TARGET.lock.d/pid")" = "99999" ]
}

@test "parallel read-modify-write under the lock loses no update when mkdir reports success for an existing directory" {
  local n=6 i
  echo 0 > "$T/counter"
  for i in $(seq 1 "$n"); do
    PATH="$T/stub:$PATH" WITH_LOCK_TIMEOUT_SECONDS=60 "$WL" "$TARGET" -- \
      sh -c 'v=$(cat "$1"); sleep 0.05; echo $((v + 1)) > "$1"' sh "$T/counter" &
  done
  wait
  [ "$(cat "$T/counter")" -eq "$n" ]
  [ ! -e "$TARGET.lock.d" ]
}

@test "the lock is released after the command and can be taken again" {
  run "$WL" "$TARGET" -- sh -c 'exit 7'
  [ "$status" -eq 7 ]
  [ ! -e "$TARGET.lock.d" ]
  run "$WL" "$TARGET" -- true
  [ "$status" -eq 0 ]
  [ ! -e "$TARGET.lock.d" ]
}

@test "a stale lock is still reclaimed, also when mkdir reports success for an existing directory" {
  "$REAL_MKDIR" "$TARGET.lock.d"
  echo "99999" > "$TARGET.lock.d/pid"
  touch -t 200001010000 "$TARGET.lock.d"
  PATH="$T/stub:$PATH" WITH_LOCK_TIMEOUT_SECONDS=10 WITH_LOCK_STALE_SECONDS=60 run "$WL" "$TARGET" -- touch "$T/ran"
  [ "$status" -eq 0 ]
  [ -e "$T/ran" ]
  [ ! -e "$TARGET.lock.d" ]
}

@test "a fresh lock is not reclaimed as stale and the waiter times out with exit 2" {
  "$REAL_MKDIR" "$TARGET.lock.d"
  echo "99999" > "$TARGET.lock.d/pid"
  WITH_LOCK_TIMEOUT_SECONDS=1 run "$WL" "$TARGET" -- touch "$T/ran"
  [ "$status" -eq 2 ]
  [ ! -e "$T/ran" ]
  [ -d "$TARGET.lock.d" ]
}
