#!/usr/bin/env bats
#
# Root-to-mirror parity invariant for hooks/ (E89_S06_T04).
#
# Why this file exists
# --------------------
# `hooks/` at the repo root is canonical; `.claude/hooks/` and `.agents/hooks/` are generated
# mirrors. The harness reads the MIRRORS, so a hook that exists only in the root tree does nothing
# at all — it is not merely stale, it never runs.
#
# Before this file, no suite asserted parity for `hooks/` in any form. The consequence was measured,
# not hypothesised. Within one epic, two files were added at the root and not mirrored:
#
#   * a new SKILL.md         — tripped tests/skill-allow-list-bijection.bats loudly (that suite walks
#                              skill DIRECTORIES) and was fixed within the hour.
#   * a new hook             — went missing from BOTH mirror trees with every suite green: 135/135 on
#                              the suites written for it, 6/6 on the bijection check. Nothing looked.
#
# Same class of defect, opposite outcome, and the only difference was coverage. This file closes the
# `hooks/` half of that gap.
#
# Relationship to `j.self-sync` — this is an INVARIANT CHECK, NOT A REPLACEMENT FOR THE SYNC
# ------------------------------------------------------------------------------------------
# `j.self-sync` is the mechanism that mirrors the root framework trees (`bin/`, `lib/`, `scripts/`,
# `agents/`, `hooks/`, `mcp/`, `skills/`, `templates/`, `settings.json`) into `.claude/` and
# `.agents/`. This suite does none of that. It performs no copy, writes nothing into either mirror,
# and is read-only with respect to the repository: it only reports that a divergence exists.
#
# The division of labour is deliberate:
#
#   * `j.self-sync` ESTABLISHES parity. Run it to fix a failure reported here.
#   * this suite DETECTS a lapse in parity — most usefully a root-tree commit that landed without a
#     following sync, which is exactly how the missing hook above happened.
#
# So a red test here is never "the test is wrong, go edit the mirror". The canonical direction is
# root -> mirror, always; `.claude/` and `.agents/` are generated outputs and are never a source.
# The remedy for a failure is to run the sync (or copy root -> mirror by hand and commit it), never
# to propagate a mirror's content back into `hooks/`.
#
# This suite's scope is also narrower than the sync's on purpose: it covers `hooks/` only. The full
# `j.self-sync` pass across every tree in the copy set is owned elsewhere (E89_S05's sync task) and
# this file does not substitute for it. A green run here says nothing whatsoever about `skills/`,
# `scripts/`, `templates/` or `settings.json`.
#
# Why executable bits are compared, not only content
# --------------------------------------------------
# A hook whose `+x` bit was lost is as broken as one that is absent, and the failure is silent — the
# file is present, its content is correct, and it simply never executes. Content-only parity (the
# approach tests/commit-test-gate-mirror.bats takes for skills, where modes are irrelevant) would
# stay green through it.
#
# That is not a theoretical drift path. `lib/mirror.js` copies with `fs.copyFileSync`, which adopts
# the source's mode only when it CREATES the destination. When the destination already exists it
# truncates and writes in place, leaving the destination's existing mode untouched. A mode that
# diverges once therefore survives every subsequent sync.
#
# Two mode axes are checked, because they can disagree:
#
#   * the ON-DISK executable bit (`test -x`) — what actually decides whether the harness can run it.
#   * the GIT INDEX mode (`git ls-files -s`, 100644 vs 100755) — what propagates to a fresh clone and
#     into the published package. A bit fixed only on disk and never staged is lost for everyone else.
#
# Portability note: the on-disk check uses `test -x` rather than `stat`, whose mode format differs
# between BSD and GNU, and rather than a full numeric mode, which would make the suite sensitive to
# umask-driven group/other differences that carry no meaning here. Git records exactly one
# permission distinction (755 vs 644), and that is the one that matters.
#
# Why the detector is also proven against a synthetic tree
# --------------------------------------------------------
# A parity suite that has never been observed failing is not known to work — the inert-assertion
# episode in this repo's history (37 assertions that "passed" while asserting nothing) is the
# standing reminder. The cases below therefore run the same detector functions used against the real
# repo over purpose-built fixtures, so each is shown to discriminate rather than to pass vacuously.
# The fixtures live in $BATS_TEST_TMPDIR; the real tree is never damaged.
#
# All three detectors are covered, and the coverage is deliberately exhaustive over their failure
# modes: absent file, content drift, exec bit lost, exec bit spuriously gained, mirror orphan, index
# mode differing, mirror path untracked in the index, plus clean-tree cases and two
# "fails rather than passing vacuously" cases (an empty root walk, an untracked root path).
#
# `assert_index_modes_match` gets a scratch `git init` repo rather than a plain directory, because
# the axis it guards lives in the index and nowhere else. Its drift case stages a mode change with
# `git update-index --chmod=-x` while leaving the file executable ON DISK, then asserts that
# `assert_tree_mirrored` stays GREEN on that same tree — which is the direct proof that the two mode
# axes are independent and that both are load-bearing.

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
MIRRORS=".claude .agents"

