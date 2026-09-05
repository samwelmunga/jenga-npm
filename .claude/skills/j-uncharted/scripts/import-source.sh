#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-uncharted/scripts/import-source.sh
#
# Acquisition half of `/uncharted import`. Fetches an external source into a
# STAGING directory only — it never places anything at a final destination
# inside the repo, because placement requires user confirmation (E40_S03_T02)
# and the analysis handoff belongs to `segment` mode (E40_S03_T03).
#
# Three source types, auto-detected from the argument (override with --type):
#   git      shallow clone (--depth 1) of a git URL
#   path     recursive copy of a local directory or file OUTSIDE this repo
#   snippet  pasted text read from stdin, written under a caller-supplied name
#
# SECURITY CONTRACT — the acquired source is treated as hostile:
#   * Nothing from the source is ever executed, sourced, built, or installed.
#     No install scripts, no postinstall hooks, no makefiles, no git hooks.
#   * Clones run with core.hooksPath=/dev/null and GIT_TERMINAL_PROMPT=0, with
#     submodule recursion off, and the cloned .git directory is deleted after
#     the clone so no hooks or remote config survive into staging.
#   * The staging root lives under the system temp dir, OUTSIDE the repo
#     working tree, so acquired source can never be committed by accident.
#   * Source arguments are validated against path traversal and against being
#     reinterpreted as command options.
#
# Usage:
#   import-source.sh [options] <source>
#   cat file | import-source.sh [options] --type snippet --name <filename> -
#
# Options:
#   --type git|path|snippet   Force the source type (default: auto-detect)
#   --name <filename>         Filename for snippet mode (default: snippet.txt).
#                             Must be a bare filename — no directory separators.
#   --staging-dir <dir>       Use this staging root instead of a fresh temp dir.
#                             Must not exist, or must be an empty directory.
#   --json-only               Print only the JSON summary on stdout.
#   -h, --help                Show this help.
#
# Output (stdout):
#   <staging path>            (suppressed by --json-only)
#   <JSON summary object>
#
# JSON summary fields:
#   source_type, source, staging_path, content_path,
#   file_count, total_size_bytes, total_size_human, symlink_count, git_ref
#
# Exit codes:
#   0  source acquired and staged
#   1  usage error (bad flag, missing argument, invalid --name/--type)
#   2  environment error (git unavailable, cannot create staging dir)
#   3  git clone failed (network, auth, bad URL, missing ref)
#   4  source unreadable, missing, empty, or refused (in-repo path, traversal)
#   5  empty snippet input
#   6  staging directory refused (non-empty, not a directory, or inside the repo)
# ---------------------------------------------------------------------------

set -euo pipefail

SELF="$(basename "$0")"

die() {
  local code="$1"; shift
  printf '%s: error: %s\n' "$SELF" "$*" >&2
  exit "$code"
}

usage() {
  sed -n '/^# Usage:/,/^# Exit codes:/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

SOURCE=""
FORCED_TYPE=""
SNIPPET_NAME="snippet.txt"
STAGING_ROOT=""
JSON_ONLY=0
SOURCE_SET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --type)
      [ "$#" -ge 2 ] || die 1 "--type requires a value (git|path|snippet)"
      FORCED_TYPE="$2"; shift 2 ;;
    --type=*)
      FORCED_TYPE="${1#--type=}"; shift ;;
    --name)
      [ "$#" -ge 2 ] || die 1 "--name requires a value"
      SNIPPET_NAME="$2"; shift 2 ;;
    --name=*)
      SNIPPET_NAME="${1#--name=}"; shift ;;
    --staging-dir)
      [ "$#" -ge 2 ] || die 1 "--staging-dir requires a value"
      STAGING_ROOT="$2"; shift 2 ;;
    --staging-dir=*)
      STAGING_ROOT="${1#--staging-dir=}"; shift ;;
    --json-only)
      JSON_ONLY=1; shift ;;
    -h|--help)
      usage ;;
    --)
      shift
      if [ "$#" -gt 0 ]; then SOURCE="$1"; SOURCE_SET=1; shift; fi
      [ "$#" -eq 0 ] || die 1 "unexpected extra argument: $1" ;;
    -)
      SOURCE="-"; SOURCE_SET=1; shift ;;
    -*)
      die 1 "unknown option: $1 (use -- before a source that starts with '-')" ;;
    *)
      [ "$SOURCE_SET" -eq 0 ] || die 1 "unexpected extra argument: $1"
      SOURCE="$1"; SOURCE_SET=1; shift ;;
  esac
done

