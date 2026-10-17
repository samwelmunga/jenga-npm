#!/usr/bin/env bash
# scripts/pages-cutover.sh  (E70_S03_T02)
#
# One-time manual cutover of the public samwelmunga/jenga-npm repository's GitHub
# Pages source, from branch mode (/docs on main) to GitHub Actions (site/, built by
# .github/workflows/pages.yml). Run by hand only; never from a hook or a test.
#
#   --dry-run   run the gh preflight, then print the command that would run (no PUT)
#   --execute   run the gh preflight, then run the PUT
#
# Exit codes: 0 ok, 2 usage, 3 gh missing, 4 gh unauthenticated, 5 PUT failed.

set -euo pipefail

REPO="samwelmunga/jenga-npm"
PUT_ARGS=(api -X PUT "repos/${REPO}/pages" -f build_type=workflow)

usage() {
  printf 'usage: pages-cutover.sh --dry-run | --execute\n' >&2
}

case "${1:-}" in
  --dry-run|--execute) MODE="$1" ;;
  "") usage; exit 2 ;;
  *) printf 'pages-cutover.sh: unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
esac
if [ "$#" -ne 1 ]; then
  printf 'pages-cutover.sh: expected exactly one argument\n' >&2
  usage
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  printf 'pages-cutover.sh: the gh CLI is not installed or not on PATH. Install it from https://cli.github.com and re-run.\n' >&2
  exit 3
fi

if ! gh auth status >/dev/null 2>&1; then
  printf 'pages-cutover.sh: gh is not authenticated. Run "gh auth login" with an account that has admin rights on %s, then re-run.\n' "$REPO" >&2
  exit 4
fi

if [ "$MODE" = "--dry-run" ]; then
  printf '%s\n' gh "${PUT_ARGS[@]}"
  exit 0
fi

if ! gh "${PUT_ARGS[@]}"; then
  printf 'pages-cutover.sh: the Pages PUT failed. Check the gh output above and your admin rights on %s.\n' "$REPO" >&2
  exit 5
fi

cat <<EOF
Pages source for ${REPO} is now GitHub Actions. The site serves nothing new until the
Pages workflow deploys, so run these steps back to back, in this order:
  1. Run /j-mirror-public so site/ reaches the public repo and docs/ is removed.
  2. Trigger the workflow: gh workflow run pages.yml --repo ${REPO}
  3. Confirm the deploy succeeded in the repository's Actions tab.
Failure mode and rollback: project/documentation/site-decisions.md, "Manual cutover".
EOF
