#!/usr/bin/env bash
# scripts/merge-settings.sh - merge the Jenga settings fragments into a consumer's settings files
# (epic E100, task E100_S03_T03; design: project/documentation/e100-s03-merge-design.md)
#
# Usage:
#   merge-settings.sh --consumer-root <dir> [--package-root <dir>] [--dry-run] [--interactive]
#   merge-settings.sh --help
#
# What it does: finds every shipped fragment (skills/*/settings-fragment.json, hooks/*.fragment.json) under the package
# root, validates them with validate-settings-fragment.sh, and adds each declared hook entry that is not already present to
# <consumer>/.claude/settings.json and <consumer>/.agents/settings.json. An entry is "present" when it equals a declared
# entry after JSON normalisation; a similar but different consumer entry is left alone and Jenga's is added next to it.
# Nothing else is touched: user entries, other keys and key order. A file is rewritten (atomically) only when an entry was
# added, so a second run is byte-identical. Missing files, .claude/ and .agents/ are created only when writing.
# WorktreeCreate and WorktreeRemove replace Claude's default handling: when either already holds an entry that is not the
# declared one, Jenga does not add its own, prints "conflict hooks.<Event>" and the run ends with exit 6.
# env is merged PER KEY (contract sections 3 and 5): a declared key absent from the file's env object is added and every
# other key is left as it is; the object is never replaced. A key present with the identical value is left alone. A key
# present with another value is a conflict: the client's value stays, the file is not changed for that key, and one stderr
# line names the file, the key path and both values. A conflict never stops other keys from being added.
# permissions.allow is opt-in (contract section 4): the rules declared as {rule, optIn: true} that a file lacks are listed
# exactly, one per line per file, and are written only after the user answers yes on the terminal in this run. The question
# is asked only with --interactive, when stdin is a terminal, and the answer is read from /dev/tty. There is no flag,
# environment variable or config value that supplies the yes. No, silence, an unrecognised answer and a closed input write
# nothing, and the question is asked once per run. Without --interactive or without a terminal each pending rule is
# reported "inactive allow <rule>" with the command that asks, and the run ends with exit 6. A rule already in the file
# counts as active and is not written. A declined or unanswered diff never stops the hooks and env writes. Only <consumer>/.claude/settings.json and <consumer>/.agents/settings.json are read or written, never
# settings.local.json, user settings or managed settings.
#
# Manifest (contract sections 6 and 7): beside each settings file, jenga-settings-manifest.json records every entry written
# (keyClass, path, id = sha256 of the compact key-sorted entry, fragment, jengaVersion, entry; manifestVersion 1, file). It is
# written only after the settings file write succeeded and was re-read and parsed; a failed write leaves it as it was. Conflicts,
# declined or inactive allow rules and entries that were already present are never recorded. On a later run a record that is no
# longer declared is removed only when the file's entry still equals the recorded one (JSON equality): hooks and env at once,
# an allow rule only after the exact diff and an explicit yes (same --interactive rules as the opt-in; otherwise it stays and is
# reported "still present allow <rule>"). A client-edited entry is kept ("kept, client-modified <path>"), a hand-deleted one is
# "already absent <path>"; both records are dropped. An edit is recognised for env (key present with another value) and for
# hooks (an entry with the same matcher sharing a handler command); an edited allow rule reads as absent. A missing manifest
# removes nothing and says "no manifest, nothing removed"; a corrupt one (unparseable, wrong manifestVersion or file) removes
# nothing, is reported ("corrupt manifest <file>") and is never overwritten. Removal output: "removed hooks.<Event>",
# "removed env <KEY>", "removed allow <rule>", and with --dry-run "would remove ..." (no manifest or settings file is written).
# The manifest holds no secret beyond the declared env values, which fragments must not make secret.
#
# Never acts on the package itself: when the consumer root is the package root it prints "skipped" and exits 0.
#
# Allow output: "added allow <rule>", "would add allow <rule>" (--dry-run shows the diff and never asks), "inactive allow
# <rule>"; the inactive lines are followed by "to activate: <command>".
# Output (stdout): "added <Event>" per added event, "unchanged" when nothing was added, "skipped: <reason>". With
# --dry-run, "would add <Event>" and nothing is written (no directory either). "conflict hooks.<Event>" for a collision.
# env: "added env <KEY>" / "would add env <KEY>" per key, "conflict env.<KEY>" per conflict and, when any conflict
# occurred, "<n> conflict(s); the requirement is inactive". A conflict or an inactive allow rule ends the run with exit 6
# after everything else that could be added was added.
# Exit: 0 ok/skipped, 2 usage, 3 source unusable (jq missing, no fragment, invalid fragment), 4 an existing settings file
#       is not a JSON object (left untouched), 5 write failed, 6 completed with conflicts or inactive allow rules.
set -euo pipefail

