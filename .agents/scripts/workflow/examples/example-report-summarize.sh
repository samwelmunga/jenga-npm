#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# example-report-summarize.sh - one-line summary of a confirmed id list (epic E80, task E80_S06_T01)
#
# The second of the two `compute` commands of the example-report workflow. It needs no model and no network.
#
# USAGE
#   example-report-summarize.sh <id_list>
#
# <id_list> is the confirmed id list as ONE argument, in the form of the `id_list` type: elements separated by
# commas and/or newlines. It is normalised the way the type registry does (split on comma, trim, drop empty) and
# printed as a single line:
#   <n> high-priority items: <id>, <id>, ...
# where <n> is the number of elements, in the order given.
#
# EXIT CODES
#   0  success (the summary line is on stdout)
#   2  usage error, or the list is empty after normalisation; a message is written to stderr and NOTHING is
#      written to stdout
#
# Deterministic (same input, same output). Reads no file and writes no file.
# ---------------------------------------------------------------------------
set -u

die() {
  printf 'example-report-summarize.sh: %s\n' "$1" >&2
  exit 2
}

[ "$#" -eq 1 ] || die "usage: example-report-summarize.sh <id_list>"

# split_on_comma, trim, drop_empty
ids="$(printf '%s\n' "$1" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$')" || true

[ -n "$ids" ] || die "the id list is empty"

count="$(printf '%s\n' "$ids" | wc -l | tr -d '[:space:]')"
joined="$(printf '%s\n' "$ids" | paste -sd ',' - | sed 's/,/, /g')"

printf '%s high-priority items: %s\n' "$count" "$joined"
