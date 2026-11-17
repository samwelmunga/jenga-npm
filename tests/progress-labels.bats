#!/usr/bin/env bats
#
# E92_S02_T01: scripts/lib/progress-labels.sh - the sv/en label table, progress_label and progress_lang.
# Default language is en (confirmed by the user 2026-11-12); sv is selected with JENGA_PROGRESS_LANG=sv.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LIB="$REPO/scripts/lib/progress-labels.sh"
  unset JENGA_PROGRESS_LANG
}

# Runs a snippet in a fresh bash with the library sourced.
run_lib() { # <snippet>
  run bash -c ". '$LIB'; $1"
}

@test "sourcing prints nothing" {
  run bash -c ". '$LIB'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sourcing does not change shell options" {
  run bash -c 'before="$(set +o; shopt -p)"; . "$1"; after="$(set +o; shopt -p)"; [ "$before" = "$after" ]' _ "$LIB"
  [ "$status" -eq 0 ]
}

@test "the library file is valid UTF-8 and parses under bash -n" {
  run bash -n "$LIB"
  [ "$status" -eq 0 ]
  run python3 -c 'import sys; open(sys.argv[1], encoding="utf-8").read()' "$LIB"
  [ "$status" -eq 0 ]
}

@test "progress_label in_progress sv prints pågår" {
  run_lib 'progress_label in_progress sv'
  [ "$status" -eq 0 ]
  [ "$output" = "pågår" ]
}

@test "progress_label rejected_note sv prints the format string with %d" {
  run_lib 'progress_label rejected_note sv'
  [ "$status" -eq 0 ]
  [ "$output" = "⊘ %d avvisade (ej räknade)" ]
}

@test "sv labels for the remaining keys" {
  run_lib 'progress_label failed sv'
  [ "$output" = "röd" ]
  run_lib 'progress_label unknown sv'
  [ "$output" = "okända" ]
  run_lib 'progress_label nothing sv'
  [ "$output" = "inget att räkna" ]
}

@test "en labels for every key" {
  run_lib 'progress_label in_progress en'
  [ "$output" = "in progress" ]
  run_lib 'progress_label failed en'
  [ "$output" = "red" ]
  run_lib 'progress_label rejected_note en'
  [ "$output" = "⊘ %d rejected (not counted)" ]
  run_lib 'progress_label unknown en'
  [ "$output" = "unknown" ]
  run_lib 'progress_label nothing en'
  [ "$output" = "nothing to count" ]
}

@test "rejected_note is usable as a printf format in both languages" {
  run_lib 'printf "$(progress_label rejected_note sv)\n" 3; printf "$(progress_label rejected_note en)\n" 2'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "⊘ 3 avvisade (ej räknade)" ]
  [ "${lines[1]}" = "⊘ 2 rejected (not counted)" ]
}

