#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-workflow-capture/scripts/export-package.sh - bundle one workflow as a portable package (E103_S05_T02)
#
# A workflow captured or authored in one project is meant to run in another. This script writes ONE package file
# holding everything the workflow needs and nothing else, plus a manifest of every file with its sha256, so the
# importing side (j.workflow-capture import, E103_S05_T03) can verify each file before it writes anything.
# Never reads or writes the recorder's active-recording pointer.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   export-package.sh [--out <file>] [--force] <workflow-id>
#   export-package.sh -h | --help | help        this usage on stdout, exit 0
#
#   --out <file>   where to write the package    default: ./<workflow-id>.workflow.tar.gz (the current directory)
#   --force        overwrite an existing <file>  default: refuse (exit 7)
#   On success prints the package's path on stdout, and one line per included file on stderr.
#
# ---------------------------------------------------------------------------
# WHAT IS INCLUDED (and nothing else)
# ---------------------------------------------------------------------------
#   <workflows> is `scripts/resolve-root.sh get workflows`; <anchor> is `scripts/resolve-root.sh root`.
#   1. the definition   <workflows>/<workflow-id>.json. It must exist (exit 3) and be a JSON object with a
#                       `steps` array (exit 4). Only the project directory is read, never a builtin definition.
#   2. the wrappers     every regular file under <workflows>/scripts/<workflow-id>/, at any depth. The directory is
#                       optional: a workflow without one exports the definition and templates only.
#   3. the templates    the `template` of every `render` step, at any depth of `steps`, each file once. A template
#                       path is anchor-relative, as the renderer reads it (project/documentation/workflows.md, "The
#                       markdown renderer"): one plain token of letters, digits and `. _ @ + / -`, not absolute, no
#                       `..` segment, real directory inside <anchor>, an existing regular file. A path with a
#                       `${...}` reference cannot be known before a run and is refused like any other bad path.
#   A symbolic link anywhere among these, a file name holding a newline or a TAB, or a template that breaks a rule
#   above is refused (exit 5) and nothing is written: a package never carries a file from outside these three.
#
# ---------------------------------------------------------------------------
# THE PACKAGE (format jenga-workflow-package, version 1)
# ---------------------------------------------------------------------------
#   A gzip-compressed tar archive whose members are, with no leading directory:
#       manifest.json
#       definition/<workflow-id>.json
#       scripts/<path relative to <workflows>/scripts/<workflow-id>/>      (only when that directory has files)
#       templates/<anchor-relative template path>                           (only when templates are referenced)
#   manifest.json:
#       { "format": "jenga-workflow-package", "format_version": 1, "workflow_id": "<id>",
#         "files": [ { "path": "<member path>", "role": "definition|script|template",
#                      "origin": "<path in the exporting project>", "origin_base": "workflows|anchor",
#                      "sha256": "<64 hex>", "size": <bytes>, "executable": true|false }, ... ] }
#   `files` lists every member except manifest.json itself, sorted by path. `origin` is relative to <workflows>
#   (definition, scripts) or to <anchor> (templates), so an importer can place each file where the definition
#   expects it. The manifest carries no timestamp and no absolute path: the same inputs give the same manifest.
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   the package was written; its path on stdout
#   2   usage error, or the id does not match the schema's id_pattern
#   3   no definition <workflows>/<workflow-id>.json
#   4   the definition is not JSON or has no steps array
#   5   a file or a template reference that may not be packaged (message names it); nothing was written
#   6   the environment is incomplete: jq, tar, a sha256 tool, the schema or resolve-root.sh
#   7   the output file exists (use --force), or it could not be written
#
# Compatible with macOS bash 3.2 and safe under `set -u`.
# ---------------------------------------------------------------------------
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '3,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die() { local code="$1"; shift; printf 'export-package.sh: %s\n' "$*" >&2; exit "$code"; }

OUT=""
FORCE=0
WF_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) printf 'usage:\n'; usage; exit 0 ;;
    --out) [ $# -ge 2 ] && [ -n "$2" ] || die 2 "--out needs a file"; OUT="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -*) die 2 "unknown option $1 (see --help)" ;;
    *) [ -z "$WF_ID" ] || die 2 "one workflow id only (got \"$WF_ID\" and \"$1\")"; WF_ID="$1"; shift ;;
  esac
done
[ -n "$WF_ID" ] || die 2 "a workflow id is required (see --help)"

# --- environment -------------------------------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || die 6 "jq is required"
command -v tar >/dev/null 2>&1 || die 6 "tar is required"
if command -v shasum >/dev/null 2>&1; then sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then sha256_of() { sha256sum "$1" | awk '{print $1}'; }
else die 6 "shasum or sha256sum is required"; fi