ME="merge-settings.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }

CONSUMER=""; PACKAGE_ROOT=""; DRY=0; INTERACTIVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --consumer-root) [[ $# -ge 2 ]] || { echo "$ME: --consumer-root needs a value" >&2; exit 2; }; CONSUMER="$2"; shift 2 ;;
    --package-root)  [[ $# -ge 2 ]] || { echo "$ME: --package-root needs a value" >&2; exit 2; }; PACKAGE_ROOT="$2"; shift 2 ;;
    --dry-run)       DRY=1; shift ;;
    --interactive)   INTERACTIVE=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "$ME: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[[ -n "$CONSUMER" && -d "$CONSUMER" ]] || { echo "$ME: --consumer-root must be an existing directory" >&2; exit 2; }
if [[ -n "$PACKAGE_ROOT" && ! -d "$PACKAGE_ROOT" ]]; then echo "$ME: --package-root must be an existing directory" >&2; exit 2; fi
command -v jq >/dev/null 2>&1 || { echo "$ME: jq is required" >&2; exit 3; }

if [[ -z "$PACKAGE_ROOT" ]]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/../skills/index/scripts/package-root.sh" 2>/dev/null || true
  if command -v jenga_package_root >/dev/null 2>&1; then
    PACKAGE_ROOT="$(jenga_package_root "$SCRIPT_DIR/../skills/index/scripts" 2>/dev/null)" || true
  fi
  [[ -n "$PACKAGE_ROOT" && -d "$PACKAGE_ROOT" ]] || PACKAGE_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
fi
CONSUMER="$(cd "$CONSUMER" && pwd -P)"; PACKAGE_ROOT="$(cd "$PACKAGE_ROOT" && pwd -P)"
if [[ "$CONSUMER" == "$PACKAGE_ROOT" ]]; then echo "skipped: consumer root is the package itself"; exit 0; fi

# --- fragments: discover and validate -------------------------------------------------------------------------------
FRAGS=()
for f in "$PACKAGE_ROOT"/skills/*/settings-fragment.json "$PACKAGE_ROOT"/hooks/*.fragment.json; do
  [[ -f "$f" ]] && FRAGS+=("$f")
done
[[ ${#FRAGS[@]} -gt 0 ]] || { echo "$ME: no settings fragment found under $PACKAGE_ROOT" >&2; exit 3; }
VALIDATOR="$PACKAGE_ROOT/scripts/validate-settings-fragment.sh"
[[ -f "$VALIDATOR" ]] || VALIDATOR="$SCRIPT_DIR/validate-settings-fragment.sh"
[[ -f "$VALIDATOR" ]] || { echo "$ME: validate-settings-fragment.sh not found" >&2; exit 3; }
bash "$VALIDATOR" "${FRAGS[@]}" >/dev/null || { echo "$ME: a settings fragment is invalid; nothing was changed" >&2; exit 3; }

# Declared hooks: per event, the union of every fragment's entries, deduplicated by JSON equality, first-seen order.
DECL="$(jq -s 'reduce (.[] | (.hooks // {}) | to_entries[]) as $e ({};
    reduce $e.value[] as $x (.; (.[$e.key] // []) as $l | if ($l | index([$x])) != null then . else .[$e.key] = $l + [$x] end))' \
  "${FRAGS[@]}")" || { echo "$ME: could not read the fragments" >&2; exit 3; }

# Declared env: the union of every fragment's env object, first-seen value wins for a key two fragments both declare.
DENV="$(jq -s 'reduce (.[] | (.env // {}) | to_entries[]) as $e ({}; if has($e.key) then . else .[$e.key] = $e.value end)' \
  "${FRAGS[@]}")" || { echo "$ME: could not read the fragments" >&2; exit 3; }

# Declared allow rules: every fragment's permissions.allow[].rule, deduplicated, first-seen order.
DALLOW="$(jq -s '[.[] | (.permissions.allow // [])[] | .rule] | reduce .[] as $r ([]; if index([$r]) == null then . + [$r] else . end)' \
  "${FRAGS[@]}")" || { echo "$ME: could not read the fragments" >&2; exit 3; }

# Declared entries with their fragment id, for the manifest and for deciding what is "no longer declared".
DECLENT="$(jq -s '[.[] | (.id // "unknown") as $f | (
    ((.hooks // {}) | to_entries[] | .key as $ev | .value[] | {keyClass: "hooks", path: ("hooks." + $ev), entry: ., fragment: $f}),
    ((.env // {}) | to_entries[] | {keyClass: "env", path: ("env." + .key), entry: {key: .key, value: .value}, fragment: $f}),
    ((.permissions.allow // [])[] | {keyClass: "allow", path: "permissions.allow", entry: .rule, fragment: $f}))]' \
  "${FRAGS[@]}")" || { echo "$ME: could not read the fragments" >&2; exit 3; }
JENGA_VERSION="$(jq -r '.version // "unknown"' "$PACKAGE_ROOT/package.json" 2>/dev/null)" || JENGA_VERSION="unknown"
[[ -n "$JENGA_VERSION" ]] || JENGA_VERSION="unknown"

# --- per settings file: compute -------------------------------------------------------------------------------------
DESTS=("$CONSUMER/.claude/settings.json" "$CONSUMER/.agents/settings.json")
for d in "${DESTS[@]}"; do
  if [[ -f "$d" ]]; then
    jq -e 'type == "object" and (if has("hooks") then (.hooks | type) == "object" else true end)
        and (if has("env") then (.env | type) == "object" else true end)
        and (if has("permissions") then (.permissions | type) == "object"
             and (if (.permissions | has("allow")) then (.permissions.allow | type) == "array" else true end) else true end)' "$d" >/dev/null 2>&1 \
      || { echo "$ME: $d is not a valid JSON object; left untouched" >&2; exit 4; }
  fi
done

# --- manifest: read, and decide what is no longer declared (contract sections 6 and 7) -------------------------------------
MANIFESTS=("$CONSUMER/.claude/jenga-settings-manifest.json" "$CONSUMER/.agents/jenga-settings-manifest.json")
MSTATE=(); MREC=(); RMREC=(); DROPREC=(); NEWMAN=()
CLASSIFY='
  . as $s
  | [$man[] | select(. as $r | ($decl | any(.keyClass == $r.keyClass and .path == $r.path and .entry == $r.entry)) | not)
    | . as $r
    | {rec: $r, state: (
        if $r.keyClass == "hooks" then
          ($r.path | sub("^hooks\\."; "")) as $ev | ($s.hooks[$ev] // []) as $h
          | if ($h | type) != "array" then "absent"
            elif ($h | index([$r.entry])) != null then "present"
            elif ($h | any(. as $x | ($x.matcher // "") == ($r.entry.matcher // "")
                  and (($x.hooks // []) | any(.command as $c | ($r.entry.hooks // []) | any(.command == $c))))) then "modified"
            else "absent" end
        elif $r.keyClass == "env" then
          ($s.env // {}) as $e
          | if ($e | has($r.entry.key) | not) then "absent" elif $e[$r.entry.key] == $r.entry.value then "present" else "modified" end
        else if (($s.permissions.allow // []) | index([$r.entry])) != null then "present" else "absent" end end)}]'
VALID_MAN='type == "object" and .manifestVersion == 1 and .file == $file and (.entries | type) == "array"
  and (.entries | all(type == "object" and (.keyClass | IN("hooks", "allow", "env")) and (.path | type) == "string"
       and (.id | type) == "string" and has("entry")
       and (if .keyClass == "hooks" then (.path | startswith("hooks.")) and (.entry | type) == "object"
            elif .keyClass == "env" then (.entry | type) == "object" and (.entry.key | type) == "string" and (.entry | has("value"))
            else (.entry | type) == "string" end)))'
RM_ALLOW_PENDING=()   # "<index>\t<rule>"
for i in 0 1; do
  m="${MANIFESTS[$i]}"; rel="${DESTS[$i]#"$CONSUMER"/}"
  MSTATE[$i]="missing"; MREC[$i]="[]"; RMREC[$i]="[]"; DROPREC[$i]="[]"
  if [[ -e "$m" ]]; then
    if jq -e --arg file "$rel" "$VALID_MAN" "$m" >/dev/null 2>&1; then
      MSTATE[$i]="ok"; MREC[$i]="$(jq -c '.entries' "$m")"
    else
      MSTATE[$i]="corrupt"
      echo "corrupt manifest ${m#"$CONSUMER"/}"
      echo "$ME: ${m#"$CONSUMER"/} is unparseable, has another manifestVersion or does not belong to $rel; nothing was removed and the manifest was not overwritten" >&2
    fi
  elif [[ -f "${DESTS[$i]}" ]]; then
    echo "no manifest, nothing removed: $rel"
  fi
  [[ "${MSTATE[$i]}" == "ok" ]] || continue
  if [[ -f "${DESTS[$i]}" ]]; then CLS="$(jq -c --argjson man "${MREC[$i]}" --argjson decl "$DECLENT" "$CLASSIFY" "${DESTS[$i]}")"
  else CLS="$(jq -nc --argjson man "${MREC[$i]}" --argjson decl "$DECLENT" "{} | $CLASSIFY")"; fi
  # Records to remove now, and records to drop (everything classified except an allow rule that stays for lack of a yes).
  RMREC[$i]="$(printf '%s' "$CLS" | jq -c '[.[] | select(.state == "present" and .rec.keyClass != "allow") | .rec]')"
  DROPREC[$i]="$(printf '%s' "$CLS" | jq -c '[.[] | select(.state != "present" or .rec.keyClass != "allow") | .rec]')"
  while IFS= read -r r; do [[ -z "$r" ]] || RM_ALLOW_PENDING+=("$i"$'\t'"$r"); done \
    < <(printf '%s' "$CLS" | jq -r '.[] | select(.state == "present" and .rec.keyClass == "allow") | .rec.entry')
  while IFS=$'\t' read -r st path; do
    [[ -n "$st" ]] || continue
    case "$st" in
      modified) echo "kept, client-modified $path" ;;
      absent)   echo "already absent $path" ;;
    esac
  done < <(printf '%s' "$CLS" | jq -r '.[] | select(.state != "present") | [.state, (if .rec.keyClass == "allow" then .rec.path + " " + .rec.entry else .rec.path end)] | @tsv')
done
# Removal program (hooks, env, allow) applied to a settings object.
APPLY_RM='
  reduce $rm[] as $r (.;
    if $r.keyClass == "hooks" then
      ($r.path | sub("^hooks\\."; "")) as $ev
      | .hooks[$ev] |= map(select(. != $r.entry))
      | if (.hooks[$ev] | length) == 0 then del(.hooks[$ev]) else . end
      | if (.hooks | length) == 0 then del(.hooks) else . end
    elif $r.keyClass == "env" then
      del(.env[$r.entry.key]) | if (.env | length) == 0 then del(.env) else . end
    else
      .permissions.allow |= map(select(. != $r.entry))
      | if (.permissions.allow | length) == 0 then del(.permissions.allow) else . end
      | if (.permissions | length) == 0 then del(.permissions) else . end
    end)'

# The file as it will be read for the additions: hooks and env records that are no longer declared are removed first, so a
# changed declaration (an env value, a hook path) is an update and never a conflict with Jenga's own earlier entry.
BASES=(); NRM0=()
for i in 0 1; do
  if [[ -f "${DESTS[$i]}" ]]; then BASES[$i]="$(cat "${DESTS[$i]}")"; else BASES[$i]="{}"; fi
  NRM0[$i]="$(printf '%s' "${RMREC[$i]}" | jq 'length')"
  [[ "${NRM0[$i]}" -eq 0 ]] || BASES[$i]="$(printf '%s' "${BASES[$i]}" | jq --argjson rm "${RMREC[$i]}" "$APPLY_RM")"
done

# Emits {"settings": <merged>, "addedent": [entries written], "added": [events], "conflicts": [events], "envadded": [keys],
#        "envconflicts": [{key, have, want}]}.
FILTER='
  def worktree: . == "WorktreeCreate" or . == "WorktreeRemove";
  reduce ($decl | to_entries[]) as $e ({settings: ., added: [], conflicts: [], envadded: [], envconflicts: [], addedent: []};
    ((.settings.hooks[$e.key]) // []) as $have
    | if ($have | type) != "array" then .conflicts += [$e.key]
      elif ($e.key | worktree) then
        if ([$have[] | select(. as $x | $e.value | index([$x]) == null)] | length) > 0 then .conflicts += [$e.key]
        elif ($e.value | all(. as $x | $have | index([$x]) != null)) then .
        else ([$e.value[] | select(. as $x | $have | index([$x]) == null)]) as $new
          | .settings.hooks[$e.key] = ($have + $new) | .added += [$e.key]
          | .addedent += [$new[] | {keyClass: "hooks", path: ("hooks." + $e.key), entry: .}] end
      else
        ([$e.value[] | select(. as $x | $have | index([$x]) == null)]) as $new
        | if ($new | length) == 0 then . else .settings.hooks[$e.key] = ($have + $new) | .added += [$e.key]
          | .addedent += [$new[] | {keyClass: "hooks", path: ("hooks." + $e.key), entry: .}] end
      end)
  | reduce ($denv | to_entries[]) as $k (.;
      if (.settings.env // {} | has($k.key) | not) then .settings.env[$k.key] = $k.value | .envadded += [$k.key]
        | .addedent += [{keyClass: "env", path: ("env." + $k.key), entry: {key: $k.key, value: $k.value}}]
      elif .settings.env[$k.key] == $k.value then .
      else .envconflicts += [{key: $k.key, have: .settings.env[$k.key], want: $k.value}] end)
'
OUTS=(); ADDED_ALL=(); CONFLICTS=(); ENV_ADDED=(); ENV_CONFLICTS=(); NCONF=0
for i in 0 1; do
  d="${DESTS[$i]}"
  OUT="$(printf '%s' "${BASES[$i]}" | jq --argjson decl "$DECL" --argjson denv "$DENV" --argjson nrm "${NRM0[$i]}" "$FILTER | .removed = \$nrm")"
  OUTS[$i]="$OUT"
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    case " ${ENV_ADDED[*]:-} " in *" $k "*) ;; *) ENV_ADDED+=("$k") ;; esac
  done < <(printf '%s' "$OUT" | jq -r '.envadded[]')
  while IFS=$'\t' read -r k have want; do
    [[ -n "$k" ]] || continue
    echo "$ME: ${d#"$CONSUMER"/}: env.$k: client value $have, declared value $want; the client's value stays" >&2
    case " ${ENV_CONFLICTS[*]:-} " in *" $k "*) ;; *) ENV_CONFLICTS+=("$k") ;; esac
    NCONF=$((NCONF + 1))
  done < <(printf '%s' "$OUT" | jq -r '.envconflicts[] | [.key, (.have | tojson), (.want | tojson)] | @tsv')
  while IFS= read -r ev; do
    [[ -n "$ev" ]] || continue
    case " ${ADDED_ALL[*]:-} " in *" $ev "*) ;; *) ADDED_ALL+=("$ev") ;; esac
  done < <(printf '%s' "$OUT" | jq -r '.added[]')
  while IFS= read -r ev; do
    [[ -n "$ev" ]] || continue
    echo "$ME: ${d#"$CONSUMER"/}: $ev already holds a worktree handler that is not Jenga's; Jenga's was not added" >&2
    case " ${CONFLICTS[*]:-} " in *" $ev "*) ;; *) CONFLICTS+=("$ev") ;; esac
    NCONF=$((NCONF + 1))
  done < <(printf '%s' "$OUT" | jq -r '.conflicts[]')
done

# --- permissions.allow: the opt-in (contract section 4) ---------------------------------------------------------------
# Pending rules per file: declared, and not already present in that file (a present rule is active and never rewritten).
PEND=(); NPEND=0
for i in 0 1; do
  d="${DESTS[$i]}"
  if [[ -f "$d" ]]; then PEND[$i]="$(jq -c --argjson a "$DALLOW" '(.permissions.allow // []) as $h | [$a[] | select(. as $r | $h | index([$r]) == null)]' "$d")"
  else PEND[$i]="$DALLOW"; fi
  NPEND=$((NPEND + $(printf '%s' "${PEND[$i]}" | jq 'length')))
done
ALLOW_ADDED=()   # "<index>\t<rule>" for every rule that is written (or would be, under --dry-run)
ALLOW_INACTIVE=()
show_diff() {   # the exact rules, one per line, per file named
  local i
  for i in 0 1; do
    [[ "$(printf '%s' "${PEND[$i]}" | jq 'length')" -gt 0 ]] || continue
    echo "--- ${DESTS[$i]#"$CONSUMER"/} (permissions.allow)"
    printf '%s' "${PEND[$i]}" | jq -r '.[] | "+ " + .'
  done
}
collect_pending() {   # prints "<index>\t<rule>" for every pending rule
  local i r
  for i in 0 1; do
    while IFS= read -r r; do [[ -z "$r" ]] || printf '%s\t%s\n' "$i" "$r"; done < <(printf '%s' "${PEND[$i]}" | jq -r '.[]')
  done
}
# ask_yes <header> <diff function> <prompt>: returns 0 only for an explicit yes typed on the terminal. The answer comes from
# the terminal only, never from stdin, a flag or the environment.
ask_yes() {
  local can=0 ans=""
  if [[ $INTERACTIVE -eq 1 && -t 0 ]] && (exec </dev/tty) 2>/dev/null; then can=1; fi
  if [[ $can -eq 1 ]]; then
    { echo "$ME: $1"; "$2"; printf '%s' "$3"; } > /dev/tty 2>/dev/null || can=0
    [[ $can -eq 0 ]] || IFS= read -r ans < /dev/tty 2>/dev/null || ans=""
  fi
  ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  [[ $can -eq 1 && ( "$ans" == "y" || "$ans" == "yes" ) ]]
}
ACTIVATE="bash $SCRIPT_DIR/$ME --consumer-root $CONSUMER --interactive"
if [[ $NPEND -gt 0 ]]; then
  if [[ $DRY -eq 1 ]]; then
    show_diff
    while IFS= read -r l; do ALLOW_ADDED+=("$l"); done < <(collect_pending)
  elif ask_yes "these permissions.allow rules widen the client's permissions. Exact diff:" show_diff \
      'Add them? Only "yes" or "y" writes them [y/N] '; then
    while IFS= read -r l; do ALLOW_ADDED+=("$l"); done < <(collect_pending)
  else
    while IFS= read -r l; do ALLOW_INACTIVE+=("$l"); done < <(collect_pending)
  fi
fi
# Fold the approved allow rules into the computed settings, only for the rules that were in the diff shown.
for r in "${ALLOW_ADDED[@]:-}"; do
  [[ -n "$r" ]] || continue
  i="${r%%$'\t'*}"
  OUTS[$i]="$(printf '%s' "${OUTS[$i]}" | jq --arg r "${r#*$'\t'}" '.settings.permissions.allow = ((.settings.permissions.allow // []) + [$r]) | .allowadded += [$r]
    | .addedent += [{keyClass: "allow", path: "permissions.allow", entry: $r}]')"
done

rm_allow_diff() {
  local l i r last=""
  for l in "${RM_ALLOW_PENDING[@]}"; do
    i="${l%%$'\t'*}"; r="${l#*$'\t'}"
    [[ "$last" == "$i" ]] || echo "--- ${DESTS[$i]#"$CONSUMER"/} (permissions.allow)"
    last="$i"; echo "- $r"
  done
}
RM_ALLOW_OK=(); RM_ALLOW_STAY=()
if [[ ${#RM_ALLOW_PENDING[@]} -gt 0 ]]; then
  if [[ $DRY -eq 1 ]]; then rm_allow_diff; RM_ALLOW_OK=("${RM_ALLOW_PENDING[@]}")
  elif ask_yes "these permissions.allow rules are no longer declared and Jenga wrote them. Exact diff:" rm_allow_diff \
      'Remove them? Only "yes" or "y" removes them [y/N] '; then RM_ALLOW_OK=("${RM_ALLOW_PENDING[@]}")
  else RM_ALLOW_STAY=("${RM_ALLOW_PENDING[@]}"); fi
fi
for l in "${RM_ALLOW_OK[@]:-}"; do
  [[ -n "$l" ]] || continue
  i="${l%%$'\t'*}"; r="${l#*$'\t'}"
  RMREC[$i]="$(printf '%s' "${RMREC[$i]}" | jq -c --arg r "$r" '. + [{keyClass: "allow", path: "permissions.allow", entry: $r}]')"
  DROPREC[$i]="$(printf '%s' "${DROPREC[$i]}" | jq -c --arg r "$r" '. + [{keyClass: "allow", path: "permissions.allow", entry: $r}]')"
done

REMOVED_LINES=()
for i in 0 1; do
  [[ "${NRM0[$i]}" -eq 0 ]] || while IFS= read -r l; do [[ -z "$l" ]] || REMOVED_LINES+=("$l"); done \
    < <(printf '%s' "${RMREC[$i]}" | jq -r '.[] | select(.keyClass != "allow") | if .keyClass == "env" then "env " + .entry.key else .path end')
done
for l in "${RM_ALLOW_OK[@]:-}"; do
  [[ -n "$l" ]] || continue
  i="${l%%$'\t'*}"; r="${l#*$'\t'}"
  OUTS[$i]="$(printf '%s' "${OUTS[$i]}" | jq --arg r "$r" '.settings.permissions.allow |= map(select(. != $r)) | .removed += 1
    | if (.settings.permissions.allow | length) == 0 then del(.settings.permissions.allow) else . end
    | if (.settings.permissions | length) == 0 then del(.settings.permissions) else . end')"
  REMOVED_LINES+=("allow $r")
done
# --- write ----------------------------------------------------------------------------------------------------------
# A manifest is rewritten only when its content changes, so a second run stays byte-identical.
sha_id() {
  if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  else printf '%s' "$1" | openssl dgst -sha256 | sed 's/^.* //'; fi
}
NORM='def norm: if type == "object" then (to_entries | sort_by(.key) | map({(.key): (.value | norm)}) | add // {})
  elif type == "array" then map(norm) else . end;'
# Prints the manifest content for file i, or nothing when no manifest should be written.
build_manifest() {
  local i="$1" rel="${DESTS[$1]#"$CONSUMER"/}" recs ids="[]" line n=0 id
  recs="$(printf '%s' "${OUTS[$i]}" | jq -c --argjson decl "$DECLENT" '[(.addedent // [])[] | . as $a
    | $a + {fragment: ($decl | map(select(.keyClass == $a.keyClass and .path == $a.path and .entry == $a.entry)) | (.[0].fragment // "unknown"))}]')"
  n="$(printf '%s' "$recs" | jq 'length')"
  if [[ "$n" -gt 0 ]]; then
    while IFS= read -r line; do ids="$(printf '%s' "$ids" | jq -c --arg id "sha256:$(sha_id "$line")" '. + [$id]')"; done \
      < <(printf '%s' "$recs" | jq -r "$NORM"' .[] | (.entry | norm | tojson)')
  fi
  jq -n --arg file "$rel" --arg ver "$JENGA_VERSION" --argjson old "${MREC[$i]}" --argjson drop "${DROPREC[$i]}" \
    --argjson recs "$recs" --argjson ids "$ids" --arg had "${MSTATE[$i]}" "$NORM"'
    ($old | map(select(. as $o | ($drop | any(.keyClass == $o.keyClass and .path == $o.path and .entry == $o.entry)) | not))) as $kept
    | [range(0; $recs | length) | $recs[.] + {id: $ids[.]}
        | {keyClass, path, id, fragment, jengaVersion: $ver, entry: (.entry | norm)}] as $new
    | ($new | map(.id)) as $newids
    | ($kept | map(select(.id as $k | $newids | index([$k]) == null))) + $new as $all
    | if ($all | length) == 0 and $had != "ok" then empty
      else {manifestVersion: 1, file: $file, entries: $all} end'
}
NCHANGED=0
for i in 0 1; do
  [[ "$(printf '%s' "${OUTS[$i]}" | jq '(.added | length) + (.envadded | length) + (.allowadded // [] | length) + (.removed // 0)')" -eq 0 ]] || NCHANGED=$((NCHANGED + 1))
  [[ "${MSTATE[$i]}" != "ok" || "$(printf '%s' "${DROPREC[$i]}" | jq 'length')" -eq 0 ]] || NCHANGED=$((NCHANGED + 1))
done
if [[ $DRY -eq 1 ]]; then
  for ev in "${ADDED_ALL[@]:-}"; do [[ -z "$ev" ]] || echo "would add $ev"; done
  for k in "${ENV_ADDED[@]:-}"; do [[ -z "$k" ]] || echo "would add env $k"; done
  while IFS= read -r r; do [[ -z "$r" ]] || echo "would add allow $r"; done < <(for r in "${ALLOW_ADDED[@]:-}"; do [[ -z "$r" ]] || printf '%s\n' "${r#*$'\t'}"; done | awk '!s[$0]++')
  while IFS= read -r l; do [[ -z "$l" ]] || echo "would remove $l"; done < <(printf '%s\n' "${REMOVED_LINES[@]:-}" | awk '!s[$0]++')
  [[ $NCHANGED -gt 0 || ${#ADDED_ALL[@]} -gt 0 || ${#ENV_ADDED[@]} -gt 0 || ${#ALLOW_ADDED[@]} -gt 0 ]] || echo "unchanged"
else
  TMP=""; trap '[[ -z "$TMP" ]] || rm -f "$TMP"' EXIT
  for i in 0 1; do
    d="${DESTS[$i]}"; m="${MANIFESTS[$i]}"
    if [[ "$(printf '%s' "${OUTS[$i]}" | jq '(.added | length) + (.envadded | length) + (.allowadded // [] | length) + (.removed // 0)')" -gt 0 ]]; then
      mkdir -p "$(dirname "$d")" || { echo "$ME: could not create $(dirname "$d")" >&2; exit 5; }
      TMP="$d.tmp.$$"
      if ! printf '%s' "${OUTS[$i]}" | jq '.settings' > "$TMP" || ! mv "$TMP" "$d"; then
        echo "$ME: could not write $d" >&2; exit 5
      fi
      TMP=""
      # Re-read and parse the file before anything is recorded about it.
      jq -e 'type == "object"' "$d" >/dev/null 2>&1 || { echo "$ME: $d could not be read back after writing; the manifest was not changed" >&2; exit 5; }
    fi
    [[ "${MSTATE[$i]}" != "corrupt" ]] || continue
    MAN="$(build_manifest "$i")" || { echo "$ME: could not build the manifest for $d" >&2; exit 5; }
    [[ -n "$MAN" ]] || continue
    if [[ -f "$m" ]] && [[ "$(printf '%s' "$MAN" | jq -c .)" == "$(jq -c . "$m")" ]]; then continue; fi
    mkdir -p "$(dirname "$m")" || { echo "$ME: could not create $(dirname "$m")" >&2; exit 5; }
    TMP="$m.tmp.$$"
    if ! printf '%s\n' "$MAN" | jq . > "$TMP" || ! mv "$TMP" "$m"; then echo "$ME: could not write $m" >&2; exit 5; fi
    TMP=""
  done
  for ev in "${ADDED_ALL[@]:-}"; do [[ -z "$ev" ]] || echo "added $ev"; done
  for k in "${ENV_ADDED[@]:-}"; do [[ -z "$k" ]] || echo "added env $k"; done
  while IFS= read -r r; do [[ -z "$r" ]] || echo "added allow $r"; done < <(for r in "${ALLOW_ADDED[@]:-}"; do [[ -z "$r" ]] || printf '%s\n' "${r#*$'\t'}"; done | awk '!s[$0]++')
  while IFS= read -r l; do [[ -z "$l" ]] || echo "removed $l"; done < <(printf '%s\n' "${REMOVED_LINES[@]:-}" | awk '!s[$0]++')
  [[ $NCHANGED -gt 0 || ${#ADDED_ALL[@]} -gt 0 || ${#ENV_ADDED[@]} -gt 0 || ${#ALLOW_ADDED[@]} -gt 0 ]] || echo "unchanged"
fi
if [[ ${#RM_ALLOW_STAY[@]} -gt 0 ]]; then
  for l in "${RM_ALLOW_STAY[@]}"; do echo "still present allow ${l#*$'\t'}"; done
  echo "to remove: $ACTIVATE"
fi
if [[ ${#ALLOW_INACTIVE[@]} -gt 0 ]]; then
  while IFS= read -r r; do echo "inactive allow $r"; done < <(for r in "${ALLOW_INACTIVE[@]}"; do printf '%s\n' "${r#*$'\t'}"; done | awk '!s[$0]++')
  echo "to activate: $ACTIVATE"
fi
if [[ $NCONF -gt 0 || ${#ALLOW_INACTIVE[@]} -gt 0 ]]; then
  for ev in "${CONFLICTS[@]:-}"; do [[ -z "$ev" ]] || echo "conflict hooks.$ev"; done
  for k in "${ENV_CONFLICTS[@]:-}"; do [[ -z "$k" ]] || echo "conflict env.$k"; done
  [[ $NCONF -eq 0 ]] || echo "$NCONF conflict(s); the requirement is inactive"
  exit 6
fi
exit 0
