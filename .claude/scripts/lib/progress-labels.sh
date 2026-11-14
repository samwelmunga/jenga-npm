# shellcheck shell=bash
# scripts/lib/progress-labels.sh - the label table for the terminal progress bar (epic E92, task E92_S02_T01).
#
# Source this file; do not execute it. bash 3.2 compatible. Sourcing prints nothing, sets no shell options and runs
# no command. This file is UTF-8: the Swedish and symbol strings are not ASCII.
#
# Every user-visible word of the bar lives in the one table below, so switching language is a data change.
#
#   progress_label <key> [<lang>]   print the label for <key>; <lang> defaults to progress_lang. An unknown key or an
#                                   unknown language prints nothing and returns 1.
#   progress_lang                   print the effective language: JENGA_PROGRESS_LANG when it names a shipped
#                                   language, otherwise the default.
#
# Default language: en (confirmed by the user on 2026-11-12; this package is distributed to other projects).
# Swedish ships as well and is selected with JENGA_PROGRESS_LANG=sv. Changing the default is the one-word edit of
# PROGRESS_LABEL_DEFAULT_LANG below.
#
# rejected_note is a printf format string and keeps its %d for the caller to fill in.

PROGRESS_LABEL_DEFAULT_LANG='en'
PROGRESS_LABEL_LANGS='sv en'
# shellcheck disable=SC2034  # read by callers and tests that source this library
PROGRESS_LABEL_KEYS='in_progress failed rejected_note unknown nothing'

# _progress_label_raw <lang> <key>: the table. Prints the label, or returns 1 for an unknown lang/key pair.
_progress_label_raw() {
  case "$1:$2" in
    sv:in_progress)   printf '%s\n' 'pågår' ;;
    sv:failed)        printf '%s\n' 'röd' ;;
    sv:rejected_note) printf '%s\n' '⊘ %d avvisade (ej räknade)' ;;
    sv:unknown)       printf '%s\n' 'okända' ;;
    sv:nothing)       printf '%s\n' 'inget att räkna' ;;
    en:in_progress)   printf '%s\n' 'in progress' ;;
    en:failed)        printf '%s\n' 'red' ;;
    en:rejected_note) printf '%s\n' '⊘ %d rejected (not counted)' ;;
    en:unknown)       printf '%s\n' 'unknown' ;;
    en:nothing)       printf '%s\n' 'nothing to count' ;;
    *) return 1 ;;
  esac
}

# progress_lang: the effective language. Exact match only (no case folding, no trimming).
progress_lang() {
  local l
  for l in $PROGRESS_LABEL_LANGS; do
    if [ "${JENGA_PROGRESS_LANG-}" = "$l" ]; then
      printf '%s\n' "$l"
      return 0
    fi
  done
  printf '%s\n' "$PROGRESS_LABEL_DEFAULT_LANG"
}

# progress_label <key> [<lang>]
progress_label() {
  local key="${1-}" lang
  if [ "$#" -ge 2 ]; then
    lang="$2"
  else
    lang="$(progress_lang)"
  fi
  [ -n "$key" ] && [ -n "$lang" ] || return 1
  _progress_label_raw "$lang" "$key"
}
