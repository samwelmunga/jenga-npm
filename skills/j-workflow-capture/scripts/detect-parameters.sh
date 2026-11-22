#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-capture/scripts/detect-parameters.sh - propose parameters (epic E103, task E103_S02_T04)
#
# A workflow captured in project A must run in project B, so values that differ per project become run inputs.
# This script PROPOSES them for each row of a candidate-steps file (render-review-table.sh's contract); the user
# confirms or corrects them in the review, record-review.sh persists the decision through record-answer.sh, and
# emit-workflow.sh turns the confirmed ones into the definition's `inputs`. Nothing here decides: every proposal is
# shown in the review table's Parameters column. Never reads or writes the recorder's active-recording pointer.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   detect-parameters.sh propose [options] [--apply] <candidates-file>
#   detect-parameters.sh secret-check <value>
#   detect-parameters.sh -h | --help | help             this usage on stdout, exit 0
#
#   propose options (each defaults from the project, so the agent normally passes none):
#     --project-root <dir>    the project's root          default: `git rev-parse --show-toplevel` of the cwd, else cwd
#     --project-name <name>   the project's name          default: the basename of the project root
#     --repo <owner/name>     the repository              default: parsed from `git remote get-url origin`
#     --package-name <name>   the package name            default: `name` in <project-root>/package.json
#   An empty value ("") switches that kind off.
#
#   Without --apply: prints ONE JSON object on stdout,
#     {"parameters_version": 1, "rows": [{"n": 1, "parameters": [...], "redacted": <markers>, "text_redacted": bool}]}
#   with the row's proposals in the candidate-steps shape ({"name","value"} or {"name","secret":true}).
#   With --apply: writes the proposals into the candidates file itself (atomic: temp file in the same directory,
#   checked with render-review-table.sh --check, then one mv) and prints the file's path:
#     - a row whose `parameters` is already set (by an earlier run or by hand) keeps it;
#     - a row holding a redacted value is marked uncertain (reason kept when one is already there), because the
#       redaction may be a false alarm (rapport E103_S02_T02: `max_tokens=4096` becomes `max_tokens=<redacted>`);
#       the user then names the input, which the run asks a value for, or says none;
#     - a raw key-shaped value still in a row's text is replaced by <redacted> in the text, so it can never be
#       appended to a recording;
#     - a row being filled gets {"name", "secret": true} for every uncleared `secret_flags` name that
#       scan-secrets.sh left in it (E103_S03_T02), so the `${inputs.<name>}` it wrote is declared at emission.
#
# ---------------------------------------------------------------------------
# WHAT IS PROPOSED (fixed order; a value claimed by one kind is not proposed again by a later one)
# ---------------------------------------------------------------------------
#   secret        every <redacted> / <redacted private key> marker (extract-steps.sh writes them) and every raw key
#                 shape (sk-..., gh?_..., github_pat_..., xox?-..., AKIA..., AIza..., a JWT eyJ...x.y, a bearer token,
#                 URL userinfo, a private-key block). Proposed by NAME ONLY ({"name", "secret": true}), never with a value: the
#                 name is the key the value was assigned to (`api_key=<redacted>` -> api_key), else private_key,
#                 url_credentials, bearer_token or credential.
#   project_root  the project root's absolute path (also as the prefix of a longer path).
#   repo_slug     owner/name of the repository, as a whole word.
#   package_name  the package name, as a whole word; also any scoped `@scope/name` token.
#   project_name  the project's name, as a whole word.        repo_name   the repository name, when it differs.
#   <x>_path      any other absolute path (two segments or more) or `~/` path; <x> is its last component.
#   region        a cloud region such as us-east-1.            environment the value of --env/--environment/NODE_ENV=...
# Names match ^[a-z][a-z0-9_]*$. They are allocated over the whole file: the same value gets the same name in
# every row, a different value never shares a name (a later one gets _2, _3, ...). Two secrets in one row get
# distinct names; the same secret name in two rows is one input (a credential used twice).
#
# secret-check <value>: exit 0 when <value> looks like a credential by the shapes above (or holds a redaction
# marker), 1 when it does not. Prints nothing. record-review.sh uses it to refuse writing such a literal.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   success (secret-check: the value looks like a credential)
#   1   secret-check only: the value does not look like a credential
#   2   usage error
#   3   the candidates file does not exist or is not readable
#   4   the candidates file is not valid (render-review-table.sh's problems on stderr); nothing written
#   6   jq or render-review-table.sh is missing
#   7   --apply: the write failed or the result did not pass render-review-table.sh --check; the file is unchanged
#
# Compatible with macOS bash 3.2 and safe under `set -u`.
# ---------------------------------------------------------------------------