# shellcheck source=/dev/null
if [ -f "$SCRIPT_DIR/../../index/scripts/package-root.sh" ]; then . "$SCRIPT_DIR/../../index/scripts/package-root.sh"; else jenga_package_root() { (cd "$1/../../.." && pwd); }; fi
PKG_ROOT="$(jenga_package_root "$SCRIPT_DIR" 2>/dev/null)" || true
RESOLVE_ROOT="$PKG_ROOT/scripts/resolve-root.sh"
SCHEMA="$PKG_ROOT/templates/workflow-schema.json"
[ -f "$RESOLVE_ROOT" ] || die 6 "resolve-root.sh not found under $PKG_ROOT/scripts"
[ -f "$SCHEMA" ] || die 6 "the workflow schema was not found at $SCHEMA"

ID_PATTERN="$(jq -r '.top_level.id_pattern // empty' "$SCHEMA" 2>/dev/null)"
[ -n "$ID_PATTERN" ] || die 6 "$SCHEMA carries no top_level.id_pattern"
printf '%s\n' "$WF_ID" | grep -Eq "$ID_PATTERN" && [ "$(printf '%s' "$WF_ID" | wc -l | tr -d ' ')" = "0" ] || \
  die 2 "\"$WF_ID\" is not a workflow id (it must match $ID_PATTERN)"

WF_DIR="$(bash "$RESOLVE_ROOT" get workflows 2>/dev/null)" && [ -n "$WF_DIR" ] || \
  die 6 "could not resolve the workflows directory with resolve-root.sh get workflows"
ANCHOR="$(bash "$RESOLVE_ROOT" root 2>/dev/null)" && [ -n "$ANCHOR" ] || \
  die 6 "could not resolve the project anchor with resolve-root.sh root"
ANCHOR_REAL="$(cd "$ANCHOR" 2>/dev/null && pwd -P)" || die 6 "the project anchor $ANCHOR is not a directory"

# --- the definition ----------------------------------------------------------------------------------------------
DEF="$WF_DIR/$WF_ID.json"
[ -L "$DEF" ] && die 5 "$DEF is a symbolic link; only regular files are packaged"
[ -f "$DEF" ] || die 3 "no workflow \"$WF_ID\": $DEF does not exist (j.workflow list shows the ids)"
jq -e 'type == "object" and (.steps | type) == "array"' "$DEF" >/dev/null 2>&1 || \
  die 4 "$DEF is not a workflow definition (not JSON, or no steps array)"

# --- the output --------------------------------------------------------------------------------------------------
[ -n "$OUT" ] || OUT="./$WF_ID.workflow.tar.gz"
OUT_DIR="$(dirname "$OUT")"
[ -d "$OUT_DIR" ] || die 7 "the output directory $OUT_DIR does not exist"
if [ -e "$OUT" ] || [ -L "$OUT" ]; then
  [ "$FORCE" -eq 1 ] || die 7 "$OUT already exists; pass --force to overwrite it"
  [ -f "$OUT" ] && [ ! -L "$OUT" ] || die 7 "$OUT exists and is not a regular file; refusing to overwrite it"
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/export-package.XXXXXX")" || die 7 "could not create a staging directory"
TMP_OUT=""
cleanup() { rm -rf "$STAGE"; [ -n "$TMP_OUT" ] && rm -f "$TMP_OUT"; return 0; }
trap cleanup EXIT
trap 'exit 130' INT TERM
LIST="$STAGE/.list"   # one line per file: member TAB role TAB origin TAB origin_base TAB source
: > "$LIST"
mkdir -p "$STAGE/pkg"

TAB="$(printf '\t')"
NL='
'
add_file() { # member role origin origin_base source
  case "$1$3" in *"$TAB"*|*"$NL"*) die 5 "the file name \"$3\" holds a TAB or a newline; it cannot be packaged" ;; esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$LIST"
}

add_file "definition/$WF_ID.json" definition "$WF_ID.json" workflows "$DEF"

# --- the wrapper-script directory (optional) ---------------------------------------------------------------------
SDIR="$WF_DIR/scripts/$WF_ID"
if [ -L "$SDIR" ]; then
  die 5 "$SDIR is a symbolic link; only a real directory is packaged"
elif [ -d "$SDIR" ]; then
  bad="$(find "$SDIR" -mindepth 1 \( -type l -o \( ! -type f ! -type d \) \) -print 2>/dev/null | head -n 1)"
  [ -z "$bad" ] || die 5 "$bad is a symbolic link or not a regular file; only regular files are packaged"
  while IFS= read -r -d '' f; do
    rel="${f#"$SDIR"/}"
    add_file "scripts/$rel" script "scripts/$WF_ID/$rel" workflows "$f"
  done < <(find "$SDIR" -type f -print0 2>/dev/null)
