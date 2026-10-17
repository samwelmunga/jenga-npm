#!/usr/bin/env bash
# scripts/verify-pages-permalinks.sh  (E70_S03_T05)
#
# Requests the site root and every permalink declared in site/**/*.md front matter
# against a live Pages base URL, and prints "<http-status> <url>" per line.
#
#   verify-pages-permalinks.sh <base-url>
#
# Exit codes: 0 every URL returned 200, 1 at least one did not, 2 usage error.
# Read-only: it issues GET requests and writes nothing.

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  printf 'usage: verify-pages-permalinks.sh <base-url>\n' >&2
  exit 2
fi

BASE="${1%/}"
SITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/site"

PERMALINKS="$(grep -rhoE '^permalink: *[^ ]+' --include='*.md' "$SITE_DIR" | sed -E 's/^permalink: *//; s/["'\'']//g' | sort -u || true)"

failed=0
check() {
  local url="$1" status
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$url" || true)"
  printf '%s %s\n' "${status:-000}" "$url"
  [ "${status:-000}" = "200" ] || failed=$((failed + 1))
}

check "$BASE/"
while IFS= read -r permalink; do
  [ -n "$permalink" ] || continue
  check "$BASE$permalink"
done <<< "$PERMALINKS"

if [ "$failed" -gt 0 ]; then
  printf 'verify-pages-permalinks.sh: %s URL(s) did not return 200\n' "$failed" >&2
  exit 1
fi
