#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# skills/j-cloud-connect/scripts/install-rclone.sh
#
# Detects whether `rclone` is already on PATH and, if not, installs it
# automatically for the current OS:
#   - macOS: via `brew install rclone` (requires Homebrew already installed)
#   - Linux: via rclone's official install script
#     (`curl https://rclone.org/install.sh | sudo bash`)
#
# This is standalone install-detection/automation ONLY (E60_S01_T01's scope).
# It does NOT configure any remote and does NOT run any auth flow — that is
# E60_S01_T02's scope, layered on top of this script later.
#
# Every failure path (unsupported OS, no package manager, sudo unavailable,
# network failure) exits non-zero with an actionable message. Success is
# NEVER reported without re-verifying, post-install, that `rclone` is both on
# PATH and actually runnable (`rclone version` succeeds) — this script never
# takes a package manager's reported success at face value.
#
# Invoked via `bash`, not executed directly: this script intentionally ships
# without the executable bit, matching the same convention documented in
# skills/j-dashboard/scripts/resolve-app-dir.sh's header — a shipped script
# losing its executable bit (e.g. during packaging/distribution) is exactly
# the class of failure this avoids by never depending on it in the first
# place. Whatever wires this into the j-cloud-connect skill (E60_S01_T03)
# should invoke it as `bash skills/j-cloud-connect/scripts/install-rclone.sh`.
#
# Usage:
#   install-rclone.sh
#
# Exit codes:
#   0  rclone is on PATH and runnable (already present, or freshly installed
#      and re-verified).
#   1  Installation could not proceed or could not be verified afterward.
#      A human-readable reason is always printed to stderr.
# -----------------------------------------------------------------------------

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install-rclone.sh

Detects whether `rclone` is on PATH. If missing, installs it automatically:
  - macOS: `brew install rclone` (requires Homebrew)
  - Linux: rclone's official install script (requires curl + sudo)

Exits 0 only once `rclone` is confirmed on PATH and runnable. Exits 1 with an
actionable message on every failure path (unsupported OS, no package manager,
sudo/curl unavailable, network failure, or post-install re-verification
failure).
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage >&2; die "unknown argument: $1" ;;
esac

# -----------------------------------------------------------------------------
# Step 1 — Detection: skip installation entirely if rclone is already present.
# -----------------------------------------------------------------------------

if command -v rclone >/dev/null 2>&1; then
  RCLONE_PATH="$(command -v rclone)"
  RCLONE_VERSION="$(rclone version 2>/dev/null | head -n 1 || echo "unknown version")"
  echo "rclone is already installed at $RCLONE_PATH ($RCLONE_VERSION) — skipping install."
  exit 0
fi

echo "rclone not found on PATH. Attempting automatic install..."

# -----------------------------------------------------------------------------
# Step 2 — Post-install re-verification (defined up front, used by both OS
# branches below). Never report success without this check actually passing.
# -----------------------------------------------------------------------------

verify_install() {
  if ! command -v rclone >/dev/null 2>&1; then
    die "install step ran but 'rclone' is still not on PATH. Installation did not succeed — see output above for details."
  fi

  local rclone_bin
  rclone_bin="$(command -v rclone)"

  if ! rclone version >/dev/null 2>&1; then
    die "'rclone' was found on PATH at $rclone_bin after install, but 'rclone version' failed to run. The binary is present but not usable — installation did not succeed."
  fi

  local rclone_version
  rclone_version="$(rclone version 2>/dev/null | head -n 1 || echo "unknown version")"
  echo "rclone installed and verified successfully: $rclone_bin ($rclone_version)"
}

# -----------------------------------------------------------------------------
# Step 3 — OS detection and OS-specific install.
# -----------------------------------------------------------------------------

OS_NAME="$(uname -s)"

case "$OS_NAME" in
  Darwin)
    if ! command -v brew >/dev/null 2>&1; then
      die "rclone is not installed and Homebrew ('brew') is not available on this macOS machine, so it cannot be installed automatically. Install Homebrew (https://brew.sh) and re-run, or install rclone manually from https://rclone.org/downloads/."
    fi

    echo "Installing rclone via Homebrew ('brew install rclone')..."
    if ! brew install rclone; then
      die "'brew install rclone' failed. This is commonly a network failure or a Homebrew environment issue — check the output above, then re-run. You can also install rclone manually from https://rclone.org/downloads/."
    fi
    ;;

  Linux)
    if ! command -v curl >/dev/null 2>&1; then
      die "rclone is not installed and 'curl' is not available on this Linux machine, so the official install script cannot be downloaded. Install curl (e.g. 'apt install curl' / 'yum install curl') and re-run, or install rclone manually from https://rclone.org/downloads/."
    fi
    if ! command -v sudo >/dev/null 2>&1; then
      die "rclone is not installed and 'sudo' is not available on this Linux machine, but is required by rclone's official install script. Install rclone manually (as a privileged user) from https://rclone.org/downloads/, or make sudo available and re-run."
    fi

    echo "Installing rclone via the official install script (curl https://rclone.org/install.sh | sudo bash)..."

    INSTALL_SCRIPT_TMP="$(mktemp)"
    trap 'rm -f "$INSTALL_SCRIPT_TMP"' EXIT

    if ! curl --fail --silent --show-error https://rclone.org/install.sh -o "$INSTALL_SCRIPT_TMP"; then
      die "failed to download rclone's official install script from https://rclone.org/install.sh. This usually indicates no network access. Check your connection and re-run, or install rclone manually from https://rclone.org/downloads/."
    fi

    INSTALL_EXIT_CODE=0
    sudo bash "$INSTALL_SCRIPT_TMP" || INSTALL_EXIT_CODE=$?
    if [ "$INSTALL_EXIT_CODE" -ne 0 ]; then
      die "rclone's official install script downloaded successfully but failed to run (exit status $INSTALL_EXIT_CODE). This may indicate a sudo/permission issue or an unsupported Linux environment — check the output above. You can also install rclone manually from https://rclone.org/downloads/."
    fi
    ;;

  *)
    die "unsupported OS '$OS_NAME' — this script only automates rclone install on macOS (via brew) and Linux (via rclone's official install script). Install rclone manually from https://rclone.org/downloads/."
    ;;
esac

# -----------------------------------------------------------------------------
# Step 4 — Re-verify before ever reporting success.
# -----------------------------------------------------------------------------

verify_install
