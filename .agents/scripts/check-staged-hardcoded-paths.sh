#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/check-staged-hardcoded-paths.sh - the verify command of the pre-commit item code-paths-use-resolved-root
#
# USAGE
#   check-staged-hardcoded-paths.sh
#
# Scans the lines ADDED by the staged diff for hardcoded machine-specific locations: a macOS or Linux home
# directory (/Users/<name>/, /home/<name>/), a Windows user directory (drive, backslash, Users), or a file:// URI
# with an absolute path. Code should reach files and URIs through the resolved project root instead (scripts/resolve-root.sh,
# a paths key of project/configs/workflow.json, or a root variable derived from git).
#
# A line that carries the marker  allow-hardcoded-path  is skipped, for the rare place a literal is the point
# (a fixture, a documented example inside code). Removed lines and context lines are never scanned.
#
# Not scanned: Markdown, the board, internal documentation, the wiki, the site, the .claude/ and .agents/ mirrors
# (they duplicate root files), project/logs, project/queue, project/data, lockfiles and generated HTML.
#
# LIMITS (it is a mechanical net, not a proof): it finds literal machine-specific locations only. A fixed-depth climb
# such as "$SCRIPT_DIR/../../.." or a relative path that is simply wrong is NOT detected; that part of the rule stays a
# reviewer's judgment. It reads the whole staged diff, so with unrelated files staged it also reports their lines.
#
# stdout: nothing. stderr: one "<file>:<line>: <added text>" line per hit, then a one-line summary.
# EXIT CODES: 0 nothing found (or not inside a git repository), 1 at least one hit, 2 git failed.
# ---------------------------------------------------------------------------
set -u

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

diff_out="$(git diff --cached -U0 --no-color --no-ext-diff --diff-filter=ACMR -- . \
  ':(exclude,glob)**/*.md' ':(exclude)project/board' ':(exclude)project/documentation' ':(exclude)project/.wiki' \
  ':(exclude)site' ':(exclude).claude' ':(exclude).agents' ':(exclude)project/logs' ':(exclude)project/queue' \
  ':(exclude)project/data' ':(exclude,glob)**/package-lock.json' ':(exclude,glob)**/*.html' 2>/dev/null)" || exit 2

hits="$(printf '%s\n' "$diff_out" | awk '
  /^\+\+\+ / { file = substr($0, 7); next }
  /^@@ /     { split($3, a, ","); line = substr(a[1], 2) + 0; next }
  /^\+/      {
    text = substr($0, 2)
    if (text !~ /allow-hardcoded-path/ &&
        (text ~ /(^|[^A-Za-z0-9._~$}\/-])\/Users\/[A-Za-z0-9._-]+\// || text ~ /(^|[^A-Za-z0-9._~$}\/-])\/home\/[A-Za-z0-9._-]+\// ||
         text ~ /[A-Za-z]:[\\\\]Users[\\\\]/ || text ~ /file:\/\/\/[^ "\047)]/)) {
      printf "%s:%d: %s\n", file, line, text
    }
    line++
  }
')"

[ -z "$hits" ] && exit 0

printf '%s\n' "$hits" >&2
printf 'check-staged-hardcoded-paths.sh: %s added line(s) hardcode a machine-specific path or URI; use the resolved project root (scripts/resolve-root.sh, a workflow.json paths key or a root variable from git), or mark an intentional literal with allow-hardcoded-path\n' \
  "$(printf '%s\n' "$hits" | wc -l | tr -d ' ')" >&2
exit 1