elif [ -e "$SDIR" ]; then
  die 5 "$SDIR is not a directory"
fi

# --- the referenced templates ------------------------------------------------------------------------------------
TEMPLATES="$(jq -r '[.steps | .. | objects | select(.type? == "render") | .template | select(type == "string")]
                    | unique | .[]' "$DEF" 2>/dev/null)" || die 4 "$DEF could not be read for render templates"
NONSTRING="$(jq -r '[.steps | .. | objects | select(.type? == "render" and has("template"))
                     | select((.template | type) != "string")] | length' "$DEF")"
[ "$NONSTRING" = "0" ] || die 5 "a render step's template is not a string; it cannot be resolved to a file"
if [ -n "$TEMPLATES" ]; then
  while IFS= read -r t; do
    printf '%s\n' "$t" | grep -Eq '^[A-Za-z0-9._@+/-]+$' || \
      die 5 "the template \"$t\" is not one plain path token (a \${...} reference or an unusual character); it cannot be packaged"
    case "$t" in /*) die 5 "the template \"$t\" is an absolute path; template paths are anchor-relative" ;; esac
    case "/$t/" in */../*) die 5 "the template \"$t\" has a .. segment; it may not leave the project" ;; esac
    src="$ANCHOR_REAL/$t"
    [ -L "$src" ] && die 5 "the template \"$t\" is a symbolic link; only regular files are packaged"
    [ -f "$src" ] || die 5 "the template \"$t\" referenced by the definition does not exist under $ANCHOR_REAL"
    tdir="$(cd "$(dirname "$src")" 2>/dev/null && pwd -P)" || die 5 "the template \"$t\" could not be resolved"
    case "$tdir/" in "$ANCHOR_REAL"/*) ;; *) die 5 "the template \"$t\" resolves outside the project ($tdir)" ;; esac
    add_file "templates/$t" template "$t" anchor "$tdir/$(basename "$src")"
  done <<EOF
$TEMPLATES
EOF
fi

# --- stage, hash, manifest ---------------------------------------------------------------------------------------
ENTRIES="$STAGE/.entries"
: > "$ENTRIES"
LC_ALL=C sort -t "$TAB" -k1,1 "$LIST" | while IFS="$TAB" read -r member role origin base src; do
  mkdir -p "$STAGE/pkg/$(dirname "$member")" || exit 1
  cp "$src" "$STAGE/pkg/$member" || exit 1
  if [ -x "$src" ]; then chmod 755 "$STAGE/pkg/$member"; exe=true; else chmod 644 "$STAGE/pkg/$member"; exe=false; fi
  sum="$(sha256_of "$STAGE/pkg/$member")"
  size="$(wc -c < "$STAGE/pkg/$member" | tr -d ' ')"
  jq -cn --arg p "$member" --arg r "$role" --arg o "$origin" --arg b "$base" --arg s "$sum" \
        --argjson z "$size" --argjson x "$exe" \
        '{path: $p, role: $r, origin: $o, origin_base: $b, sha256: $s, size: $z, executable: $x}' >> "$ENTRIES" || exit 1
  printf '  %s  %s\n' "$role" "$member" >&2
done || die 7 "could not stage the files"

jq -s --arg id "$WF_ID" \
  '{format: "jenga-workflow-package", format_version: 1, workflow_id: $id, files: .}' "$ENTRIES" \
  > "$STAGE/pkg/manifest.json" || die 7 "could not write the manifest"

# --- archive, then move into place -------------------------------------------------------------------------------
MEMBERS="manifest.json definition"
[ -d "$STAGE/pkg/scripts" ] && MEMBERS="$MEMBERS scripts"
[ -d "$STAGE/pkg/templates" ] && MEMBERS="$MEMBERS templates"
TMP_OUT="$(mktemp "$OUT_DIR/.export-package.XXXXXX")" || die 7 "could not create a file in $OUT_DIR"
# shellcheck disable=SC2086  # MEMBERS is a fixed list of plain words
COPYFILE_DISABLE=1 tar -czf "$TMP_OUT" -C "$STAGE/pkg" $MEMBERS 2>/dev/null || die 7 "tar could not write the package"
chmod 644 "$TMP_OUT"
mv -f "$TMP_OUT" "$OUT" || die 7 "could not move the package to $OUT"
TMP_OUT=""
printf '%s\n' "$OUT"