# -----------------------------------------------------------------------------
# Detector: forward direction (root -> mirror)
#
# assert_tree_mirrored <root-dir> <mirror-dir>
#
# For every file under <root-dir>, require a counterpart under <mirror-dir> that is present,
# byte-identical, and equal on the executable bit. Prints the first finding to stderr and returns 1.
# Returns 1 also when <root-dir> yields no files at all, so an empty walk can never pass vacuously.
# -----------------------------------------------------------------------------
assert_tree_mirrored() {
  local root="$1" mirror="$2" file count=0

  if [ ! -d "$root" ]; then
    echo "root tree does not exist: $root" >&2
    return 1
  fi

  for file in $(cd "$root" && find . -type f | sed 's|^\./||' | sort); do
    count=$((count + 1))

    if [ ! -f "$mirror/$file" ]; then
      echo "MISSING FROM MIRROR: $mirror/$file (present at root: $root/$file)" >&2
      return 1
    fi

    if ! cmp -s "$root/$file" "$mirror/$file"; then
      echo "CONTENT DIFFERS FROM ROOT: $mirror/$file" >&2
      return 1
    fi

    if [ -x "$root/$file" ] && [ ! -x "$mirror/$file" ]; then
      echo "EXECUTABLE BIT LOST IN MIRROR: $mirror/$file (root $root/$file is executable)" >&2
      return 1
    fi

    if [ ! -x "$root/$file" ] && [ -x "$mirror/$file" ]; then
      echo "EXECUTABLE BIT ADDED IN MIRROR: $mirror/$file (root $root/$file is not executable)" >&2
      return 1
    fi
  done

  if [ "$count" -eq 0 ]; then
    echo "root tree yielded no files, so nothing was actually compared: $root" >&2
    return 1
  fi

  return 0
}

# -----------------------------------------------------------------------------
# Detector: reverse direction (mirror -> root)
#
# assert_no_mirror_orphans <root-dir> <mirror-dir>
#
# Require that every file under <mirror-dir> has a counterpart under <root-dir>. A mirror file with
# no root counterpart is either a leftover from a deleted root file or an edit made directly in a
# generated tree — both are drift, and neither is caught by the forward walk.
# -----------------------------------------------------------------------------
assert_no_mirror_orphans() {
  local root="$1" mirror="$2" file

  if [ ! -d "$mirror" ]; then
    return 0
  fi

  for file in $(cd "$mirror" && find . -type f | sed 's|^\./||' | sort); do
    if [ ! -f "$root/$file" ]; then
      echo "ORPHANED IN MIRROR: $mirror/$file has no counterpart at root ($root/$file)" >&2
      return 1
    fi
  done

  return 0
}

