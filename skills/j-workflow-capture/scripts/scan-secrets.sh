#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-capture/scripts/scan-secrets.sh - flag secret handling, write placeholders only
# (epic E103, task E103_S03_T02)
#
# A captured process often creates, copies, exports or pastes a credential: `export STRIPE_SECRET_KEY=sk_live_...`,
# "copy the API key from the dashboard", `gh auth login --with-token $GITHUB_TOKEN`. This script finds those steps in
# a CANDIDATE-STEPS FILE (render-review-table.sh's header is the contract) BEFORE anything is appended to a recording,
# flags them for the review table, and replaces every literal credential value by a `${inputs.<name>}` placeholder.
# The value itself is never written to the recording, the emitted workflow or any default, and this script never
# prints it: every report names the input and the pattern, never the value.
#
# Read-only on everything but the candidates file it is given (scan --apply, clear) and the recording it is given
# (clear, only through record-review.sh, which writes through skills/j-workflow-recorder/scripts/record-answer.sh).
# It never reads or writes the recorder's active-recording pointer, so a captured recording never becomes the
# session's active recording (epic E103, decision 6).
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   scan-secrets.sh scan [--apply] <candidates-file>
#   scan-secrets.sh check <candidates-file>
#   scan-secrets.sh clear <recording> <candidates-file> <n> [--note <text>]
#   scan-secrets.sh -h | --help | help                  this usage on stdout, exit 0
#
# scan     Without --apply: prints ONE JSON object on stdout and writes nothing,
#            {"secret_scan_version": 1, "rows": [{"n": 2, "flags": [{"kind", "pattern", "name", ...}]}]}
#          listing only the rows that carry a flag. With --apply: rewrites the candidates file (atomic: a temp file
#          in the same directory, checked with render-review-table.sh --check, then one mv) and prints its path:
#            - every literal value in a row's `text` and `evidence` is replaced by `${inputs.<name>}`;
#            - the row gets `secret_flags` (merged with the flags of an earlier run: a flag already there, cleared
#              or not, is kept as it is, so a re-run is idempotent and never re-raises a cleared flag);
#            - a row with an uncleared flag is marked uncertain, its reason ending in "secret: ..." (names and
#              pattern ids only), so the review asks about it one row at a time;
#            - a row whose `parameters` is already set gets {"name", "secret": true} appended for every uncleared
#              flag name it lacks; a row without `parameters` keeps it unset (detect-parameters.sh propose --apply
#              merges the names when it fills the row);
#            - a row with an uncleared `copy-key` flag and no `step_type` is proposed `step_type: "confirm"` (a
#              manual step that names the variable); the flag carries "set_confirm": true so clear can undo it.
# check    exit 0 when no literal would be replaced (phrasing flags do not count: they carry no value), exit 1
#          when one would, printing `<n><TAB><pattern>` per finding (never the value). write-capture.sh create runs
#          it and refuses to append a candidates file that still holds a literal.
# clear    the user said the row's flags are false positives. Marks every flag of row <n> "cleared": true, drops
#          the secret parameters only a phrasing flag introduced (a literal flag's input stays: its value was
#          replaced before the recording was written and is not recoverable, so the run asks for it), removes a
#          `confirm` type the scan proposed, strips the "secret: ..." part of the reason (the row stops being
#          uncertain when nothing else was doubted), and records the row's resulting parameters decision with
#          `record-review.sh decide <recording> <n> params ... --replace --note "secret flag cleared ..."`, i.e.
#          through record-answer.sh. Refused (exit 9) while the row's `parameters` is unset: run
#          detect-parameters.sh propose --apply first, so the recorded decision does not drop its proposals.
#          --note carries the user's own words; a note that itself looks like a credential is refused (exit 2).
#
# ---------------------------------------------------------------------------
# WHAT IS FLAGGED (fixed order; one pass per pattern over every row, so the same value gets the same input name
# in every row, and a value claimed by an earlier pattern is not seen by a later one)
# ---------------------------------------------------------------------------
#   kind "literal"  - a value is replaced by ${inputs.<name>}:
#     private-key-block   -----BEGIN ... PRIVATE KEY----- ... -----END ... PRIVATE KEY-----      name private_key
#     url-credentials     the user:password part of scheme://user:password@host                name url_credentials
#     bearer-token        Bearer <8+ token characters>                                          name bearer_token
#     auth-scheme         Authorization: token|Basic <8+ token characters>             name auth_token / basic_auth
#     user-credentials    the user:password value of -u / --user (curl and similar); not when the password part
#                         is a placeholder ($VAR, <...>, ...)                                   name user_credentials
#     cli-option          --NAME=value or --NAME value for a credential NAME (see assignment below: --password,
#                         --api-key, --token, --client-secret); the value must not start with `-`; same placeholder
#                         and space-separator rules as `:` in assignment                      name: NAME, lower-cased
#     assignment          NAME=value or NAME: value where NAME ends in key, token, secret, password, passwd, pwd,
#                         credential(s) (as a word part: SORT_KEY, GITHUB_TOKEN, api_key, apikey, authToken; not
#                         monkey or max_tokens), optionally `export`ed or quoted. With `:` the value must look like a
#                         secret (12+ characters, or 6+ with a digit), so prose such as "password: see below" is not
#                         touched. A placeholder value (<...>, $VAR, ${VAR}, %VAR%, your-..., xxx, ..., changeme) is
#                         not a literal: it is flagged as assignment-placeholder below.  name: NAME, lower-cased
#     key-shape           vendor key shapes: sk_live_/sk_test_/rk_live_/rk_test_ (stripe_secret_key /
#                         stripe_restricted_key), sk-... (api_key), ghp_/gho_/ghu_/ghs_/ghr_/github_pat_
#                         (github_token), glpat- (gitlab_token), xoxa/b/p/r/s- (slack_token), AKIA/ASIA + 16
#                         (aws_access_key_id), AIza... (google_api_key), npm_ + 36 (npm_token), a JWT eyJ.x.y (token)
#     Every further occurrence of a replaced value anywhere in the file (as a whole word) is replaced too.
#   kind "phrasing" - the step handles a credential but holds no value; the name is the variable it names:
#     copy-key                copy/paste/grab/fetch/retrieve/obtain/create/generate/regenerate/rotate/reveal/issue/
#                             get/store/save/enter ... the/your/a/new [api|access|secret|private|auth|personal
#                             access|deploy|signing|client] key|token|secret|password|credential. Name: the first
#                             NAME_KEY-style variable in the step, else the noun phrase (api_key, access_token, ...;
#                             a bare "key" is api_key, a bare "token" api_token). Proposes a confirm step.
#     export-name             export NAME (no value) for a credential-suffixed NAME
#     variable-reference      $NAME, ${NAME} or %NAME% for a credential-suffixed NAME
#     assignment-placeholder  NAME=<placeholder> (see assignment above)
# Names match ^[a-z][a-z0-9_]*$ (cut to 40). A literal name never reuses a name already given to a different value
# or to a non-secret parameter (a later one gets _2, _3, ...); a phrasing name reuses the name of the same variable.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   success (check: no literal left)
#   1   check only: a literal would still be replaced; the findings are on stdout
#   2   usage error (unknown sub-command or option, missing argument, bad row number, a credential-looking --note)
#   3   the candidates file or the recording does not exist or is not readable
#   4   the candidates file is not valid (render-review-table.sh's problems on stderr); nothing written
#   5   clear: row <n> does not exist, or has no uncleared secret flag
#   6   jq or a sibling script (render-review-table.sh, record-review.sh, detect-parameters.sh) is missing
#   7   --apply / clear: the write failed or the result did not pass render-review-table.sh --check; the file is
#       unchanged
#   9   clear: the row's `parameters` is not set yet (run detect-parameters.sh propose --apply first)
#   other  clear: record-review.sh's own exit code, passed through; the candidates file is then unchanged
#
# Compatible with macOS bash 3.2 and safe under `set -u`. Never uses the `LC_ALL=C <cmd>` prefix form.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER="$SCRIPT_DIR/render-review-table.sh"
REVIEW="$SCRIPT_DIR/record-review.sh"
DETECT="$SCRIPT_DIR/detect-parameters.sh"

