#!/usr/bin/env bash
#
# assert_sandboxed: the shared "is this run provably contained in a temp directory" check (E99_S01_T07).
#
# Anything that runs git against a REAL repository's remote, or runs a script that might, calls this first. It
# answers one question: "if the code under test pushes, tags, fetches or clones, can that reach anything outside
# <root>?". It fails closed: a caller in a bats setup() sees a failing setup (never a skip), and a script
# that sources this file refuses to start.
#
# No bats dependency (plain bash 3.2: no associative arrays, no ${v,,}, no [[ -v ]]), so a bats file and a
# plain script can both source it:
#
#     . "$REPO_ROOT/tests/helpers/assert-sandboxed.bash"
#     assert_sandboxed "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR/work" "$BATS_TEST_TMPDIR/origin.git" || return 1
#
# Contract
# --------
#   assert_sandboxed [<root>] [<path-or-remote> ...]
#
#   <root>      the directory everything must live under; defaults to $BATS_TEST_TMPDIR. It must exist and must not
#               be "/" (a root that contains everything proves nothing).
#   <path-or-remote> ...
#               every push target and worktree path the caller is about to use: a filesystem path, a file:// URL,
#               or anything else (an https:// or ssh:// URL, a scp-like host:path), which is always a violation.
#
# It returns 0 only when ALL of these hold, and otherwise prints one line per violated condition on stderr
# ("assert_sandboxed: <what is wrong>") and returns 1. Every condition is evaluated; the first failure does not
# hide the others.
#
#   1. every given target, and the resolved URL of `origin` in the repository of the current directory (when it has
#      one), is under <root> after symlinks are resolved (a path that does not exist yet is resolved through its
#      nearest existing ancestor, and one that climbs with ".." is refused);
#   2. HOME is under <root>;
#   3. GIT_CONFIG_GLOBAL is /dev/null;
#   4. GIT_CONFIG_NOSYSTEM is 1 (HOME=<tmp> does not hide the SYSTEM gitconfig, which is where a credential helper
#      such as osxkeychain comes from);
#   5. GIT_ALLOW_PROTOCOL is file (a git operation on an https, ssh or git@host: URL then fails inside git);
#   6. SSH_AUTH_SOCK, GIT_ASKPASS and SSH_ASKPASS are unset;
#   7. `git config --get-all credential.helper`, run in the current directory under the CURRENT environment, is empty.
#
# The checks read the environment of the calling shell, so a caller that sandboxes a child process (env -i ...)
# runs this inside the same environment, for example:
#     env -i PATH=... HOME=... GIT_CONFIG_GLOBAL=/dev/null ... bash -c '. helper; assert_sandboxed "$@"' _ <root> <targets>

# _as_say <message>: one violation line on stderr.
_as_say() { printf 'assert_sandboxed: %s\n' "$1" >&2; }

# _as_realpath <path>: the physical absolute path, resolving symlinks through the nearest existing ancestor.
# Prints nothing and returns 1 when the path climbs with ".." or "." below that ancestor, or cannot be resolved.
_as_realpath() {
  local p="$1" rest="" base dir
  [ -n "$p" ] || return 1
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ "$p" != "/" ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  while [ ! -e "$p" ] && [ "$p" != "/" ]; do
    base="${p##*/}"
    case "$base" in ""|.|..) return 1 ;; esac
    rest="/$base$rest"
    dir="${p%/*}"
    [ -n "$dir" ] || dir="/"
    p="$dir"
  done
  if [ -d "$p" ]; then
    p="$(cd "$p" 2>/dev/null && pwd -P)" || return 1
  else
    dir="$(cd "${p%/*}" 2>/dev/null && pwd -P)" || return 1
    p="${dir%/}/${p##*/}"
  fi
  case "$rest" in */../*|*/./*|*/..|*/.) return 1 ;; esac
  if [ "$p" = "/" ] && [ -z "$rest" ]; then printf '/\n'; else printf '%s%s\n' "${p%/}" "$rest"; fi
}