@test "unknown key exits non-zero with empty stdout" {
  run_lib 'out="$(progress_label no_such_key en)"; rc=$?; [ -z "$out" ] && exit $rc'
  [ "$status" -ne 0 ]
  run_lib 'progress_label no_such_key'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "unknown language exits non-zero with empty stdout" {
  run_lib 'progress_label in_progress fr'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run_lib 'progress_label in_progress ""'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "missing key exits non-zero with empty stdout" {
  run_lib 'progress_label'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "progress_lang defaults to en when JENGA_PROGRESS_LANG is unset" {
  run_lib 'progress_lang'
  [ "$status" -eq 0 ]
  [ "$output" = "en" ]
}

@test "progress_lang defaults to en for an unshipped or malformed language" {
  for v in fr "" SV " sv" "sv " xx; do
    JENGA_PROGRESS_LANG="$v" run_lib 'progress_lang'
    [ "$status" -eq 0 ]
    [ "$output" = "en" ]
  done
}

@test "progress_lang returns sv and en when named" {
  JENGA_PROGRESS_LANG=sv run_lib 'progress_lang'
  [ "$output" = "sv" ]
  JENGA_PROGRESS_LANG=en run_lib 'progress_lang'
  [ "$output" = "en" ]
}

@test "progress_label without a language uses the default (en) and honours JENGA_PROGRESS_LANG=sv" {
  run_lib 'progress_label in_progress'
  [ "$output" = "in progress" ]
  JENGA_PROGRESS_LANG=sv run_lib 'progress_label in_progress'
  [ "$output" = "pågår" ]
  JENGA_PROGRESS_LANG=fr run_lib 'progress_label in_progress'
  [ "$output" = "in progress" ]
}

@test "an explicit language argument wins over JENGA_PROGRESS_LANG" {
  JENGA_PROGRESS_LANG=sv run_lib 'progress_label in_progress en'
  [ "$output" = "in progress" ]
}

@test "every key exists in both languages" {
  run_lib '
    for k in $PROGRESS_LABEL_KEYS; do
      for l in $PROGRESS_LABEL_LANGS; do
        out="$(progress_label "$k" "$l")" || { echo "missing $l:$k"; exit 1; }
        [ -n "$out" ] || { echo "empty $l:$k"; exit 1; }
      done
    done
    n=0; for k in $PROGRESS_LABEL_KEYS; do n=$((n+1)); done
    [ "$n" -ge 17 ]'
  [ "$status" -eq 0 ]
}

@test "the key list is complete: no key outside it resolves for sv" {
  run_lib '
    for l in $PROGRESS_LABEL_LANGS; do
      for k in in_progress failed rejected_note unknown nothing ready_to_take unlocked_by tree_title goal state_done state_ready state_locked state_failed state_rejected tree_empty nothing_ready card_bar_aria; do
        case " $PROGRESS_LABEL_KEYS " in *" $k "*) ;; *) echo "unlisted $k"; exit 1 ;; esac
      done
    done'
  [ "$status" -eq 0 ]
}

@test "the default language is en" {
  run_lib 'printf "%s" "$PROGRESS_LABEL_DEFAULT_LANG"'
  [ "$output" = "en" ]
}

@test "works under bash 3.2-style constructs: no associative arrays or case-modification expansions" {
  run grep -nE 'declare -A|\$\{[A-Za-z_]+(,,|\^\^)' "$LIB"
  [ "$status" -ne 0 ]
}

@test "E92_S06_T03: every listed key resolves and every table key is listed (lockstep)" {
  run_lib '
    for k in $PROGRESS_LABEL_KEYS; do progress_label "$k" en >/dev/null || { echo "dangling $k"; exit 1; }; done
    for k in $(grep -oE "^    en:[a-z_]+" "$LIB" | sed "s/.*://"); do
      case " $PROGRESS_LABEL_KEYS " in *" $k "*) ;; *) echo "unlisted $k"; exit 1 ;; esac
    done'
  [ "$status" -eq 0 ]
}

@test "E92_S06_T03: Swedish placeholders match English in number and order for every key" {
  run_lib '
    for k in $PROGRESS_LABEL_KEYS; do
      a="$(progress_label "$k" en | grep -oE "%[sd%]" | tr -d "\n")"
      b="$(progress_label "$k" sv | grep -oE "%[sd%]" | tr -d "\n")"
      [ "$a" = "$b" ] || { echo "mismatch $k: $a vs $b"; exit 1; }
    done'
  [ "$status" -eq 0 ]
}

@test "E92_S06_T03: unlocked_by and card_bar_aria stay raw format strings" {
  run_lib 'progress_label unlocked_by en; progress_label card_bar_aria sv'
  [ "${lines[0]}" = "%s unlocked by %s" ]
  # E92_S09_T04: the card percent is the epic percent (epic_progress), no longer a task share, so the words changed.
  [ "${lines[1]}" = "%d av %d berättelser klara, %d%% av epicen klar" ]
  run_lib 'printf "$(progress_label card_bar_aria en)\n" 2 5 40'
  [ "$output" = "2 of 5 stories complete, 40% of the epic done" ]
}

@test "E92_S06_T03: exporter prints valid JSON with lang and one entry per key" {
  run bash "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys,subprocess
d=json.load(sys.stdin)
assert d["lang"]=="en"
keys=subprocess.check_output(["bash","-c",". "+sys.argv[1]+"; echo $PROGRESS_LABEL_KEYS"]).decode().split()
assert list(d["labels"].keys())==keys
assert d["labels"]["unlocked_by"]=="%s unlocked by %s"' "$LIB"
}