set -u
export LC_ALL=C

SELF="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER="$SCRIPT_DIR/render-review-table.sh"

err() { printf '%s: %s\n' "$SELF" "$*" >&2; }
die() { local code="$1"; shift; err "$*"; exit "$code"; }

usage() {
  cat <<'USAGE'
usage:
  detect-parameters.sh propose [--project-root <dir>] [--project-name <name>] [--repo <owner/name>]
                               [--package-name <name>] [--apply] <candidates-file>
  detect-parameters.sh secret-check <value>
  detect-parameters.sh -h | --help | help

Proposes the project-specific values in each candidate step (absolute paths, the project, repository and package
name, cloud regions, environment names, key-shaped values) as workflow parameters. A key-shaped value is proposed
by name only, never with its value. --apply writes the proposals into the candidates file. Contract and exit
codes: this script's header.
USAGE
}

# The key shapes, shared by the redaction and secret-check (same shapes as extract-steps.sh's last rule, plus
# bearer tokens, URL userinfo and private-key blocks).
JQ_SHAPES='
  def redact_shapes:
    gsub("-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY-----"; "<redacted private key>")
    | gsub("(?<s>[A-Za-z][A-Za-z0-9+.-]*://)[^/\\s:@<]+:[^/\\s@]+@"; "\(.s)<redacted>@")
    | gsub("(?<b>[Bb][Ee][Aa][Rr][Ee][Rr]\\s+)(?!<redacted>)[A-Za-z0-9._~+/=-]{8,}"; "\(.b)<redacted>")
    | gsub("(?<![A-Za-z0-9])(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|eyJ[A-Za-z0-9_-]{8,}[.][A-Za-z0-9_-]{8,}[.][A-Za-z0-9_-]+)"; "<redacted>");
  def marker_rx: "<redacted(?: private key)?>";
'

cmd_secret_check() {
  [ "$#" -eq 1 ] || { usage >&2; die 2 "secret-check needs exactly one value"; }
  command -v jq >/dev/null 2>&1 || die 6 "jq is required and was not found on PATH"
  local v="$1" r
  r="$(jq -rn --arg v "$v" "$JQ_SHAPES"' $v | (redact_shapes != $v) or test(marker_rx) or
        test("(?:api[_-]?key|apikey|token|secret|password|passwd|credential)[A-Za-z0-9_.-]*[ \\t]*[=:][ \\t]*[^\\s<]"; "i")')" || \
    die 6 "jq failed"
  [ "$r" = "true" ]
}