err() { printf '%s: %s\n' "$SELF" "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'USAGE'
usage:
  scan-secrets.sh scan [--apply] <candidates-file>
  scan-secrets.sh check <candidates-file>
  scan-secrets.sh clear <recording> <candidates-file> <n> [--note <text>]
  scan-secrets.sh -h | --help | help

Flags candidate steps that create, copy, export or paste a credential (key-shaped values, NAME_KEY=/NAME_TOKEN=
assignments, "copy the key from the dashboard", $NAME_TOKEN references) and, with --apply, replaces every literal
value by ${inputs.<name>} before anything is appended to a recording. check refuses a file that still holds a
literal; clear records a false positive through record-review.sh (record-answer.sh). No value is ever printed.
Contract and exit codes: this script's header.
USAGE
}

# ---- the scan, one jq program -------------------------------------------------------------------------------------
# Input: the candidates file. Output: the file with text/evidence replaced and `_flags` (this run's flags) on each
# row. The literal values live only inside jq; nothing below prints them.
JQ_SCAN='
  def slug: ascii_downcase | gsub("[^a-z0-9]+"; "_") | gsub("^_+|_+$"; "")
            | if test("^[a-z]") then . else "v_" + . end | .[0:40] | sub("_+$"; "");
  def rxq: gsub("(?<c>[\\\\.^$|?*+()\\[\\]{}/-])"; "\\\(.c)");
  def credname: test("(?:^|[_.-]|api|access|secret|private|auth|refresh|bearer|client)(?:key|token|secret|password|passwd|pwd|credentials?)$"; "i");
  def placeholder: test("^(?:<.*>|[$%{].*|\\.\\.\\.+|x{3,}|X{3,}|\\*+|(?:your|my|the)[_-].*|.*[_-]here|changeme|placeholder|redacted)$"; "i");
  def sent($n): "\u0002" + $n + "\u0003";
  def rebuild($x): (.pre // "") + (.k // "") + (.kq // "") + (.sep // "") + (.q // "") + $x;
  def candidates($b): [range(1; 1000) | if . == 1 then $b else "\($b)_\(.)" end];

  def keyname:
    if test("^[sr]k_(?:live|test)_") then (if startswith("rk_") then "stripe_restricted_key" else "stripe_secret_key" end)
    elif test("^sk-") then "api_key"
    elif test("^(?:gh[pousr]_|github_pat_)") then "github_token"
    elif test("^glpat-") then "gitlab_token"
    elif test("^xox") then "slack_token"
    elif test("^(?:AKIA|ASIA)") then "aws_access_key_id"
    elif test("^AIza") then "google_api_key"
    elif test("^npm_") then "npm_token"
    else "token" end;

  def NAMERX: "(?<k>(?:[A-Za-z0-9]+[_.-])*(?:api[_-]?key|apikey|access[_-]?key|secret[_-]?key|private[_-]?key|client[_-]?secret|key|(?:auth|access|refresh|api|bearer)?[_-]?token|secret|password|passwd|pwd|credentials?))";

  # The literal patterns, in order. Every rx is consumed entirely by its named groups (pre k kq sep q v), so
  # rebuild() reproduces an unchanged match byte for byte.
  def literal_patterns: [
    {id: "private-key-block", flags: "",
     rx: "(?<v>-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----)"},
    {id: "url-credentials", flags: "",
     rx: "(?<pre>[A-Za-z][A-Za-z0-9+.-]*://)(?<v>[^/\\s:@<$\u0002\u0003]+:[^/\\s@\u0002\u0003]+)(?=@)"},
    {id: "bearer-token", flags: "",
     rx: "(?<pre>[Bb][Ee][Aa][Rr][Ee][Rr][ \\t]+)(?<v>(?![$<%{])[A-Za-z0-9._~+/=-]{8,})"},
    {id: "auth-scheme", flags: "i",
     rx: "(?<pre>authorization:[ \\t]*(?:token|basic)[ \\t]+)(?<v>(?![$<%{])[A-Za-z0-9._~+/=-]{8,})"},
    {id: "user-credentials", flags: "",
     rx: "(?<pre>(?<![A-Za-z0-9_-])(?:-u|--user)(?:[ \\t]+|=))(?<q>[\"\u0027]?)(?<v>[^\\s\"\u0027:@$<%{\u0002\u0003]+:[^\\s\"\u0027\u0002\u0003]+)"},
    {id: "cli-option", flags: "i",
     rx: ("(?<pre>(?<![A-Za-z0-9_-])--)" + NAMERX + "(?<sep>=|[ \\t]+)(?<q>[\"\u0027]?)(?<v>(?!-)[^\\s\"\u0027`,;\u0002\u0003]+)")},
    {id: "assignment", flags: "i",
     rx: ("(?<![A-Za-z0-9_.$-])" + NAMERX + "(?<kq>[\"\u0027]?)(?<sep>[ \\t]*=[ \\t]*|[ \\t]*:[ \\t]+)(?<q>[\"\u0027]?)(?<v>[^\\s\"\u0027`,;\u0002\u0003]+)")},
    {id: "key-shape", flags: "",
     rx: "(?<![A-Za-z0-9_])(?<v>(?:[sr]k_(?:live|test)_[A-Za-z0-9]{8,}|sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|(?:AKIA|ASIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|npm_[A-Za-z0-9]{36}|eyJ[A-Za-z0-9_-]{8,}[.][A-Za-z0-9_-]{8,}[.][A-Za-z0-9_-]+))(?![A-Za-z0-9_])"}
  ];

  # Is this match a literal to replace? (assignment only filters; the others always are.)
  def keep($p):
    if $p.id == "user-credentials" then (.v | split(":")[1:] | join(":") | placeholder | not)
    elif ($p.id != "assignment" and $p.id != "cli-option") then true
    elif (.v | placeholder) then false
    elif (.sep | contains("=")) then true
    else ((.v | length) >= 12 or ((.v | length) >= 6 and (.v | test("[0-9]")))) end;

  def basename($p): if ($p.id == "assignment" or $p.id == "cli-option") then (.k | slug)
                    elif $p.id == "auth-scheme" then (if (.pre | test("basic"; "i")) then "basic_auth" else "auth_token" end)
                    elif $p.id == "user-credentials" then "user_credentials"
                    elif $p.id == "key-shape" then (.v | keyname)
                    elif $p.id == "private-key-block" then "private_key"
                    elif $p.id == "url-credentials" then "url_credentials"
                    else "bearer_token" end;

  # Allocation over state {byval, used}; used[name] is lit | phr | param | secret.
  def alloc_lit($v; $b):
    if .byval[$v] != null then .
    else (. as $st | first(candidates($b)[] | select($st.used[.] == null or $st.used[.] == "phr"))) as $n
         | .used[$n] = "lit" | .byval[$v] = $n end;
  def alloc_phr($b):
    if (.used[$b] // "") == "param" then
      (. as $st | first(candidates($b)[] | select($st.used[.] == null or $st.used[.] == "phr"))) as $n
      | .used[$n] = "phr" | .last = $n
    else .used[$b] = (.used[$b] // "phr") | .last = $b end;

  # The strings of a row that are scanned: text, then every evidence item (a non-string item as its JSON).
  def ev_str: if type == "string" then . else tojson end;

  def flag_add($f): ._flags = ((._flags // []) + [$f] | unique_by([.kind, .pattern, .name]));

  # One literal pattern over every row.
  def literal_pass($p):
    reduce range(0; .rows | length) as $i (.;
      ([.rows[$i].text] + [(.rows[$i].evidence // [])[] | ev_str]) as $strs
      | [ $strs[] | [capture($p.rx; "g" + $p.flags)][] | select(keep($p)) | {v, b: basename($p)} ] as $hits
      | reduce $hits[] as $h (.;
          alloc_lit($h.v; $h.b)
          | .byval[$h.v] as $n
          | .rows[$i] |= flag_add({kind: "literal", pattern: $p.id, name: $n}))
      | .byval as $bv
      | .rows[$i].text |= gsub($p.rx; if keep($p) and $bv[.v] != null then rebuild(sent($bv[.v])) else rebuild(.v) end; $p.flags)
      | if .rows[$i].evidence != null then
          .rows[$i].evidence |= map(. as $o | ($o | ev_str) as $s
            | ($s | gsub($p.rx; if keep($p) and $bv[.v] != null then rebuild(sent($bv[.v])) else rebuild(.v) end; $p.flags)) as $r
            | if $r == $s then $o else $r end)
        else . end);

  # Every further whole-word occurrence of a replaced value, anywhere in the file.
  def repeat_pass:
    .byval as $bv
    | ($bv | to_entries | sort_by(.key | length) | reverse) as $pairs
    | def rep: reduce $pairs[] as $e (.; gsub("(?<![A-Za-z0-9_\u0002])" + ($e.key | rxq) + "(?![A-Za-z0-9_\u0003])"; sent($e.value)));
      .rows |= map(.text |= rep
                   | if .evidence != null then .evidence |= map(. as $o | ($o | ev_str) as $s | ($s | rep) as $r
                                                                | if $r == $s then $o else $r end)
                     else . end);

  def finish: gsub("\u0002(?<n>[a-z0-9_]+)\u0003"; "${inputs.\(.n)}");

  # Phrasing over one finished text; emits {pattern, base, confirm}.
  def phrasing:
    . as $t
    | ([$t | scan("(?<![A-Za-z0-9_])([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*)(?![A-Za-z0-9_])")[0] | select(credname)] | first // null) as $var
    | ( [ $t | capture("\\b(?:copy|paste|grab|fetch|retrieve|obtain|create|generate|regenerate|rotate|reveal|issue|get|store|save|enter)\\b[^.\\n]{0,40}?\\b(?:the|your|an?|new|this|that)[ \\t]+(?:new[ \\t]+)?(?:(?<q>api|access|secret|private|auth|personal[ \\t]+access|deploy|signing|client)[ \\t_-]?)?(?<noun>key|token|secret|password|credential)s?\\b"; "gi") ]
        | if length > 0 then
            .[0] as $c
            | [{pattern: "copy-key", confirm: true,
                base: (if $var != null then ($var | slug)
                       elif $c.q != null then (($c.q + "_" + $c.noun) | slug)
                       elif ($c.noun | ascii_downcase) == "key" then "api_key"
                       elif ($c.noun | ascii_downcase) == "token" then "api_token"
                       else ($c.noun | slug) end)}]
          else [] end )[],
      ( $t | [capture("(?<![A-Za-z0-9_])export[ \\t]+(?<k>[A-Za-z_][A-Za-z0-9_]*)(?![A-Za-z0-9_])(?![ \\t]*=)"; "g")][]
        | select(.k | credname) | {pattern: "export-name", confirm: false, base: (.k | slug)} ),
      ( $t | [capture("(?:\\$\\{?|%)(?<k>[A-Za-z_][A-Za-z0-9_]*)"; "g")][]
        | select(.k | credname) | {pattern: "variable-reference", confirm: false, base: (.k | slug)} ),
      ( $t | [capture("(?<![A-Za-z0-9_.$-])" + NAMERX + "(?<kq>[\"\u0027]?)[ \\t]*=[ \\t]*[\"\u0027]?(?<v>[^\\s\"\u0027`,;]+)"; "gi")][]
        | select((.v | startswith("${inputs.") | not) and (.v | placeholder))
        | {pattern: "assignment-placeholder", confirm: false, base: (.k | slug)} );

  def phrasing_pass:
    reduce range(0; .rows | length) as $i (.;
      [.rows[$i].text | phrasing] as $ph
      | reduce $ph[] as $f (.;
          alloc_phr($f.base) | .last as $n
          | .rows[$i] |= flag_add({kind: "phrasing", pattern: $f.pattern, name: $n}
                                  + (if $f.confirm then {suggest_confirm: true} else {} end))));

  # Seed the allocation state from the file: existing parameters and the flags of an earlier run.
  def seed($in_flags):
    { rows: .steps,
      byval: {},
      used: (reduce (.steps[] | (.parameters // [])[]) as $p ({};
               .[$p.name] = (if .[$p.name] == "secret" or $p.secret == true then "secret" else "param" end))
             | reduce ($in_flags[]) as $f (.; .[$f.name] = (if $f.kind == "literal" then "lit" else "phr" end))) };

  ([.steps[] | (.secret_flags // [])[]]) as $in_flags
  | seed($in_flags)
  | reduce literal_patterns[] as $p (.; literal_pass($p))
  | repeat_pass
  | .rows |= map(.text |= finish | if .evidence != null then .evidence |= map(if type == "string" then finish else . end) else . end)
  | phrasing_pass
  | .rows
'

# Merges this run's `_flags` into the file (scan --apply).
JQ_MERGE='
  def summary: [.[] | select(.cleared != true)] | group_by(.name)
               | map("\(.[0].name) (\([.[].kind] | unique | join("+")))") | join(", ");
  def strip_secret: if . == null then "" else sub("(?:; )?secret: .*$"; "") end;
  . as $doc
  | .steps |= [ .[] | . as $s | ($rows[] | select(.n == $s.n)) as $r
      | .text = $r.text
      | (if $r.evidence != null then .evidence = $r.evidence else . end)
      | ((.secret_flags // []) as $old
         | $old + [ ($r._flags // [])[] | . as $f
                    | select([$old[] | select(.kind == $f.kind and .pattern == $f.pattern and .name == $f.name)] | length == 0) ]) as $flags
      | if ($flags | length) == 0 then . else
          .secret_flags = $flags
          | [ $flags[] | select(.cleared != true) ] as $live
          | if ($live | length) == 0 then . else
              (if .parameters != null then
                 .parameters as $ps
                 | .parameters += [ $live | map(.name) | unique[] | . as $n
                                    | select([$ps[] | select(.name == $n)] | length == 0) | {name: $n, secret: true} ]
               else . end)
              | (if .step_type == null and ([$live[] | select(.suggest_confirm == true)] | length) > 0 then
                   .step_type = "confirm"
                   | .secret_flags |= map(if .suggest_confirm == true and .cleared != true then .set_confirm = true else . end)
                 else . end)
              | .uncertain = true
              | (.reason | strip_secret) as $base
              | .reason = ((if $base == "" then "" else $base + "; " end)
                           + "secret: " + ($live | summary) + "; clear it if it is a false positive")
            end
        end ]
'

need_file() {
  [ -f "$1" ] || die 3 "no such $2: $1"
  [ -r "$1" ] || die 3 "$2 is not readable: $1"
}

check_candidates() {
  command -v jq >/dev/null 2>&1 || die 6 "jq is required and was not found on PATH"
  [ -f "$RENDER" ] || die 6 "cannot find $RENDER"
  need_file "$1" "candidates file"
  local rc=0
  bash "$RENDER" --check "$1" || rc=$?
  case "$rc" in 0) ;; 4) exit 4 ;; 6) exit 6 ;; *) die 3 "could not read $1 (render-review-table.sh exit $rc)" ;; esac
}

# Writes stdin-produced JSON ($2) atomically to $1 after a render --check.
atomic_write() {
  local file="$1" content="$2" tmp
  tmp="$(mktemp "$(dirname "$file")/.scan-secrets.XXXXXX")" || die 7 "could not create a temp file next to $file"
  if ! printf '%s\n' "$content" > "$tmp"; then
    rm -f "$tmp"; die 7 "could not write the result; $file is unchanged"
  fi
  if ! bash "$RENDER" --check "$tmp"; then
    rm -f "$tmp"; die 7 "the result did not pass render-review-table.sh --check; $file is unchanged"
  fi
  chmod 600 "$tmp" 2>/dev/null
  mv "$tmp" "$file" || { rm -f "$tmp"; die 7 "could not move the result into place; $file is unchanged"; }
}

run_scan() {
  jq -c "$JQ_SCAN" "$1" || die 4 "could not run the scan over $1"
}

cmd_scan() {
  local apply=0 file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply) apply=1; shift ;;
      -*) usage >&2; die 2 "unknown option for scan: $1" ;;
      *) [ -z "$file" ] || die 2 "only one candidates file, got \"$file\" and \"$1\""; file="$1"; shift ;;
    esac
  done
  [ -n "$file" ] || { usage >&2; die 2 "scan needs a candidates file"; }
  check_candidates "$file"
  local rows
  rows="$(run_scan "$file")" || exit $?
  if [ "$apply" -eq 0 ]; then
    printf '%s\n' "$rows" | jq -c '{secret_scan_version: 1,
      rows: [.[] | select((._flags // []) | length > 0) | {n, flags: ._flags}]}'
    return 0
  fi
  local out
  out="$(jq --argjson rows "$rows" "$JQ_MERGE" "$file")" || die 7 "could not merge the flags; $file is unchanged"
  atomic_write "$file" "$out"
  printf '%s\n' "$file"
}

cmd_check() {
  [ "$#" -eq 1 ] || { usage >&2; die 2 "check needs exactly one candidates file"; }
  check_candidates "$1"
  local rows found
  rows="$(run_scan "$1")" || exit $?
  found="$(printf '%s\n' "$rows" | jq -r '.[] | .n as $n | (._flags // [])[] | select(.kind == "literal")
                                          | "\($n)\t\(.pattern)"' | sort -u -n)"
  if [ -n "$found" ]; then
    printf '%s\n' "$found"
    return 1
  fi
  return 0
}

cmd_clear() {
  local note="" note_set=0 args=""
  local rec="" cands="" n=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note) [ "$#" -ge 2 ] || die 2 "--note needs a value"; note="$2"; note_set=1; shift 2 ;;
      --note=*) note="${1#--note=}"; note_set=1; shift ;;
      -*) usage >&2; die 2 "unknown option for clear: $1" ;;
      *)
        if [ -z "$rec" ]; then rec="$1"
        elif [ -z "$cands" ]; then cands="$1"
        elif [ -z "$n" ]; then n="$1"
        else die 2 "clear takes <recording> <candidates-file> <n>; unexpected \"$1\""; fi
        shift ;;
    esac
  done
  [ -n "$n" ] || { usage >&2; die 2 "clear needs <recording> <candidates-file> <n>"; }
  case "$n" in ''|*[!0-9]*|0*) die 2 "clear wants a positive row number, got \"$n\"" ;; esac
  [ -f "$REVIEW" ] || die 6 "cannot find $REVIEW"
  [ -f "$DETECT" ] || die 6 "cannot find $DETECT"
  need_file "$rec" "recording"
  check_candidates "$cands"
  if [ "$note_set" -eq 1 ] && [ -n "$note" ]; then
    # Both detectors: detect-parameters.sh's secret-check and this script's own literal patterns.
    local ntmp nfound
    ntmp="$(mktemp "$(dirname "$cands")/.scan-secrets-note.XXXXXX")" || die 7 "could not create a temp file next to $cands"
    jq -n --arg t "$note" '{candidate_steps_version: 1, steps: [{n: 1, text: $t}]}' > "$ntmp" || { rm -f "$ntmp"; die 7 "could not check the note"; }
    nfound="$(jq -c "$JQ_SCAN" "$ntmp" 2>/dev/null | jq -r '[.[] | (._flags // [])[] | select(.kind == "literal")] | length')"
    rm -f "$ntmp"
    if bash "$DETECT" secret-check "$note" || [ "${nfound:-1}" != "0" ]; then
      die 2 "the note looks like it holds a credential; it is never written down - describe the false positive without the value"
    fi
  fi

  local state
  state="$(jq -r --argjson n "$n" '
      [.steps[] | select(.n == $n)] | if length == 0 then "missing"
      elif ([.[0].secret_flags // [] | .[] | select(.cleared != true)] | length) == 0 then "noflag"
      elif .[0].parameters == null then "noparams" else "ok" end' "$cands")" || die 4 "could not read $cands"
  case "$state" in
    missing) die 5 "no row $n in $cands" ;;
    noflag) die 5 "row $n has no uncleared secret flag" ;;
    noparams) die 9 "row $n has no parameters yet; run detect-parameters.sh propose --apply on $cands first" ;;
  esac

  local out
  out="$(jq --argjson n "$n" '
      .steps |= map(if .n != $n then . else
        (.secret_flags | map(select(.cleared != true))) as $live
        | ([$live[] | select(.kind == "literal") | .name] | unique) as $litnames
        | ([$live[] | select(.kind == "phrasing") | .name] | unique
           | map(. as $x | select(($litnames | index($x)) == null))) as $drop
        | .parameters |= map(. as $p | select(($p.secret == true and ($drop | index($p.name)) != null) | not))
        | (if .step_type == "confirm" and ([$live[] | select(.set_confirm == true)] | length) > 0
           then del(.step_type) else . end)
        | .secret_flags |= map(if .cleared != true then .cleared = true | del(.set_confirm) else . end)
        | (.reason // "" | sub("(?:; )?secret: .*$"; "")) as $base
        | if $base == "" then del(.reason) | del(.uncertain) else .reason = $base end
      end)' "$cands")" || die 7 "could not compute the cleared row; $cands is unchanged"

  local summary params
  summary="$(jq -r --argjson n "$n" '[.steps[] | select(.n == $n) | .secret_flags[] | select(.cleared != true)
                                      | "\(.name) (\(.kind): \(.pattern))"] | unique | join(", ")' "$cands")"
  params="$(printf '%s\n' "$out" | jq -r --argjson n "$n" '.steps[] | select(.n == $n) | .parameters
                                     | if length == 0 then "none" else .[] | if .secret == true then .name else "\(.name)=\(.value)" end end')"

  local full_note="secret flag cleared by the user as a false positive: $summary. A replaced value was not recorded; its input stays and the run asks for it."
  if [ "$note_set" -eq 1 ] && [ -n "$note" ]; then
    full_note="$full_note User: $note"
  fi

  # Build the params argument list (one argument per line of $params; bash 3.2, no mapfile).
  local -a pargs
  pargs=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && pargs[${#pargs[@]}]="$line"
  done <<EOF_PARAMS
$params
EOF_PARAMS

  # The out file is checked BEFORE the decision is recorded, so a bad result writes nothing anywhere.
  local tmp
  tmp="$(mktemp "$(dirname "$cands")/.scan-secrets.XXXXXX")" || die 7 "could not create a temp file next to $cands"
  if ! printf '%s\n' "$out" > "$tmp" || ! bash "$RENDER" --check "$tmp"; then
    rm -f "$tmp"; die 7 "the cleared row did not pass render-review-table.sh --check; nothing was written"
  fi
  local rc=0
  bash "$REVIEW" decide "$rec" "$n" params "${pargs[@]}" --note "$full_note" --replace || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"; err "record-review.sh refused the decision (exit $rc); $cands is unchanged"; exit "$rc"
  fi
  chmod 600 "$tmp" 2>/dev/null
  mv "$tmp" "$cands" || { rm -f "$tmp"; die 7 "the decision was recorded but $cands could not be updated; run clear again"; }
  printf '%s\tparameters\tcleared %s\n' "$n" "$summary"
}

[ "$#" -ge 1 ] || { usage >&2; die 2 "needs a sub-command (scan, check or clear)"; }
sub="$1"; shift
case "$sub" in
  -h|--help|help) usage; exit 0 ;;
  scan) cmd_scan "$@" ;;
  check) cmd_check "$@" ;;
  clear) cmd_clear "$@" ;;
  *) usage >&2; die 2 "unknown sub-command: $sub" ;;
esac