@test "E92_S06_T03: exporter honours JENGA_PROGRESS_LANG=sv and falls back to en" {
  JENGA_PROGRESS_LANG=sv run bash "$REPO/scripts/progress-labels-json.sh"
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["lang"]=="sv" and d["labels"]["goal"]=="Mål"'
  JENGA_PROGRESS_LANG=zz run bash "$REPO/scripts/progress-labels-json.sh"
  echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["lang"]=="en" and d["labels"]["goal"]=="Goal"'
}

@test "E92_S06_T03: exporter escapes quote, backslash and control characters" {
  run bash -c '. "$1" --source-only; json_escape "a\"b\\c$(printf "\t")d"' _ "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  [ "$output" = 'a\"b\\c\td' ]
}

# E92_S06_T20: the dependency tree v2 labels (gate, group card, goal, tooltip), in English and Swedish.
T20_KEYS="gate_waiting gate_open group_tasks show_all collapse goal_reached goal_progress tip_depends_on tip_unlocks tip_goal_direct"

@test "E92_S06_T20: the tree v2 keys are listed once each, in both languages, with non-empty text" {
  run_lib '
    for k in '"$T20_KEYS"'; do
      c=0; for x in $PROGRESS_LABEL_KEYS; do [ "$x" = "$k" ] && c=$((c+1)); done
      [ "$c" -eq 1 ] || { echo "$k listed $c times"; exit 1; }
      for l in en sv; do
        out="$(progress_label "$k" "$l")" || { echo "missing $l:$k"; exit 1; }
        [ -n "$out" ] || { echo "empty $l:$k"; exit 1; }
      done
    done'
  [ "$status" -eq 0 ]
}

@test "E92_S06_T20: no key of the whole list is printed twice by the exporter, and the new keys reach the payload" {
  run bash "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,re,sys
raw=sys.stdin.read()
keys=re.findall(r"\"([a-z_]+)\":\"", raw.split("\"labels\":",1)[1])
assert len(keys)==len(set(keys)), "a key is printed twice"
d=json.loads(raw)["labels"]
for k in sys.argv[1].split():
    assert k in d and d[k], k
assert d["gate_open"]=="Dependency done (unlocked)" and d["goal_reached"]=="Goal reached!" and d["collapse"]=="Collapse"' "$T20_KEYS"
}

@test "E92_S06_T20: the Swedish exporter output carries the Swedish tree words" {
  JENGA_PROGRESS_LANG=sv run bash "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)["labels"]
assert d["gate_waiting"]=="Väntar på beroende (låst)" and d["gate_open"]=="Beroendet är klart (upplåst)"
assert d["collapse"]=="Fäll ihop" and d["goal_reached"]=="Mål nått!" and d["tip_goal_direct"]=="Leder direkt till målet"
assert d["tip_depends_on"]=="Beror på" and d["tip_unlocks"]=="Låser upp"'
}

@test "E92_S06_T20: group_tasks, show_all and goal_progress are printf formats that fill the same way in both languages" {
  run_lib 'printf "$(progress_label group_tasks en)|$(progress_label show_all en)|$(progress_label goal_progress en)\n" 6 6 3 7 43'
  [ "$output" = "6 tasks|Show all 6|3 / 7 done · 43 %" ]
  run_lib 'printf "$(progress_label group_tasks sv)|$(progress_label show_all sv)|$(progress_label goal_progress sv)\n" 6 6 3 7 43'
  [ "$output" = "6 uppgifter|Visa alla 6|3 / 7 klara · 43 %" ]
}

# E92_S06_T21: the overlay tree zoom controls and the dashboard Animations toggle labels, in English and Swedish.
T21_KEYS="zoom_group zoom_out zoom_in zoom_fit zoom_actual zoom_percent zoom_hint motion_label motion_auto motion_off motion_activate motion_os_reduced"

@test "E92_S06_T21: the zoom and motion keys are listed once each, in both languages, with non-empty text" {
  run_lib '
    for k in '"$T21_KEYS"'; do
      c=0; for x in $PROGRESS_LABEL_KEYS; do [ "$x" = "$k" ] && c=$((c+1)); done
      [ "$c" -eq 1 ] || { echo "$k listed $c times"; exit 1; }
      for l in en sv; do
        out="$(progress_label "$k" "$l")" || { echo "missing $l:$k"; exit 1; }
        [ -n "$out" ] || { echo "empty $l:$k"; exit 1; }
      done
    done'
  [ "$status" -eq 0 ]
}

