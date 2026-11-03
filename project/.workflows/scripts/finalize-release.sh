#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# finalize-release.sh - last step of the `deploy-stage` workflow: once the version is
# live on the registry, record it in git the way this project's release protocol does.
#
# The protocol is taken from the `publish` job of .github/workflows/npm-publish.yml,
# which is what does this when a release goes out through `/publish deploy`:
#   tag v<version>, push the tag, then delete v<version>-stage locally and on origin.
# A release promoted with `npm stage approve` never runs that job, so these steps are
# this script's job instead. It also pushes the current branch, so the release-notes
# and ledger commits made by the preceding steps reach origin.
#
# It REFUSES to tag anything until the registry actually serves the version, so a
# declined or failed approval cannot leave a tag claiming a release that never happened.
#
# Usage: finalize-release.sh [--dry-run] [<remote>] [<branch>]   (defaults: origin main)
#
# Exit: 0 done (the summary is on stdout); 1 the version is not live on the registry,
# or a git step failed; 2 setup error.
# ---------------------------------------------------------------------------
set -uo pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi
REMOTE="${1:-origin}"
BRANCH="${2:-main}"

die() { printf 'finalize-release: %s\n' "$1" >&2; exit "${2:-2}"; }
note() { printf 'finalize-release: %s\n' "$1" >&2; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    note "dry-run, would run: $*"
    return 0
  fi
  "$@"
}

command -v git >/dev/null 2>&1 || die "git not installed"
command -v node >/dev/null 2>&1 || die "node not installed"
command -v npm >/dev/null 2>&1 || die "npm not installed"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git work tree"
cd "$ROOT" || die "cannot cd to the repo root"
[ -f package.json ] || die "no package.json at $ROOT"

VERSION="$(node -p "require('./package.json').version" 2>/dev/null)" || die "cannot read the version from package.json"
PKG="$(node -p "require('./package.json').name" 2>/dev/null)" || die "cannot read the name from package.json"
TAG="v${VERSION}"
STAGE_TAG="v${VERSION}-stage"

# --- the gate: the registry must already serve this version ----------------------
LIVE="$(npm view "${PKG}@${VERSION}" version 2>/dev/null)" || LIVE=""
if [ "$LIVE" != "$VERSION" ]; then
  printf 'NOT FINALIZED: %s@%s is not on the registry yet (npm view returned "%s").\n' "$PKG" "$VERSION" "${LIVE:-nothing}"
  printf 'Nothing was tagged or pushed. If the approval is still in flight, wait and run this step again;\n'
  printf 'if the approval was declined or failed, the stage is still unapproved and there is nothing to tag.\n'
  die "${PKG}@${VERSION} is not live on the registry - refusing to tag" 1
fi
note "${PKG}@${VERSION} is live on the registry"

OUTPUT=""
out() { OUTPUT="${OUTPUT}$1
"; }

out "package        ${PKG}@${VERSION} (live on the registry)"
out "repo           $ROOT"
[ "$DRY_RUN" -eq 1 ] && out "mode           DRY RUN - nothing below was actually done"

# --- tag v<version> at HEAD -------------------------------------------------------
HEAD_SHA="$(git rev-parse HEAD)"
if EXISTING="$(git rev-parse -q --verify "refs/tags/${TAG}" 2>/dev/null)" && [ -n "$EXISTING" ]; then
  if [ "$EXISTING" = "$HEAD_SHA" ]; then
    out "tag $TAG     already existed at HEAD ($(git rev-parse --short=9 HEAD))"
  else
    out "tag $TAG     already existed, but at $(git rev-parse --short=9 "$EXISTING") instead of HEAD $(git rev-parse --short=9 HEAD) - left untouched"
    note "existing $TAG does not point at HEAD; not moving it"
  fi
else
  if run git tag -a "$TAG" -m "Release ${VERSION}"; then
    out "tag $TAG     created at $(git rev-parse --short=9 HEAD)"
  else
    die "could not create the tag $TAG" 1
  fi
fi

# --- push the branch, then the tag ------------------------------------------------
AHEAD="$(git rev-list --count "refs/remotes/${REMOTE}/${BRANCH}..HEAD" 2>/dev/null || echo 0)"
if [ "$AHEAD" != "0" ]; then
  if run git push "$REMOTE" "HEAD:refs/heads/${BRANCH}"; then
    out "branch         pushed $AHEAD commit(s) to ${REMOTE}/${BRANCH}"
  else
    out "branch         FAILED to push to ${REMOTE}/${BRANCH} - push it by hand"
    note "git push $REMOTE HEAD:refs/heads/$BRANCH failed"
  fi
else
  out "branch         ${REMOTE}/${BRANCH} already has every local commit"
fi

if run git push "$REMOTE" "refs/tags/${TAG}"; then
  out "tag push       ${TAG} -> ${REMOTE}"
else
  out "tag push       FAILED for ${TAG} - push it by hand (git push ${REMOTE} refs/tags/${TAG})"
  note "git push $REMOTE refs/tags/$TAG failed"
fi

# --- drop the stage tag, locally and on the remote --------------------------------
if git rev-parse -q --verify "refs/tags/${STAGE_TAG}" >/dev/null 2>&1; then
  if run git tag -d "$STAGE_TAG" >/dev/null; then
    out "stage tag      deleted locally ($STAGE_TAG)"
  else
    out "stage tag      could not be deleted locally ($STAGE_TAG)"
  fi
else
  out "stage tag      no local $STAGE_TAG"
fi

if git ls-remote --tags --exit-code "$REMOTE" "refs/tags/${STAGE_TAG}" >/dev/null 2>&1; then
  if run git push "$REMOTE" ":refs/tags/${STAGE_TAG}"; then
    out "stage tag      deleted on ${REMOTE} ($STAGE_TAG)"
  else
    out "stage tag      could not be deleted on ${REMOTE} ($STAGE_TAG) - delete it by hand"
  fi
else
  out "stage tag      no $STAGE_TAG on ${REMOTE}"
fi

DIRTY="$(git status --porcelain | wc -l | tr -d ' ')"
if [ "$DIRTY" -ne 0 ]; then
  out ""
  out "NOTE           $DIRTY file(s) are still uncommitted (ledger or changelog writes from the steps above?) - commit and push them separately."
fi

printf '%s' "$OUTPUT"
printf '\nRELEASED: %s@%s is live, tagged %s on %s.\n' "$PKG" "$VERSION" "$TAG" "$REMOTE"
