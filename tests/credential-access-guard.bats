#!/usr/bin/env bats
#
# Standing guard against bundled skill scripts READING credential values (E85_S02_T05).
#
# The audit (project/documentation/credential-access-audit.md) separates a MENTION of a credential (a comment,
# user-run guidance, an exit-code-only `gh auth status` probe) from a READ (a script that obtains the value of a
# secret). A pattern scanner cannot tell them apart; this suite enforces the difference:
#
#   * READ detector   hard failure over skills/*/scripts/ and scripts/, excused only by a `read` entry in
#                     tests/fixtures/credential-access-allowlist.txt (today: the one accepted by-design use in
#                     skills/j-publish/scripts/ios_pipeline.sh).
#   * MENTION detector runs scripts/scan-credential-patterns.sh over skills/ and scripts/ and fails on every row
#                     the allow-list does not cover, naming file and line.
#   * STALE entries   an allow-list entry that no longer matches any line fails, so the list cannot rot into a
#                     blanket exemption. Entries whose file is absent are skipped (the public mirror withholds
#                     some skills; see the .publicignore note at the end of this header).
#   * VALIDATORS      validate_npm_env.sh and validate_ios_env.sh must stay presence-only: no allow-list entry for
#                     either, and neither matches the read detector.
#   * SELF-TESTS      every forbidden construct is injected into a throwaway tree under $BATS_TEST_TMPDIR and must
#                     make the detector fail, and pass only once a matching entry is allow-listed. The real tree
#                     and the real allow-list are never written.
#
# READ DETECTOR REGEXES (evaluated per line by the awk program in READ_AWK below; a line whose first
# non-blank character is `#` is a comment and is not examined; only scripts are examined, never prose):
#   R1 credential-file read   (cat|head|tail) <args> CRED          e.g. cat ~/.npmrc, $(cat "$HOME/.ssh/id_x")
#   R2 redirection read       (^|space|$() < <args> CRED           e.g. read -r l < .env, $(< ~/.netrc), gh secret set X < ~/.ssh/k
#        CRED = \.aws/credentials | \.ssh/ | \.npmrc | \.netrc | .env as a whole path component start
#   R3 gh auth token          gh[[:space:]]+auth[[:space:]]+token
#   R4 printenv dynamic       printenv [quote] $...                e.g. printenv "$name", printenv ${var}
#   R5 printenv secret name   printenv NAME where NAME is a secret name (see below)
#   R6 echo/printf of secret  echo|printf ... $NAME or ${NAME...} where NAME is a secret name, looked for only up
#                             to the next pipe, && or "; " on the line
#   R7 indirect expansion     <anything>=...${!name}               a ${!name} lookup assigned to a variable
#                             (a bare presence test such as [ -n "${!name}" ] is not an assignment and passes)
#   R8 secret copied          var=$NAME / var="${NAME}"           assigning a secret variable's value to another
#        secret NAME = AWS_*SECRET* | AWS_ACCESS_KEY* | *_TOKEN | *_KEY, except the names in BENIGN_KEY_NAMES
#        (SESSION_KEY is a session identifier in scripts/checklist-marker.sh, not a credential).
# R4 deliberately does not require the result to be assigned: the dynamic-name lookup in ios_pipeline.sh is a
# function body whose output a caller captures, and the guard is meant to see it. The only shipped match after
# E85_S02_T03 is that lookup (ios_pipeline.sh, the printenv "$var_name" line).
#
# Allow-list matching: an entry `file:class:substring  # reason` excuses a finding in `file` of that class whose
# trimmed line CONTAINS `substring`. Classes are the five scanner classes (mentions) or `read`.
#
# .publicignore (E85_S02_T05 check): this file, scripts/scan-credential-patterns.sh and the allow-list are not
# blocklisted. The subjects they scan are public except skills/j-mirror-public/, whose single allow-list entry
# is skipped when its file is absent (stale check), and the mention detector simply sees no row for a withheld
# file. Nothing here reads a skill that the mirror withholds, so no test-subject skip condition is needed.
#
# Deterministic and offline: reads only files in the tree under test, no network, no clock, no ordering
# dependence (sorted output), mktemp-style per-test directories for every self-test.

