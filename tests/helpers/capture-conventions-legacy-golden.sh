#!/usr/bin/env bash
#
# capture-conventions-legacy-golden.sh - (re)write the legacy conventions goldens (E79_S03_T01).
#
# Renders every case defined in tests/helpers/conventions-legacy-golden.bash against the CURRENT scripts and writes
# one tests/fixtures/conventions-legacy-golden/<case>.golden per case. The goldens pin the behaviour of a project
# that records no commit-format.template and no commit-trace, so that later E79_S03 tasks can prove it unchanged.
#
# Usage:
#   tests/helpers/capture-conventions-legacy-golden.sh [--out <dir>]
#
#   --out <dir>   write the goldens there instead of tests/fixtures/conventions-legacy-golden/ (used to check that two
#                 captures are identical, and by reviewers who want to diff a fresh capture against the committed set)
#
# This is a deliberate, reviewed action, never part of a test run: it refuses to run when BATS_TEST_FILENAME is set.
# Any *.golden file already in the output directory is removed first so a retired case cannot leave an orphan;
# nothing else in that directory is touched. It writes nothing outside the output directory and a scratch directory
# that it removes on exit. It needs jq and python3 (as the scripts it runs do).
#
# Exit codes: 0 captured; 1 a case failed to render or a golden carries a scratch path; 2 usage / refused under bats.
#
# Compatible with macOS bash 3.2.

set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=conventions-legacy-golden.bash
. "$here/conventions-legacy-golden.bash"

if [ -n "${BATS_TEST_FILENAME:-}" ]; then
  printf 'capture-conventions-legacy-golden.sh: refusing to run inside a bats test; goldens are regenerated only by a deliberate, reviewed change\n' >&2
  exit 2
fi

out="$CLG_GOLDEN_DIR_DEFAULT"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --out)
      [ "$#" -ge 2 ] || { printf 'usage: capture-conventions-legacy-golden.sh [--out <dir>]\n' >&2; exit 2; }
      out="$2"
      shift 2
      ;;
    *)
      printf 'usage: capture-conventions-legacy-golden.sh [--out <dir>]\n' >&2
      exit 2
      ;;
  esac
done

CLG_WORK="$(mktemp -d "${TMPDIR:-/tmp}/clg-capture.XXXXXX")" || exit 1
trap 'rm -rf "$CLG_WORK"' EXIT
mkdir -p "$out" || exit 1
rm -f "$out"/*.golden

n=0
status=0
for c in $(clg_cases); do
  if ! clg_render "$c" "$out/$c.golden"; then
    printf 'capture-conventions-legacy-golden.sh: case %s failed to render\n' "$c" >&2
    status=1
  fi
  n=$((n + 1))
done

# A golden must not carry a scratch path (normalisation failed): it would differ on every run.
if grep -lE '/var/folders|/private/var|/tmp/|clg-capture' "$out"/*.golden >&2; then
  printf 'capture-conventions-legacy-golden.sh: the files above carry a scratch path\n' >&2
  status=1
fi

printf 'captured %s cases into %s\n' "$n" "$out"
exit "$status"
