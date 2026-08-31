#!/usr/bin/env bash
# npm_stage_inspect.sh — `/publish stage`: list/view/download a staged npm
# release, run the pre-approval smoke test, and approve or reject it.
#
# This script is the story's core value: staging without testing just
# relocates the risk. `test` installs the exact staged tarball into an
# isolated scratch directory and smoke-tests it; `approve` refuses to run
# unless a passing test is on record for that exact stage id (or the
# operator explicitly overrides with a reason).
#
# Usage:
#   npm_stage_inspect.sh <sub> [args] [--config <path>] [--dry-run] [--json]
#
# Sub-commands:
#   list [<package-spec>]                    wraps `npm stage list`
#   view <stage-id>                          wraps `npm stage view`
#   download <stage-id> [--out <dir>]        wraps `npm stage download`
#   test <stage-id> [--keep]                 pre-approval smoke test (see below)
#   approve <stage-id> [--otp <otp>] [--force <reason>]
#                                             wraps `npm stage approve`, gated
#                                             by a test interlock
#   reject <stage-id>                        wraps `npm stage reject` — the
#                                             discard path for a staged
#                                             version. npm's own docs page
#                                             (https://docs.npmjs.com/staged-publishing)
#                                             omits this command entirely;
#                                             it is documented here so it is
#                                             discoverable.
#
# `test` — the pre-approval smoke test:
#   1. Download the staged tarball via `npm stage download <stage-id>`.
#   2. Create a scratch directory via `mktemp -d`, always OUTSIDE this
#      repository's working tree (asserted explicitly, in addition to
#      `mktemp` already guaranteeing it in any normal environment) — the
#      repo's own node_modules is never touched.
#   3. `npm init -y`, then `npm install <path-to-tarball>` in the scratch
#      dir — installing the tarball by path, never by registry spec, so the
#      artifact under test is exactly the staged bytes.
#   4. Run `npm.stage.smoke_cmd` from the matching target's config when set,
#      else the documented default (see `_default_smoke_check` below), which
#      verifies what `scripts/postinstall.js` actually does today: mirrors
#      `skills/` and `agents/` into BOTH `.claude/` and `.agents/` under the
#      consumer root, writes `.jenga-version`, and bootstraps
#      `.github/copilot-instructions.md`. It deliberately does NOT check for
#      `hooks/`, `scripts/`, or `templates/` landing in the project root —
#      commit 619198b already narrowed postinstall's copy set to `skills/`
#      and `agents/` only; those three dirs stay inside
#      `node_modules/@jenga-ai/agent/` and are sourced from there at
#      runtime. See project/documentation/plans/E22_S09_T03-plan.md for the
#      full write-up of this correction relative to an earlier, stale
#      description of postinstall's behavior.
#   5. Clean up the scratch directory on both success and failure, unless
#      `--keep` was passed.
#   6. Write a `stage_tested` ledger entry (stage id + pass/fail `--result`).
#
# Exit codes:
#   0  success (or --dry-run/--help completed cleanly)
#   3  the underlying `npm stage <sub>` command failed, the tarball install
#      failed, or the smoke test failed
#   4  usage error, unknown sub-command, or the `approve` test interlock
#      refused (no passing test on record and no `--force <reason>`)
#
# Security note: `approve --otp` uses the exact argv-prescan-before-parsing
# guard documented in npm_stage_pipeline.sh (E22_S09_T02) — command tracing
# is suspended before OTP is ever assigned to a variable, for the rest of the
# run, if argv contains --otp and tracing was already active. Captured
# output is additionally scrubbed of the literal OTP value before it is ever
# printed. The OTP is never written to the ledger, never printed, and never
# appears in --json output.

set -euo pipefail

EXIT_OK=0
EXIT_OP_FAILED=3
EXIT_USAGE=4

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null)"; then
  :
else
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
fi

# shellcheck source=publish_common.sh
source "${SCRIPT_DIR}/publish_common.sh"

WRITE_LEDGER_SCRIPT="${SCRIPT_DIR}/write_ledger_entry.sh"

