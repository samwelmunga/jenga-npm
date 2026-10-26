#!/usr/bin/env bash
# Test stub for a workflow compute step (tests/helpers/workflow-fixture.bash installs it as
# <workflows>/scripts/count-run.sh in the fixture tree).
#
#   count-run.sh <label> [ignored...]
#
# Appends <label> to <tree>/wf-count.log (one line per run), prints a fixed id_list on stdout, and exits 1 with a
# message on stderr while the file <tree>/wf-fail-<label> exists. A test injects a failure by creating that file and
# "fixes" it by deleting it, so nothing has to travel through the environment into the compute child.
# <tree> is derived from this file's own location (three directories up), never from an environment variable.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TREE="$(cd "$HERE/../../.." && pwd)"
LABEL="${1:-}"
if [ -z "$LABEL" ]; then
  echo "count-run.sh: missing <label>" >&2
  exit 2
fi
printf '%s\n' "$LABEL" >> "$TREE/wf-count.log"
if [ -e "$TREE/wf-fail-$LABEL" ]; then
  echo "count-run.sh: injected failure for '$LABEL' (remove wf-fail-$LABEL to clear it)" >&2
  exit 1
fi
printf 'E80_S06\nE80_S06_T01\n'
