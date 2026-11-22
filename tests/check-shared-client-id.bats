#!/usr/bin/env bats
# bats file_tags=tier:integration
#
# Coverage for skills/j-cloud-connect/scripts/check-shared-client-id.sh (E89_S06_T08).
# Runs against a fake `rclone` on PATH; never touches the real rclone config.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/j-cloud-connect/scripts/check-shared-client-id.sh"
SECRET="SUPERSECRET-do-not-leak"

setup() {
  FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  export PATH="$FAKE_BIN:$PATH"
}

# fake_rclone <json-for-config-dump>
fake_rclone() {
  printf '%s' "$1" > "$BATS_TEST_TMPDIR/dump.json"
  cat > "$FAKE_BIN/rclone" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "config dump" ] && { cat "$BATS_TEST_TMPDIR/dump.json"; exit 0; }
exit 1
EOF
  chmod +x "$FAKE_BIN/rclone"
}

@test "drive remote without client_id is reported, exit 3, with upstream link" {
  fake_rclone "{\"gdrive\":{\"type\":\"drive\",\"client_secret\":\"$SECRET\"}}"
  run bash "$SCRIPT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"gdrive"* ]]
  [[ "$output" == *"https://rclone.org/drive/#making-your-own-client-id"* ]]
  [[ "$output" == *"not a Jenga defect"* ]]
}

@test "drive remote with own client_id passes, exit 0" {
  fake_rclone '{"gdrive":{"type":"drive","client_id":"mine.apps.googleusercontent.com"}}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == OK* ]]
}

@test "explicit legacy shared id counts as shared" {
  fake_rclone '{"gdrive":{"type":"drive","client_id":"202264815644.apps.googleusercontent.com"}}'
  run bash "$SCRIPT"
  [ "$status" -eq 3 ]
}

@test "non-drive remotes are not flagged" {
  fake_rclone '{"dbx":{"type":"dropbox"}}'
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "no client_secret value ever appears in output, including --survey" {
  fake_rclone "{\"gdrive\":{\"type\":\"drive\",\"client_id\":\"x\",\"client_secret\":\"$SECRET\"},\"b\":{\"type\":\"drive\",\"client_secret\":\"$SECRET\"}}"
  run bash "$SCRIPT" --survey
  [[ "$output" != *"$SECRET"* ]]
  [[ "$output" == *"b"*"drive"*"no own client_id"* ]]
}

@test "unknown argument fails with exit 1" {
  fake_rclone '{}'
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 1 ]
}
