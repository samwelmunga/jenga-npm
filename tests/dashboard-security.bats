#!/usr/bin/env bats
#
# Coverage for the dashboard Security view's data path (E85_S03_T07): the GET /v1/security payload
# (project/app/api/parsers/security.js behind routes/security.js) as the snapshot capture
# (project/app/api/scripts/capture-snapshot.js) records it, and the exported single-file HTML
# (project/app/ui/scripts/build-snapshot-html.cjs) that embeds it for offline use.
#
# Why it goes through capture-snapshot.js rather than a bare HTTP call
# ---------------------------------------------------------------------
# capture spins up the real API in-process against an explicit --project-root and writes every route's
# envelope to one artifact, so a single run proves three things at once: the route is mounted, the
# reader honours the fixture root, and the `security` key is in the capture's route map. The UI's own
# route map (SNAPSHOT_ROUTE_KEYS in client.js) is not exercised by capture, so it is pinned separately
# by reading the source (case "both snapshot route maps list security").
#
# Isolation
# ---------
# Every case builds a throwaway project under $BATS_TEST_TMPDIR (credential-findings.json, events.json,
# audit-config.json, a rapport) and never reads or writes this repository's own project/logs/events.json,
# project/data/, project/configs/ or rapports. The artifact and HTML are written outside the fixture so
# the "no writes" case can compare the fixture tree byte for byte.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
CAPTURE_JS="$REPO_ROOT/project/app/api/scripts/capture-snapshot.js"
CLIENT_JS="$REPO_ROOT/project/app/ui/src/api/client.js"
BUNDLER="$REPO_ROOT/project/app/ui/scripts/build-snapshot-html.cjs"

# Dir A has an older `findings` result, a newer `clean` result and a consent; dir B only an
# `unavailable` result (no consent). One torn line sits in the middle of the log.
DIR_A="/work/svc-a"
DIR_B="/work/svc-b"

setup() {
  command -v node >/dev/null 2>&1 || skip "node is not installed"
  # capture-snapshot.js requires express/cors from project/app/api/node_modules.
  ( cd "$REPO_ROOT/project/app/api" && node -e "require.resolve('express'); require.resolve('cors')" ) >/dev/null 2>&1 \
    || skip "project/app/api dependencies are not installed (run npm install in project/app/api)"

  mkdir -p "$BATS_TEST_TMPDIR/out"
  FIXTURE="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$FIXTURE/project/board" "$FIXTURE/project/configs" "$FIXTURE/project/data" \
           "$FIXTURE/project/logs" "$FIXTURE/project/rapports/problems"
  FIXTURE="$(cd "$FIXTURE" && pwd -P)"
  SNAP="$BATS_TEST_TMPDIR/out/snapshot.json"
}

# Writes a recorded-state fixture: 3 findings across 2 skills, 2 audited directories, a config.
write_full_fixture() {
  cat > "$FIXTURE/project/data/credential-findings.json" <<'EOF'
{
  "schema_version": 1,
  "scan_date": "2026-10-25",
  "command": "scripts/scan-credential-patterns.sh",
  "summary": { "total": 3, "by_skill": { "j-connect": 2, "j-publish": 1 } },
  "findings": [
    { "skill": "j-connect", "file": "skills/j-connect/SKILL.md", "line": 10, "class": "gh-auth",
      "text": "gh auth status", "scope": "flagged", "verdict": "true read",
      "reason": "Reads the account state.", "action": "reword" },
    { "skill": "j-connect", "file": "skills/j-connect/SKILL.md", "line": 22, "class": "dotfile-path",
      "text": "~/.npmrc", "scope": "flagged", "verdict": "benign mention",
      "reason": "Names the path in prose only.", "action": "none" },
    { "skill": "j-publish", "file": "skills/j-publish/SKILL.md", "line": 5, "class": "gh-auth",
      "text": "gh auth login", "scope": "other", "verdict": "benign mention",
      "reason": "User-performed login.", "action": "allow-list" }
  ]
}
EOF
  cat > "$FIXTURE/project/configs/audit-config.json" <<'EOF'
{ "config_version": 1, "mode": "ask", "severity_threshold": "high", "offline_behavior": "warn", "production_only": false }
EOF
  {
    printf '%s\n' '{"event":"session_start","agent":"developer","session_id":"s0","date":"2026-10-20T08:00:00Z"}'
    printf '%s\n' '{"event":"audit_consent","agent":"audit-record","tool_type":"vulnerability","approved_by":"user","scanned_dir":"'"$DIR_A"'","session_id":"s1","date":"2026-10-21T09:00:00Z"}'
    printf '%s\n' '{"event":"audit_result","agent":"audit-record","status":"findings","threshold":"high","counts":{"low":1,"moderate":2,"high":3,"critical":0,"total":6},"scanned_dir":"'"$DIR_A"'","consent_basis":"session-approval","rapport":"'"$FIXTURE"'/project/rapports/problems/audit-svc-a-20261021.md","session_id":"s1","date":"2026-10-21T09:01:00Z"}'
    printf '%s\n' '{"event":"audit_result","agent":"audit-record","status":"unavailable","threshold":"high","counts":{"low":0,"moderate":0,"high":0,"critical":0,"total":0},"scanned_dir":"'"$DIR_B"'","consent_basis":"config-mode-on","rapport":null,"session_id":"s2","date":"2026-10-22T09:00:00Z"}'
    printf '%s\n' '{"event":"audit_result","agent":"audit-record","status":"clean","thr'   # torn line, skipped
    printf '%s\n' '{"event":"audit_result","agent":"audit-record","status":"clean","threshold":"high","counts":{"low":0,"moderate":0,"high":0,"critical":0,"total":0},"scanned_dir":"'"$DIR_A"'","consent_basis":"session-approval","rapport":null,"session_id":"s3","date":"2026-10-24T09:00:00Z"}'
  } > "$FIXTURE/project/logs/events.json"
  printf '%s\n' '# Security concern: svc-a' 'Type: security_concern' > "$FIXTURE/project/rapports/problems/audit-svc-a-20261021.md"
}

