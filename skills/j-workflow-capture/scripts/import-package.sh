#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-capture/scripts/import-package.sh - install a portable workflow package (E103_S05_T03)
#
# The importing side of export-package.sh (E103_S05_T02). A package comes from another project, so it is untrusted
# input: it is unpacked into a fresh empty temporary directory, every member is checked against the manifest
# (path, type, sha256, size) before any content is read, every file is shown verbatim, and NOTHING is written in the
# project until `install` is called with --confirm. After writing, the definition must pass validate-workflow.sh,
# every compute command must pass resolve-compute-command.sh and the workflow must load as a project workflow;
# otherwise everything written is rolled back. No packaged script is ever executed here.
# Never reads or writes the recorder's active-recording pointer.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   import-package.sh inspect <package> [--rename <new-id> | --replace]
#   import-package.sh install <package> --confirm [--rename <new-id> | --replace]
#   import-package.sh -h | --help | help        this usage on stdout, exit 0
#
#   inspect      verify the package and print the review (below) on stdout. Writes nothing in the project.
#   install      run every inspect check again, then write the files, validate them in this project and print the
#                installed definition's path on stdout. Refuses without --confirm (exit 8).
#   --rename <new-id>  install under another id: the definition's `id` becomes <new-id> and its wrapper scripts go
#                      to <workflows>/scripts/<new-id>/. The new id must match the schema's id_pattern and collide
#                      with nothing.
#   --replace    replace the existing project workflow with the same id (its definition file and its
#                <workflows>/scripts/<id>/ directory), and overwrite any template file the review lists as a
#                conflict. Never possible against a builtin id: a builtin always wins (E80), so rename instead.
#
# ---------------------------------------------------------------------------
# WHAT IS CHECKED (inspect and install, before anything is written)
# ---------------------------------------------------------------------------
#   The archive: a gzip tar whose members are regular files or directories only (no symlink, no hard link, no
#   device), each name a relative path of letters, digits, spaces and `. _ @ + / -` with no `.`, `..` or empty
#   segment, under manifest.json, definition/, scripts/ or templates/. It is unpacked only after that check.
#   The manifest: format "jenga-workflow-package", format_version 1, a workflow_id matching the schema's id_pattern,
#   and a `files` array (export-package.sh's header is the format) in which every entry has a known role whose path
#   prefix agrees with it, a 64-hex sha256, a size and an executable flag. Exactly one definition, at
#   definition/<workflow_id>.json. Every unpacked file is listed and every listed file is present; each file's
#   sha256 and size match its entry. The definition is a JSON object with a steps array, its `id` equals
#   workflow_id, and it passes validate-workflow.sh as it will be installed.
#   The target: <workflows> is `scripts/resolve-root.sh get workflows`, <anchor> is `scripts/resolve-root.sh root`.
#     definition  -> <workflows>/<id>.json
#     scripts     -> <workflows>/scripts/<id>/<path below scripts/>, mode 755 when the manifest says executable
#     templates   -> <anchor>/<path below templates/>, mode 644 (the anchor-relative path the definition uses)
#   A template destination must resolve inside <anchor> and may not be under .git, .claude, .agents, node_modules,
#   hooks/, scripts/, skills/<name>/scripts/ or <workflows>/scripts/, nor be a .json directly in <workflows>.
#   An existing template with the same content is left as it is; one with other content is a conflict.
#   A compute command that names a packaged script by its exporting path (`.../scripts/<exported-id>/<file>`) is
#   rewritten to this project's <workflows>/scripts/<id>/<file>, so a rename or a relocated tree still runs.
#
# ---------------------------------------------------------------------------
# THE REVIEW (inspect stdout)
# ---------------------------------------------------------------------------
#   Fixed-key lines first, then every file in full:
#     package      <path>
#     workflow     <exported id>
#     installs-as  <target id>
#     collision    none | project <file> | builtin <file>
#     choice       none | rename | replace
#     file         <role> <member> -> <destination> [new|replaces|unchanged|conflict] [executable]
#                  (replaces: overwritten with --replace; conflict: an existing template differs, exit 7)
#     command      <step id> <command as installed>                    (one per compute step)
#   then, for the definition (as it will be installed) and every script and template:
#     ===== BEGIN <member> sha256:<hex> =====
#     <the file's bytes, unchanged; when it holds control characters other than TAB and newline, it is shown in
#      cat -v notation instead, after a "(control characters shown as ^X, in cat -v notation)" line>
#     ===== END <member> sha256:<hex> =====
#   The marker lines carry the file's own sha256, so a file cannot forge its end marker.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   inspect: the review was printed and install would proceed with these options
#       install: installed and validated; the definition's path on stdout
#   2   usage error, or --rename names an id that does not match the schema's id_pattern
#   3   not a readable package: missing file, not a gzip tar, no manifest.json, wrong format or format_version
#   4   the package fails verification (unsafe or unlisted member, missing file, sha256 or size mismatch, malformed
#       manifest or definition); nothing was written
#   5   an id collision needs a choice: a project workflow has the id (rename, replace or cancel), a builtin has it
#       (rename), or the --rename id itself collides. inspect still prints the review
#   6   the environment is incomplete: jq, tar, gzip, a sha256 tool, the schema, resolve-root.sh or the E80 scripts
#   7   a destination cannot be written as asked: a template conflict without --replace, a refused template
#       destination, a symlinked target, or another project file declaring the id. inspect still prints the review
#       when the package itself is sound
#   8   install without --confirm; nothing was written
#   9   the installed workflow failed validation in this project (validate-workflow.sh, resolve-compute-command.sh
#       or the workflow loader); everything written was rolled back and the reason is on stderr
#   10  a write failed; everything written was rolled back
#
# Compatible with macOS bash 3.2 and safe under `set -u`.
# ---------------------------------------------------------------------------
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '3,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die() { local code="$1"; shift; printf 'import-package.sh: %s\n' "$*" >&2; exit "$code"; }

