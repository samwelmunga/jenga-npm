#!/usr/bin/env bash
# checklist-instance.sh - instance-registry helper of the j.checklist skill (epic E67, story E67_S10, task E67_S10_T04).
#
# Answers one question the guided front end must not guess at, "does this project have its own registry yet?", and
# provides the one mechanical building block that follows from the answer.
#
# Why it exists. A project instance (<configs>/checklists.json) replaces the shipped default WHOLE and never merges with
# it. checklist-entry.sh therefore never creates a registry: add, edit, remove, show and situations exit 4 when the
# project has no instance, and `copy <shipped id> --to <new instance>` is refused as an id collision with the seed.
# So the only route for a brand-new item into a project that has no instance is: author it in a scratch registry that
# starts as a copy of the shipped default, then `checklist-entry.sh copy` it to the instance path, which seeds the
# instance from the shipped default plus that item. `scratch` and `discard` are that scratch registry.
#
# This script writes no registry that anything reads. `scratch` makes a file inside a private temp directory,
# `discard` removes only a directory `scratch` made, and `status` is read-only.
#
# Usage:
#   checklist-instance.sh status               print one TAB-separated line, always exit 0 when it can tell:
#                                                instance<TAB><instance path>
#                                                default<TAB><instance path that does not exist yet><TAB><shipped default path>
#   checklist-instance.sh target PATH         classify a copy/move target before anything is written; one word, exit 0:
#                                                shipped-default  PATH is the shipped default itself (it ships downstream)
#                                                new              PATH does not exist, so copy/move would seed it
#                                                exists           PATH is an existing file
#   checklist-instance.sh scratch              copy the shipped default into a new private temp directory and print the
#                                              path of the copy (a registry named checklists.json); nothing else on stdout
#   checklist-instance.sh discard PATH         remove the temp directory that holds PATH, only if `scratch` made it
#   checklist-instance.sh --help
#
# Resolution: the instance path is whatever `checklist-entry.sh path` prints (JENGA_CHECKLISTS_FILE, else
# <configs>/checklists.json via scripts/resolve-root.sh). The shipped default is JENGA_CHECKLISTS_DEFAULT_FILE if set, else
# templates/checklists.json of the package this script ships in, else ./templates/checklists.json, else
# ./node_modules/@jenga-ai/agent/templates/checklists.json (the same order as the other scripts here).
#
# Exit codes:
#   0  done (status always reports instance or default; discard of an already-removed scratch is not an error)
#   1  unexpected failure (temp directory or copy failed)
#   2  usage error, or `discard` was given a path this script did not make
#   4  no shipped default registry could be found
#   5  the instance path could not be resolved (checklist-entry.sh path failed; its message is on stderr)
#
# Compatible with macOS bash 3.2.

set -u

SELF="checklist-instance.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENTRY="$SCRIPT_DIR/checklist-entry.sh"
SCRATCH_PREFIX="jenga-checklist-scratch."

usage() {
  cat <<'EOF'
usage:
  checklist-instance.sh status        instance<TAB><path>   or   default<TAB><instance path><TAB><shipped default path>
  checklist-instance.sh target PATH   shipped-default | new | exists
  checklist-instance.sh scratch       print the path of a scratch copy of the shipped default
  checklist-instance.sh discard PATH  remove a scratch registry's temp directory
  checklist-instance.sh -h | --help
EOF
}

die() {
  printf '%s: %s\n' "$SELF" "$2" >&2
  exit "$1"
}

# Prints the shipped default registry path, or fails.
find_default() {
  local candidate
  if [ -n "${JENGA_CHECKLISTS_DEFAULT_FILE:-}" ]; then
    if [ -f "$JENGA_CHECKLISTS_DEFAULT_FILE" ]; then
      printf '%s' "$JENGA_CHECKLISTS_DEFAULT_FILE"
      return 0
    fi
    return 1
  fi
  for candidate in "$PACKAGE_ROOT/templates/checklists.json" "templates/checklists.json" \
    "node_modules/@jenga-ai/agent/templates/checklists.json"; do
    if [ -f "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Prints the instance path, or exits 5 with the entry script's message.
instance_path() {
  local p
  p="$("$ENTRY" path)" || exit 5
  printf '%s' "$p"
}

cmd_status() {
  local inst def
  inst="$(instance_path)" || exit 5
  if [ -f "$inst" ]; then
    printf 'instance\t%s\n' "$inst"
    return 0
  fi
  def="$(find_default)" || die 4 "no shipped default registry found (looked for templates/checklists.json)"
  printf 'default\t%s\t%s\n' "$inst" "$def"
}

# Prints the canonical (symlink-resolved) form of a path whose directory exists, else the path unchanged.
canon() {
  local d b
  d="$(dirname "$1")"
  b="$(basename "$1")"
  if [ -d "$d" ]; then
    printf '%s/%s' "$(cd "$d" && pwd -P)" "$b"
  else
    printf '%s' "$1"
  fi
}

cmd_target() {
  local def
  [ "$#" -eq 1 ] || die 2 "target takes exactly one PATH"
  def="$(find_default)" || die 4 "no shipped default registry found (looked for templates/checklists.json)"
  if [ "$(canon "$1")" = "$(canon "$def")" ]; then
    printf 'shipped-default\n'
  elif [ -e "$1" ]; then
    printf 'exists\n'
  else
    printf 'new\n'
  fi
}

cmd_scratch() {
  local def dir
  def="$(find_default)" || die 4 "no shipped default registry found (looked for templates/checklists.json)"
  dir="$(mktemp -d "${TMPDIR:-/tmp}/${SCRATCH_PREFIX}XXXXXX")" || die 1 "could not create a temp directory"
  if ! cp "$def" "$dir/checklists.json"; then
    rm -rf "$dir"
    die 1 "could not copy $def"
  fi
  printf '%s\n' "$dir/checklists.json"
}

cmd_discard() {
  local path dir
  [ "$#" -eq 1 ] || die 2 "discard takes exactly one PATH"
  path="$1"
  dir="$(dirname "$path")"
  case "$(basename "$dir")" in
    "$SCRATCH_PREFIX"*) ;;
    *) die 2 "refusing to remove $path: it is not inside a scratch directory made by this script" ;;
  esac
  [ "$(basename "$path")" = "checklists.json" ] || die 2 "refusing to remove $path: not a scratch registry"
  [ -d "$dir" ] && rm -rf "$dir"
  return 0
}

[ "$#" -ge 1 ] || {
  usage >&2
  exit 2
}

case "$1" in
  -h | --help | help)
    usage
    exit 0
    ;;
  status)
    shift
    [ "$#" -eq 0 ] || die 2 "status takes no arguments"
    cmd_status
    ;;
  target)
    shift
    cmd_target "$@"
    ;;
  scratch)
    shift
    [ "$#" -eq 0 ] || die 2 "scratch takes no arguments"
    cmd_scratch
    ;;
  discard)
    shift
    cmd_discard "$@"
    ;;
  *)
    usage >&2
    die 2 "unknown subcommand: $1"
    ;;
esac