run_capture() {
  run node "$CAPTURE_JS" --project-root "$FIXTURE" --out "$SNAP"
}

# Prints a JS expression evaluated against the parsed snapshot artifact ($1), e.g. "d.routes.security.data".
snap_eval() {
  node -e '
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const v = eval(process.argv[2]);
    process.stdout.write(typeof v === "string" ? v : JSON.stringify(v));
  ' "$SNAP" "$1"
}

# A content hash of every file in the fixture tree, for the byte-identical comparison.
tree_hash() {
  ( cd "$FIXTURE" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done )
}

# Minimal realistic prebuilt dist/ (root-absolute /assets refs, module script, stylesheet link).
write_fixture_dist() {
  local dist="$1"
  mkdir -p "$dist/assets"
  cat > "$dist/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <title>Jenga AI Dashboard</title>
    <script type="module" crossorigin src="/assets/index-fixture.js"></script>
    <link rel="stylesheet" crossorigin href="/assets/index-fixture.css">
  </head>
  <body><div id="root"></div></body>
</html>
EOF
  echo 'console.log("fixture bundle");' > "$dist/assets/index-fixture.js"
  echo '.fixture { margin: 0; }' > "$dist/assets/index-fixture.css"
}

@test "route payload: documented keys, finding count, one target per directory, unavailable preserved" {
  write_full_fixture
  run_capture
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$SNAP" ]

  # Standard envelope with no error.
  [ "$(snap_eval 'd.routes.security.error')" = "null" ]

  # Documented top-level and per-half keys.
  [ "$(snap_eval 'Object.keys(d.routes.security.data).sort().join(",")')" = "audits,credential_findings" ]
  [ "$(snap_eval 'Object.keys(d.routes.security.data.credential_findings).sort().join(",")')" = "command,error,findings,scan_date,state,summary" ]
  [ "$(snap_eval 'Object.keys(d.routes.security.data.audits).sort().join(",")')" = "config,error,history,state,targets" ]

  # Credential findings: count equals the fixture's (3), state and per-skill summary come through.
  [ "$(snap_eval 'd.routes.security.data.credential_findings.state')" = "recorded" ]
  [ "$(snap_eval 'd.routes.security.data.credential_findings.findings.length')" = "3" ]
  [ "$(snap_eval 'd.routes.security.data.credential_findings.summary.total')" = "3" ]
  [ "$(snap_eval 'd.routes.security.data.credential_findings.summary.by_skill["j-connect"]')" = "2" ]
  [ "$(snap_eval 'd.routes.security.data.credential_findings.findings[0].verdict')" = "true read" ]

  # Audits: recorded, config surfaced, one target per directory (2), newest result for each.
  [ "$(snap_eval 'd.routes.security.data.audits.state')" = "recorded" ]
  [ "$(snap_eval 'd.routes.security.data.audits.config.mode')" = "ask" ]
  [ "$(snap_eval 'd.routes.security.data.audits.targets.length')" = "2" ]
  [ "$(snap_eval 'd.routes.security.data.audits.targets.map(t => t.scanned_dir).sort().join(",")')" = "$DIR_A,$DIR_B" ]
  # Dir A: the newer `clean` result wins over the older `findings` one, and carries its consent date.
  [ "$(snap_eval 'd.routes.security.data.audits.targets.find(t => t.scanned_dir === "'"$DIR_A"'").status')" = "clean" ]
  [ "$(snap_eval 'd.routes.security.data.audits.targets.find(t => t.scanned_dir === "'"$DIR_A"'").last_consent_date')" = "2026-10-21T09:00:00Z" ]
  # Dir B: `unavailable` is preserved as itself, never folded into clean.
  [ "$(snap_eval 'd.routes.security.data.audits.targets.find(t => t.scanned_dir === "'"$DIR_B"'").status')" = "unavailable" ]
  # History: every audit_result (3; the torn line is skipped), newest first.
  [ "$(snap_eval 'd.routes.security.data.audits.history.length')" = "3" ]
  [ "$(snap_eval 'd.routes.security.data.audits.history[0].date')" = "2026-10-24T09:00:00Z" ]
  [ "$(snap_eval 'd.routes.security.data.audits.history.map(h => h.status).join(",")')" = "clean,unavailable,findings" ]
}