MODE=""
PKG=""
CONFIRM=0
RENAME=""
REPLACE=0
case "${1:-}" in
  -h|--help|help) printf 'usage:\n'; usage; exit 0 ;;
  inspect|install) MODE="$1"; shift ;;
  "") die 2 "a sub-command is required: inspect or install (see --help)" ;;
  *) die 2 "unknown sub-command \"$1\" (see --help)" ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) printf 'usage:\n'; usage; exit 0 ;;
    --confirm) CONFIRM=1; shift ;;
    --replace) REPLACE=1; shift ;;
    --rename) [ $# -ge 2 ] && [ -n "$2" ] || die 2 "--rename needs a workflow id"; RENAME="$2"; shift 2 ;;
    -*) die 2 "unknown option $1 (see --help)" ;;
    *) [ -z "$PKG" ] || die 2 "one package only (got \"$PKG\" and \"$1\")"; PKG="$1"; shift ;;
  esac
done
[ -n "$PKG" ] || die 2 "a package file is required (see --help)"
[ -n "$RENAME" ] && [ "$REPLACE" -eq 1 ] && die 2 "--rename and --replace exclude each other; choose one"
[ "$MODE" = inspect ] && [ "$CONFIRM" -eq 1 ] && die 2 "--confirm belongs to install; inspect never writes"

# --- environment -------------------------------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || die 6 "jq is required"
command -v tar >/dev/null 2>&1 || die 6 "tar is required"
command -v gzip >/dev/null 2>&1 || die 6 "gzip is required"
if command -v shasum >/dev/null 2>&1; then sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then sha256_of() { sha256sum "$1" | awk '{print $1}'; }
else die 6 "shasum or sha256sum is required"; fi

# shellcheck source=/dev/null
if [ -f "$SCRIPT_DIR/../../index/scripts/package-root.sh" ]; then . "$SCRIPT_DIR/../../index/scripts/package-root.sh"; else jenga_package_root() { (cd "$1/../../.." && pwd); }; fi
PKG_ROOT="$(jenga_package_root "$SCRIPT_DIR" 2>/dev/null)" || true
RESOLVE_ROOT="$PKG_ROOT/scripts/resolve-root.sh"
SCHEMA="$PKG_ROOT/templates/workflow-schema.json"
WF_LIB="$PKG_ROOT/scripts/workflow/lib.sh"
VALIDATE="$PKG_ROOT/scripts/workflow/validate-workflow.sh"
RESOLVE_CMD="$PKG_ROOT/scripts/workflow/resolve-compute-command.sh"
LOADER="$PKG_ROOT/scripts/workflow/load-workflows.sh"
[ -f "$RESOLVE_ROOT" ] || die 6 "resolve-root.sh not found under $PKG_ROOT/scripts"
[ -f "$SCHEMA" ] || die 6 "the workflow schema was not found at $SCHEMA"
for f in "$WF_LIB" "$VALIDATE" "$RESOLVE_CMD" "$LOADER"; do [ -f "$f" ] || die 6 "$f was not found"; done

