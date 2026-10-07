#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-connect/scripts/ensure-secret-safe.sh
#
# Pre-write guardrail (E65_S01_T03). The runner calls this BEFORE any step
# creates or writes a file that could hold a secret (e.g. `.env`). It makes
# sure that file cannot be committed by accident:
#
#   1. the path is already tracked by git        -> REFUSE (exit 1), write nothing
#   2. the path is already ignored (git check-ignore) -> exit 0, change nothing
#   3. otherwise add it to a managed block in <project_root>/.gitignore, verify
#      it is now ignored, and exit 0; if it still is not ignored (e.g. a later
#      negation rule wins) restore the original .gitignore and REFUSE (exit 1).
#   Not a git repository: there is nothing to check against, so the path is
#   written into the managed block of a writable .gitignore (git will honour it
#   once the project is initialised); if that cannot be done, REFUSE (exit 1).
#
# It NEVER reads, prints, or logs the contents of <path> (git check-ignore and
# git ls-files only look at names). Output contains paths only.
#
# Reuse of skills/j-gitignore/scripts/: NOT reused, deliberately. repair-gitignore.sh
# and _catalog.sh are bound to a fixed catalog of Jenga-owned paths
# (assets/jenga-paths.txt) and to the `# >>> jenga:gitignore >>>` block; they
# also strip stray `EOF` lines and are paired with an untrack step. This guardrail
# needs one arbitrary, caller-supplied path and nothing else, so extending that
# catalog (a data file the skill owns) would couple unrelated concerns. Instead this
# script follows the same convention (a clearly marked managed block, everything
# outside it preserved byte for byte, atomic temp-file + mv) with its OWN markers,
# `# >>> jenga:connect-secrets >>>`, so the two blocks never collide.
#
# Usage:   ensure-secret-safe.sh <path> [project_root]
#            <path>         relative to project_root, or absolute inside it
#            project_root   default: `git rev-parse --show-toplevel` from $PWD,
#                           else $PWD
# Exit:    0 safe (already ignored, or now ignored); 1 refused; 2 usage error
# -----------------------------------------------------------------------------
set -uo pipefail

BEGIN_MARK="# >>> jenga:connect-secrets >>>"
END_MARK="# <<< jenga:connect-secrets <<<"

say()  { echo "[ensure-secret-safe] $*"; }
err()  { echo "[ensure-secret-safe] ERROR: $*" >&2; }