# ---------------------------------------------------------------------------
# OTP tracing guard — MUST run at the top level, before `main "$@"` is ever
# called, and before any argv containing --otp is passed to a function.
#
# This script dispatches through main() -> cmd_approve() rather than being
# one flat top-level body (unlike npm_stage_pipeline.sh, E22_S09_T02, whose
# guard lives at its own top level with nothing to dispatch through). That
# dispatch is exactly why the guard cannot simply live inside cmd_approve as
# a narrower, subcommand-scoped check: when this script is invoked as
# `bash -x npm_stage_inspect.sh approve <id> --otp <value>`, bash's xtrace
# prints the *expanded arguments of each function-call site* —
# `+ main approve <id> ... --otp <value>` and, inside main's body,
# `+ cmd_approve <id> ... --otp <value>` — the moment each call is made,
# before that function's own body (and any guard living inside it) ever
# executes. Verified empirically: an OTP guard placed inside cmd_approve
# left both of those call-site trace lines carrying the literal OTP in
# `bash -x` output, even though the guard correctly redacted everything
# printed by the function bodies themselves. Suspending tracing here, before
# `main "$@"` is invoked at all, prevents both call-site trace lines from
# ever being emitted in the first place.
#
# A narrower window — e.g. suspending tracing only around the `npm stage
# approve` call itself — is NOT sufficient for the same reason documented in
# npm_stage_pipeline.sh: xtrace prints the *expanded* value of a variable
# for every subsequent line that references it. The only reliable guard is
# to suspend tracing before OTP is ever assigned to a variable (or passed
# into a traced function call) and never re-enable it for the rest of the
# run.
# ---------------------------------------------------------------------------
_OTP_PRESENT_IN_ARGV=0
for _otp_scan_arg in "$@"; do
  case "${_otp_scan_arg}" in
    --otp|--otp=*)
      _OTP_PRESENT_IN_ARGV=1
      ;;
  esac
done
unset _otp_scan_arg
if (( _OTP_PRESENT_IN_ARGV )); then
  case "$-" in
    *x*) set +x ;;
  esac
fi

usage() {
  cat <<'USAGE'
Usage: npm_stage_inspect.sh <sub> [args] [--config <path>] [--dry-run] [--json]

Sub-commands:
  list [<package-spec>]                    List staged versions (readable
                                            table by default; raw JSON under
                                            --json)
  view <stage-id>                          Show a staged version's details
  download <stage-id> [--out <dir>]        Download the staged tarball to
                                            <dir> (default: a fresh scratch
                                            directory, reported on success)
  test <stage-id> [--keep]                 Install the staged tarball into
                                            an isolated scratch directory
                                            outside the repo and smoke-test
                                            it; writes a stage_tested ledger
                                            entry. --keep retains the scratch
                                            dir for debugging.
  approve <stage-id> [--otp <otp>] [--force <reason>]
                                            Approve a staged version for
                                            release. Refuses without a
                                            passing `test` on record for this
                                            exact stage id, unless --force
                                            <reason> is given. --otp is
                                            passed through when supplied;
                                            npm prompts interactively
                                            otherwise.
  reject <stage-id>                        Discard a staged version — the
                                            discard path omitted from npm's
                                            own staged-publishing docs page.

Global flags (accepted by every sub-command):
  --config <path>   Path to publish.json (default: <repo-root>/publish.json,
                     then project/configs/publish.json)
  --dry-run         Print the resolved npm command(s)/steps instead of
                     running them; makes no registry-mutating call
  --json            Emit a machine-readable JSON summary instead of a
                     human-readable one (list/view pass through npm's own
                     --json output verbatim)
USAGE
}

fail_usage() {
  usage >&2
  printf 'npm stage inspect error: %s\n' "$1" >&2
  exit "${EXIT_USAGE}"
}

log_info() { printf '→ %s\n' "$1"; }
log_warn() { printf '⚠ %s\n' "$1" >&2; }