cmd_propose() {
  local root="" root_set=0 pname="" pname_set=0 repo="" repo_set=0 pkg="" pkg_set=0 apply=0 file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project-root) [ "$#" -ge 2 ] || die 2 "--project-root needs a value"; root="$2"; root_set=1; shift 2 ;;
      --project-root=*) root="${1#*=}"; root_set=1; shift ;;
      --project-name) [ "$#" -ge 2 ] || die 2 "--project-name needs a value"; pname="$2"; pname_set=1; shift 2 ;;
      --project-name=*) pname="${1#*=}"; pname_set=1; shift ;;
      --repo) [ "$#" -ge 2 ] || die 2 "--repo needs a value"; repo="$2"; repo_set=1; shift 2 ;;
      --repo=*) repo="${1#*=}"; repo_set=1; shift ;;
      --package-name) [ "$#" -ge 2 ] || die 2 "--package-name needs a value"; pkg="$2"; pkg_set=1; shift 2 ;;
      --package-name=*) pkg="${1#*=}"; pkg_set=1; shift ;;
      --apply) apply=1; shift ;;
      -*) usage >&2; die 2 "unknown option: $1" ;;
      *) [ -z "$file" ] || die 2 "only one candidates file, got \"$file\" and \"$1\""; file="$1"; shift ;;
    esac
  done
  [ -n "$file" ] || { usage >&2; die 2 "propose needs a candidates file"; }
  command -v jq >/dev/null 2>&1 || die 6 "jq is required and was not found on PATH"
  [ -f "$RENDER" ] || die 6 "cannot find $RENDER"
  [ -f "$file" ] || die 3 "no such candidates file: $file"
  [ -r "$file" ] || die 3 "candidates file is not readable: $file"
  local rc=0
  bash "$RENDER" --check "$file" || rc=$?
  case "$rc" in 0) ;; 4) exit 4 ;; 6) exit 6 ;; *) die 3 "could not read $file (render-review-table.sh exit $rc)" ;; esac

  if [ "$root_set" -eq 0 ]; then
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || root=""
    [ -n "$root" ] || root="$(pwd -P)"
  fi
  root="${root%/}"
  if [ "$pname_set" -eq 0 ]; then pname="$(basename "${root:-/}")"; [ "$pname" = "/" ] && pname=""; fi
  if [ "$repo_set" -eq 0 ] && [ -n "$root" ]; then
    local url
    url="$(git -C "$root" remote get-url origin 2>/dev/null)" || url=""
    url="${url%.git}"; url="${url%/}"
    repo="$(printf '%s\n' "$url" | sed -n 's#.*[:/]\([A-Za-z0-9_.-][A-Za-z0-9_.-]*/[A-Za-z0-9_.-][A-Za-z0-9_.-]*\)$#\1#p')"
  fi
  if [ "$pkg_set" -eq 0 ] && [ -n "$root" ] && [ -f "$root/package.json" ]; then
    pkg="$(jq -r '.name // empty | strings' "$root/package.json" 2>/dev/null)" || pkg=""
  fi
  local reponame="${repo##*/}"
  [ "$reponame" = "$pname" ] && reponame=""

  local JQ_DETECT="$JQ_SHAPES"'
    def rxq: gsub("(?<c>[\\\\.^$|?*+()\\[\\]{}/-])"; "\\\(.c)");
    def word($v): "(?<![A-Za-z0-9_.@/-])" + ($v | rxq) + "(?![A-Za-z0-9_/-])";
    def slug: ascii_downcase | gsub("[^a-z0-9]+"; "_") | gsub("^_+|_+$"; "")
              | if test("^[a-z]") then . else "v_" + . end | .[0:40] | sub("_+$"; "");
    def claim($v): split($v) | join("\u0001");
    # Secret candidates from the markers of a redacted text, in order.
    def secrets:
      [ scan("(?:(?<u>://)|(?<b>[Bb][Ee][Aa][Rr][Ee][Rr]\\s+)|(?<k>[A-Za-z][A-Za-z0-9_.-]*)[ \\t]*[=:][ \\t]*[\"'"'"']?)?<redacted(?<pk> private key)?>")
        | {secret: true, base: (if .[3] != null then "private_key" elif .[0] != null then "url_credentials"
                                 elif .[1] != null then "bearer_token" elif .[2] != null then (.[2] | slug)
                                 else "credential" end)} ];
    # Literal candidates, in the fixed order, each claim removed from the working copy.
    def literals:
      { w: (gsub(marker_rx; "\u0001")), out: [] }
      | if $root != "" and (.w | contains($root)) then .out += [{value: $root, base: "project_root"}] | .w |= claim($root) else . end
      | reduce ([["repo_slug", $repo], ["package_name", $pkg], ["project_name", $pname], ["repo_name", $reponame]][]
                | select(.[1] != "")) as $k (.;
          if (.w | test(word($k[1]))) then .out += [{value: $k[1], base: $k[0]}] | .w |= claim($k[1]) else . end)
      | reduce ([.w | scan("(?<![A-Za-z0-9_.@/-])@[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*")] | unique[]) as $v (.;
          .out += [{value: $v, base: "package_name"}] | .w |= claim($v))
      | reduce ([.w | scan("(?<![A-Za-z0-9_.~/:@\u0001-])(?:~(?:/[A-Za-z0-9._@+~-]+)+|(?:/[A-Za-z0-9._@+~-]+){2,})")
                 | sub("[.]+$"; "")] | unique | sort_by(length) | reverse[]) as $v (.;
          if (.w | contains($v)) then
            .out += [{value: $v, base: (($v | split("/") | last | sub("[.][^.]*$"; "") | slug) + "_path")}] | .w |= claim($v)
          else . end)
      | reduce ([.w | scan("(?<![A-Za-z0-9-])(?:us|eu|ap|sa|ca|me|af|il|mx)-(?:gov-)?(?:north|south|east|west|central|northeast|southeast|northwest|southwest)-[0-9](?![A-Za-z0-9-])")] | unique[]) as $v (.;
          .out += [{value: $v, base: "region"}] | .w |= claim($v))
      | reduce ([.w | scan("(?:--env(?:ironment)?[= ]|(?<![A-Za-z0-9_])(?:NODE_ENV|RAILS_ENV|APP_ENV|ENVIRONMENT|STAGE|ENV)=)([A-Za-z][A-Za-z0-9_-]*)")[0]] | unique[]) as $v (.;
          .out += [{value: $v, base: "environment"}] | .w |= claim($v))
      | .out;
    def candidate_names($b): [range(1; 1000) | if . == 1 then $b else "\($b)_\(.)" end];
    [ .steps | sort_by(.n)[] | . as $s | ($s.text | redact_shapes) as $r
      | {n: $s.n, text: $r, text_redacted: ($r != $s.text), redacted: ([$r | scan(marker_rx)] | length),
         cands: (($r | secrets) + ($r | literals))} ]
    | reduce .[] as $row ({names: {}, byval: {}, rows: []};
        . as $st
        | (reduce $row.cands[] as $c ({st: $st, used: {}, params: []};
            if $c.secret then
              (first(candidate_names($c.base)[] as $nm | select(.used[$nm] == null and
                       (.st.names[$nm] == null or .st.names[$nm] == "\u0002secret")) | $nm)) as $nm
              | .used[$nm] = 1 | .st.names[$nm] = "\u0002secret" | .params += [{name: $nm, secret: true}]
            elif .st.byval[$c.value] != null and .used[.st.byval[$c.value]] == null then
              .st.byval[$c.value] as $nm | .used[$nm] = 1 | .params += [{name: $nm, value: $c.value}]
            elif .st.byval[$c.value] != null then .
            else
              (first(candidate_names($c.base)[] as $nm | select(.used[$nm] == null and .st.names[$nm] == null) | $nm)) as $nm
              | .used[$nm] = 1 | .st.names[$nm] = $c.value | .st.byval[$c.value] = $nm
              | .params += [{name: $nm, value: $c.value}]
            end)) as $res
        | $res.st | .rows += [{n: $row.n, text: $row.text, text_redacted: $row.text_redacted,
                               redacted: $row.redacted, parameters: $res.params}])
    | .rows
  '
  local rows
  rows="$(jq -c --arg root "$root" --arg pname "$pname" --arg repo "$repo" --arg pkg "$pkg" \
            --arg reponame "$reponame" "$JQ_DETECT" "$file")" || die 4 "could not run the detection over $file"

  if [ "$apply" -eq 0 ]; then
    printf '%s\n' "$rows" | jq -c '{parameters_version: 1,
      rows: [.[] | {n, parameters, redacted, text_redacted}]}'
    return 0
  fi

  local reason="a value here was redacted as a possible credential; it may be a false alarm: name the input (the run asks for its value) or say none"
  local tmp
  tmp="$(mktemp "$(dirname "$file")/.detect-parameters.XXXXXX")" || die 7 "could not create a temp file next to $file"
  if ! jq --argjson rows "$rows" --arg reason "$reason" '
        .steps |= map(. as $s | ($rows[] | select(.n == $s.n)) as $d
          | .text = $d.text
          | if $s.parameters == null then
              .parameters = ($d.parameters | . as $ps
                  | . + [ [($s.secret_flags // [])[] | select(.cleared != true) | .name] | unique[] | . as $n
                          | select([$ps[] | select(.name == $n)] | length == 0) | {name: $n, secret: true} ])
              | if $d.redacted > 0 then .uncertain = true | .reason = (if ($s.reason // "") == "" then $reason else $s.reason end) else . end
            else . end)
      ' "$file" > "$tmp"; then
    rm -f "$tmp"; die 7 "could not write the proposals; $file is unchanged"
  fi
  if ! bash "$RENDER" --check "$tmp"; then
    rm -f "$tmp"; die 7 "the result did not pass render-review-table.sh --check; $file is unchanged"
  fi
  chmod 600 "$tmp" 2>/dev/null
  mv "$tmp" "$file" || { rm -f "$tmp"; die 7 "could not move the result into place; $file is unchanged"; }
  printf '%s\n' "$file"
}

[ "$#" -ge 1 ] || { usage >&2; die 2 "needs a sub-command (propose or secret-check)"; }
sub="$1"; shift
case "$sub" in
  -h|--help|help) usage; exit 0 ;;
  propose) cmd_propose "$@" ;;
  secret-check) cmd_secret_check "$@" ;;
  *) usage >&2; die 2 "unknown sub-command: $sub" ;;
esac
