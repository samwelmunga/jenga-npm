#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# example-report-select.sh - select the high-priority items of an items file (epic E80, task E80_S06_T01)
#
# The first of the two `compute` commands of the example-report workflow. It needs no model and no network.
#
# USAGE
#   example-report-select.sh <items.json>
#
# <items.json> is a JSON array of objects with the fields id, title and priority. The items whose priority is
# exactly "high" are selected, in the order they appear in the file. Their ids are printed on ONE line, comma
# separated with no spaces, e.g. E90_S01_T01,E90_S02_T01. That is the normalised form of the `id_list` type
# (split on comma, trim, drop empty), so every element matches the id_list verification rule of the type registry.
# When no item is high priority nothing is printed and the exit status is 0.
#
# EXIT CODES
#   0  success (the selection, possibly empty, is on stdout)
#   2  usage error, or the file is missing, unreadable, not valid JSON, or not an array of objects with a string
#      id; a message naming the file is written to stderr and NOTHING is written to stdout
#
# Deterministic (same input, same output). Reads the one file it is given; writes no file.
# ---------------------------------------------------------------------------
set -u

die() {
  printf 'example-report-select.sh: %s\n' "$1" >&2
  exit 2
}

[ "$#" -eq 1 ] || die "usage: example-report-select.sh <items.json>"
file="$1"

[ -f "$file" ] && [ -r "$file" ] || die "items file not found or not readable: $file"

# Compute first, print after, so a failure never leaves partial output on stdout.
ids="$(jq -r '
  if type == "array" and all(.[]; type == "object" and (.id | type) == "string")
  then [.[] | select(.priority == "high") | .id] | join(",")
  else error("not an array of objects with a string id")
  end' "$file" 2>/dev/null)" || die "items file is not valid JSON of the expected shape: $file"

[ -z "$ids" ] || printf '%s\n' "$ids"