# -----------------------------------------------------------------------------
# Detector: git index modes
#
# assert_index_modes_match <repo-root> <root-rel> <mirror-rel>
#
# Compare the mode git RECORDS for each tracked file (100644 vs 100755) between the two trees, by
# relative path. Catches a bit that is correct on the working copy but never staged — invisible to a
# fresh clone and to the published package.
#
# <repo-root> is a parameter rather than a closed-over $REPO_ROOT so this detector can be exercised
# against a scratch git repository in $BATS_TEST_TMPDIR, the same way the other two are exercised
# against fixture trees. Before that, this was the one detector with no fixture case: neutering it to
# `return 0` turned nothing red, because there was nothing to turn.
# -----------------------------------------------------------------------------
assert_index_modes_match() {
  local repo="$1" root_rel="$2" mirror_rel="$3" rel root_mode mirror_mode

  # Build "relpath mode" for the mirror tree, then look each root file up in it.
  local mirror_list root_list
  mirror_list="$(cd "$repo" && git ls-files -s -- "$mirror_rel" |
    awk -v pre="$mirror_rel/" '{ sub("^" pre, "", $4); print $4, $1 }' | sort)"
  root_list="$(cd "$repo" && git ls-files -s -- "$root_rel" |
    awk -v pre="$root_rel/" '{ sub("^" pre, "", $4); print $4, $1 }' | sort)"

  if [ -z "$root_list" ]; then
    echo "git tracks no files under $root_rel, so no index mode was actually compared" >&2
    return 1
  fi

  while read -r rel root_mode; do
    [ -n "$rel" ] || continue
    mirror_mode="$(printf '%s\n' "$mirror_list" | awk -v r="$rel" '$1 == r { print $2 }')"
    if [ -z "$mirror_mode" ]; then
      echo "NOT TRACKED IN MIRROR INDEX: $mirror_rel/$rel (root $root_rel/$rel is $root_mode)" >&2
      return 1
    fi
    if [ "$root_mode" != "$mirror_mode" ]; then
      echo "INDEX MODE DIFFERS: $mirror_rel/$rel is $mirror_mode, root $root_rel/$rel is $root_mode" >&2
      return 1
    fi
  done <<EOF
$root_list
EOF

  return 0
}

# =============================================================================
# The real invariant, against this repository
#
# Note the absent-mirror guard shape: `continue`, NOT `skip`, with a counter and a single `skip`
# after the loop when NO mirror was examined. `skip` aborts the whole test rather than the current
# iteration, and `.claude` is iterated first — so a per-iteration `skip` would mean that with
# `.claude/hooks` absent, `.agents/hooks` was never examined at all and a genuine defect in the
# mirror that IS present got reported as SKIP rather than as a failure. Measured, in a scratch repo
# where `.claude/hooks` was removed and `.agents/hooks/a.sh` additionally deleted so the surviving
# mirror held a real catchable defect: all three cases reported SKIP. Fail-open, and precisely the
# class of silent miss this suite exists to prevent. The packed-copy behaviour the guard exists for
# (the npm tarball ships no mirrors, so neither tree is present) is preserved by the post-loop skip.
# =============================================================================

@test "every file under hooks/ is present in .claude/hooks/ and .agents/hooks/, byte-identical, with the same executable bit" {
  local mirror checked=0
  [ -d "$REPO_ROOT/hooks" ]
  for mirror in $MIRRORS; do
    if [ ! -d "$REPO_ROOT/$mirror/hooks" ]; then
      continue
    fi
    checked=$((checked + 1))
    run -0 assert_tree_mirrored "$REPO_ROOT/hooks" "$REPO_ROOT/$mirror/hooks"
  done
  if [ "$checked" -eq 0 ]; then
    skip "neither .claude/hooks nor .agents/hooks exists in this checkout (packed or installed copy)"
  fi
}

@test "no file in .claude/hooks/ or .agents/hooks/ lacks a root hooks/ counterpart" {
  local mirror checked=0
  [ -d "$REPO_ROOT/hooks" ]
  for mirror in $MIRRORS; do
    if [ ! -d "$REPO_ROOT/$mirror/hooks" ]; then
      continue
    fi
    checked=$((checked + 1))
    run -0 assert_no_mirror_orphans "$REPO_ROOT/hooks" "$REPO_ROOT/$mirror/hooks"
  done
  if [ "$checked" -eq 0 ]; then
    skip "neither .claude/hooks nor .agents/hooks exists in this checkout (packed or installed copy)"
  fi
}