load helpers/assertions

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SCAN="$REPO_ROOT/scripts/scan-credential-patterns.sh"
ALLOWLIST="$REPO_ROOT/tests/fixtures/credential-access-allowlist.txt"
IOS_SCRIPT="skills/j-publish/scripts/ios_pipeline.sh"
VALIDATORS="skills/j-publish/scripts/validate_npm_env.sh skills/j-publish/scripts/validate_ios_env.sh"

# Names that look like *_KEY but are not credentials; space-separated.
BENIGN_KEY_NAMES="SESSION_KEY"

# --- the read detector's awk program -------------------------------------------------------------------------
# Kept in a quoted heredoc so quote characters in the regexes need no shell escaping. Input: file names on
# stdin are NOT used; the files are passed as arguments. Output: file<TAB>line<TAB>read<TAB>trimmed text.
read -r -d '' READ_AWK <<'AWK' || true
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function is_secret(n) {
  if (index(" " benign " ", " " n " ")) return 0
  return (n ~ /^AWS_[A-Za-z0-9_]*SECRET[A-Za-z0-9_]*$/ || n ~ /^AWS_ACCESS_KEY[A-Za-z0-9_]*$/ || \
          n ~ /^[A-Za-z0-9_]*_TOKEN$/ || n ~ /^[A-Za-z0-9_]*_KEY$/)
}
# true when some $NAME or ${NAME...} reference in s names a secret variable
function refs_secret(s,    name) {
  while (match(s, /[$]\{?[A-Za-z_][A-Za-z0-9_]*/)) {
    name = substr(s, RSTART, RLENGTH); sub(/^[$]\{?/, "", name)
    if (is_secret(name)) return 1
    s = substr(s, RSTART + RLENGTH)
  }
  return 0
}
# true when the argument text (everything after cat/head/tail or "<", cut at the next pipe, ; & or #) names a
# credential file; a leading space stands in for the path-component boundary that .env needs
function has_cred(rest) {
  if (match(rest, /[|;&#]/)) rest = substr(rest, 1, RSTART - 1)
  return ((" " rest) ~ /(\.aws\/credentials|\.ssh\/|\.npmrc|\.netrc|[^A-Za-z0-9_]\.env([^A-Za-z0-9_]|$))/)
}
function is_read(s,    name, rest) {
  # R1 (every cat/head/tail on the line, not only the first)
  rest = s
  while (match(rest, /(^|[ \t(]|[$][(])(cat|head|tail)[ \t]+/)) {
    rest = substr(rest, RSTART + RLENGTH)
    if (has_cred(rest)) return 1
  }
  # R2 (every "<" that is not part of a here-document or here-string)
  rest = s
  while (match(rest, /(^|[ \t(]|[$][(])<[ \t]*/)) {
    rest = substr(rest, RSTART + RLENGTH)
    if (substr(rest, 1, 1) != "<" && has_cred(rest)) return 1
  }
  # R3
  if (s ~ /(^|[^A-Za-z0-9_])gh[ \t]+auth[ \t]+token/) return 1
  # R4
  if (s ~ /(^|[^A-Za-z0-9_])printenv[ \t]+["\047]?[$]/) return 1
  # R5
  if (match(s, /(^|[^A-Za-z0-9_])printenv[ \t]+["\047]?[A-Za-z_][A-Za-z0-9_]*/)) {
    name = substr(s, RSTART, RLENGTH); sub(/^.*printenv[ \t]+["\047]?/, "", name)
    if (is_secret(name)) return 1
  }
  # R6
  if (match(s, /(^|[^A-Za-z0-9_])(echo|printf)[ \t]/)) {
    rest = substr(s, RSTART + RLENGTH)
    # stop at a pipe, && or "; " so a later command's argument is not read as an echoed value
    if (match(rest, /[|]|&&|; /)) rest = substr(rest, 1, RSTART - 1)
    if (refs_secret(rest)) return 1
  }
  # R7
  if (s ~ /=[^#]*[$]\{![A-Za-z_][A-Za-z0-9_]*\}/) return 1
  # R8
  if (match(s, /(^|[ \t;&|(])[A-Za-z_][A-Za-z0-9_]*=["\047]?[$]\{?[A-Za-z_][A-Za-z0-9_]*/)) {
    name = substr(s, RSTART, RLENGTH); sub(/^[^=]*=["\047]?[$]\{?/, "", name)
    if (is_secret(name)) return 1
  }
  return 0
}
{
  line = $0; sub(/\r$/, "", line)
  if (trim(line) ~ /^#/) next
  if (is_read(line)) printf "%s\t%d\tread\t%s\n", FILENAME, FNR, trim(line)
}
AWK

# --- helpers --------------------------------------------------------------------------------------------------

# script_files <root>: scripts the read detector examines, relative to root, sorted.
script_files() {
  ( cd "$1" && { [ -d skills ] && find skills -type f -path 'skills/*/scripts/*'; [ -d scripts ] && find scripts -type f; } \
      | grep -v -e '/node_modules/' -e '/\.git/' | LC_ALL=C sort -u )
}

# read_rows <root>: TSV rows file<TAB>line<TAB>read<TAB>text for every read-detector match.
read_rows() {
  local root="$1" files f
  files="$(script_files "$root")"
  [ -n "$files" ] || return 0
  ( cd "$root" && printf '%s\n' "$files" | while IFS= read -r f; do
      # binary or empty files are skipped; scripts are text
      grep -qI '' "$f" 2>/dev/null && printf '%s\n' "$f"
    done | xargs -I{} awk -v benign="$BENIGN_KEY_NAMES" "$READ_AWK" {} 2>/dev/null ) | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n -u
}

# mention_rows <root>: the scanner's TSV rows (file, line, class, text) over skills/ and scripts/.
mention_rows() {
  "$SCAN" --root "$1"
}

# allow_tsv <allowlist>: TSV file<TAB>class<TAB>substring<TAB>reason per entry; a malformed line becomes
# MALFORMED<TAB>lineno<TAB>text so a test can name it.
allow_tsv() {
  awk '
    /^[ \t]*(#|$)/ { next }
    {
      line = $0
      i = index(line, ":"); if (i == 0) { printf "MALFORMED\t%d\t%s\n", NR, line; next }
      file = substr(line, 1, i - 1); rest = substr(line, i + 1)
      j = index(rest, ":"); if (j == 0) { printf "MALFORMED\t%d\t%s\n", NR, line; next }
      cls = substr(rest, 1, j - 1); rest = substr(rest, j + 1)
      # reason separator: the LAST occurrence of two spaces, hash, space
      k = 0; p = 1
      while ((q = index(substr(rest, p), "  # ")) > 0) { k = p + q - 1; p = k + 1 }
      if (k == 0) { printf "MALFORMED\t%d\t%s\n", NR, line; next }
      sub_ = substr(rest, 1, k - 1); reason = substr(rest, k + 4)
      gsub(/^[ \t]+|[ \t]+$/, "", reason)
      if (file == "" || cls == "" || sub_ == "" || reason == "") { printf "MALFORMED\t%d\t%s\n", NR, line; next }
      printf "%s\t%s\t%s\t%s\n", file, cls, sub_, reason
    }' "$1"
}

# cover <want: read|mention> <allow.tsv> <rows.tsv>: prints UNCOVERED<TAB>file<TAB>line<TAB>class<TAB>text for each
# row no entry of the wanted kind covers, and STALE<TAB>file<TAB>class<TAB>substring for each entry that covers none.
cover() {
  awk -F'\t' -v want="$1" '
    FILENAME == ARGV[1] {
      if ($1 == "MALFORMED") next
      isread = ($2 == "read")
      if ((want == "read") != isread) next
      n++; ef[n] = $1; ec[n] = $2; es[n] = $3; next
    }
    {
      covered = 0
      for (i = 1; i <= n; i++)
        if (ef[i] == $1 && ec[i] == $3 && index($4, es[i]) > 0) { covered = 1; hit[i] = 1 }
      if (!covered) printf "UNCOVERED\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4
    }
    END { for (i = 1; i <= n; i++) if (!hit[i]) printf "STALE\t%s\t%s\t%s\n", ef[i], ec[i], es[i] }
  ' "$2" "$3"
}

# read_report <root> <allowlist>: one line per uncovered read, "read: file:line: text".
read_report() {
  local atsv rows
  atsv="$(mktemp "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/allow.XXXXXX")"
  rows="$(mktemp "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rows.XXXXXX")"
  allow_tsv "$2" >"$atsv"
  read_rows "$1" >"$rows"
  cover read "$atsv" "$rows" | awk -F'\t' '$1 == "UNCOVERED" { printf "read: %s:%s: %s\n", $2, $3, $5 }'
  rm -f "$atsv" "$rows"
}

# mention_report <root> <allowlist>: one line per uncovered scanner row, "mention: file:line [class]: text".
mention_report() {
  local atsv rows
  atsv="$(mktemp "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/allow.XXXXXX")"
  rows="$(mktemp "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rows.XXXXXX")"
  allow_tsv "$2" >"$atsv"
  mention_rows "$1" >"$rows"
  cover mention "$atsv" "$rows" | awk -F'\t' '$1 == "UNCOVERED" { printf "mention: %s:%s [%s]: %s\n", $2, $3, $4, $5 }'
  rm -f "$atsv" "$rows"
}

# stale_report <root> <allowlist>: one line per entry (either kind) that matches nothing in a file that exists.
stale_report() {
  local root="$1" atsv rows kind line file
  atsv="$(mktemp "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/allow.XXXXXX")"
  rows="$(mktemp "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/rows.XXXXXX")"
  allow_tsv "$2" >"$atsv"
  for kind in read mention; do
    if [ "$kind" = read ]; then read_rows "$root" >"$rows"; else mention_rows "$root" >"$rows"; fi
    cover "$kind" "$atsv" "$rows" | awk -F'\t' '$1 == "STALE"' | while IFS="$(printf '\t')" read -r _ file cls sub_; do
      # a file the tree does not have (withheld from the public mirror) cannot be stale
      [ -e "$root/$file" ] && printf 'stale: %s:%s:%s\n' "$file" "$cls" "$sub_"
    done
  done
  rm -f "$atsv" "$rows"
}

# guard <root> <allowlist>: the combined verdict used by the self-tests; status 1 and the report on failure.
guard() {
  local out
  out="$({ read_report "$1" "$2"; mention_report "$1" "$2"; })"
  [ -z "$out" ] && return 0
  printf '%s\n' "$out"
  return 1
}

# fixture_tree: builds $TREE with one skill script and an empty allow-list $TMP_ALLOW; $1 = the injected line.
fixture_tree() {
  TREE="$BATS_TEST_TMPDIR/tree"
  TMP_ALLOW="$BATS_TEST_TMPDIR/allow.txt"
  rm -rf "$TREE"
  mkdir -p "$TREE/skills/demo/scripts" "$TREE/scripts"
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"$TREE/skills/demo/scripts/evil.sh"
  : >"$TMP_ALLOW"
}

# assert_read_construct <injected line> <substring that identifies it>: the detector fails on the line (naming
# file and line 2), a read entry for a DIFFERENT file or the mention class does not excuse it, and a matching
# read entry for this file does.
assert_read_construct() {
  fixture_tree "$1"
  run read_report "$TREE" "$TMP_ALLOW"
  assert_output_contains "read: skills/demo/scripts/evil.sh:2:"
  printf '%s\n' "skills/other/scripts/evil.sh:read:$2  # wrong file" >"$TMP_ALLOW"
  run read_report "$TREE" "$TMP_ALLOW"
  assert_output_contains "read: skills/demo/scripts/evil.sh:2:"
  printf '%s\n' "skills/demo/scripts/evil.sh:credential-file:$2  # wrong class" >"$TMP_ALLOW"
  run read_report "$TREE" "$TMP_ALLOW"
  assert_output_contains "read: skills/demo/scripts/evil.sh:2:"
  printf '%s\n' "skills/demo/scripts/evil.sh:read:$2  # accepted for the test" >"$TMP_ALLOW"
  run read_report "$TREE" "$TMP_ALLOW"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- real tree ------------------------------------------------------------------------------------------------

@test "allow-list: every entry parses and carries a reason" {
  run allow_tsv "$ALLOWLIST"
  [ "$status" -eq 0 ]
  assert_output_not_contains "MALFORMED"
  # every non-comment line produced one entry, each with a non-empty reason
  expected="$(grep -c -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$ALLOWLIST")"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq "$expected" ]
  [ "$expected" -gt 0 ]
  bad="$(printf '%s\n' "$output" | awk -F'\t' '$4 == "" || NF < 4')"
  [ -z "$bad" ]
}

@test "allow-list: classes are the five scanner classes or read" {
  bad="$(allow_tsv "$ALLOWLIST" | awk -F'\t' '$2 !~ /^(gh-auth|aws-env|dotfile-path|home-ref|credential-file|read)$/ { print $1 ":" $2 }')"
  [ -z "$bad" ]
}

@test "allow-list: read entries exist only for ios_pipeline.sh" {
  reads="$(allow_tsv "$ALLOWLIST" | awk -F'\t' '$2 == "read" { print $1 }' | sort -u)"
  [ "$reads" = "$IOS_SCRIPT" ]
}

@test "read detector: no unexcused read of a credential value in skills/*/scripts/ or scripts/" {
  run read_report "$REPO_ROOT" "$ALLOWLIST"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; false; }
}

@test "read detector: the accepted ios_pipeline.sh lookup is still detected (the entry is live)" {
  rows="$(read_rows "$REPO_ROOT")"
  case "$rows" in *"$IOS_SCRIPT"*"printenv"*) : ;; *) printf 'no read match in %s\n%s\n' "$IOS_SCRIPT" "$rows" >&2; false ;; esac
}

@test "mention detector: scripts/scan-credential-patterns.sh rows over skills/ and scripts/ are all covered" {
  [ -x "$SCAN" ]
  run mention_report "$REPO_ROOT" "$ALLOWLIST"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; false; }
}

@test "stale entries: every allow-list entry (mention or read) matches a line of its file" {
  run stale_report "$REPO_ROOT" "$ALLOWLIST"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; false; }
}

@test "validators are not excused: no allow-list entry for either validator" {
  for v in $VALIDATORS; do
    n="$(allow_tsv "$ALLOWLIST" | awk -F'\t' -v f="$v" '$1 == f' | wc -l | tr -d ' ')"
    [ "$n" -eq 0 ] || { printf 'allow-list has an entry for %s\n' "$v" >&2; false; }
  done
}

@test "validators are not excused: neither validator matches the read detector" {
  for v in $VALIDATORS; do
    [ -f "$REPO_ROOT/$v" ] || continue
    run awk -v benign="$BENIGN_KEY_NAMES" "$READ_AWK" "$REPO_ROOT/$v"
    [ -z "$output" ] || { printf '%s matches the read detector:\n%s\n' "$v" "$output" >&2; false; }
  done
}

# --- self-tests: the detector bites (one @test per forbidden construct) ---------------------------------------

@test "self-test read: cat of ~/.aws/credentials" {
  assert_read_construct 'creds="$(cat ~/.aws/credentials)"' 'cat ~/.aws/credentials'
}

@test "self-test read: cat of an ~/.ssh key" {
  assert_read_construct 'key="$(cat "$HOME/.ssh/id_ed25519")"' 'id_ed25519'
}

@test "self-test read: cat of ~/.npmrc" {
  assert_read_construct 'cat ~/.npmrc' 'cat ~/.npmrc'
}

@test "self-test read: cat of a .env file" {
  assert_read_construct 'vars="$(cat .env)"' 'cat .env'
}

@test "self-test read: \$(< ~/.netrc) command substitution" {
  assert_read_construct 'netrc=$(< ~/.netrc)' '$(< ~/.netrc)'
}

@test "self-test read: redirection from .env" {
  assert_read_construct 'read -r first < .env' 'read -r first < .env'
}

@test "self-test read: redirecting an ssh key into a command" {
  assert_read_construct 'gh secret set DEPLOY < ~/.ssh/id_deploy' 'gh secret set DEPLOY'
}

@test "self-test read: gh auth token" {
  assert_read_construct 'tok="$(gh auth token)"' 'gh auth token'
}

@test "self-test read: printenv of an AWS secret" {
  assert_read_construct 'printenv AWS_SECRET_ACCESS_KEY' 'printenv AWS_SECRET_ACCESS_KEY'
}

@test "self-test read: printenv of an AWS access key id" {
  assert_read_construct 'id="$(printenv AWS_ACCESS_KEY_ID)"' 'printenv AWS_ACCESS_KEY_ID'
}

@test "self-test read: printenv of a *_TOKEN variable" {
  assert_read_construct 'value="$(printenv NPM_TOKEN)"' 'printenv NPM_TOKEN'
}

@test "self-test read: printenv of a *_KEY variable" {
  assert_read_construct 'value=$(printenv DEPLOY_KEY)' 'printenv DEPLOY_KEY'
}

@test "self-test read: echo of an AWS access key" {
  assert_read_construct 'echo "$AWS_ACCESS_KEY_ID"' 'echo "$AWS_ACCESS_KEY_ID"'
}

@test "self-test read: echo of a *_TOKEN variable" {
  assert_read_construct 'echo "token is ${GITHUB_TOKEN}"' 'echo "token is'
}

@test "self-test read: printf of a *_KEY variable" {
  assert_read_construct "printf '%s' \"\$API_KEY\"" "printf '%s'"
}

@test "self-test read: dynamic-name printenv assigned to a variable" {
  assert_read_construct 'value="$(printenv "$name")"' 'printenv "$name"'
}

@test "self-test read: dynamic-name \${!name} lookup assigned to a variable" {
  assert_read_construct 'value="${!name}"' 'value="${!name}"'
}

@test "self-test read: assigning a secret variable's value to another variable" {
  assert_read_construct 'copy="$NPM_TOKEN"' 'copy="$NPM_TOKEN"'
}

@test "self-test read: assigning a *_KEY variable with braces to another variable" {
  assert_read_construct 'local k=${DEPLOY_KEY}' 'local k=${DEPLOY_KEY}'
}

@test "self-test read: a read in a python-style script under scripts/ is also caught" {
  fixture_tree 'true'
  printf '%s\n' 'x=$(cat ~/.netrc)' >"$TREE/scripts/helper.sh"
  run read_report "$TREE" "$TMP_ALLOW"
  assert_output_contains "read: scripts/helper.sh:1:"
}

# --- self-tests: things that are NOT reads, and the mention detector ------------------------------------------

@test "self-test: presence tests and plain mentions are not reads" {
  fixture_tree 'true'
  cat >"$TREE/skills/demo/scripts/evil.sh" <<'SH'
#!/usr/bin/env bash
# cat ~/.npmrc in a comment is not a read
[ -n "${!name}" ] || echo "NPM_TOKEN is not set"
printf '%s\n' "set NODE_AUTH_TOKEN first" >&2
echo "$SESSION_KEY" >/dev/null
if compgen -e | grep -qx "$name"; then :; fi
SH
  run read_report "$TREE" "$TMP_ALLOW"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; false; }
}

@test "self-test: a gh auth status probe passes the whole guard only when allow-listed" {
  fixture_tree 'gh auth status >/dev/null 2>&1'
  run guard "$TREE" "$TMP_ALLOW"
  [ "$status" -ne 0 ]
  assert_output_contains "mention: skills/demo/scripts/evil.sh:2 [gh-auth]"
  # it is not a read, so the read detector alone is clean
  run read_report "$TREE" "$TMP_ALLOW"
  [ -z "$output" ]
  printf '%s\n' 'skills/demo/scripts/evil.sh:gh-auth:gh auth status >/dev/null  # exit-code-only probe in the self-test' >"$TMP_ALLOW"
  run guard "$TREE" "$TMP_ALLOW"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "self-test: a new unclassified mention fails the mention detector naming file and line" {
  fixture_tree 'x=1'
  printf '%s\n' '# note' 'echo "Run gh auth login first"' >>"$TREE/skills/demo/scripts/evil.sh"
  run mention_report "$TREE" "$TMP_ALLOW"
  assert_output_contains "mention: skills/demo/scripts/evil.sh:4 [gh-auth]"
  printf '%s\n' 'skills/demo/scripts/evil.sh:gh-auth:Run gh auth login first  # user guidance in the self-test' >"$TMP_ALLOW"
  run mention_report "$TREE" "$TMP_ALLOW"
  [ -z "$output" ]
}

@test "self-test: a mention entry does not excuse a different file or a different class" {
  fixture_tree 'x=1'
  printf '%s\n' 'echo "Run gh auth login first"' >>"$TREE/skills/demo/scripts/evil.sh"
  printf '%s\n' 'skills/other/scripts/evil.sh:gh-auth:gh auth login  # wrong file' >"$TMP_ALLOW"
  run mention_report "$TREE" "$TMP_ALLOW"
  assert_output_contains "evil.sh:3 [gh-auth]"
  printf '%s\n' 'skills/demo/scripts/evil.sh:home-ref:gh auth login  # wrong class' >"$TMP_ALLOW"
  run mention_report "$TREE" "$TMP_ALLOW"
  assert_output_contains "evil.sh:3 [gh-auth]"
}

@test "self-test: an allow-list entry that matches nothing is reported as stale" {
  fixture_tree 'x=1'
  printf '%s\n' \
    'skills/demo/scripts/evil.sh:gh-auth:gh auth login  # no such line' \
    'skills/demo/scripts/evil.sh:read:printenv "$name"  # no such read' \
    'skills/gone/scripts/missing.sh:gh-auth:gh auth login  # file absent from the tree, skipped' >"$TMP_ALLOW"
  run stale_report "$TREE" "$TMP_ALLOW"
  assert_output_contains "stale: skills/demo/scripts/evil.sh:gh-auth:gh auth login"
  assert_output_contains 'stale: skills/demo/scripts/evil.sh:read:printenv "$name"'
  assert_output_not_contains "skills/gone/"
}

@test "self-test: a malformed or reasonless allow-list line is rejected by the parser" {
  fixture_tree 'x=1'
  printf '%s\n' \
    'skills/demo/scripts/evil.sh:gh-auth:gh auth login' \
    'skills/demo/scripts/evil.sh:gh-auth:gh auth login  # ' \
    'not an entry' >"$TMP_ALLOW"
  run allow_tsv "$TMP_ALLOW"
  [ "$(printf '%s\n' "$output" | grep -c '^MALFORMED')" -eq 3 ]
}

@test "self-test: validators are not excused (an injected validator read fails, with or without an entry for another file)" {
  fixture_tree 'x=1'
  mkdir -p "$TREE/skills/j-publish/scripts"
  printf '%s\n' '#!/usr/bin/env bash' 'NPM_TOKEN_VALUE="$(printenv NPM_TOKEN 2>/dev/null)"' \
    >"$TREE/skills/j-publish/scripts/validate_npm_env.sh"
  printf '%s\n' "$IOS_SCRIPT:read:printenv \"\$var_name\"  # the one accepted use" >"$TMP_ALLOW"
  run read_report "$TREE" "$TMP_ALLOW"
  assert_output_contains "read: skills/j-publish/scripts/validate_npm_env.sh:2:"
}
