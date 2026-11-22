#!/usr/bin/env bash
# Builds the synthetic board for tests/task-usage-coverage.bats into the directory given as $1.
# Cases: measured (with cost units), explicit zero, possibly incomplete, stale measured (no cost units),
# two unmeasured (E99 and E100, to check numeric order), an unparseable file, and a partial-field file.
set -eu
d="$1"; mkdir -p "$d"
raw() { printf 'usage_input_tokens: 1\nusage_output_tokens: 2\nusage_cache_write_tokens: 3\nusage_cache_read_tokens: 4\nusage_total_tokens: 10\nusage_transcripts: 1\nusage_measured_on: 2026-11-19\n'; }
mk() { # id, extra-lines
  printf -- '---\nid: %s\ntitle: "t"\nstatus: Passed\n%s---\n\n# Task\nusage_total_tokens: 999 (body text, must be ignored)\n' "$1" "$2" > "$d/$1_x.md"
}
mk E99_S01_T01 "$(raw)
usage_cost_units: 7
"
mk E99_S01_T02 "usage_input_tokens: 0
usage_output_tokens: 0
usage_cache_write_tokens: 0
usage_cache_read_tokens: 0
usage_total_tokens: 0
usage_cost_units: 0
"
mk E99_S01_T03 "$(raw)
usage_possibly_incomplete: true
usage_cost_units: 7
"
mk E99_S01_T04 "$(raw)
"
mk E99_S01_T05 ""
mk E100_S01_T01 ""
mk E99_S01_T07 "usage_input_tokens: 5
"
printf 'no frontmatter here\n' > "$d/E99_S01_T06_broken.md"