if [ $# -ge 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  echo "Usage: $(basename "$0") <path> [project_root]"
  exit 0
fi
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: $(basename "$0") <path> [project_root]" >&2
  exit 2
fi

TARGET="$1"
ROOT="${2:-}"
if [ -z "$ROOT" ]; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
if [ ! -d "$ROOT" ]; then
  err "project root does not exist: $ROOT"
  exit 2
fi
ROOT_GIVEN="${ROOT%/}"
ROOT="$(cd "$ROOT" && pwd -P)"

# Normalise <path> to a clean relative path inside the root. An absolute path
# may use either the root as given or its symlink-resolved form (e.g. macOS
# /var -> /private/var).
REL="$TARGET"
case "$REL" in
  /*)
    case "$REL" in
      "$ROOT"/*) REL="${REL#"$ROOT"/}" ;;
      "$ROOT_GIVEN"/*) REL="${REL#"$ROOT_GIVEN"/}" ;;
      *) err "path is outside the project root: $TARGET"; exit 2 ;;
    esac ;;
esac
while [ "${REL#./}" != "$REL" ]; do REL="${REL#./}"; done
case "/$REL/" in
  */../*) err "path may not contain '..': $TARGET"; exit 2 ;;
esac
if [ -z "$REL" ] || [ "$REL" = "." ]; then err "empty path"; exit 2; fi
# Keep the gitignore line unambiguous: no glob metacharacters, comment/negation
# prefixes, trailing space, or newlines.
case "$REL" in
  '#'*|'!'*|*'*'*|*'?'*|*'['*|*\\*|*' ') err "unsupported characters in path: $REL"; exit 2 ;;
esac
case "$REL" in
  *$'\n'*|*$'\r'*) err "unsupported characters in path"; exit 2 ;;
esac

GITIGNORE="$ROOT/.gitignore"
IN_REPO=0
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then IN_REPO=1; fi

is_ignored() { git -C "$ROOT" check-ignore -q -- "$REL" 2>/dev/null; }

if [ "$IN_REPO" -eq 1 ]; then
  if git -C "$ROOT" ls-files --error-unmatch -- "$REL" >/dev/null 2>&1; then
    err "refusing: '$REL' is tracked by git; a tracked file's contents would be committed. Untrack it first (git rm --cached) and re-run."
    exit 1
  fi
  if is_ignored; then
    say "already ignored: $REL (no changes)"
    exit 0
  fi
fi

# ---- add "/<rel>" to the managed block, atomically -------------------------
ENTRY="/$REL"

if [ -e "$GITIGNORE" ] && [ ! -w "$GITIGNORE" ]; then
  err "refusing: $GITIGNORE is not writable, so '$REL' cannot be made ignored."
  exit 1
fi
if [ ! -e "$GITIGNORE" ] && [ ! -w "$ROOT" ]; then
  err "refusing: cannot create $GITIGNORE, so '$REL' cannot be made ignored."
  exit 1
fi

TMP="$(mktemp "$ROOT/.gitignore.ensure-secret-safe.XXXXXX")" || { err "cannot create a temp file in $ROOT"; exit 1; }
BACKUP="$(mktemp "${TMPDIR:-/tmp}/ensure-secret-safe.backup.XXXXXX")" || { rm -f "$TMP"; err "cannot create a backup file"; exit 1; }
trap 'rm -f "$TMP" "$BACKUP"' EXIT
HAD_FILE=0
if [ -e "$GITIGNORE" ]; then
  HAD_FILE=1
  cp -p "$GITIGNORE" "$BACKUP"
  cp -p "$GITIGNORE" "$TMP"   # carry the file mode over; the content is rewritten below
else
  chmod 644 "$TMP"
fi

if [ "$HAD_FILE" -eq 1 ] && grep -qxF "$BEGIN_MARK" "$GITIGNORE" && grep -qxF "$END_MARK" "$GITIGNORE"; then
  if grep -qxF "$ENTRY" "$GITIGNORE"; then
    # Entry already in the file but git does not treat the path as ignored
    # (e.g. a later negation rule). Nothing useful to add; fall through to the
    # verification below, which refuses.
    cp -p "$GITIGNORE" "$TMP"
  else
    END_LINE="$(grep -nxF "$END_MARK" "$GITIGNORE" | head -n1 | cut -d: -f1)"
    { head -n $((END_LINE - 1)) "$GITIGNORE"; printf '%s\n' "$ENTRY"; tail -n +"$END_LINE" "$GITIGNORE"; } > "$TMP"
  fi
else
  {
    if [ "$HAD_FILE" -eq 1 ]; then
      cat "$GITIGNORE"
      # Make sure the block starts on its own line without altering earlier bytes.
      if [ -s "$GITIGNORE" ] && [ "$(tail -c1 "$GITIGNORE" | wc -l | tr -d ' ')" = "0" ]; then printf '\n'; fi
    fi
    printf '%s\n%s\n%s\n' "$BEGIN_MARK" "$ENTRY" "$END_MARK"
  } > "$TMP"
fi

if ! mv "$TMP" "$GITIGNORE"; then
  err "could not write $GITIGNORE"
  exit 1
fi

if [ "$IN_REPO" -eq 1 ]; then
  if is_ignored; then
    say "added to .gitignore managed block: $REL"
    exit 0
  fi
  # Still not ignored: undo our change and refuse.
  if [ "$HAD_FILE" -eq 1 ]; then cp -p "$BACKUP" "$GITIGNORE"; else rm -f "$GITIGNORE"; fi
  err "refusing: '$REL' is still not ignored after updating .gitignore (a later rule probably re-includes it). .gitignore was restored unchanged."
  exit 1
fi

say "not a git repository; recorded '$REL' in the .gitignore managed block (takes effect once the project is a git repo)"
exit 0