[ "$SOURCE_SET" -eq 1 ] || usage

if [ -n "$FORCED_TYPE" ]; then
  case "$FORCED_TYPE" in
    git|path|snippet) ;;
    *) die 1 "invalid --type '$FORCED_TYPE' (expected git, path, or snippet)" ;;
  esac
fi

# --name must be a bare filename: no separators, no traversal, no leading dash.
case "$SNIPPET_NAME" in
  ""|.|..)            die 1 "invalid --name '$SNIPPET_NAME'" ;;
  */*|*\\*)           die 1 "invalid --name '$SNIPPET_NAME': must not contain a path separator" ;;
  -*)                 die 1 "invalid --name '$SNIPPET_NAME': must not start with '-'" ;;
esac
case "$SNIPPET_NAME" in
  *..*) die 1 "invalid --name '$SNIPPET_NAME': must not contain '..'" ;;
esac

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Canonicalise a path without depending on GNU realpath (absent on macOS).
# Collapses symlinks and '..' components so traversal cannot be smuggled past
# the in-repo check below. Works for a path whose parent exists.
canonicalise() {
  local target="$1" dir base link hops=0
  # Resolve a symlinked FINAL component before canonicalising. The [ -d ]
  # branch below already follows directory symlinks via `cd`, but a symlink to
  # a *file* would otherwise be reported at its own location — letting a link
  # that points at an in-repo file slip past is_inside_repo while `cp`
  # dereferences it. The hop cap stops a symlink loop from hanging the script.
  while [ -L "$target" ] && [ "$hops" -lt 40 ]; do
    link="$(readlink "$target")" || break
    case "$link" in
      /*) target="$link" ;;
      *)  target="$(dirname "$target")/$link" ;;
    esac
    hops=$((hops + 1))
  done
  if [ -d "$target" ]; then
    (cd "$target" 2>/dev/null && pwd -P)
  else
    dir="$(dirname "$target")"
    base="$(basename "$target")"
    if [ -d "$dir" ]; then
      printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
    else
      printf '%s\n' "$target"
    fi
  fi
}

# Echo the working-tree root containing $1, if any. Asks git about the
# CANDIDATE PATH rather than matching against a precomputed list of roots —
# a list can never cover every working tree on the host, and a lexical prefix
# match in particular misses the parent repo when this script runs from a git
# worktree (the main checkout is an ancestor of .claude/worktrees/..., so it
# never matches). Walks up to the nearest existing ancestor so it also answers
# for a staging directory that has not been created yet.
path_repo_root() {
  local probe="$1"
  while [ -n "$probe" ] && [ "$probe" != "/" ] && [ ! -d "$probe" ]; do
    probe="$(dirname "$probe")"
  done
  [ -d "$probe" ] || return 1
  git -C "$probe" rev-parse --show-toplevel 2>/dev/null
}

# True when $1 sits inside ANY git working tree; echoes that tree's root.
is_inside_repo() {
  local root
  root="$(path_repo_root "$1")" || return 1
  [ -n "$root" ] || return 1
  printf '%s\n' "$root"
  return 0
}

# Working-tree roots belonging to THIS project's repository. A git worktree and
# its main checkout share one repository, so `git worktree list` enumerates all
# of them from either side — which is what the parent-of-worktree case needs and
# what a lexical prefix match over two guessed roots got wrong.
own_worktree_roots() {
  local script_dir d
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || script_dir=""
  for d in "$script_dir" "$(pwd -P)"; do
    [ -n "$d" ] || continue
    git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    git -C "$d" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p'
  done | sort -u
}

# True when $1 is inside one of THIS project's working trees; echoes that root.
# Deliberately NOT "inside any git repository": an external cloned project is a
# git repo too, and importing one is the entire point of `import` mode. Only
# staging uses the broader any-repo test, because writing acquired source into
# any committable tree is wrong regardless of whose tree it is.
is_inside_own_repo() {
  local candidate="$1" root real
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    real="$(cd "$root" 2>/dev/null && pwd -P)" || continue
    if [ "$candidate" = "$real" ]; then printf '%s\n' "$real"; return 0; fi
    case "$candidate" in "$real"/*) printf '%s\n' "$real"; return 0 ;; esac
  done <<< "$OWN_WORKTREE_ROOTS"
  return 1
}

# Detect the source type from the argument alone (pure; no filesystem writes).
detect_type() {
  local src="$1"
  if [ "$src" = "-" ]; then
    printf 'snippet\n'; return 0
  fi
  case "$src" in
    https://*|http://*|git://*|ssh://*|git+ssh://*|file://*)
      printf 'git\n'; return 0 ;;
    *@*:*)
      # scp-style git remote, e.g. git@github.com:owner/repo.git
      printf 'git\n'; return 0 ;;
    *.git)
      printf 'git\n'; return 0 ;;
  esac
  printf 'path\n'
}

human_size() {
  local bytes="$1"
  if [ "$bytes" -lt 1024 ]; then
    printf '%sB\n' "$bytes"
  elif [ "$bytes" -lt 1048576 ]; then
    printf '%sKB\n' "$(( (bytes + 512) / 1024 ))"
  elif [ "$bytes" -lt 1073741824 ]; then
    printf '%sMB\n' "$(( (bytes + 524288) / 1048576 ))"
  else
    printf '%sGB\n' "$(( (bytes + 536870912) / 1073741824 ))"
  fi
}

json_escape() {
  # Minimal RFC 8259 string escaping for the jq-less fallback path.
  printf '%s' "$1" | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    -e 's/\t/\\t/g' -e 's/\r/\\r/g' | awk 'BEGIN{ORS=""} {print sep $0; sep="\\n"}'
}

# ---------------------------------------------------------------------------
# Resolve type
# ---------------------------------------------------------------------------

if [ -n "$FORCED_TYPE" ]; then
  SOURCE_TYPE="$FORCED_TYPE"
else
  SOURCE_TYPE="$(detect_type "$SOURCE")"
fi

OWN_WORKTREE_ROOTS="$(own_worktree_roots)"

# ---------------------------------------------------------------------------
# Pre-flight validation (before creating any staging directory)
# ---------------------------------------------------------------------------

case "$SOURCE_TYPE" in
  git)
    command -v git >/dev/null 2>&1 || die 2 "git is required for git sources but was not found on PATH"
    case "$SOURCE" in
      -*) die 4 "refusing git URL '$SOURCE': must not start with '-'" ;;
    esac
    # Reject shell/option metacharacters that have no place in a git URL.
    # shellcheck disable=SC2016  # '$(' is an intentional literal, not an expansion
    case "$SOURCE" in
      *';'*|*'|'*|*'&'*|*'$('*|*'`'*|*$'\n'*|*$'\r'*)
        die 4 "refusing git URL '$SOURCE': contains disallowed characters" ;;
    esac
    ;;
  path)
    [ -e "$SOURCE" ] || die 4 "source path does not exist: $SOURCE"
    [ -r "$SOURCE" ] || die 4 "source path is not readable: $SOURCE"
    ABS_SOURCE="$(canonicalise "$SOURCE")"
    case "$ABS_SOURCE" in
      /*) ;;
      *) die 4 "could not resolve source path to an absolute location: $SOURCE" ;;
    esac
    # This script imports EXTERNAL sources. An in-repo target is `segment`
    # mode's job, and allowing it here would let a traversal argument
    # ('../../repo/x') round-trip repo content through the import path.
    if MATCHED_ROOT="$(is_inside_own_repo "$ABS_SOURCE")"; then
      die 4 "refusing '$SOURCE': resolves to $ABS_SOURCE, inside this project's repo at $MATCHED_ROOT. Use \`/uncharted segment\` for in-repo targets."
    fi
    if [ -d "$ABS_SOURCE" ] && [ -z "$(ls -A "$ABS_SOURCE" 2>/dev/null)" ]; then
      die 4 "source directory is empty: $SOURCE"
    fi
    if [ -f "$ABS_SOURCE" ] && [ ! -s "$ABS_SOURCE" ]; then
      die 4 "source file is empty: $SOURCE"
    fi
    ;;
  snippet)
    : # stdin is validated at read time
    ;;
esac

# ---------------------------------------------------------------------------
# Staging directory
# ---------------------------------------------------------------------------

if [ -n "$STAGING_ROOT" ]; then
  # Staging must never live inside the repo working tree — that is the
  # structural guarantee that acquired external source cannot be committed.
  STAGING_PROBE="$(canonicalise "$STAGING_ROOT")"
  if MATCHED_ROOT="$(is_inside_repo "$STAGING_PROBE")"; then
    die 6 "refusing --staging-dir '$STAGING_ROOT': staging must live outside the repo working tree ($MATCHED_ROOT)"
  fi
  if [ -e "$STAGING_ROOT" ]; then
    [ -d "$STAGING_ROOT" ] || die 6 "staging path exists and is not a directory: $STAGING_ROOT"
    [ -z "$(ls -A "$STAGING_ROOT" 2>/dev/null)" ] || die 6 "refusing to write into non-empty staging directory: $STAGING_ROOT"
  else
    mkdir -p "$STAGING_ROOT" || die 2 "could not create staging directory: $STAGING_ROOT"
  fi
  STAGING_ROOT="$(canonicalise "$STAGING_ROOT")"
else
  STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/uncharted-import.XXXXXXXX")" \
    || die 2 "could not create a temporary staging directory"
  STAGING_ROOT="$(canonicalise "$STAGING_ROOT")"
  # The default path is only safe if TMPDIR itself is not inside a working
  # tree. Exotic, but the guarantee above is stated absolutely, so assert it
  # rather than assume it — and clean up the temp dir we just made.
  if MATCHED_ROOT="$(is_inside_repo "$STAGING_ROOT")"; then
    rmdir "$STAGING_ROOT" 2>/dev/null || true
    die 6 "refusing default staging dir '$STAGING_ROOT': TMPDIR resolves inside a repo working tree ($MATCHED_ROOT). Set TMPDIR or pass --staging-dir to a location outside any repo."
  fi
fi

# Acquired content never sits at the staging root itself — downstream steps
# need a stable subdirectory to point the placement prompt at.
CONTENT_DIR="$STAGING_ROOT/source"
[ ! -e "$CONTENT_DIR" ] || die 6 "refusing to write into non-empty staging directory: $STAGING_ROOT"

GIT_REF=""

# shellcheck disable=SC2329  # invoked via `trap`, not called directly
cleanup_on_failure() {
  local code="$?"
  if [ "$code" -ne 0 ] && [ -n "${STAGING_ROOT:-}" ] && [ -d "$STAGING_ROOT" ]; then
    case "$STAGING_ROOT" in
      /|/tmp|/var|/usr|/etc|"$HOME") : ;;          # never blast a system root
      *)
        if is_inside_repo "$STAGING_ROOT" >/dev/null; then
          : # never rm -rf anything inside a repo working tree
        else
          rm -rf "$STAGING_ROOT"
        fi ;;
    esac
  fi
}
trap cleanup_on_failure EXIT

# ---------------------------------------------------------------------------
# Acquisition
# ---------------------------------------------------------------------------

case "$SOURCE_TYPE" in
  git)
    CLONE_LOG="$STAGING_ROOT/.clone.log"
    # Hardened clone: no hooks, no interactive credential prompt, no tags,
    # no submodule recursion, single branch, depth 1.
    if ! GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/true \
         git -c core.hooksPath=/dev/null \
             -c protocol.ext.allow=never \
             -c advice.detachedHead=false \
             clone --depth 1 --no-tags --single-branch --no-recurse-submodules \
             -- "$SOURCE" "$CONTENT_DIR" >"$CLONE_LOG" 2>&1; then
      printf '%s: error: git clone failed for %s\n' "$SELF" "$SOURCE" >&2
      printf -- '--- git output ---\n' >&2
      cat "$CLONE_LOG" >&2 || true
      printf -- '------------------\n' >&2
      printf 'Hint: for a private repository this is usually missing or expired credentials.\n' >&2
      printf '      Interactive prompts are disabled on purpose; configure git credentials and retry.\n' >&2
      exit 3
    fi
    if [ -d "$CONTENT_DIR/.git" ]; then
      GIT_REF="$(git -C "$CONTENT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
      # Drop .git entirely: removes fetched hooks/config and prevents the
      # staged tree from behaving as a nested repository downstream.
      rm -rf "$CONTENT_DIR/.git"
    fi
    rm -f "$CLONE_LOG"
    ;;

  path)
    mkdir -p "$CONTENT_DIR" || die 2 "could not create staging content directory: $CONTENT_DIR"
    if [ -d "$ABS_SOURCE" ]; then
      # Copy the directory's CONTENTS (not the directory itself) into staging.
      # `cp -R src/. dest/` is the portable form that includes dotfiles.
      cp -R "$ABS_SOURCE/." "$CONTENT_DIR/" || die 4 "failed to copy source directory: $SOURCE"
    else
      cp "$ABS_SOURCE" "$CONTENT_DIR/$(basename "$ABS_SOURCE")" || die 4 "failed to copy source file: $SOURCE"
    fi
    # A copied tree may carry its own .git; strip it for the same reasons as above.
    rm -rf "$CONTENT_DIR/.git"
    ;;

  snippet)
    mkdir -p "$CONTENT_DIR" || die 2 "could not create staging content directory: $CONTENT_DIR"
    SNIPPET_FILE="$CONTENT_DIR/$SNIPPET_NAME"
    if [ "$SOURCE" = "-" ] || [ "$SOURCE" = "" ]; then
      cat > "$SNIPPET_FILE" || die 4 "failed to read snippet from stdin"
    elif [ -f "$SOURCE" ]; then
      [ -r "$SOURCE" ] || die 4 "snippet file is not readable: $SOURCE"
      cat -- "$SOURCE" > "$SNIPPET_FILE" || die 4 "failed to read snippet file: $SOURCE"
    else
      printf '%s' "$SOURCE" > "$SNIPPET_FILE" || die 4 "failed to write snippet"
    fi
    if [ ! -s "$SNIPPET_FILE" ]; then
      die 5 "empty snippet input — nothing to import"
    fi
    ;;
esac

if [ ! -d "$CONTENT_DIR" ] || [ -z "$(ls -A "$CONTENT_DIR" 2>/dev/null)" ]; then
  die 4 "acquisition produced no content for source: $SOURCE"
fi

# Nothing in the staged tree should be executable — this script never runs it,
# and a non-executable tree makes accidental execution downstream harder.
find "$CONTENT_DIR" -type f -exec chmod a-x {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

FILE_COUNT="$(find "$CONTENT_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"

# Apparent size, not disk usage: `du` rounds every file up to a block, which
# reports 4KB for a 30-byte snippet. BSD and GNU `stat` disagree on flags, so
# resolve the right one once and batch with `find -exec ... +`.
# Probe on `stat --version`, which only GNU coreutils implements. Probing on
# `stat -f %z` instead is ambiguous: GNU's -f selects *filesystem* status, so
# it can exit 0 on Linux and wrongly select the BSD branch.
if stat --version >/dev/null 2>&1; then
  STAT_ARGS=(-c %s)     # GNU / coreutils
else
  STAT_ARGS=(-f %z)     # BSD / macOS
fi
TOTAL_BYTES="$(find "$CONTENT_DIR" -type f -exec stat "${STAT_ARGS[@]}" {} + 2>/dev/null \
  | awk '{ s += $1 } END { print s + 0 }')"
[ -n "$TOTAL_BYTES" ] || TOTAL_BYTES=0
TOTAL_HUMAN="$(human_size "$TOTAL_BYTES")"

# Symlinks are preserved rather than dereferenced or stripped — deleting them
# would corrupt legitimate source trees. But a symlink escaping the staged tree
# would let the placement step (E40_S03_T02) pull arbitrary host files into the
# repo, so surface the count and let placement decide.
SYMLINK_COUNT="$(find "$CONTENT_DIR" -type l 2>/dev/null | wc -l | tr -d ' ')"
[ -n "$SYMLINK_COUNT" ] || SYMLINK_COUNT=0

trap - EXIT

if [ "$JSON_ONLY" -eq 0 ]; then
  printf '%s\n' "$STAGING_ROOT"
fi

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --arg source_type "$SOURCE_TYPE" \
    --arg source "$SOURCE" \
    --arg staging_path "$STAGING_ROOT" \
    --arg content_path "$CONTENT_DIR" \
    --argjson file_count "$FILE_COUNT" \
    --argjson total_size_bytes "$TOTAL_BYTES" \
    --arg total_size_human "$TOTAL_HUMAN" \
    --argjson symlink_count "$SYMLINK_COUNT" \
    --arg git_ref "$GIT_REF" \
    '{source_type: $source_type,
      source: $source,
      staging_path: $staging_path,
      content_path: $content_path,
      file_count: $file_count,
      total_size_bytes: $total_size_bytes,
      total_size_human: $total_size_human,
      symlink_count: $symlink_count,
      git_ref: (if $git_ref == "" then null else $git_ref end)}'
else
  if [ -n "$GIT_REF" ]; then
    GIT_REF_JSON="\"$(json_escape "$GIT_REF")\""
  else
    GIT_REF_JSON="null"
  fi
  printf '{"source_type":"%s","source":"%s","staging_path":"%s","content_path":"%s","file_count":%s,"total_size_bytes":%s,"total_size_human":"%s","symlink_count":%s,"git_ref":%s}\n' \
    "$(json_escape "$SOURCE_TYPE")" \
    "$(json_escape "$SOURCE")" \
    "$(json_escape "$STAGING_ROOT")" \
    "$(json_escape "$CONTENT_DIR")" \
    "$FILE_COUNT" \
    "$TOTAL_BYTES" \
    "$(json_escape "$TOTAL_HUMAN")" \
    "$SYMLINK_COUNT" \
    "$GIT_REF_JSON"
fi

exit 0
