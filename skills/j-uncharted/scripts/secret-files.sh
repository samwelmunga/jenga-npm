#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# skills/j-uncharted/scripts/secret-files.sh  (epic E85, task E85_S04_T05)
#
# THE one list of file names that j-uncharted treats as "looks like a secret", plus the helpers that apply it.
# Source: project/rapports/problems/E85_S02_T04-j-uncharted-triage-does-not-skip-secret-files.md. A credential
# file inside an analysed or imported target could otherwise be counted, read by the investigating agent and
# quoted into a committed document. E85_S04_T06, T07 and T08 wire this file into the other scripts; there is
# exactly one list so those scripts cannot drift apart.
#
# ---------------------------------------------------------------------------
# WHAT IT DOES AND DOES NOT DO
# ---------------------------------------------------------------------------
#   * Matches on the file's BASE NAME only: never on content, never on the directory it sits in.
#   * Case-insensitive, so an upper-case variant of a listed name is caught too.
#   * Never opens a file. It sees a name (a string) and nothing else; no cat, no grep of a file, no stat.
#   * Names only is a KNOWN TRADEOFF: a secret kept in an oddly named file is not caught, and a harmless file
#     with a listed name (for example a localisation key file with a .key extension) is skipped. Skipping is
#     the safe direction, and the notice below makes every skip visible, so nothing vanishes silently.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
# As a library (bash 3.2 compatible; safe to source from other j-uncharted scripts):
#
#   . "$(dirname "$0")/secret-files.sh"
#   if secret_files_is_secret "$path"; then ... skip it, remember "$rel_path" for the notice ... fi
#   secret_files_notice "$count" "${skipped[@]}"          # one line on STDERR; nothing when count is 0
#   line="$(secret_files_notice_text "$count" "${skipped[@]}")"   # the same line on STDOUT, for JSON/summaries
#
# Sourcing prints nothing, exits nothing, sets no shell option, installs no trap, and defines only names
# prefixed secret_files_ / SECRET_FILES_. Every function leaves the caller's shell options as it found them.
#
# As a command (for the Python heredocs inside detect-*.sh and inspect-provenance.sh, and for tests):
#
#   secret-files.sh is-secret <path>        exit 0 = secret-looking, 1 = not, 2 = usage
#   secret-files.sh patterns                the positive globs, one per line
#   secret-files.sh templates               the exempt template names, one per line
#   secret-files.sh notice <count> [name]...        the notice line on stderr
#   secret-files.sh notice-text <count> [name]...   the notice line on stdout
#   secret-files.sh -h | --help
#
# ---------------------------------------------------------------------------
# THE RULE, PRECISELY (so a re-implementation gets identical results)
# ---------------------------------------------------------------------------
#   name := the last path component of the argument (trailing slashes ignored), lower-cased
#   secret(name) := name matches NONE of the SECRET_FILES_TEMPLATES (exact, whole-name equality)
#                   AND name matches AT LEAST ONE glob in SECRET_FILES_PATTERNS
#   A glob is a shell glob matched against the whole name: `*` matches any run of characters, including a
#   leading dot and including none. fnmatch.fnmatchcase(name, glob) in Python behaves the same for these globs.
#   `patterns` therefore prints only POSITIVE globs. The template exemption is a separate list, printed by
#   `templates`; `is-secret` applies both. A consumer that cannot call `is-secret` re-implements it as above
#   (Python: not any(name == t for t in templates) and any(fnmatchcase(name, g) for g in patterns)).
#   Templates are exact names: a variant such as a ".local" template is NOT exempt and is skipped.
#
# Lines of the pattern arrays that contain a [policy] marker are the entries the repository's credential-access
# scanner would otherwise report as mentions of a credential file. They are listed in
# tests/fixtures/credential-access-allowlist.txt under ONE entry for this file: the script only compares names.
#
# Portability: macOS bash 3.2 and BSD userland (no associative arrays, mapfile or ${var,,}).
# ---------------------------------------------------------------------------

# --- THE LIST ----------------------------------------------------------------------------------------------
# Lower-case globs. One entry per line so the whole policy reads on one screen.
SECRET_FILES_PATTERNS=(
  # Environment files: hold API keys, database passwords and tokens in plain text.
  '.env'                # [policy] the bare dot-env file
  '.env.*'              # [policy] per-environment variants (local, production, ...)
  '*.env'               # [policy] "<name>.env" style files
  # Auth and credential files: package-manager and tool logins, stored tokens and passwords.
  '.npmrc'              # [policy] registry auth tokens
  '.yarnrc.yml'         # registry auth tokens (yarn berry)
  '.netrc'              # [policy] machine/login/password triples
  '_netrc'              # the Windows spelling of the same file
  '.pypirc'             # PyPI upload credentials
  '.dockercfg'          # registry credentials (legacy docker login file)
  'credentials'         # cloud CLI credential files
  'credentials.json'
  'credentials.yml'
  'secrets.json'        # conventional names for hand-kept secret stores
  'secrets.yml'
  'secrets.yaml'
  'service-account*.json'   # cloud service-account key files
  '.git-credentials'    # stored git passwords/tokens
  '.htpasswd'           # web-server password hashes
  '.pgpass'             # PostgreSQL passwords
  # Private keys and key material, recognised by name.
  'id_rsa'              # [policy] ssh private keys, exact names
  'id_dsa'
  'id_ecdsa'
  'id_ed25519'
  '*.pem'               # PEM containers: private keys and certificate bundles
  '*.key'               # private keys (see the tradeoff in the header)
  '*.p12'               # PKCS#12 bundles: key plus certificate
  '*.pfx'
  '*.jks'               # Java keystores
  '*.keystore'
  '*.ppk'               # PuTTY private keys
  # Deliberately NOT listed: *.asc. That extension is used for PUBLIC keys and detached signatures, which are
  # meant to be shared and are worth reading; listing it would hide them for no safety gain.
)