@test "E92_S06_T21: the exporter carries the new keys, once each, in English and in Swedish" {
  run bash "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,re,sys
raw=sys.stdin.read()
keys=re.findall(r"\"([a-z_]+)\":\"", raw.split("\"labels\":",1)[1])
assert len(keys)==len(set(keys)), "a key is printed twice"
d=json.loads(raw)["labels"]
for k in sys.argv[1].split():
    assert k in d and d[k], k
assert d["motion_label"]=="Animations" and d["motion_auto"]=="Auto" and d["motion_off"]=="Off" and d["zoom_out"]=="Zoom out"' "$T21_KEYS"
  JENGA_PROGRESS_LANG=sv run bash "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)["labels"]
assert d["motion_label"]=="Animationer" and d["motion_off"]=="Av" and d["zoom_in"]=="Zooma in" and d["zoom_fit"]=="Anpassa"'
}

@test "E92_S06_T21: zoom_percent and motion_activate are printf formats that fill the same way in both languages" {
  run_lib 'printf "$(progress_label zoom_percent en)|$(progress_label motion_activate en)\n" 125 Off'
  [ "$output" = "125 %|Activate to switch to Off." ]
  run_lib 'printf "$(progress_label zoom_percent sv)|$(progress_label motion_activate sv)\n" 125 Av'
  [ "$output" = "125 %|Aktivera för att byta till Av." ]
}

# E92_S07_T02: the fullscreen button labels of the dependency tree view, in English and Swedish.
S07_T02_KEYS="fullscreen_enter fullscreen_exit fullscreen_hint fullscreen_layer"

@test "E92_S07_T02: the fullscreen keys are listed once each, in both languages, with the exact words" {
  run_lib '
    for k in '"$S07_T02_KEYS"'; do
      c=0; for x in $PROGRESS_LABEL_KEYS; do [ "$x" = "$k" ] && c=$((c+1)); done
      [ "$c" -eq 1 ] || { echo "$k listed $c times"; exit 1; }
      for l in en sv; do
        out="$(progress_label "$k" "$l")" || { echo "missing $l:$k"; exit 1; }
        [ -n "$out" ] || { echo "empty $l:$k"; exit 1; }
      done
    done
    [ "$(progress_label fullscreen_enter en)" = "Show full screen" ]
    [ "$(progress_label fullscreen_exit en)" = "Exit full screen" ]
    [ "$(progress_label fullscreen_hint en)" = "Press Esc to exit" ]
    [ "$(progress_label fullscreen_layer en)" = "Dependency tree, full screen" ]
    [ "$(progress_label fullscreen_enter sv)" = "Visa i helskärm" ]
    [ "$(progress_label fullscreen_exit sv)" = "Avsluta helskärm" ]
    [ "$(progress_label fullscreen_hint sv)" = "Tryck Esc för att avsluta" ]
    [ "$(progress_label fullscreen_layer sv)" = "Beroendeträd i helskärm" ]'
  [ "$status" -eq 0 ]
}

@test "E92_S07_T02: fullscreen_enter and fullscreen_exit differ in both languages" {
  run_lib '
    for l in en sv; do
      [ "$(progress_label fullscreen_enter "$l")" != "$(progress_label fullscreen_exit "$l")" ] || { echo "same in $l"; exit 1; }
    done'
  [ "$status" -eq 0 ]
}

@test "E92_S07_T02: the exporter carries the fullscreen keys, once each, in English and in Swedish" {
  run bash "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,re,sys
raw=sys.stdin.read()
keys=re.findall(r"\"([a-z_]+)\":\"", raw.split("\"labels\":",1)[1])
assert len(keys)==len(set(keys)), "a key is printed twice"
d=json.loads(raw)["labels"]
for k in sys.argv[1].split():
    assert k in d and d[k], k
assert d["fullscreen_enter"]=="Show full screen" and d["fullscreen_exit"]=="Exit full screen"
assert d["fullscreen_hint"]=="Press Esc to exit" and d["fullscreen_layer"]=="Dependency tree, full screen"' "$S07_T02_KEYS"
  JENGA_PROGRESS_LANG=sv run bash "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)["labels"]
assert d["fullscreen_enter"]=="Visa i helskärm" and d["fullscreen_exit"]=="Avsluta helskärm"
assert d["fullscreen_hint"]=="Tryck Esc för att avsluta" and d["fullscreen_layer"]=="Beroendeträd i helskärm"'
}