# ---------------------------------------------------------------------------
# Config resolution — mirrors validate_npm_stage_env.sh's search order.
# Returns non-zero (empty stdout) rather than failing the script outright:
# list/view/download/reject can all operate without a config at all, and
# test/approve fall back to documented defaults when unresolved.
# ---------------------------------------------------------------------------
resolve_config_path() {
  local explicit="$1"
  if [[ -n "${explicit}" ]]; then
    publish_normalize_path "${explicit}"
    return 0
  fi
  if [[ -f "${REPO_ROOT}/publish.json" ]]; then
    printf '%s\n' "${REPO_ROOT}/publish.json"
    return 0
  fi
  if [[ -f "${PUBLISH_DEFAULT_CONFIG_FILE}" ]]; then
    printf '%s\n' "${PUBLISH_DEFAULT_CONFIG_FILE}"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Stage metadata helpers — `npm stage view --json` output shape is an
# unverifiable-in-this-environment npm CLI surface (npm >= 11.15.0 is very
# new; no real binary or network access to npm's docs here), same caveat
# already documented for npm_stage_pipeline.sh's stage-id capture. Parsed
# defensively with fallback key names; a failed/empty view is tolerated
# everywhere it's used — callers fall back to documented defaults.
# ---------------------------------------------------------------------------
_stage_view_json() {
  npm stage view "$1" --json 2>/dev/null || true
}

_stage_view_field() {
  local view_json="$1"
  shift
  [[ -n "${view_json}" ]] || { printf ''; return; }
  printf '%s' "${view_json}" | jq -e . >/dev/null 2>&1 || { printf ''; return; }
  printf '%s' "${view_json}" | jq -r "$1" 2>/dev/null || true
}

_stage_package_name() {
  _stage_view_field "$1" '.name // .package // .packageName // empty'
}

_stage_package_version() {
  _stage_view_field "$1" '.version // empty'
}

# resolve_stage_target <package-name> <config-path>
# Prints four tab-separated fields: target_name target_type smoke_cmd
# require_test_before_approve. Falls back to "unknown"/"npm"/""/"true" when
# no config, no matching target, or no npm.stage block is found — test and
# approve must still work against an unconfigured target using documented
# defaults.
resolve_stage_target() {
  local package_name="$1" config_path="$2"
  local target_name="unknown" target_type="npm" smoke_cmd="" require_test="true"

  if [[ -n "${config_path}" && -f "${config_path}" ]] && command -v jq >/dev/null 2>&1; then
    local target_json=""
    if [[ -n "${package_name}" ]]; then
      target_json="$(jq -c --arg pkg "${package_name}" \
        '.targets[]? | select((.type == "npm" or .type == "npm-ci") and (.npm.package_name // "") == $pkg)' \
        "${config_path}" 2>/dev/null | head -n 1)"
    fi
    if [[ -z "${target_json}" ]]; then
      # No package-name match (or view failed) — fall back to the first
      # configured npm/npm-ci target that has a stage block, so the common
      # single-target setup still resolves.
      target_json="$(jq -c '.targets[]? | select((.type == "npm" or .type == "npm-ci") and (.npm.stage // null) != null)' \
        "${config_path}" 2>/dev/null | head -n 1)"
    fi
    if [[ -z "${target_json}" ]]; then
      target_json="$(jq -c '.targets[]? | select(.type == "npm" or .type == "npm-ci")' \
        "${config_path}" 2>/dev/null | head -n 1)"
    fi
    if [[ -n "${target_json}" ]]; then
      target_name="$(printf '%s' "${target_json}" | jq -r '.name // "unknown"')"
      target_type="$(printf '%s' "${target_json}" | jq -r '.type // "npm"')"
      smoke_cmd="$(printf '%s' "${target_json}" | jq -r '.npm.stage.smoke_cmd // empty')"
      require_test="$(printf '%s' "${target_json}" | jq -r '(.npm.stage.require_test_before_approve // true)')"
    fi
  fi

  # A plain tab is unsuitable as the field delimiter here: bash's `read`
  # treats tab as "IFS whitespace" regardless of what IFS is set to, which
  # collapses consecutive delimiters and silently drops empty fields (e.g.
  # an unset smoke_cmd) rather than preserving them as empty. The ASCII
  # Unit Separator (0x1F) is not treated specially and is never expected to
  # appear in any of these values.
  printf '%s\x1f%s\x1f%s\x1f%s\n' "${target_name}" "${target_type}" "${smoke_cmd}" "${require_test}"
}

# ---------------------------------------------------------------------------
# Tarball download — shared by `download` and `test`. Since the exact output
# shape/naming convention of `npm stage download` is unverifiable in this
# environment, this snapshots the destination directory's file listing
# before and after running the command (with cwd set to the destination, so
# wherever the tarball lands, it lands inside it) and diffs to find the new
# file — robust regardless of naming convention.
# ---------------------------------------------------------------------------
_download_stage_tarball() {
  local stage_id="$1" dest_dir="$2"
  mkdir -p "${dest_dir}"
  dest_dir="$(cd "${dest_dir}" && pwd)"

  local before after new_file=""
  before="$(find "${dest_dir}" -maxdepth 1 -type f 2>/dev/null | sort)"

  local output status=0
  output="$(cd "${dest_dir}" && npm stage download "${stage_id}" 2>&1)" || status=$?
  if [[ ${status} -ne 0 ]]; then
    printf '%s\n' "${output}" >&2
    printf 'npm stage inspect: npm stage download failed (exit %s).\n' "${status}" >&2
    return "${EXIT_OP_FAILED}"
  fi

  after="$(find "${dest_dir}" -maxdepth 1 -type f 2>/dev/null | sort)"
  new_file="$(comm -13 <(printf '%s\n' "${before}") <(printf '%s\n' "${after}") | head -n 1)"

  if [[ -z "${new_file}" ]]; then
    new_file="$(printf '%s\n' "${output}" | grep -Eo '[^[:space:]"'"'"']+\.tgz' | head -n 1)"
    if [[ -n "${new_file}" && "${new_file}" != /* ]]; then
      new_file="${dest_dir}/${new_file}"
    fi
  fi

  if [[ -z "${new_file}" || ! -f "${new_file}" ]]; then
    printf 'npm stage inspect: could not locate the downloaded tarball in %s after "npm stage download %s". npm output:\n%s\n' \
      "${dest_dir}" "${stage_id}" "${output}" >&2
    return "${EXIT_OP_FAILED}"
  fi

  printf '%s\n' "${new_file}"
}

# _installed_package_info <scratch-dir>
# Prints "<name>\x1f<version>" for the single dependency npm installed from
# the tarball into a fresh `npm init -y` scratch project — the ground-truth
# name/version actually installed (read from the scratch project's own
# package.json "dependencies" key, then the installed package's own
# package.json), independent of whatever `npm stage view` reports. Uses the
# ASCII Unit Separator (0x1F) as the field delimiter, not a tab — see the
# comment in resolve_stage_target for why a tab silently drops empty fields
# under bash's `read`.
_installed_package_info() {
  local scratch_dir="$1"
  local dep_name
  dep_name="$(jq -r '.dependencies // {} | keys[0] // empty' "${scratch_dir}/package.json" 2>/dev/null || true)"
  if [[ -z "${dep_name}" ]]; then
    printf '\x1f\n'
    return
  fi
  local pkg_json="${scratch_dir}/node_modules/${dep_name}/package.json"
  if [[ ! -f "${pkg_json}" ]]; then
    printf '%s\x1f\n' "${dep_name}"
    return
  fi
  local version
  version="$(jq -r '.version // empty' "${pkg_json}" 2>/dev/null || true)"
  printf '%s\x1f%s\n' "${dep_name}" "${version}"
}

# _default_smoke_check <scratch-dir>
# See the header comment for why this checks .claude/.agents mirroring
# rather than a project-root copy of hooks/scripts/templates.
_default_smoke_check() {
  local scratch_dir="$1"
  local -a missing=()
  local dir

  for dir in .claude/skills .claude/agents .agents/skills .agents/agents; do
    if [[ ! -d "${scratch_dir}/${dir}" ]] || [[ -z "$(ls -A "${scratch_dir}/${dir}" 2>/dev/null)" ]]; then
      missing+=("${dir}/ (missing or empty)")
    fi
  done

  [[ -f "${scratch_dir}/.jenga-version" ]] || missing+=(".jenga-version (not written)")
  [[ -f "${scratch_dir}/.github/copilot-instructions.md" ]] || missing+=(".github/copilot-instructions.md (not bootstrapped)")

  if (( ${#missing[@]} > 0 )); then
    printf 'default smoke check FAILED — postinstall did not produce the expected layout under %s:\n' "${scratch_dir}"
    printf '  - %s\n' "${missing[@]}"
    return 1
  fi

  printf 'default smoke check passed — postinstall populated .claude/{skills,agents}, .agents/{skills,agents}, .jenga-version, and .github/copilot-instructions.md under %s\n' "${scratch_dir}"
}

# _cleanup_scratch_dir <scratch-dir> <keep-flag>
# Invoked from an EXIT trap registered by cmd_test, with both arguments
# baked into the trap command string at registration time (see the comment
# at the trap registration site for why — dynamic-scope lookup of the
# calling function's `local`s does not survive `exit` unwinding the call
# stack before traps run).
_cleanup_scratch_dir() {
  local dir="$1" keep_flag="$2"
  if [[ "${keep_flag}" == "1" ]]; then
    log_warn "--keep set: leaving scratch dir at ${dir}"
    return
  fi
  rm -rf "${dir}"
}

_write_stage_tested_ledger() {
  local stage_id="$1" target_name="$2" target_type="$3" config_path="$4" result="$5" version="$6"
  local -a cmd=(bash "${WRITE_LEDGER_SCRIPT}" "${target_name}" "${target_type}" stage_tested "" --stage-id "${stage_id}" --result "${result}")
  [[ -n "${config_path}" ]] && cmd+=(--config "${config_path}")
  [[ -n "${version}" ]] && cmd+=(--version "${version}")
  "${cmd[@]}" || log_warn "failed to write 'stage_tested' ledger entry for stage ${stage_id} (result: ${result})"
}

# ---------------------------------------------------------------------------
# list [<package-spec>] [--config <path>] [--dry-run] [--json]
# ---------------------------------------------------------------------------
cmd_list() {
  local config_arg="" dry_run=0 json_out=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) [[ $# -ge 2 ]] || fail_usage "--config requires a value"; config_arg="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --json) json_out=1; shift ;;
      -h|--help) usage; exit "${EXIT_OK}" ;;
      -*) fail_usage "list: unknown flag: $1" ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [[ ${#positional[@]} -le 1 ]] || fail_usage "list: too many arguments"
  local package_spec="${positional[0]:-}"
  # config_arg is accepted for interface consistency across sub-commands;
  # `list` itself needs no config (npm stage list takes no target/config).
  : "${config_arg}"

  local -a cmd=(npm stage list)
  [[ -n "${package_spec}" ]] && cmd+=("${package_spec}")
  cmd+=(--json)

  if (( dry_run )); then
    log_info "[dry-run] resolved command: $(printf '%q ' "${cmd[@]}")"
    exit "${EXIT_OK}"
  fi

  local output status=0
  output="$("${cmd[@]}" 2>&1)" || status=$?
  if [[ ${status} -ne 0 ]]; then
    printf '%s\n' "${output}" >&2
    printf 'npm stage inspect: npm stage list failed (exit %s).\n' "${status}" >&2
    exit "${EXIT_OP_FAILED}"
  fi

  if (( json_out )); then
    printf '%s\n' "${output}"
    exit "${EXIT_OK}"
  fi

  if ! printf '%s' "${output}" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "${output}"
    exit "${EXIT_OK}"
  fi

  printf '%-24s %-30s %-10s %-10s %s\n' 'STAGE ID' 'PACKAGE' 'VERSION' 'DIST-TAG' 'STAGED AT'
  printf '%-24s %-30s %-10s %-10s %s\n' '--------' '-------' '-------' '--------' '---------'
  printf '%s' "${output}" | jq -r '
    ( if (type == "array") then . else (.stages? // .items? // []) end ) as $entries
    | $entries[]?
    | [ (.id // .stageId // .stage_id // "-"),
        (.name // .package // .packageName // "-"),
        (.version // "-"),
        (.tag // .distTag // .dist_tag // "-"),
        (.stagedAt // .staged_at // .created // .createdAt // "-") ]
    | @tsv
  ' | while IFS=$'\t' read -r sid pkg ver tag staged; do
    printf '%-24s %-30s %-10s %-10s %s\n' "${sid}" "${pkg}" "${ver}" "${tag}" "${staged}"
  done
}

# ---------------------------------------------------------------------------
# view <stage-id> [--config <path>] [--dry-run] [--json]
# ---------------------------------------------------------------------------
cmd_view() {
  local config_arg="" dry_run=0 json_out=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) [[ $# -ge 2 ]] || fail_usage "--config requires a value"; config_arg="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --json) json_out=1; shift ;;
      -h|--help) usage; exit "${EXIT_OK}" ;;
      -*) fail_usage "view: unknown flag: $1" ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [[ ${#positional[@]} -ge 1 ]] || fail_usage "view: <stage-id> is required"
  [[ ${#positional[@]} -le 1 ]] || fail_usage "view: too many arguments"
  local stage_id="${positional[0]}"
  : "${config_arg}"

  local -a cmd=(npm stage view "${stage_id}")
  (( json_out )) && cmd+=(--json)

  if (( dry_run )); then
    log_info "[dry-run] resolved command: $(printf '%q ' "${cmd[@]}")"
    exit "${EXIT_OK}"
  fi

  local output status=0
  output="$("${cmd[@]}" 2>&1)" || status=$?
  printf '%s\n' "${output}"
  if [[ ${status} -ne 0 ]]; then
    printf 'npm stage inspect: npm stage view failed (exit %s).\n' "${status}" >&2
    exit "${EXIT_OP_FAILED}"
  fi
}

# ---------------------------------------------------------------------------
# download <stage-id> [--out <dir>] [--config <path>] [--dry-run] [--json]
# ---------------------------------------------------------------------------
cmd_download() {
  local config_arg="" dry_run=0 json_out=0 out_dir=""
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) [[ $# -ge 2 ]] || fail_usage "--config requires a value"; config_arg="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --json) json_out=1; shift ;;
      --out) [[ $# -ge 2 ]] || fail_usage "--out requires a value"; out_dir="$2"; shift 2 ;;
      -h|--help) usage; exit "${EXIT_OK}" ;;
      -*) fail_usage "download: unknown flag: $1" ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [[ ${#positional[@]} -ge 1 ]] || fail_usage "download: <stage-id> is required"
  [[ ${#positional[@]} -le 1 ]] || fail_usage "download: too many arguments"
  local stage_id="${positional[0]}"
  : "${config_arg}"

  if (( dry_run )); then
    log_info "[dry-run] resolved command: npm stage download $(printf '%q' "${stage_id}") (cwd: ${out_dir:-<a fresh mktemp -d>})"
    exit "${EXIT_OK}"
  fi

  if [[ -z "${out_dir}" ]]; then
    out_dir="$(mktemp -d "${TMPDIR:-/tmp}/npm-stage-download.XXXXXX")"
  fi

  local tarball_path
  tarball_path="$(_download_stage_tarball "${stage_id}" "${out_dir}")" || exit "${EXIT_OP_FAILED}"

  if (( json_out )); then
    jq -cn --arg stage_id "${stage_id}" --arg path "${tarball_path}" '{stage_id: $stage_id, tarball_path: $path}'
  else
    printf 'Downloaded stage %s to %s\n' "${stage_id}" "${tarball_path}"
  fi
}

# ---------------------------------------------------------------------------
# test <stage-id> [--keep] [--config <path>] [--dry-run] [--json]
# ---------------------------------------------------------------------------
cmd_test() {
  local config_arg="" dry_run=0 json_out=0 keep=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) [[ $# -ge 2 ]] || fail_usage "--config requires a value"; config_arg="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --json) json_out=1; shift ;;
      --keep) keep=1; shift ;;
      -h|--help) usage; exit "${EXIT_OK}" ;;
      -*) fail_usage "test: unknown flag: $1" ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [[ ${#positional[@]} -ge 1 ]] || fail_usage "test: <stage-id> is required"
  [[ ${#positional[@]} -le 1 ]] || fail_usage "test: too many arguments"
  local stage_id="${positional[0]}"

  local config_path=""
  config_path="$(resolve_config_path "${config_arg}" || true)"

  local view_json package_name_hint
  view_json="$(_stage_view_json "${stage_id}")"
  package_name_hint="$(_stage_package_name "${view_json}")"

  local target_name target_type smoke_cmd require_test
  IFS=$'\x1f' read -r target_name target_type smoke_cmd require_test < <(resolve_stage_target "${package_name_hint}" "${config_path}")

  if (( dry_run )); then
    log_info "[dry-run] would: download stage ${stage_id}; npm init -y && npm install <tarball> in a mktemp -d scratch dir outside ${REPO_ROOT}; then run: ${smoke_cmd:-<documented default smoke check>}"
    exit "${EXIT_OK}"
  fi

  local scratch_dir
  scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/npm-stage-test.XXXXXX")"

  # Defense in depth: mktemp already guarantees a location outside the repo
  # working tree in any normal environment; assert it explicitly so a
  # misconfigured TMPDIR can never silently install into (or overwrite) the
  # repo's own node_modules.
  local scratch_real repo_real
  scratch_real="$(cd "${scratch_dir}" && pwd -P)"
  repo_real="$(cd "${REPO_ROOT}" && pwd -P)"
  case "${scratch_real}" in
    "${repo_real}"|"${repo_real}"/*)
      printf 'npm stage inspect: refusing to run — scratch dir %s resolved inside the repository (%s). Check TMPDIR.\n' "${scratch_real}" "${repo_real}" >&2
      rm -rf "${scratch_dir}"
      exit "${EXIT_OP_FAILED}"
      ;;
  esac

  # Register cleanup via a top-level function invoked with explicit
  # arguments baked into the trap command string at registration time —
  # NOT a closure referencing cmd_test's `local $scratch_dir`/`$keep`
  # directly. `exit` unwinds the function call stack (popping `local`
  # bindings) before running EXIT traps, so a trap body that reads those
  # names by dynamic scope sees them as unset once triggered; passing the
  # values as positional arguments sidesteps that entirely.
  # shellcheck disable=SC2064 # intentional: expand now, not at signal time
  trap "_cleanup_scratch_dir $(printf '%q' "${scratch_dir}") $(printf '%q' "${keep}")" EXIT

  log_info "[test] downloading stage ${stage_id}..."
  local tarball_path
  tarball_path="$(_download_stage_tarball "${stage_id}" "${scratch_dir}")" || exit "${EXIT_OP_FAILED}"

  log_info "[test] installing tarball into isolated scratch project at ${scratch_dir}..."
  local install_output install_status=0
  install_output="$(cd "${scratch_dir}" && npm init -y >/dev/null 2>&1 && npm install "${tarball_path}" 2>&1)" || install_status=$?
  if [[ ${install_status} -ne 0 ]]; then
    printf '%s\n' "${install_output}" >&2
    printf 'npm stage inspect: tarball install failed (exit %s).\n' "${install_status}" >&2
    _write_stage_tested_ledger "${stage_id}" "${target_name}" "${target_type}" "${config_path}" fail ""
    exit "${EXIT_OP_FAILED}"
  fi

  local installed_name installed_version
  IFS=$'\x1f' read -r installed_name installed_version < <(_installed_package_info "${scratch_dir}")
  [[ -n "${installed_version}" ]] || installed_version="$(_stage_package_version "${view_json}")"

  local smoke_status=0 smoke_output=""
  if [[ -n "${smoke_cmd}" ]]; then
    log_info "[test] running configured npm.stage.smoke_cmd: ${smoke_cmd}"
    smoke_output="$(cd "${scratch_dir}" && bash -c "${smoke_cmd}" 2>&1)" || smoke_status=$?
  else
    log_info "[test] running default smoke check (postinstall file-copy verification)..."
    smoke_output="$(_default_smoke_check "${scratch_dir}" 2>&1)" || smoke_status=$?
  fi

  if [[ ${smoke_status} -ne 0 ]]; then
    printf '%s\n' "${smoke_output}" >&2
    printf 'npm stage inspect: smoke test FAILED for stage %s (package %s).\n' "${stage_id}" "${installed_name:-unknown}" >&2
    _write_stage_tested_ledger "${stage_id}" "${target_name}" "${target_type}" "${config_path}" fail "${installed_version}"
    exit "${EXIT_OP_FAILED}"
  fi

  printf '%s\n' "${smoke_output}"
  log_info "[test] smoke test PASSED for stage ${stage_id} (package ${installed_name:-unknown})."
  _write_stage_tested_ledger "${stage_id}" "${target_name}" "${target_type}" "${config_path}" pass "${installed_version}"

  if (( json_out )); then
    jq -cn --arg stage_id "${stage_id}" --arg pkg "${installed_name:-}" --arg version "${installed_version:-}" \
      '{stage_id: $stage_id, package: $pkg, version: $version, result: "pass"}'
  fi
}

# ---------------------------------------------------------------------------
# approve <stage-id> [--otp <otp>] [--force <reason>] [--config <path>] [--dry-run] [--json]
# ---------------------------------------------------------------------------
cmd_approve() {
  # The OTP tracing guard runs once, at the top level of this script, before
  # `main "$@"` is ever called — see the comment there for why a guard
  # placed only here (inside cmd_approve) is provably insufficient: bash's
  # xtrace prints the expanded arguments of the `main "$@"` and
  # `cmd_approve "$@"` call sites themselves, before this function's body
  # ever runs.

  local config_arg="" dry_run=0 json_out=0 otp="" force_reason="" force_given=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) [[ $# -ge 2 ]] || fail_usage "--config requires a value"; config_arg="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --json) json_out=1; shift ;;
      --otp) [[ $# -ge 2 ]] || fail_usage "--otp requires a value"; otp="$2"; shift 2 ;;
      --otp=*) otp="${1#*=}"; shift ;;
      --force) [[ $# -ge 2 ]] || fail_usage "--force requires a <reason>"; force_given=1; force_reason="$2"; shift 2 ;;
      -h|--help) usage; exit "${EXIT_OK}" ;;
      -*) fail_usage "approve: unknown flag: $1" ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [[ ${#positional[@]} -ge 1 ]] || fail_usage "approve: <stage-id> is required"
  [[ ${#positional[@]} -le 1 ]] || fail_usage "approve: too many arguments"
  local stage_id="${positional[0]}"

  if (( force_given )); then
    [[ -n "${force_reason}" ]] || fail_usage "approve: --force requires a non-empty <reason>"
  fi

  local config_path=""
  config_path="$(resolve_config_path "${config_arg}" || true)"

  local view_json package_name package_version
  view_json="$(_stage_view_json "${stage_id}")"
  package_name="$(_stage_package_name "${view_json}")"
  package_version="$(_stage_package_version "${view_json}")"

  local target_name target_type smoke_cmd require_test
  IFS=$'\x1f' read -r target_name target_type smoke_cmd require_test < <(resolve_stage_target "${package_name}" "${config_path}")
  : "${smoke_cmd}"

  if [[ "${require_test}" == "true" ]] && (( ! force_given )); then
    local history_file
    history_file="$(publish_resolve_history_file "${config_path}")"
    if ! publish_history_has_passing_stage_test "${history_file}" "${stage_id}"; then
      printf 'npm stage inspect: approve refused — stage %s has no passing test on record in %s.\n' "${stage_id}" "${history_file}" >&2
      printf 'Fix: run "npm_stage_inspect.sh test %s" first, or pass --force <reason> to override.\n' "${stage_id}" >&2
      exit "${EXIT_USAGE}"
    fi
  fi

  local -a exec_cmd=(npm stage approve "${stage_id}")
  local -a display_cmd=("${exec_cmd[@]}")
  if [[ -n "${otp}" ]]; then
    display_cmd+=(--otp '********')
    # Tracing was already suspended for the rest of this run (if it was
    # active) by the guard above, the moment argv was found to contain
    # --otp — before OTP was ever assigned to a variable. Nothing further
    # to do here.
    exec_cmd+=(--otp "${otp}")
  fi

  if (( dry_run )); then
    log_info "[dry-run] resolved command: $(printf '%q ' "${display_cmd[@]}")"
    exit "${EXIT_OK}"
  fi

  log_info "[approve] resolved command: $(printf '%q ' "${display_cmd[@]}")"

  local output status=0
  output="$("${exec_cmd[@]}" 2>&1)" || status=$?

  # Defensive redaction: strip the literal OTP from captured output before
  # it is ever printed, in case npm echoed the argv back in an error
  # message.
  if [[ -n "${otp}" ]]; then
    output="${output//"${otp}"/********}"
  fi
  printf '%s\n' "${output}"

  if [[ ${status} -ne 0 ]]; then
    printf 'npm stage inspect: npm stage approve failed (exit %s).\n' "${status}" >&2
    exit "${EXIT_OP_FAILED}"
  fi

  local -a ledger_cmd=(bash "${WRITE_LEDGER_SCRIPT}" "${target_name}" "${target_type}" approved "" --stage-id "${stage_id}")
  [[ -n "${config_path}" ]] && ledger_cmd+=(--config "${config_path}")
  [[ -n "${package_version}" ]] && ledger_cmd+=(--version "${package_version}")
  (( force_given )) && ledger_cmd+=(--reason "${force_reason}")
  "${ledger_cmd[@]}" || log_warn "failed to write 'approved' ledger entry for stage ${stage_id}"

  if (( json_out )); then
    jq -cn --arg stage_id "${stage_id}" --arg pkg "${package_name:-}" '{stage_id: $stage_id, package: $pkg, state: "approved"}'
  fi
}

# ---------------------------------------------------------------------------
# reject <stage-id> [--config <path>] [--dry-run] [--json]
# ---------------------------------------------------------------------------
cmd_reject() {
  local config_arg="" dry_run=0 json_out=0
  local -a positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config) [[ $# -ge 2 ]] || fail_usage "--config requires a value"; config_arg="$2"; shift 2 ;;
      --dry-run) dry_run=1; shift ;;
      --json) json_out=1; shift ;;
      -h|--help) usage; exit "${EXIT_OK}" ;;
      -*) fail_usage "reject: unknown flag: $1" ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  [[ ${#positional[@]} -ge 1 ]] || fail_usage "reject: <stage-id> is required"
  [[ ${#positional[@]} -le 1 ]] || fail_usage "reject: too many arguments"
  local stage_id="${positional[0]}"

  local config_path=""
  config_path="$(resolve_config_path "${config_arg}" || true)"

  local view_json package_name package_version
  view_json="$(_stage_view_json "${stage_id}")"
  package_name="$(_stage_package_name "${view_json}")"
  package_version="$(_stage_package_version "${view_json}")"

  local target_name target_type smoke_cmd require_test
  IFS=$'\x1f' read -r target_name target_type smoke_cmd require_test < <(resolve_stage_target "${package_name}" "${config_path}")
  : "${smoke_cmd}" "${require_test}"

  local -a cmd=(npm stage reject "${stage_id}")

  if (( dry_run )); then
    log_info "[dry-run] resolved command: $(printf '%q ' "${cmd[@]}")"
    exit "${EXIT_OK}"
  fi

  local output status=0
  output="$("${cmd[@]}" 2>&1)" || status=$?
  printf '%s\n' "${output}"
  if [[ ${status} -ne 0 ]]; then
    printf 'npm stage inspect: npm stage reject failed (exit %s).\n' "${status}" >&2
    exit "${EXIT_OP_FAILED}"
  fi

  local -a ledger_cmd=(bash "${WRITE_LEDGER_SCRIPT}" "${target_name}" "${target_type}" rejected "" --stage-id "${stage_id}")
  [[ -n "${config_path}" ]] && ledger_cmd+=(--config "${config_path}")
  [[ -n "${package_version}" ]] && ledger_cmd+=(--version "${package_version}")
  "${ledger_cmd[@]}" || log_warn "failed to write 'rejected' ledger entry for stage ${stage_id}"

  if (( json_out )); then
    jq -cn --arg stage_id "${stage_id}" --arg pkg "${package_name:-}" '{stage_id: $stage_id, package: $pkg, state: "rejected"}'
  fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
main() {
  [[ $# -ge 1 ]] || fail_usage "a sub-command is required"
  local sub="$1"
  shift
  case "${sub}" in
    list) cmd_list "$@" ;;
    view) cmd_view "$@" ;;
    download) cmd_download "$@" ;;
    test) cmd_test "$@" ;;
    approve) cmd_approve "$@" ;;
    reject) cmd_reject "$@" ;;
    -h|--help) usage; exit "${EXIT_OK}" ;;
    *) fail_usage "unknown sub-command: '${sub}'" ;;
  esac
}

main "$@"