@test "git records the same mode for every hooks/ file in both mirrors as at the root" {
  local mirror checked=0
  if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    skip "not a git checkout, so index modes cannot be compared"
  fi
  for mirror in $MIRRORS; do
    if [ ! -d "$REPO_ROOT/$mirror/hooks" ]; then
      continue
    fi
    checked=$((checked + 1))
    run -0 assert_index_modes_match "$REPO_ROOT" "hooks" "$mirror/hooks"
  done
  if [ "$checked" -eq 0 ]; then
    skip "neither .claude/hooks nor .agents/hooks exists in this checkout (packed or installed copy)"
  fi
}

# =============================================================================
# The detectors themselves, against synthetic fixture trees
#
# These prove the suite above discriminates. Without them, all three cases could be passing because
# they compare nothing.
# =============================================================================

# Builds a clean root/mirror pair under $BATS_TEST_TMPDIR:
#   root/alpha.sh   executable, "alpha"
#   root/beta.js    non-executable, "beta"
#   mirror/         identical
make_fixture() {
  FIX_ROOT="$BATS_TEST_TMPDIR/fixture/root"
  FIX_MIRROR="$BATS_TEST_TMPDIR/fixture/mirror"
  mkdir -p "$FIX_ROOT" "$FIX_MIRROR"

  printf 'alpha\n' > "$FIX_ROOT/alpha.sh"
  printf 'beta\n' > "$FIX_ROOT/beta.js"
  chmod 755 "$FIX_ROOT/alpha.sh"
  chmod 644 "$FIX_ROOT/beta.js"

  printf 'alpha\n' > "$FIX_MIRROR/alpha.sh"
  printf 'beta\n' > "$FIX_MIRROR/beta.js"
  chmod 755 "$FIX_MIRROR/alpha.sh"
  chmod 644 "$FIX_MIRROR/beta.js"
}

@test "detector: a clean fixture tree passes both directions" {
  make_fixture
  run -0 assert_tree_mirrored "$FIX_ROOT" "$FIX_MIRROR"
  run -0 assert_no_mirror_orphans "$FIX_ROOT" "$FIX_MIRROR"
}

@test "detector: a root file absent from the mirror is caught" {
  make_fixture
  rm "$FIX_MIRROR/alpha.sh"
  run -1 assert_tree_mirrored "$FIX_ROOT" "$FIX_MIRROR"
  [[ "$output" == *"MISSING FROM MIRROR"* ]]
  [[ "$output" == *"alpha.sh"* ]]
}

@test "detector: a mirror file whose content drifted from the root is caught" {
  make_fixture
  printf 'alpha but edited in the mirror\n' > "$FIX_MIRROR/alpha.sh"
  run -1 assert_tree_mirrored "$FIX_ROOT" "$FIX_MIRROR"
  [[ "$output" == *"CONTENT DIFFERS FROM ROOT"* ]]
}

@test "detector: a mirror file that lost the root's executable bit is caught even though its content matches" {
  make_fixture
  chmod 644 "$FIX_MIRROR/alpha.sh"
  # Content parity alone would still be green here -- that is the whole point of this case.
  cmp -s "$FIX_ROOT/alpha.sh" "$FIX_MIRROR/alpha.sh"
  run -1 assert_tree_mirrored "$FIX_ROOT" "$FIX_MIRROR"
  [[ "$output" == *"EXECUTABLE BIT LOST IN MIRROR"* ]]
}

@test "detector: a mirror file that gained an executable bit the root does not have is caught" {
  make_fixture
  chmod 755 "$FIX_MIRROR/beta.js"
  run -1 assert_tree_mirrored "$FIX_ROOT" "$FIX_MIRROR"
  [[ "$output" == *"EXECUTABLE BIT ADDED IN MIRROR"* ]]
}