# E92_S10_T02: the goal line that names a failed story (no goal while a story of the epic has failed), English and Swedish.
T02_FAILED_KEYS="goal_failed goal_failed_more"

@test "E92_S10_T02: goal_failed and goal_failed_more are listed once each, in both languages, and reach the exporter" {
  run_lib '
    for k in '"$T02_FAILED_KEYS"'; do
      c=0; for x in $PROGRESS_LABEL_KEYS; do [ "$x" = "$k" ] && c=$((c+1)); done
      [ "$c" -eq 1 ] || { echo "$k listed $c times"; exit 1; }
      for l in en sv; do
        out="$(progress_label "$k" "$l")" || { echo "missing $l:$k"; exit 1; }
        [ -n "$out" ] || { echo "empty $l:$k"; exit 1; }
      done
    done'
  [ "$status" -eq 0 ]
  run bash "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)["labels"]
assert d["goal_failed"]=="Goal not reached - %s has failed", d["goal_failed"]
assert d["goal_failed_more"]=="Goal not reached - %s and %d more have failed", d["goal_failed_more"]'
  JENGA_PROGRESS_LANG=sv run bash "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)["labels"]
assert d["goal_failed"]=="Målet ej nått - %s har misslyckats", d["goal_failed"]
assert d["goal_failed_more"]=="Målet ej nått - %s och %d till har misslyckats", d["goal_failed_more"]'
}

@test "E92_S10_T02: goal_failed and goal_failed_more fill the same way (%s then %d) in both languages" {
  run_lib 'printf "$(progress_label goal_failed en)|$(progress_label goal_failed_more en)\n" E92_S08 E92_S08 2'
  [ "$output" = "Goal not reached - E92_S08 has failed|Goal not reached - E92_S08 and 2 more have failed" ]
  run_lib 'printf "$(progress_label goal_failed sv)|$(progress_label goal_failed_more sv)\n" E92_S08 E92_S08 2'
  [ "$output" = "Målet ej nått - E92_S08 har misslyckats|Målet ej nått - E92_S08 och 2 till har misslyckats" ]
}

# E92_S11_T02: the words of the "?" mark on a done task whose dependency is not done, English and Swedish. They use " - "
# (not an en dash) as goal_failed does, so --charset ascii keeps them readable. The dashboard's fallback words in
# DependencyTree.jsx must be the English ones.
T02_UNFINISHED_KEYS="dep_unfinished dep_unfinished_more"

@test "E92_S11_T02: dep_unfinished and dep_unfinished_more are listed once each, in both languages, and reach the exporter" {
  run_lib '
    for k in '"$T02_UNFINISHED_KEYS"'; do
      c=0; for x in $PROGRESS_LABEL_KEYS; do [ "$x" = "$k" ] && c=$((c+1)); done
      [ "$c" -eq 1 ] || { echo "$k listed $c times"; exit 1; }
      for l in en sv; do
        out="$(progress_label "$k" "$l")" || { echo "missing $l:$k"; exit 1; }
        [ -n "$out" ] || { echo "empty $l:$k"; exit 1; }
      done
    done'
  [ "$status" -eq 0 ]
  run bash "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)["labels"]
assert d["dep_unfinished"]=="Done although dependency %s is not done - check the dependency", d["dep_unfinished"]
assert d["dep_unfinished_more"]=="Done although dependency %s and %d more are not done - check the dependencies", d["dep_unfinished_more"]'
  JENGA_PROGRESS_LANG=sv run bash "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)["labels"]
assert d["dep_unfinished"]=="Klar trots att beroendet %s inte är klart - kontrollera beroendet", d["dep_unfinished"]
assert d["dep_unfinished_more"]=="Klar trots att beroendet %s och %d till inte är klara - kontrollera beroendena", d["dep_unfinished_more"]'
}

