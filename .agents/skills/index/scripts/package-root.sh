#!/usr/bin/env bash
# skills/index/scripts/package-root.sh
#
# Shared package-root resolver for skill scripts. Source it, then call:
#
#   PACKAGE_ROOT="$(jenga_package_root "$SCRIPT_DIR")"
#
# WHY IT EXISTS. A skill script used to find the package (the directory that holds `scripts/`,
# `templates/`, `lib/`, `hooks/`) as "$SCRIPT_DIR/../../..". That is right in this monorepo
# (skills/<skill>/scripts -> repo root) and inside the installed package
# (node_modules/@jenga-ai/agent/skills/<skill>/scripts -> package root). It is WRONG in a consumer
# project: postinstall mirrors only skills/ and agents/ into the consumer's `.claude/` and `.agents/`,
# so from `.claude/skills/<skill>/scripts` the same three levels land on `.claude/`, which has no
# `templates/` or `scripts/`. The package assets are in `node_modules/@jenga-ai/agent`.
#
# RESOLUTION, first hit wins. A directory "is the package" when it has both `scripts/resolve-root.sh`
# and `templates/`:
#   1. the install root implied by the script's own location: the directory above the `skills/`
#      directory the script sits under (any depth below `skills/<skill>/`), so a script in
#      skills/<skill>/scripts/lib/ resolves like one in skills/<skill>/scripts/
#   2. <dir>/node_modules/@jenga-ai/agent for <dir> = JENGA_PROJECT_ROOT, CLAUDE_PROJECT_DIR, the
#      install root of (1), then each ancestor of the script directory, then each ancestor of $PWD
#
# When nothing qualifies it prints candidate (1) on stdout anyway and returns 1, so a caller that
# ignores the status keeps the behaviour it had before this helper existed, and one that checks it can
# say what was missing. It also writes ONE line to stderr naming what it looked for, because nearly
# every caller does `PACKAGE_ROOT="$(jenga_package_root ...)" || true` and would otherwise fail later
# with a path under the wrong directory and no hint that the package is simply not installed. stdout is
# never anything but the path. It creates nothing, never exits the caller, and is safe under `set -u`.
# bash 3.2 compatible. What a script should do on a non-zero status: project/documentation/skill-authoring.md,
# "Locating the package root".

_jenga_pkg_is_root() {
  [ -f "$1/scripts/resolve-root.sh" ] && [ -d "$1/templates" ]
}

# jenga_package_root <script-dir>
jenga_package_root() {
  local sdir d install="" base cand
  sdir="$(cd -- "${1:-.}" 2>/dev/null && pwd -P)" || sdir="${1:-.}"

  # Candidate 1: the directory above the nearest enclosing `skills/` directory.
  d="$sdir"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ "$(basename -- "$d")" = "skills" ]; then install="$(dirname -- "$d")"; break; fi
    d="$(dirname -- "$d")"
  done
  [ -n "$install" ] || install="$(cd -- "$sdir/../../.." 2>/dev/null && pwd -P)"

  if _jenga_pkg_is_root "$install"; then printf '%s\n' "$install"; return 0; fi

  # Candidate 2: an installed package, looked up from every plausible project directory.
  for base in "${JENGA_PROJECT_ROOT:-}" "${CLAUDE_PROJECT_DIR:-}" "$install"; do
    [ -n "$base" ] || continue
    cand="$base/node_modules/@jenga-ai/agent"
    if _jenga_pkg_is_root "$cand"; then printf '%s\n' "$cand"; return 0; fi
  done
  for d in "$sdir" "$PWD"; do
    while [ -n "$d" ]; do
      cand="$d/node_modules/@jenga-ai/agent"
      if _jenga_pkg_is_root "$cand"; then printf '%s\n' "$cand"; return 0; fi
      [ "$d" = "/" ] && break
      d="$(dirname -- "$d")"
    done
  done

  printf 'package-root.sh: no Jenga package found for %s (looked for a directory with scripts/resolve-root.sh and templates/ above skills/, and at node_modules/@jenga-ai/agent from the script directory, $PWD, JENGA_PROJECT_ROOT and CLAUDE_PROJECT_DIR); is @jenga-ai/agent installed?\n' "$sdir" >&2
  printf '%s\n' "$install"
  return 1
}

# Executed directly (not sourced): print the resolved root for the script directory given as $1.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  jenga_package_root "${1:-$PWD}"
fi