@test "detector: the reverse case -- a mirror file with no root counterpart -- is caught" {
  make_fixture
  printf 'only in the mirror\n' > "$FIX_MIRROR/gamma.sh"
  # The forward walk cannot see this: every root file is still mirrored correctly.
  run -0 assert_tree_mirrored "$FIX_ROOT" "$FIX_MIRROR"
  run -1 assert_no_mirror_orphans "$FIX_ROOT" "$FIX_MIRROR"
  [[ "$output" == *"ORPHANED IN MIRROR"* ]]
  [[ "$output" == *"gamma.sh"* ]]
}

@test "detector: an empty root tree fails rather than passing vacuously" {
  mkdir -p "$BATS_TEST_TMPDIR/empty/root" "$BATS_TEST_TMPDIR/empty/mirror"
  run -1 assert_tree_mirrored "$BATS_TEST_TMPDIR/empty/root" "$BATS_TEST_TMPDIR/empty/mirror"
  [[ "$output" == *"yielded no files"* ]]
}

# -----------------------------------------------------------------------------
# The git-index detector, against a scratch repository
#
# `assert_index_modes_match` was the only detector with no fixture case. Its sole exercise was
# real-repo case 3, which passes -- so neutering it to `return 0` turned nothing red, and the
# suite's own non-vacuity argument did not actually extend to the axis that decides what a fresh
# clone and the published package receive. These cases close that asymmetry.
#
# No commit is needed: `git update-index --chmod` writes the index and `git ls-files -s` reads it,
# so `git init` plus `git add` is sufficient and no user identity is required.
# -----------------------------------------------------------------------------

# Builds a scratch git repo under $BATS_TEST_TMPDIR with hooks/a.sh (755) mirrored into
# .claude/hooks/a.sh (755), both staged. Sets $IDX_REPO.
make_index_fixture() {
  IDX_REPO="$BATS_TEST_TMPDIR/idxrepo"
  mkdir -p "$IDX_REPO/hooks" "$IDX_REPO/.claude/hooks"
  printf 'alpha\n' > "$IDX_REPO/hooks/a.sh"
  printf 'alpha\n' > "$IDX_REPO/.claude/hooks/a.sh"
  chmod 755 "$IDX_REPO/hooks/a.sh" "$IDX_REPO/.claude/hooks/a.sh"
  git -C "$IDX_REPO" init -q
  git -C "$IDX_REPO" add hooks .claude
}

@test "detector: matching index modes in a scratch repo pass" {
  make_index_fixture
  run -0 assert_index_modes_match "$IDX_REPO" "hooks" ".claude/hooks"
}

@test "detector: an index mode that differs from the root is caught even though the working tree agrees" {
  make_index_fixture
  # Stage the mirror as non-executable while leaving the FILE on disk executable. This is the drift
  # a `test -x` check cannot see and a fresh clone would inherit.
  git -C "$IDX_REPO" update-index --chmod=-x .claude/hooks/a.sh
  [ -x "$IDX_REPO/.claude/hooks/a.sh" ]
  run -1 assert_index_modes_match "$IDX_REPO" "hooks" ".claude/hooks"
  [[ "$output" == *"INDEX MODE DIFFERS"* ]]
  [[ "$output" == *"100644"* ]]
  # The on-disk detector stays green on the very same tree -- the two axes are independent.
  run -0 assert_tree_mirrored "$IDX_REPO/hooks" "$IDX_REPO/.claude/hooks"
}

@test "detector: a root file git does not track in the mirror index is caught" {
  make_index_fixture
  git -C "$IDX_REPO" rm -q --cached .claude/hooks/a.sh
  run -1 assert_index_modes_match "$IDX_REPO" "hooks" ".claude/hooks"
  [[ "$output" == *"NOT TRACKED IN MIRROR INDEX"* ]]
}

@test "detector: an untracked root path fails rather than passing vacuously" {
  make_index_fixture
  run -1 assert_index_modes_match "$IDX_REPO" "no-such-dir" ".claude/hooks"
  [[ "$output" == *"no index mode was actually compared"* ]]
}