@test "E92_S11_T02: dep_unfinished fills %s, dep_unfinished_more %s then %d, in both languages; the JSX fallback words match en" {
  run_lib 'printf "$(progress_label dep_unfinished en)|$(progress_label dep_unfinished_more en)\n" E01_S01_T02 E01_S01_T02 1'
  [ "$output" = "Done although dependency E01_S01_T02 is not done - check the dependency|Done although dependency E01_S01_T02 and 1 more are not done - check the dependencies" ]
  run_lib 'printf "$(progress_label dep_unfinished sv)|$(progress_label dep_unfinished_more sv)\n" E01_S01 E01_S01 2'
  [ "$output" = "Klar trots att beroendet E01_S01 inte är klart - kontrollera beroendet|Klar trots att beroendet E01_S01 och 2 till inte är klara - kontrollera beroendena" ]
  JSX="$REPO/project/app/ui/src/components/progress/DependencyTree.jsx"
  [ -f "$JSX" ] || skip "the dashboard sources are not part of a consumer install"
  for k in $T02_UNFINISHED_KEYS; do
    run_lib "progress_label $k en"
    grep -qF "  $k: '$output'," "$JSX" || { echo "fallback of $k does not match: $output"; false; }
  done
}

# E92_S12_T03: the node text and the aria sentence of a story that has no tasks yet on the epic progress map, English and
# Swedish. Both are read by DependencyTree.jsx through optLabel: there is no English fallback word in the JSX, so a payload
# without them draws the dashed outline and omits the text.
S12_T03_KEYS="story_undecomposed story_undecomposed_aria"

@test "E92_S12_T03: story_undecomposed and story_undecomposed_aria are listed once each, last, in both languages" {
  run_lib '
    for k in '"$S12_T03_KEYS"'; do
      c=0; for x in $PROGRESS_LABEL_KEYS; do [ "$x" = "$k" ] && c=$((c+1)); done
      [ "$c" -eq 1 ] || { echo "$k listed $c times"; exit 1; }
      for l in en sv; do
        out="$(progress_label "$k" "$l")" || { echo "missing $l:$k"; exit 1; }
        [ -n "$out" ] || { echo "empty $l:$k"; exit 1; }
      done
    done
    set -- $PROGRESS_LABEL_KEYS
    eval "a=\${$(($# - 1))} b=\${$#}"
    [ "$a $b" = "story_undecomposed story_undecomposed_aria" ] || { echo "order: $a $b"; exit 1; }'
  [ "$status" -eq 0 ]
}

@test "E92_S12_T03: the two keys reach the exporter in the pinned order with the English and Swedish text" {
  run bash "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)["labels"]
keys=list(d.keys())
assert keys[-2:]==["story_undecomposed","story_undecomposed_aria"], keys[-3:]
assert d["story_undecomposed"]=="Not broken down yet", d["story_undecomposed"]
assert d["story_undecomposed_aria"]=="%s - not broken down into tasks yet", d["story_undecomposed_aria"]'
  JENGA_PROGRESS_LANG=sv run bash "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json,sys
d=json.load(sys.stdin)["labels"]
assert d["story_undecomposed"]=="Inte nedbruten ännu", d["story_undecomposed"]
assert d["story_undecomposed_aria"]=="%s - ännu inte nedbruten i uppgifter", d["story_undecomposed_aria"]'
}

@test "E92_S12_T03: story_undecomposed_aria fills one %s in both languages, and carries no other placeholder" {
  run_lib 'printf "$(progress_label story_undecomposed_aria en)|$(progress_label story_undecomposed_aria sv)\n" "E01_S02 Second" "E01_S02 Second"'
  [ "$output" = "E01_S02 Second - not broken down into tasks yet|E01_S02 Second - ännu inte nedbruten i uppgifter" ]
  run_lib 'progress_label story_undecomposed en; progress_label story_undecomposed sv'
  ! printf '%s' "$output" | grep -q '%'
}

@test "E92_S12_T03: the exporter keeps the two new texts intact through JSON escaping (quote, backslash)" {
  run bash -c '. "$1" --source-only; json_escape "$(progress_label story_undecomposed_aria en)"; printf "|"; json_escape "a\"b\\c"' _ "$REPO/scripts/progress-labels-json.sh"
  [ "$status" -eq 0 ]
  [ "$output" = '%s - not broken down into tasks yet|a\"b\\c' ]
}