ID_PATTERN="$(jq -r '.top_level.id_pattern // empty' "$SCHEMA" 2>/dev/null)"
[ -n "$ID_PATTERN" ] || die 6 "$SCHEMA carries no top_level.id_pattern"
is_id() { printf '%s\n' "$1" | grep -Eq "$ID_PATTERN" && [ "$(printf '%s' "$1" | wc -l | tr -d ' ')" = "0" ]; }
[ -z "$RENAME" ] || is_id "$RENAME" || die 2 "\"$RENAME\" is not a workflow id (it must match $ID_PATTERN)"

WF_DIR="$(bash "$RESOLVE_ROOT" get workflows 2>/dev/null)" && [ -n "$WF_DIR" ] || \
  die 6 "could not resolve the workflows directory with resolve-root.sh get workflows"
ANCHOR="$(bash "$RESOLVE_ROOT" root 2>/dev/null)" && [ -n "$ANCHOR" ] || \
  die 6 "could not resolve the project anchor with resolve-root.sh root"
ANCHOR_REAL="$(cd "$ANCHOR" 2>/dev/null && pwd -P)" || die 6 "the project anchor $ANCHOR is not a directory"
case "$WF_DIR" in
  "$ANCHOR"/*) WF_REL="${WF_DIR#"$ANCHOR"/}" ;;
  "$ANCHOR_REAL"/*) WF_REL="${WF_DIR#"$ANCHOR_REAL"/}" ;;
  /*) die 6 "the workflows directory $WF_DIR is not inside the project anchor $ANCHOR" ;;
  *) WF_REL="$WF_DIR" ;;
esac
WF_DIR="$ANCHOR_REAL/$WF_REL"

# --- the package -------------------------------------------------------------------------------------------------
[ -f "$PKG" ] && [ -r "$PKG" ] || die 3 "$PKG is not a readable file"
gzip -t "$PKG" >/dev/null 2>&1 || die 3 "$PKG is not a gzip-compressed package"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/import-package.XXXXXX")" || die 10 "could not create a temporary directory"
JOURNAL="$WORK/.journal"   # one action per line, TAB-separated: rmfile <path> | rmtree <dir> | restore <backup> <path>
: > "$JOURNAL"
WRITING=0
rollback() {
  local action a b
  awk '{l[NR] = $0} END {for (i = NR; i > 0; i--) print l[i]}' "$JOURNAL" | while IFS="$(printf '\t')" read -r action a b; do
    case "$action" in
      rmfile) rm -f "$a" ;;
      rmtree) rm -rf "$a" ;;
      restore) rm -rf "$b"; mv -f "$a" "$b" ;;
    esac
  done
  : > "$JOURNAL"
}
cleanup() { [ "$WRITING" -eq 1 ] && rollback; rm -rf "$WORK"; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM

NAMES="$WORK/.names"
VERBOSE_LIST="$WORK/.verbose"
tar -tzf "$PKG" > "$NAMES" 2>/dev/null || die 3 "$PKG is not a readable tar archive"
tar -tvzf "$PKG" > "$VERBOSE_LIST" 2>/dev/null || die 3 "$PKG is not a readable tar archive"
[ "$(wc -l < "$NAMES")" -eq "$(wc -l < "$VERBOSE_LIST")" ] || die 4 "the package lists a member name it cannot list safely"
grep -qx 'manifest.json' "$NAMES" || die 3 "$PKG holds no manifest.json; it is not a workflow package"

# Member types: regular files and directories only.
bad="$(awk '{ t = substr($1, 1, 1); if ((t != "-" && t != "d") || index($0, " link to ") || index($0, " -> ")) { print; exit } }' "$VERBOSE_LIST")"
[ -z "$bad" ] || die 4 "the package holds a member that is not a regular file or directory (a link or a device): $bad"
# Member names.
seen_dup="$(LC_ALL=C sort "$NAMES" | uniq -d | head -n 1)"
[ -z "$seen_dup" ] || die 4 "the package lists the member \"$seen_dup\" twice"
while IFS= read -r n; do
  name="${n%/}"
  printf '%s\n' "$name" | grep -Eq '^[A-Za-z0-9._@+/ -]+$' || die 4 "the member \"$n\" has a name a package may not use"
  case "$name" in /*) die 4 "the member \"$n\" is an absolute path" ;; esac
  case "/$name/" in */../*|*/./*|*//*) die 4 "the member \"$n\" has a ., .. or empty path segment" ;; esac
  case "$name" in
    manifest.json|definition|scripts|templates|definition/*|scripts/*|templates/*) ;;
    *) die 4 "the member \"$n\" is outside manifest.json, definition/, scripts/ and templates/" ;;
  esac
done < "$NAMES"

X="$WORK/pkg"
mkdir "$X" || die 10 "could not create the unpack directory"
tar -xzf "$PKG" -C "$X" 2>/dev/null || die 4 "the package could not be unpacked"
bad="$(find "$X" -mindepth 1 ! -type f ! -type d -print 2>/dev/null | head -n 1)"
[ -z "$bad" ] || die 4 "the package unpacked a member that is not a regular file or directory: ${bad#"$X"/}"

# --- the manifest ------------------------------------------------------------------------------------------------
MAN="$X/manifest.json"
[ -f "$MAN" ] || die 3 "the package holds no manifest.json file"
jq -e 'type == "object"' "$MAN" >/dev/null 2>&1 || die 3 "manifest.json is not a JSON object"
[ "$(jq -r '.format // empty' "$MAN")" = "jenga-workflow-package" ] || die 3 "manifest.json is not a jenga-workflow-package manifest"
[ "$(jq -r '.format_version // empty' "$MAN")" = "1" ] || \
  die 3 "manifest.json has format_version $(jq -c '.format_version' "$MAN"); this importer reads version 1"
SRC_ID="$(jq -r '.workflow_id | strings' "$MAN")"
is_id "$SRC_ID" || die 4 "the manifest's workflow_id \"$SRC_ID\" is not a workflow id"
problem="$(jq -r --arg id "$SRC_ID" '
  if (.files | type) != "array" then "files is not an array"
  else (.files | map(
      if type != "object" then "a files entry is not an object"
      elif (.path | type) != "string" then "a files entry has no path"
      elif ((.role == "definition" and (.path | startswith("definition/"))) or
            (.role == "script" and (.path | startswith("scripts/"))) or
            (.role == "template" and (.path | startswith("templates/")))) | not
        then "\(.path): role \(.role) does not match its path"
      elif ((.sha256 | type) != "string") or ((.sha256 | test("^[0-9a-f]{64}$")) | not) then "\(.path): sha256 is not 64 hex digits"
      elif ((.size | type) != "number") or .size < 0 then "\(.path): size is not a number"
      elif (.executable | type) != "boolean" then "\(.path): executable is not true or false"
      else empty end) | first) //
    (if ([.files[].path] | length) != ([.files[].path] | unique | length) then "a path is listed twice"
     elif ([.files[] | select(.role == "definition")] | length) != 1 then "the manifest does not list exactly one definition"
     elif ([.files[] | select(.role == "definition") | .path][0]) != "definition/\($id).json"
       then "the definition is not definition/\($id).json"
     else empty end)
  end' "$MAN" 2>/dev/null)" || die 4 "manifest.json could not be read"
[ -z "$problem" ] || die 4 "manifest.json: $problem"

TAB="$(printf '\t')"
ENTRIES="$WORK/.entries"   # path TAB role TAB sha256 TAB size TAB executable, sorted by path
jq -r '.files[] | [.path, .role, .sha256, (.size | tostring), (.executable | tostring)] | @tsv' "$MAN" \
  | LC_ALL=C sort -t "$TAB" -k1,1 > "$ENTRIES"
# Every unpacked file is listed, and every listed file is unpacked.
(cd "$X" && find . -type f ! -path ./manifest.json -print | sed 's|^\./||' | LC_ALL=C sort) > "$WORK/.present"
cut -f1 "$ENTRIES" > "$WORK/.listed"
extra="$(LC_ALL=C comm -23 "$WORK/.present" "$WORK/.listed" | head -n 1)"
[ -z "$extra" ] || die 4 "the package holds \"$extra\", which the manifest does not list"
missing="$(LC_ALL=C comm -13 "$WORK/.present" "$WORK/.listed" | head -n 1)"
[ -z "$missing" ] || die 4 "the manifest lists \"$missing\", which the package does not hold"
while IFS="$TAB" read -r p role sum size exe; do
  [ "$(sha256_of "$X/$p")" = "$sum" ] || die 4 "sha256 mismatch for $p: the package was altered or damaged; nothing was written"
  [ "$(wc -c < "$X/$p" | tr -d ' ')" = "$size" ] || die 4 "size mismatch for $p: the package was altered or damaged; nothing was written"
done < "$ENTRIES"

SRC_DEF="$X/definition/$SRC_ID.json"
jq -e 'type == "object" and (.steps | type) == "array"' "$SRC_DEF" >/dev/null 2>&1 || \
  die 4 "definition/$SRC_ID.json is not a workflow definition (not JSON, or no steps array)"
[ "$(jq -r '.id | strings' "$SRC_DEF")" = "$SRC_ID" ] || die 4 "definition/$SRC_ID.json declares another id than the manifest"

# --- target id and collisions ------------------------------------------------------------------------------------
TARGET="${RENAME:-$SRC_ID}"
CHOICE=none
[ -n "$RENAME" ] && CHOICE=rename
[ "$REPLACE" -eq 1 ] && CHOICE=replace

# shellcheck source=/dev/null
. "$WF_LIB" || die 6 "could not load $WF_LIB"
BUILTIN_DIR="$(workflow_builtin_dir 2>/dev/null)" || BUILTIN_DIR=""
builtin_file() { # $1 id -> prints the builtin file declaring it
  local f
  [ -n "$BUILTIN_DIR" ] && [ -d "$BUILTIN_DIR" ] || return 1
  for f in "$BUILTIN_DIR"/*.json; do
    [ -f "$f" ] || continue
    [ "$(jq -r '.id? | strings' "$f" 2>/dev/null)" = "$1" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}
project_files() { # $1 id -> prints every project file that is, or declares, that workflow
  local f
  [ -d "$WF_DIR" ] || return 0
  for f in "$WF_DIR"/*.json; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    if [ "$f" = "$WF_DIR/$1.json" ] || [ "$(jq -r '.id? | strings' "$f" 2>/dev/null)" = "$1" ]; then printf '%s\n' "$f"; fi
  done
}

COLLISION=none
COLLISION_FILE=""
EXIT_AFTER_REVIEW=0
EXIT_MSG=""
defer() { [ "$EXIT_AFTER_REVIEW" -ne 0 ] || { EXIT_AFTER_REVIEW="$1"; EXIT_MSG="$2"; }; }

if bf="$(builtin_file "$TARGET")"; then
  COLLISION=builtin; COLLISION_FILE="$bf"
  if [ -n "$RENAME" ]; then
    defer 5 "the id \"$TARGET\" is a builtin workflow ($bf); choose another name"
  else
    defer 5 "the id \"$TARGET\" is a builtin workflow ($bf); a builtin always wins, so install it under another id with --rename"
  fi
else
  pf="$(project_files "$TARGET")"
  SDIR_T="$WF_DIR/scripts/$TARGET"
  if [ -n "$pf" ] || [ -e "$SDIR_T" ] || [ -L "$SDIR_T" ]; then
    COLLISION=project
    COLLISION_FILE="$(printf '%s\n' "$pf" | head -n 1)"
    [ -n "$COLLISION_FILE" ] || COLLISION_FILE="$SDIR_T"
    if [ -n "$RENAME" ]; then
      defer 5 "the id \"$TARGET\" is already a project workflow ($COLLISION_FILE); choose another name"
    elif [ "$REPLACE" -eq 0 ]; then
      defer 5 "the id \"$TARGET\" is already a project workflow ($COLLISION_FILE); choose rename, replace or cancel"
    else
      other="$(printf '%s\n' "$pf" | grep -vxF "$WF_DIR/$TARGET.json" | head -n 1)"
      [ -z "$other" ] || defer 7 "$other also declares the id \"$TARGET\"; replace only replaces $WF_DIR/$TARGET.json, so rename instead"
      [ ! -L "$WF_DIR/$TARGET.json" ] || defer 7 "$WF_DIR/$TARGET.json is a symbolic link; it is not replaced"
      [ ! -L "$SDIR_T" ] || defer 7 "$SDIR_T is a symbolic link; it is not replaced"
      { [ ! -e "$SDIR_T" ] || [ -d "$SDIR_T" ]; } || defer 7 "$SDIR_T is not a directory; it is not replaced"
    fi
  fi
fi

# A path below the anchor resolves inside it: the deepest existing ancestor of $1 is inside ANCHOR_REAL.
confined() {
  local d r
  d="$(dirname "$1")"
  while [ ! -e "$d" ] && [ ! -L "$d" ]; do d="$(dirname "$d")"; done
  r="$(cd -P "$d" 2>/dev/null && pwd -P)" || return 1
  [ "$r" = "$ANCHOR_REAL" ] && return 0
  case "$r/" in "$ANCHOR_REAL"/*) return 0 ;; esac
  return 1
}

# --- plan every file ---------------------------------------------------------------------------------------------
PLAN="$WORK/.plan"   # role TAB member TAB destination TAB state TAB mode
: > "$PLAN"
SCRIPT_RELS="$WORK/.script-rels"
: > "$SCRIPT_RELS"
DEF_DEST="$WF_DIR/$TARGET.json"
if [ "$COLLISION" = project ] && [ "$REPLACE" -eq 1 ]; then def_state=replaces; else def_state=new; fi
printf 'definition\tdefinition/%s.json\t%s\t%s\t644\n' "$SRC_ID" "$DEF_DEST" "$def_state" >> "$PLAN"
while IFS="$TAB" read -r p role sum size exe; do
  case "$role" in
    script)
      rel="${p#scripts/}"
      printf '%s\n' "$rel" >> "$SCRIPT_RELS"
      dest="$WF_DIR/scripts/$TARGET/$rel"
      confined "$dest" || defer 7 "the script $p would be written outside the project ($dest)"
      if [ "$exe" = true ]; then mode=755; else mode=644; fi
      printf 'script\t%s\t%s\tnew\t%s\n' "$p" "$dest" "$mode" >> "$PLAN" ;;
    template)
      t="${p#templates/}"
      dest="$ANCHOR_REAL/$t"
      state=new
      printf '%s\n' "$t" | grep -Eq '^[A-Za-z0-9._@+/-]+$' || defer 7 "the template path \"$t\" is not one plain path token"
      case "/$t/" in
        */.git/*|*/.claude/*|*/.agents/*|*/node_modules/*) defer 7 "the template $t would be written into a protected directory" ;;
      esac
      case "$t" in
        hooks/*|scripts/*|skills/*/scripts/*|"$WF_REL"/scripts/*) defer 7 "the template $t would be written into a script directory" ;;
      esac
      if [ "$(dirname "$t")" = "$WF_REL" ]; then
        case "$t" in *.json) defer 7 "the template $t would be read as a workflow definition" ;; esac
      fi
      if ! confined "$dest"; then
        defer 7 "the template $t resolves outside the project"
      elif [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -f "$dest" ]; }; then
        defer 7 "the template destination $dest exists and is not a regular file"; state=conflict
      elif [ -f "$dest" ]; then
        if [ "$(sha256_of "$dest")" = "$sum" ]; then state=unchanged
        else
          if [ "$REPLACE" -eq 1 ]; then state=replaces; else state=conflict; fi
          [ "$REPLACE" -eq 1 ] || defer 7 "the template $dest already exists with other content; move it, or replace it with --replace"
        fi
      fi
      printf 'template\t%s\t%s\t%s\t644\n' "$p" "$dest" "$state" >> "$PLAN" ;;
  esac
done < "$ENTRIES"
confined "$DEF_DEST" || defer 7 "the definition would be written outside the project ($DEF_DEST)"

# --- the definition as it will be installed ----------------------------------------------------------------------
NEW_DEF="$WORK/definition.json"
jq --arg old "$SRC_ID" --arg new "$TARGET" --arg wf "$WF_REL" \
   --argjson rels "$(jq -R . "$SCRIPT_RELS" | jq -s .)" '
  def fix: . as $c
    | ([$rels[] | . as $rel | select(($c | endswith("/scripts/" + $old + "/" + $rel)) or $c == ("scripts/" + $old + "/" + $rel))]
       | first) as $r
    | if $r == null then $c else ($wf + "/scripts/" + $new + "/" + $r) end;
  .id = $new
  | .steps |= walk(if type == "object" and .type? == "compute" and (.command | type) == "string"
                   then .command |= fix else . end)' "$SRC_DEF" > "$NEW_DEF.rewritten" 2>/dev/null || \
  die 4 "definition/$SRC_ID.json could not be prepared for installation"
if [ "$(jq -S . "$NEW_DEF.rewritten")" = "$(jq -S . "$SRC_DEF")" ]; then cp "$SRC_DEF" "$NEW_DEF"; else mv "$NEW_DEF.rewritten" "$NEW_DEF"; fi
rm -f "$NEW_DEF.rewritten"
DEF_SHA="$(sha256_of "$NEW_DEF")"
VOUT="$(bash "$VALIDATE" "$NEW_DEF" 2>&1)"
vrc=$?
if [ "$vrc" -ne 0 ]; then
  printf '%s\n' "$VOUT" | sed "s|$NEW_DEF|definition/$SRC_ID.json|" >&2
  die 4 "definition/$SRC_ID.json does not pass validate-workflow.sh; nothing was written"
fi

# --- the review --------------------------------------------------------------------------------------------------
show_file() { # member sha path [note]
  printf '===== BEGIN %s sha256:%s =====\n' "$1" "$2"
  if [ "$(LC_ALL=C tr -d '\11\12\40-\176\200-\377' < "$3" | wc -c | tr -d ' ')" != "0" ]; then
    printf '(control characters shown as ^X, in cat -v notation)\n'
    cat -v "$3"
  else
    cat "$3"
  fi
  [ -s "$3" ] && [ "$(tail -c 1 "$3" | od -An -c | tr -d ' ')" != '\n' ] && printf '\n(no newline at end of file)\n'
  printf '===== END %s sha256:%s =====\n' "$1" "$2"
}
review() {
  local role member dest state mode extra
  printf 'package      %s\n' "$PKG"
  printf 'workflow     %s\n' "$SRC_ID"
  printf 'installs-as  %s\n' "$TARGET"
  if [ "$COLLISION" = none ]; then printf 'collision    none\n'; else printf 'collision    %s %s\n' "$COLLISION" "$COLLISION_FILE"; fi
  printf 'choice       %s\n' "$CHOICE"
  while IFS="$TAB" read -r role member dest state mode; do
    extra=""; [ "$mode" = 755 ] && extra=" executable"
    printf 'file         %s %s -> %s [%s]%s\n' "$role" "$member" "$dest" "$state" "$extra"
  done < "$PLAN"
  jq -r '.steps | .. | objects | select(.type? == "compute") | "command      \(.id) \(.command | tostring)"' "$NEW_DEF"
  show_file "definition/$SRC_ID.json" "$DEF_SHA" "$NEW_DEF"
  while IFS="$TAB" read -r p role sum size exe; do
    [ "$role" = definition ] && continue
    show_file "$p" "$sum" "$X/$p"
  done < "$ENTRIES"
}

if [ "$MODE" = inspect ]; then
  review
  [ "$EXIT_AFTER_REVIEW" -eq 0 ] || die "$EXIT_AFTER_REVIEW" "$EXIT_MSG"
  exit 0
fi

[ "$EXIT_AFTER_REVIEW" -eq 0 ] || die "$EXIT_AFTER_REVIEW" "$EXIT_MSG"
[ "$CONFIRM" -eq 1 ] || die 8 "install writes only with --confirm, after the review (inspect) was shown and accepted; nothing was written"

# --- write (journalled; any failure rolls back) ------------------------------------------------------------------
fail_write() { printf 'import-package.sh: %s; everything written was rolled back\n' "$1" >&2; rollback; WRITING=0; exit 10; }
journal() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$JOURNAL"; }
mkdirs() { # create directory $1, journalling the topmost directory created
  local d="$1" top=""
  while [ ! -d "$d" ]; do top="$d"; d="$(dirname "$d")"; done
  [ -n "$top" ] || return 0
  mkdir -p "$1" || return 1
  journal rmtree "$top"
}
BACKUP="$WORK/backup"
mkdir "$BACKUP" || die 10 "could not create the backup directory"
nb=0
move_aside() { # move existing $1 into the backup and journal its restore
  nb=$((nb + 1))
  mv "$1" "$BACKUP/$nb" || return 1
  journal restore "$BACKUP/$nb" "$1"
}
put() { # copy $1 to $2 with mode $3, via a temporary file in the same directory
  local tmp
  tmp="$(mktemp "$(dirname "$2")/.import-package.XXXXXX")" || return 1
  journal rmfile "$tmp"
  cp "$1" "$tmp" && chmod "$3" "$tmp" || return 1
  mv -f "$tmp" "$2" || return 1
  journal rmfile "$2"
}

WRITING=1
mkdirs "$WF_DIR" || fail_write "could not create $WF_DIR"
if [ "$COLLISION" = project ] && [ "$REPLACE" -eq 1 ]; then
  if [ -e "$DEF_DEST" ]; then move_aside "$DEF_DEST" || fail_write "could not move $DEF_DEST aside"; fi
  if [ -e "$WF_DIR/scripts/$TARGET" ]; then move_aside "$WF_DIR/scripts/$TARGET" || fail_write "could not move $WF_DIR/scripts/$TARGET aside"; fi
fi
put "$NEW_DEF" "$DEF_DEST" 644 || fail_write "could not write $DEF_DEST"
while IFS="$TAB" read -r role member dest state mode; do
  case "$role" in
    definition) continue ;;
  esac
  [ "$state" = unchanged ] && continue
  mkdirs "$(dirname "$dest")" || fail_write "could not create $(dirname "$dest")"
  if [ "$state" = replaces ]; then move_aside "$dest" || fail_write "could not move $dest aside"; fi
  put "$X/$member" "$dest" "$mode" || fail_write "could not write $dest"
done < "$PLAN"

# --- validate in this project ------------------------------------------------------------------------------------
fail_validate() { printf 'import-package.sh: %s\n' "$1" >&2; rollback; WRITING=0; die 9 "the workflow did not pass validation in this project; everything written was rolled back"; }
VOUT="$(bash "$VALIDATE" "$DEF_DEST" 2>&1)" || fail_validate "validate-workflow.sh: $VOUT"
CMDS="$(jq -r '.steps | .. | objects | select(.type? == "compute") | "\(.id)\t\(.command | tostring)"' "$DEF_DEST")" || \
  fail_validate "the compute commands could not be read"
if [ -n "$CMDS" ]; then
  while IFS="$TAB" read -r sid cmd; do
    case "$cmd" in *'${'*) fail_validate "compute step $sid: the command \"$cmd\" holds a reference and cannot be resolved before a run" ;; esac
    ROUT="$(cd "$ANCHOR_REAL" && bash "$RESOLVE_CMD" "$cmd" 2>&1)" || fail_validate "compute step $sid: resolve-compute-command.sh: $ROUT"
  done <<EOF
$CMDS
EOF
fi
LOUT="$(cd "$ANCHOR_REAL" && bash "$LOADER" lookup "$TARGET" 2>/dev/null)" || fail_validate "the workflow loader does not list \"$TARGET\""
[ "$(printf '%s' "$LOUT" | jq -r '.source // empty' 2>/dev/null)" = project ] || \
  fail_validate "the workflow loader does not list \"$TARGET\" as a project workflow"

WRITING=0
while IFS="$TAB" read -r role member dest state mode; do
  printf '  %s  %s -> %s [%s]\n' "$role" "$member" "$dest" "$state" >&2
done < "$PLAN"
printf '%s\n' "$DEF_DEST"
