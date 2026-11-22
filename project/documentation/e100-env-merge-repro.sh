#!/usr/bin/env bash
# E100_S01_T02: reproduce how Claude Code merges `env` across settings scopes.
# Isolation: a throw-away CLAUDE_CONFIG_DIR (user scope) and a throw-away project
# directory. Nothing under the real ~/.claude or any repository is read or written;
# the real files are checksummed before and after as proof.
# The probe is a SessionStart hook that dumps the probe variables from its own
# environment. It fires before authentication, so no login or model call is needed
# (`claude -p` prints "Not logged in" afterwards, which is expected and ignored).
set -u
REAL_FILES=("$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json")
for f in "$@"; do REAL_FILES+=("$f"); done   # pass any repo/client settings files to guard
sums() { for f in "${REAL_FILES[@]}"; do if [ -f "$f" ]; then shasum -a 256 "$f"; else echo "absent  $f"; fi; done; }
BEFORE="$(sums)"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
HOOK='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"env | grep -E \"^(ONLY_|BOTH_)\" | sort > \"$OUT\""}]}]}}'

# run <case> <user-env-json|-> <project-env-json|-> <local-env-json|-> [extra claude args]
run() {
  local name="$1" u="$2" p="$3" l="$4"; shift 4
  local cfg="$T/$name/cfg" proj="$T/$name/proj"
  mkdir -p "$cfg" "$proj/.claude"
  if [ "$u" = - ]; then echo "$HOOK" > "$cfg/settings.json"
  else echo "$HOOK" | jq --argjson e "$u" '. + {env:$e}' > "$cfg/settings.json"; fi
  [ "$p" = - ] || echo "{\"env\":$p}" > "$proj/.claude/settings.json"
  [ "$l" = - ] || echo "{\"env\":$l}" > "$proj/.claude/settings.local.json"
  ( cd "$proj" && OUT="$T/$name/out.txt" CLAUDE_CONFIG_DIR="$cfg" timeout 90 claude -p "hi" "$@" >/dev/null 2>&1 )
  echo "== $name"; cat "$T/$name/out.txt" 2>/dev/null || echo "(no output: hook did not run)"
}

echo "claude version: $(claude --version)"
# Variables: ONLY_USER/ONLY_PROJ/ONLY_LOCAL = defined in one layer; BOTH_DIFF = differing values; BOTH_SAME = equal values.
U='{"ONLY_USER":"u","BOTH_DIFF":"user","BOTH_SAME":"same"}'
P='{"ONLY_PROJ":"p","BOTH_DIFF":"proj","BOTH_SAME":"same"}'
L='{"ONLY_LOCAL":"l","BOTH_DIFF":"local"}'
run A_user_project_local "$U" "$P" "$L"
run B_user_project       "$U" "$P" -
run C_user_only_higher_files_have_no_env "$U" - -
# D: higher files exist but contain no `env` key at all
mkdir -p "$T/D/cfg" "$T/D/proj/.claude"
echo "$HOOK" | jq --argjson e "$U" '. + {env:$e}' > "$T/D/cfg/settings.json"
echo '{"permissions":{"allow":[]}}' > "$T/D/proj/.claude/settings.json"
( cd "$T/D/proj" && OUT="$T/D/out.txt" CLAUDE_CONFIG_DIR="$T/D/cfg" timeout 90 claude -p hi >/dev/null 2>&1 )
echo "== D_project_file_exists_without_env_key"; cat "$T/D/out.txt" 2>/dev/null
# E: empty env object in the higher layer
run E_project_has_empty_env_object "$U" '{}' -

AFTER="$(sums)"
echo "== checksums before/after"; echo "$BEFORE"; [ "$BEFORE" = "$AFTER" ] && echo "UNCHANGED" || { echo "CHANGED!"; echo "$AFTER"; }
