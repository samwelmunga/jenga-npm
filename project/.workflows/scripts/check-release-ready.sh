#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-release-ready.sh - step 1 of the `deploy-stage` workflow: is there a new,
# unreleased version on origin/main to stage?
#
# Read-only apart from `git fetch`. Prints a human-readable summary block on stdout
# (the step's `release` output) and exits non-zero when the run must not proceed, so
# the workflow stops before anything is dispatched.
#
# Usage: check-release-ready.sh [<remote>] [<branch>]   (defaults: origin main)
#
# Exit: 0 ready to stage; 1 not ready (the reason is the last line of stdout and is
# also on stderr); 2 setup error (not a git repo, no package.json, git/node missing).
# ---------------------------------------------------------------------------
set -uo pipefail

REMOTE="${1:-origin}"
BRANCH="${2:-main}"

die() { printf 'check-release-ready: %s\n' "$1" >&2; exit "${2:-2}"; }

command -v git >/dev/null 2>&1 || die "git not installed"
command -v node >/dev/null 2>&1 || die "node not installed"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree"

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || die "cannot cd to the repo root"
[ -f package.json ] || die "no package.json at $ROOT"

VERSION="$(node -p "require('./package.json').version" 2>/dev/null)" || die "cannot read the version from package.json"
PKG="$(node -p "require('./package.json').name" 2>/dev/null)" || die "cannot read the name from package.json"
TAG="v${VERSION}"
STAGE_TAG="v${VERSION}-stage"

# --no-tags with an explicit refspec, deliberately: a plain `git fetch --tags` exits
# non-zero in this repo because local stage tags differ from the remote's ("would
# clobber existing tag"), which would block every run. No local tag is needed here -
# the tag checks below ask the remote directly with `git ls-remote`.
git fetch --no-tags --quiet "$REMOTE" \
  "+refs/heads/${BRANCH}:refs/remotes/${REMOTE}/${BRANCH}" 2>/dev/null \
  || die "git fetch $REMOTE $BRANCH failed"

LOCAL_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse "refs/remotes/${REMOTE}/${BRANCH}" 2>/dev/null)" || die "no ${REMOTE}/${BRANCH} ref after fetch"
CUR_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
AHEAD="$(git rev-list --count "refs/remotes/${REMOTE}/${BRANCH}..HEAD" 2>/dev/null || echo '?')"
BEHIND="$(git rev-list --count "HEAD..refs/remotes/${REMOTE}/${BRANCH}" 2>/dev/null || echo '?')"
DIRTY="$(git status --porcelain | wc -l | tr -d ' ')"

tag_on_remote() {
  git ls-remote --tags --exit-code "$REMOTE" "refs/tags/$1" >/dev/null 2>&1 && echo yes || echo no
}
PROD_TAG_REMOTE="$(tag_on_remote "$TAG")"
STAGE_TAG_REMOTE="$(tag_on_remote "$STAGE_TAG")"

REGISTRY_VERSION="unknown (npm not installed)"
if command -v npm >/dev/null 2>&1; then
  REGISTRY_VERSION="$(npm view "${PKG}@${VERSION}" version 2>/dev/null)" || REGISTRY_VERSION=""
  [ -n "$REGISTRY_VERSION" ] || REGISTRY_VERSION="not published"
fi

BUMP_SHA="$(git log -1 --format=%h --grep="bump version to ${VERSION}" "refs/remotes/${REMOTE}/${BRANCH}" 2>/dev/null || true)"

printf 'package        %s\n' "$PKG"
printf 'version        %s   (prod tag %s, stage tag %s)\n' "$VERSION" "$TAG" "$STAGE_TAG"
printf 'HEAD           %s on %s\n' "$(git rev-parse --short=9 HEAD)" "$CUR_BRANCH"
printf '%s/%s    %s\n' "$REMOTE" "$BRANCH" "$(git rev-parse --short=9 "refs/remotes/${REMOTE}/${BRANCH}")"
printf 'ahead/behind   %s/%s\n' "$AHEAD" "$BEHIND"
printf 'working tree   %s\n' "$([ "$DIRTY" -eq 0 ] && echo clean || echo "$DIRTY file(s) modified")"
printf 'version bump   %s\n' "${BUMP_SHA:-no \"bump version to ${VERSION}\" commit on ${REMOTE}/${BRANCH}}"
printf 'tags on %s %s=%s  %s=%s\n' "$REMOTE" "$TAG" "$PROD_TAG_REMOTE" "$STAGE_TAG" "$STAGE_TAG_REMOTE"
printf 'on registry    %s\n' "$REGISTRY_VERSION"

REASON=""
if [ "$CUR_BRANCH" != "$BRANCH" ]; then
  REASON="HEAD is on '$CUR_BRANCH', not '$BRANCH' - check out $BRANCH before staging"
elif [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
  REASON="HEAD and ${REMOTE}/${BRANCH} differ (ahead $AHEAD, behind $BEHIND) - the stage job builds ${REMOTE}/${BRANCH}, so push or pull first"
elif [ "$PROD_TAG_REMOTE" = "yes" ]; then
  REASON="$TAG already exists on $REMOTE - $VERSION looks released already; bump the version first"
elif [ "$REGISTRY_VERSION" = "$VERSION" ]; then
  REASON="${PKG}@${VERSION} is already live on the registry - bump the version first"
fi

if [ -n "$REASON" ]; then
  printf '\nNOT READY: %s\n' "$REASON"
  printf 'check-release-ready: %s\n' "$REASON" >&2
  exit 1
fi

printf '\nREADY: %s is on %s/%s, has no prod tag and is not on the registry.\n' "$VERSION" "$REMOTE" "$BRANCH"