# _as_under <resolved-root> <resolved-path>: true when the path is the root or inside it.
_as_under() {
  case "$2/" in "$1"/*) return 0 ;; esac
  return 1
}

# _as_check_target <label> <resolved-root> <target>: reports a violation unless the target is a path (or a
# file:// URL) under the root. Returns the number of violations (0 or 1).
_as_check_target() {
  local label="$1" root="$2" t="$3" path real
  case "$t" in
    file://*) path="${t#file://}" ;;
    *://*) _as_say "$label '$t' is a network URL, not a path under $root"; return 1 ;;
    *)
      # scp-like host:path (a colon before the first slash) is a network target; a path may legitimately hold a colon later.
      case "${t%%/*}" in
        *:*) _as_say "$label '$t' is a scp-like host:path target, not a path under $root"; return 1 ;;
      esac
      path="$t" ;;
  esac
  if ! real="$(_as_realpath "$path")"; then
    _as_say "$label '$t' cannot be resolved to a physical path (a '..' below an existing directory, or an empty value)"
    return 1
  fi
  if ! _as_under "$root" "$real"; then
    _as_say "$label '$t' resolves to $real, which is outside $root"
    return 1
  fi
  return 0
}

assert_sandboxed() {
  local root_arg="${1-}" root rc=0 t origin credential_helpers home_real
  if [ $# -gt 0 ]; then shift; else root_arg="${BATS_TEST_TMPDIR-}"; fi
  [ -n "$root_arg" ] || { _as_say "no root: pass one, or run inside a bats test with BATS_TEST_TMPDIR set"; return 1; }
  if ! root="$(_as_realpath "$root_arg")" || [ ! -d "$root" ]; then
    _as_say "root '$root_arg' is not an existing directory"
    return 1
  fi
  if [ "$root" = "/" ]; then
    _as_say "root '$root_arg' is the filesystem root, which contains everything and proves nothing"
    return 1
  fi

  for t in "$@"; do
    _as_check_target "target" "$root" "$t" || rc=1
  done

  # origin of the repository the caller is standing in. No repository, or no origin, is not a violation: nothing to push to.
  if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    if origin="$(git remote get-url origin 2>/dev/null)" && [ -n "$origin" ]; then
      _as_check_target "origin" "$root" "$origin" || rc=1
    fi
  fi

  if [ -z "${HOME-}" ]; then
    _as_say "HOME is unset or empty, so it does not point under $root"
    rc=1
  elif ! home_real="$(_as_realpath "$HOME")" || ! _as_under "$root" "$home_real"; then
    _as_say "HOME ($HOME) is not under $root"
    rc=1
  fi
  [ "${GIT_CONFIG_GLOBAL-}" = "/dev/null" ] || { _as_say "GIT_CONFIG_GLOBAL is '${GIT_CONFIG_GLOBAL-<unset>}', not /dev/null"; rc=1; }
  [ "${GIT_CONFIG_NOSYSTEM-}" = "1" ] || { _as_say "GIT_CONFIG_NOSYSTEM is '${GIT_CONFIG_NOSYSTEM-<unset>}', not 1 (the system gitconfig can supply a credential helper)"; rc=1; }
  [ "${GIT_ALLOW_PROTOCOL-}" = "file" ] || { _as_say "GIT_ALLOW_PROTOCOL is '${GIT_ALLOW_PROTOCOL-<unset>}', not file (https, ssh and host:path remotes would be allowed)"; rc=1; }
  [ -z "${SSH_AUTH_SOCK+x}" ] || { _as_say "SSH_AUTH_SOCK is set (an ssh agent could authenticate a push)"; rc=1; }
  [ -z "${GIT_ASKPASS+x}" ] || { _as_say "GIT_ASKPASS is set (a credential prompt program is reachable)"; rc=1; }
  [ -z "${SSH_ASKPASS+x}" ] || { _as_say "SSH_ASKPASS is set (a credential prompt program is reachable)"; rc=1; }

  if command -v git >/dev/null 2>&1; then
    credential_helpers="$(git config --get-all credential.helper 2>/dev/null)"
    if [ -n "$credential_helpers" ]; then
      _as_say "a git credential.helper is configured under this environment: $(printf '%s' "$credential_helpers" | head -n 1)"
      rc=1
    fi
  else
    _as_say "git is not on PATH, so credential.helper cannot be checked"
    rc=1
  fi
  return "$rc"
}