@test "empty project: never-scanned and never-audited, capture exits 0" {
  run_capture
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(snap_eval 'd.routes.security.error')" = "null" ]
  [ "$(snap_eval 'd.routes.security.data.credential_findings.state')" = "never-scanned" ]
  [ "$(snap_eval 'd.routes.security.data.credential_findings.findings.length')" = "0" ]
  [ "$(snap_eval 'd.routes.security.data.audits.state')" = "never-audited" ]
  [ "$(snap_eval 'd.routes.security.data.audits.config')" = "null" ]
  [ "$(snap_eval 'd.routes.security.data.audits.targets.length')" = "0" ]
  [ "$(snap_eval 'd.routes.security.data.audits.history.length')" = "0" ]
}

@test "malformed findings file: only that half errors, the audits half is intact" {
  write_full_fixture
  printf '%s' '{"schema_version": 1, "findings": [ {' > "$FIXTURE/project/data/credential-findings.json"
  run_capture
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(snap_eval 'd.routes.security.error')" = "null" ]
  [ "$(snap_eval 'd.routes.security.data.credential_findings.state')" = "error" ]
  [ -n "$(snap_eval 'd.routes.security.data.credential_findings.error')" ]
  [ "$(snap_eval 'd.routes.security.data.credential_findings.findings.length')" = "0" ]
  # Audits half unaffected.
  [ "$(snap_eval 'd.routes.security.data.audits.state')" = "recorded" ]
  [ "$(snap_eval 'd.routes.security.data.audits.error')" = "null" ]
  [ "$(snap_eval 'd.routes.security.data.audits.targets.length')" = "2" ]
}

@test "malformed audit config: only the audits half errors, findings are intact" {
  write_full_fixture
  printf '%s' '{ "mode": ' > "$FIXTURE/project/configs/audit-config.json"
  run_capture
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(snap_eval 'd.routes.security.data.audits.state')" = "error" ]
  [ "$(snap_eval 'd.routes.security.data.credential_findings.state')" = "recorded" ]
  [ "$(snap_eval 'd.routes.security.data.credential_findings.findings.length')" = "3" ]
}

@test "snapshot HTML: jenga-dashboard-data carries the security route with the fixture's findings" {
  write_full_fixture
  run_capture
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # Consumer-shaped prebuilt dist: the bundler needs no build tooling, only dist/index.html + assets.
  local dist="$BATS_TEST_TMPDIR/dist"
  local html="$BATS_TEST_TMPDIR/out/snapshot.html"
  write_fixture_dist "$dist"
  run node "$BUNDLER" --dist "$dist" --data "$SNAP" --out "$html"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -s "$html" ]

  run node -e '
    const html = require("fs").readFileSync(process.argv[1], "utf8");
    const m = html.match(/<script id="jenga-dashboard-data" type="application\/json">([\s\S]*?)<\/script>/);
    if (!m) { console.error("no jenga-dashboard-data element"); process.exit(1); }
    const snap = JSON.parse(m[1]);
    const sec = snap.routes && snap.routes.security;
    if (!sec) { console.error("no security route in the embedded data"); process.exit(1); }
    const d = sec.data;
    console.log(d.credential_findings.state + "|" + d.credential_findings.findings.length + "|" +
                d.audits.targets.length + "|" + d.audits.targets.map(t => t.status).sort().join(","));
  ' "$html"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "recorded|3|2|clean,unavailable" ]
}

@test "both snapshot route maps list security (capture ROUTE_KEYS and the UI's SNAPSHOT_ROUTE_KEYS)" {
  # capture-snapshot.js: the path is requested and mapped to the `security` key.
  grep -Eq "const ROUTES = \[[^]]*'/v1/security'" "$CAPTURE_JS"
  grep -Eq "^[[:space:]]*'/v1/security':[[:space:]]*'security'," "$CAPTURE_JS"
  # client.js is not exercised by capture, so it is pinned here: without this entry the exported HTML
  # throws "no embedded snapshot data" for the Security tab even though the data is embedded.
  grep -Eq "^[[:space:]]*'/v1/security':[[:space:]]*'security'," "$CLIENT_JS"
}

@test "no writes: the fixture's events, findings and rapports are byte-identical after capture" {
  write_full_fixture
  local before after
  before="$(tree_hash)"
  [ -n "$before" ]
  # The three sources named by the task must be among the hashed files.
  echo "$before" | grep -q "project/logs/events.json"
  echo "$before" | grep -q "project/data/credential-findings.json"
  echo "$before" | grep -q "project/rapports/problems/audit-svc-a-20261021.md"

  run_capture
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  after="$(tree_hash)"
  [ "$before" = "$after" ] || { diff <(echo "$before") <(echo "$after"); false; }
}