# Conventional non-secret templates. They document which variables exist, hold placeholders, and stay visible.
# Exact, whole-name matches (case-insensitive); the globs above would otherwise catch them.
SECRET_FILES_TEMPLATES=(
  '.env.example'        # [policy]
  '.env.sample'         # [policy]
  '.env.template'       # [policy]
  '.env.dist'           # [policy]
)

# Names listed by the notice before it falls back to "... and M more".
SECRET_FILES_NOTICE_CAP=20

# --- functions ---------------------------------------------------------------------------------------------

# secret_files_is_secret <path>: status 0 when the base name of <path> looks like a secret file, 1 when not.
# Looks at the string only. Restores the caller's nocasematch setting before returning.
secret_files_is_secret() {
  local name="${1:-}" pat tpl prev_ncm=0 verdict=1
  while [ "${name%/}" != "$name" ]; do name="${name%/}"; done
  name="${name##*/}"
  [ -n "$name" ] || return 1

  if shopt -q nocasematch; then prev_ncm=1; fi
  shopt -s nocasematch

  for tpl in "${SECRET_FILES_TEMPLATES[@]}"; do
    case "$name" in
      $tpl)
        verdict=2
        break
        ;;
    esac
  done
  if [ "$verdict" -ne 2 ]; then
    for pat in "${SECRET_FILES_PATTERNS[@]}"; do
      case "$name" in
        $pat)
          verdict=0
          break
          ;;
      esac
    done
  fi

  if [ "$prev_ncm" -eq 0 ]; then shopt -u nocasematch; fi
  [ "$verdict" -eq 0 ]
}

# secret_files_notice_text <count> [name]...: the notice as text on stdout; prints NOTHING when <count> is 0.
# Names are de-duplicated and sorted, capped at SECRET_FILES_NOTICE_CAP, then "... and M more". Control
# characters in a name are shown as "?". Never prints anything but the count and the names it was given.
# Status 2 (and no output) when <count> is not a non-negative integer.
secret_files_notice_text() {
  local count="${1:-0}" listed total shown more n
  case "$count" in
    '' | *[!0-9]*) return 2 ;;
  esac
  [ "$count" -gt 0 ] || return 0
  if [ $# -gt 0 ]; then shift; fi

  # One name per line, "./" prefix dropped, control characters neutralised, blank lines gone, sorted unique.
  listed="$(
    for n in "$@"; do
      printf '%s\n' "${n#./}"
    done | LC_ALL=C tr '\000-\010\013-\037\177' '?' | LC_ALL=C sed '/^$/d' | LC_ALL=C sort -u
  )"

  if [ -z "$listed" ]; then
    printf '%s secret-looking file(s) skipped (names not available, contents never read)\n' "$count"
    return 0
  fi

  total="$(printf '%s\n' "$listed" | wc -l | tr -d ' ')"
  shown="$(printf '%s\n' "$listed" | head -n "$SECRET_FILES_NOTICE_CAP" | sed 's/$/, /' | tr -d '\n')"
  shown="${shown%, }"
  if [ "$total" -gt "$SECRET_FILES_NOTICE_CAP" ]; then
    more=$((total - SECRET_FILES_NOTICE_CAP))
    printf '%s secret-looking file(s) skipped (names listed, contents never read): %s, ... and %s more\n' \
      "$count" "$shown" "$more"
  else
    printf '%s secret-looking file(s) skipped (names listed, contents never read): %s\n' "$count" "$shown"
  fi
}

# secret_files_notice <count> [name]...: the same line on stderr, so a script's machine-readable stdout stays clean.
secret_files_notice() {
  secret_files_notice_text "$@" >&2
}

secret_files_usage() {
  awk 'NR==1{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "${BASH_SOURCE[0]}" | sed -n '/^USAGE/,/^THE RULE/p' | sed '1,2d;$d' | sed '$d'
}

# secret_files_main: the command-line form. Only ever called when the file is executed, never when sourced.
secret_files_main() {
  local item
  case "${1:-}" in
    is-secret)
      [ $# -eq 2 ] || { printf 'secret-files.sh: is-secret needs exactly one path\n' >&2; return 2; }
      secret_files_is_secret "$2"
      ;;
    patterns)
      for item in "${SECRET_FILES_PATTERNS[@]}"; do printf '%s\n' "$item"; done
      ;;
    templates)
      for item in "${SECRET_FILES_TEMPLATES[@]}"; do printf '%s\n' "$item"; done
      ;;
    notice)
      shift
      secret_files_notice "$@"
      ;;
    notice-text)
      shift
      secret_files_notice_text "$@"
      ;;
    -h | --help)
      secret_files_usage
      ;;
    *)
      printf 'secret-files.sh: unknown or missing command: %s\n' "${1:-}" >&2
      printf 'try: secret-files.sh --help\n' >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  secret_files_main "$@"
  exit $?
fi
