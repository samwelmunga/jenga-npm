#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/npm-reach-files.sh - the files an npm consumer receives (E28_S21_T05)
#
# Prints, one per line, root-relative and sorted under LC_ALL=C, every file `npm pack` would put in the tarball.
# package.json "files" and .npmignore stay the single source of truth: there is no second list here to drift, and a
# directory later added to "files" is picked up automatically. Two consumers share it so they cannot disagree about
# the scan scope for path references to a never-public skill:
#   - the mirror-time reference guard (skills/j-mirror-public/scripts/mirror.sh, check_never_public_refs_invariant)
#   - the maintainer-side audit (scripts/check-public-references.sh)
#
# Usage: npm-reach-files.sh [<root>]
#   <root>   the directory holding package.json (default: this script's parent directory)
#
# Deterministic: the same tree always yields byte-identical output. The list is the list for the PRIVATE repository
# (the mirror strips blocked files afterwards), so it can over-state what ships; that errs toward scanning more.
# `npm pack` is run with --ignore-scripts, so the prepack UI build is not triggered; a built UI dist that is absent
# from the tree is therefore absent from the list.
#
# FAIL CLOSED. If the scope cannot be computed, the exit status is non-zero, the reason goes to stderr and NOTHING is
# written to stdout, so a failure to compute the scope can never be read as an empty (silently green) scan set. The
# failures: npm or node missing, root not a directory, npm pack failing, output that is not the expected JSON, and an
# empty list.
#
# Exit status: 0 list printed; 1 could not compute it; 2 usage.
# Portable: bash 3.2, no GNU-only flags.
# ---------------------------------------------------------------------------
set -u

die() {
  echo "npm-reach-files.sh: error: $1" >&2
  exit 1
}

if [ "$#" -gt 1 ]; then
  echo "usage: npm-reach-files.sh [<root>]" >&2
  exit 2
fi

if [ "$#" -eq 1 ]; then
  ROOT="$1"
else
  SELF="${BASH_SOURCE[0]}"
  case "$SELF" in
    */*) ROOT="${SELF%/*}/.." ;;
    *) ROOT=".." ;;
  esac
fi

[ -d "$ROOT" ] || die "root is not a directory: $ROOT"
command -v npm >/dev/null 2>&1 || die "npm is not installed or not on PATH, cannot compute the npm-reach list"
command -v node >/dev/null 2>&1 || die "node is not installed or not on PATH, cannot parse the npm pack output"

ERR_FILE="$(mktemp -t npm-reach-err.XXXXXX)" || die "cannot create a temporary file"
OUT_FILE="$(mktemp -t npm-reach-out.XXXXXX)" || { rm -f "$ERR_FILE"; die "cannot create a temporary file"; }
trap 'rm -f "$ERR_FILE" "$OUT_FILE"' EXIT

# --ignore-scripts: never run the prepack UI build from a check. The notifier is switched off so a run never reaches
# the network.
if ! (cd "$ROOT" && npm_config_update_notifier=false npm pack --dry-run --json --ignore-scripts >"$OUT_FILE" 2>"$ERR_FILE"); then
  die "npm pack --dry-run failed: $(tr '\n' ' ' <"$ERR_FILE" | cut -c1-300)"
fi

# Print every files[].path of the first pack result, or exit 3 (unparseable) / 4 (no files). Nothing reaches stdout
# of this script until the whole list has been validated and sorted.
LIST="$(node -e '
  const fs = require("fs");
  let data;
  try { data = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { process.exit(3); }
  const first = Array.isArray(data) ? data[0] : null;
  if (!first || !Array.isArray(first.files)) process.exit(3);
  const paths = first.files.map((f) => f && f.path).filter((p) => typeof p === "string" && p.length > 0);
  if (paths.length === 0) process.exit(4);
  process.stdout.write(paths.join("\n") + "\n");
' "$OUT_FILE")"
rc=$?
case "$rc" in
  0) ;;
  3) die "npm pack --dry-run --json output could not be parsed as the expected JSON" ;;
  4) die "npm pack --dry-run reports an empty file list, refusing to treat it as an empty scan set" ;;
  *) die "could not read the npm pack output (node exited $rc)" ;;
esac

printf '%s\n' "$LIST" | LC_ALL=C sort -u
