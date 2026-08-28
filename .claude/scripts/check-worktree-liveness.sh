#!/usr/bin/env bash
# scripts/check-worktree-liveness.sh — detect OS processes still rooted
# inside a given worktree path.
#
# Usage:
#   scripts/check-worktree-liveness.sh <worktree-path>
#
# Why this exists: `ListAgents` reports agent lifecycle, not detached OS
# processes. A live incident (2026-08-25, see E37's Purpose) showed a
# completed agent leaving shell polling loops running with their cwd inside
# a worktree; `ListAgents` showed the agent itself as "completed" and gave
# no signal that those loops were still alive, so the worktree was removed
# out from under them. This script answers a narrower, deterministic
# question instead: "does any OS process currently have its *current
# working directory* rooted inside this path (the path itself, or any
# subdirectory of it)?" It is intended to be run as a precondition before
# `git worktree remove` (wired in the sibling task E37_S03_T02, not here —
# this task only produces the standalone check).
#
# Detection mechanism (primary): `lsof +D <path> -F pcfn`
#   `+D <path>` recursively restricts lsof's report to files open within
#   that directory subtree (this alone gives us "inside the given path,
#   including subdirectories" — verified locally against a nested-subdir
#   case). `-F pcfn` is lsof's machine-parsable output mode, emitting one
#   attribute per line: `p<pid>`, `c<command>`, `f<fd-or-descriptor-type>`,
#   `n<file name>`, grouped per matching open-file record. Records are then
#   filtered down to those whose `f` field is literally `cwd` — this is what
#   distinguishes "this process's current working directory is here" from
#   "this process merely has some unrelated file open under here" (e.g. a
#   log file), which `+D` alone does not distinguish.
#
#   `-F pcfn` (not lsof's default human-readable columnar output) is used
#   deliberately: column widths/ordering in the default output are not
#   guaranteed stable across lsof versions/platforms, whereas the `-F` field
#   protocol is. Verified directly against this repo's own Darwin runtime
#   (lsof 4.91) — both an exact-path cwd match and a subdirectory cwd match
#   are correctly reported, and process cwd is resolved through symlinks
#   (macOS reports `/tmp/x` as `/private/tmp/x`), which is why the input
#   path is canonicalized below before comparison.
#
# Detection mechanism (fallback, when `lsof` is not on PATH): enumerate
# `/proc/[0-9]*` (Linux only — macOS has no `/proc`) and `readlink` each
# `/proc/<pid>/cwd`, comparing against the canonicalized target path. macOS
# ships `lsof` by default, so this branch is not expected to run on this
# repo's actual runtime, but keeps the script functional on minimal Linux
# containers that may lack `lsof`. If neither mechanism is available, the
# script cannot determine liveness at all and fails closed (non-zero exit,
# clear stderr message) rather than silently reporting "clear" when it does
# not actually know.
#
# Command-line resolution for reported matches uses `ps -o command= -p
# <pid>` — confirmed to behave identically on macOS's BSD `ps` and Linux's
# GNU `ps`, unlike some other `ps` flags/keywords (e.g. `-e` listing
# semantics differ between BSD and GNU `ps`, which is why the fallback path
# above enumerates PIDs via `/proc` rather than `ps -e`).
#
# Caller-cwd self-detection hardening: if the *caller* invokes this script
# from a shell whose own cwd is already inside the target path (e.g. `cd
# <worktree> && check-worktree-liveness.sh <worktree>` — a very plausible
# state right before a worktree is removed), every subprocess the script
# forks (the `lsof` child, and the process-substitution subshell wrapping
# it below, or the `readlink` calls in the /proc fallback) would otherwise
# *inherit* that cwd, since bash processes inherit cwd from their parent by
# default. That produced a real, reproduced false positive: the script's
# own subprocess chain got reported as a "live process rooted in" the very
# path being checked, even with zero genuinely orphaned processes running.
# See project/rapports/problems/E37_S03_T01-self-detection-false-positive-remarks.md
# for the original reproduction and the two fix options it proposed.
#
# Fix: immediately after resolving $ABS_PATH (and before spawning anything),
# the script `cd`s itself to `/` — a path guaranteed to be outside every
# possible target. This moves the *script's own process* outside the target,
# so every descendant it forks from this point on inherits a cwd of `/`
# instead of the caller's original cwd, regardless of where the caller
# happened to be standing when it invoked this script. This is preferred
# over tracking and excluding individual subprocess PIDs (the script's own
# PID `$$` was already excluded as a courtesy, see below) because `cd /`
# removes the precondition for the whole bug class structurally, rather
# than requiring every current and future subprocess this script might ever
# spawn to be enumerated and excluded by PID after the fact.
#
# The script also excludes its own PID ($$) from reported matches as a
# second, defense-in-depth courtesy (now largely redundant given the `cd /`
# fix above, but harmless to keep).
#
# Exit codes:
#   0   clear — no live process found, no output
#   1   one or more live processes found — PID(s) and command(s) printed
#   2   invalid usage (wrong argument count / empty argument)
#   3   <worktree-path> does not resolve to an existing directory
#   4   unable to determine liveness on this platform (neither `lsof` nor
#       /proc available) — fail closed, this is NOT the same as "clear"

set -u

SCRIPT_NAME="check-worktree-liveness.sh"

usage() {
  echo "Usage: $SCRIPT_NAME <worktree-path>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
RAW_PATH="$1"
[ -n "$RAW_PATH" ] || usage

if [ ! -d "$RAW_PATH" ]; then
  echo "$SCRIPT_NAME: '$RAW_PATH' is not a directory" >&2
  exit 3
fi

# Canonicalize to an absolute, symlink-resolved path so comparisons against
# process cwd values (which the OS reports fully resolved — e.g. macOS
# reports /tmp as /private/tmp) match correctly regardless of how the
# caller spelled the input path.
ABS_PATH="$(cd "$RAW_PATH" 2>/dev/null && pwd -P)"
if [ -z "$ABS_PATH" ]; then
  echo "$SCRIPT_NAME: unable to resolve '$RAW_PATH' to an absolute path" >&2
  exit 3
fi

# Move this process (and therefore every subprocess it forks from here on)
# outside of every possible target path, so the scan below can never
# self-detect regardless of the caller's cwd at invocation time. See the
# "Caller-cwd self-detection hardening" comment in the header above. `/` is
# always present and readable on every platform this script targets; if for
# some reason it could not be `cd`'d into, fall through rather than abort —
# worst case the pre-existing $$ exclusion below is the only mitigation,
# same as before this fix.
cd / 2>/dev/null || true

SELF_PID="$$"
FOUND_ANY=0
REPORTED_PIDS=""

already_reported() {
  case " $REPORTED_PIDS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

report_match() {
  pid="$1"
  already_reported "$pid" && return 0
  REPORTED_PIDS="$REPORTED_PIDS $pid"
  cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
  [ -n "$cmd" ] || cmd="(command unavailable — process may have exited)"
  echo "$SCRIPT_NAME: live process rooted in '$ABS_PATH' — PID $pid: $cmd"
  FOUND_ANY=1
}

if command -v lsof >/dev/null 2>&1; then
  current_pid=""
  current_fd=""
  while IFS= read -r line; do
    case "$line" in
      p*)
        current_pid="${line#p}"
        current_fd=""
        ;;
      f*)
        current_fd="${line#f}"
        ;;
      n*)
        if [ "$current_fd" = "cwd" ] && [ -n "$current_pid" ] && [ "$current_pid" != "$SELF_PID" ]; then
          report_match "$current_pid"
        fi
        ;;
    esac
  done < <(lsof +D "$ABS_PATH" -F pcfn 2>/dev/null)
else
  if [ -d /proc ]; then
    for pid_dir in /proc/[0-9]*; do
      [ -e "$pid_dir" ] || continue
      pid="${pid_dir#/proc/}"
      [ "$pid" != "$SELF_PID" ] || continue
      cwd_link="$(readlink "$pid_dir/cwd" 2>/dev/null)" || continue
      [ -n "$cwd_link" ] || continue
      case "$cwd_link" in
        "$ABS_PATH"|"$ABS_PATH"/*)
          report_match "$pid"
          ;;
      esac
    done
  else
    echo "$SCRIPT_NAME: neither 'lsof' nor /proc is available on this system — cannot determine worktree liveness for '$ABS_PATH'" >&2
    exit 4
  fi
fi

[ "$FOUND_ANY" -eq 1 ] && exit 1
exit 0
