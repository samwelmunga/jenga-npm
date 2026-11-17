# shellcheck shell=bash
# scripts/lib/progress-labels.sh - the label table for the terminal progress bar (epic E92, task E92_S02_T01).
#
# Source this file; do not execute it. bash 3.2 compatible. Sourcing prints nothing, sets no shell options and runs
# no command. This file is UTF-8: the Swedish and symbol strings are not ASCII.
#
# Every user-visible word of the bar lives in the one table below, so switching language is a data change.
#
#   progress_label <key> [<lang>]   print the label for <key>; <lang> defaults to progress_lang. An unknown key or an
#                                   unknown language prints nothing and returns 1.
#   progress_lang                   print the effective language: JENGA_PROGRESS_LANG when it names a shipped
#                                   language, otherwise the default.
#
# Default language: en (confirmed by the user on 2026-11-12; this package is distributed to other projects).
# Swedish ships as well and is selected with JENGA_PROGRESS_LANG=sv. Changing the default is the one-word edit of
# PROGRESS_LABEL_DEFAULT_LANG below.
#
# rejected_note, unlocked_by and card_bar_aria are printf format strings and keep their % placeholders for the
# caller to fill in (card_bar_aria: %d of %d stories complete, %d%% of the epic done; the same three placeholders in
# the same order in every language). goal_failed (%s: the first failed story id) and goal_failed_more (%s: the first
# failed story id, %d: how many more) are filled the same way (E92_S10_T02), the placeholders in the same order in
# every language. So are dep_unfinished (%s: the unfinished dependency id) and dep_unfinished_more (%s: the first id, %d:
# how many more) (E92_S11_T02), the words of the "?" mark on a done task whose dependency is not done; they use " - ",
# not an en dash, as goal_failed does, so --charset ascii keeps them readable.

PROGRESS_LABEL_DEFAULT_LANG='en'
PROGRESS_LABEL_LANGS='sv en'
# shellcheck disable=SC2034  # read by callers and tests that source this library
PROGRESS_LABEL_KEYS='in_progress failed rejected_note unknown nothing ready_to_take unlocked_by tree_title goal state_done state_ready state_locked state_failed state_rejected tree_empty nothing_ready card_bar_aria'

# _progress_label_raw <lang> <key>: the table. Prints the label, or returns 1 for an unknown lang/key pair.
_progress_label_raw() {
  case "$1:$2" in
    sv:in_progress)   printf '%s\n' 'pågår' ;;
    sv:failed)        printf '%s\n' 'röd' ;;
    sv:rejected_note) printf '%s\n' '⊘ %d avvisade (ej räknade)' ;;
    sv:unknown)       printf '%s\n' 'okända' ;;
    sv:nothing)       printf '%s\n' 'inget att räkna' ;;
    sv:ready_to_take) printf '%s\n' 'Redo att ta' ;;
    sv:unlocked_by)   printf '%s\n' '%s upplåst av %s' ;;
    sv:tree_title)    printf '%s\n' 'Beroendeträd' ;;
    sv:goal)          printf '%s\n' 'Mål' ;;
    sv:state_done)    printf '%s\n' 'Klar' ;;
    sv:state_ready)   printf '%s\n' 'Redo' ;;
    sv:state_locked)  printf '%s\n' 'Låst' ;;
    sv:state_failed)  printf '%s\n' 'Misslyckad' ;;
    sv:state_rejected) printf '%s\n' 'Avvisad' ;;
    sv:tree_empty)    printf '%s\n' 'Inga uppgifter i detta omfång' ;;
    sv:nothing_ready) printf '%s\n' 'Inget är redo att ta just nu' ;;
    sv:card_bar_aria) printf '%s\n' '%d av %d berättelser klara, %d%% av epicen klar' ;;
    en:ready_to_take) printf '%s\n' 'Ready to take' ;;
    en:unlocked_by)   printf '%s\n' '%s unlocked by %s' ;;
    en:tree_title)    printf '%s\n' 'Dependency tree' ;;
    en:goal)          printf '%s\n' 'Goal' ;;
    en:state_done)    printf '%s\n' 'Done' ;;
    en:state_ready)   printf '%s\n' 'Ready' ;;
    en:state_locked)  printf '%s\n' 'Locked' ;;
    en:state_failed)  printf '%s\n' 'Failed' ;;
    en:state_rejected) printf '%s\n' 'Rejected' ;;
    en:tree_empty)    printf '%s\n' 'No tasks in this scope' ;;
    en:nothing_ready) printf '%s\n' 'Nothing is ready to take right now' ;;
    en:card_bar_aria) printf '%s\n' '%d of %d stories complete, %d%% of the epic done' ;;
    en:in_progress)   printf '%s\n' 'in progress' ;;
    en:failed)        printf '%s\n' 'red' ;;
    en:rejected_note) printf '%s\n' '⊘ %d rejected (not counted)' ;;
    en:unknown)       printf '%s\n' 'unknown' ;;
    en:nothing)       printf '%s\n' 'nothing to count' ;;
    # --- begin E92_S06_T24 (j.status overview renderer labels) ---
    sv:ov_board) printf '%s\n' 'Board' ;;
    sv:ov_epics) printf '%s\n' 'epics' ;;
    sv:ov_tasks) printf '%s\n' 'uppgifter' ;;
    sv:ov_pending) printf '%s\n' 'väntar' ;;
    sv:ov_group_attention) printf '%s\n' 'Behöver uppmärksamhet' ;;
    sv:ov_group_progress) printf '%s\n' 'Pågår' ;;
    sv:ov_group_started) printf '%s\n' 'Påbörjade' ;;
    sv:ov_group_notstarted) printf '%s\n' 'Ej påbörjade' ;;
    sv:ov_complete) printf '%s\n' 'Klara' ;;
    sv:ov_hidden) printf '%s\n' 'dolda' ;;
    sv:ov_rejected_empty) printf '%s\n' 'Bara avvisade eller tomma' ;;
    sv:ov_footer_scope) printf '%s\n' 'Detaljer för en epic: j.status <id>' ;;
    sv:ov_footer_all) printf '%s\n' 'alla rader: j.status --all' ;;
    en:ov_board) printf '%s\n' 'Board' ;;
    en:ov_epics) printf '%s\n' 'epics' ;;
    en:ov_tasks) printf '%s\n' 'tasks' ;;
    en:ov_pending) printf '%s\n' 'pending' ;;
    en:ov_group_attention) printf '%s\n' 'Needs attention' ;;
    en:ov_group_progress) printf '%s\n' 'In progress' ;;
    en:ov_group_started) printf '%s\n' 'Started' ;;
    en:ov_group_notstarted) printf '%s\n' 'Not started' ;;
    en:ov_complete) printf '%s\n' 'Complete' ;;
    en:ov_hidden) printf '%s\n' 'hidden' ;;
    en:ov_rejected_empty) printf '%s\n' 'Only rejected or empty' ;;
    en:ov_footer_scope) printf '%s\n' 'Details for one epic: j.status <id>' ;;
    en:ov_footer_all) printf '%s\n' 'all rows: j.status --all' ;;
    # --- end E92_S06_T24 ---
    # --- begin E92_S06_T23 (after-story line labels: the counts after the bar; "in progress" reuses in_progress) ---
    sv:sl_failed_one)  printf '%s\n' 'misslyckad' ;;
    sv:sl_failed_many) printf '%s\n' 'misslyckade' ;;
    sv:sl_ready)       printf '%s\n' 'redo' ;;
    sv:sl_rejected)    printf '%s\n' 'avvisade' ;;
    en:sl_failed_one)  printf '%s\n' 'failed' ;;
    en:sl_failed_many) printf '%s\n' 'failed' ;;
    en:sl_ready)       printf '%s\n' 'ready' ;;
    en:sl_rejected)    printf '%s\n' 'rejected' ;;
    # --- end E92_S06_T23 ---
    # --- begin E92_S06_T20 (dependency tree v2 labels: gate, group card, goal, tooltip) ---
    sv:gate_waiting) printf '%s\n' 'Väntar på beroende (låst)' ;;
    sv:gate_open) printf '%s\n' 'Beroendet är klart (upplåst)' ;;
    sv:group_tasks) printf '%s\n' '%d uppgifter' ;;
    sv:show_all) printf '%s\n' 'Visa alla %d' ;;
    sv:collapse) printf '%s\n' 'Fäll ihop' ;;
    sv:goal_reached) printf '%s\n' 'Mål nått!' ;;
    sv:goal_progress) printf '%s\n' '%d / %d klara · %d %%' ;;
    sv:tip_depends_on) printf '%s\n' 'Beror på' ;;
    sv:tip_unlocks) printf '%s\n' 'Låser upp' ;;
    sv:tip_goal_direct) printf '%s\n' 'Leder direkt till målet' ;;
    en:gate_waiting) printf '%s\n' 'Waiting for a dependency (locked)' ;;
    en:gate_open) printf '%s\n' 'Dependency done (unlocked)' ;;
    en:group_tasks) printf '%s\n' '%d tasks' ;;
    en:show_all) printf '%s\n' 'Show all %d' ;;
    en:collapse) printf '%s\n' 'Collapse' ;;
    en:goal_reached) printf '%s\n' 'Goal reached!' ;;
    en:goal_progress) printf '%s\n' '%d / %d done · %d %%' ;;
    en:tip_depends_on) printf '%s\n' 'Depends on' ;;
    en:tip_unlocks) printf '%s\n' 'Unlocks' ;;
    en:tip_goal_direct) printf '%s\n' 'Leads straight to the goal' ;;
    # --- end E92_S06_T20 ---
    # --- begin E92_S09_T04 (the epic percent: decomposed stories beside it, section 5.1) ---
    sv:epic_decomposed) printf '%s\n' '%d/%d berättelser nedbrutna' ;;
    en:epic_decomposed) printf '%s\n' '%d/%d stories decomposed' ;;
    # --- end E92_S09_T04 ---
    # --- begin E92_S10_T02 (no goal while a story of the epic has failed: the goal line names it) ---
    sv:goal_failed) printf '%s\n' 'Målet ej nått - %s har misslyckats' ;;
    sv:goal_failed_more) printf '%s\n' 'Målet ej nått - %s och %d till har misslyckats' ;;
    en:goal_failed) printf '%s\n' 'Goal not reached - %s has failed' ;;
    en:goal_failed_more) printf '%s\n' 'Goal not reached - %s and %d more have failed' ;;
    # --- end E92_S10_T02 ---
    # --- begin E92_S11_T02 (a done task whose dependency is not done: the "?" mark's words) ---
    sv:dep_unfinished) printf '%s\n' 'Klar trots att beroendet %s inte är klart - kontrollera beroendet' ;;
    sv:dep_unfinished_more) printf '%s\n' 'Klar trots att beroendet %s och %d till inte är klara - kontrollera beroendena' ;;
    en:dep_unfinished) printf '%s\n' 'Done although dependency %s is not done - check the dependency' ;;
    en:dep_unfinished_more) printf '%s\n' 'Done although dependency %s and %d more are not done - check the dependencies' ;;
    # --- end E92_S11_T02 ---
    # --- begin E92_S06_T25 (j.status scope renderer labels) ---
    sv:sc_hidden) printf '%s\n' '%d klara berättelser dolda, --all visar dem' ;;
    sv:sc_hidden_one) printf '%s\n' '%d klar berättelse dold, --all visar den' ;;
    sv:sc_msg_done) printf '%s\n' 'Målet är nått - snyggt jobbat!' ;;
    sv:sc_msg_last) printf '%s\n' 'Sista berättelsen - målet är i sikte!' ;;
    sv:sc_msg_almost) printf '%s\n' 'Nästan framme - %d berättelser kvar' ;;
    sv:sc_msg_half) printf '%s\n' 'Över halvvägs - %d berättelser kvar' ;;
    sv:sc_msg_going) printf '%s\n' 'Bra fart! %d berättelser kvar' ;;
    sv:sc_msg_start) printf '%s\n' 'Första steget är precis framför dig' ;;
    sv:sc_after) printf '%s\n' 'efter' ;;
    sv:sc_waits) printf '%s\n' 'väntar på' ;;
    sv:sc_unlocks_after) printf '%s\n' 'Låses upp efter' ;;
    sv:sc_no_stories) printf '%s\n' 'Inga berättelser i detta omfång' ;;
    en:sc_hidden) printf '%s\n' '%d complete stories hidden, --all shows them' ;;
    en:sc_hidden_one) printf '%s\n' '%d complete story hidden, --all shows it' ;;
    en:sc_msg_done) printf '%s\n' 'Goal reached - well done!' ;;
    en:sc_msg_last) printf '%s\n' 'Last story - the goal is in sight!' ;;
    en:sc_msg_almost) printf '%s\n' 'Almost there - %d stories left' ;;
    en:sc_msg_half) printf '%s\n' 'Past halfway - %d stories left' ;;
    en:sc_msg_going) printf '%s\n' 'Good pace! %d stories left' ;;
    en:sc_msg_start) printf '%s\n' 'The first step is just ahead' ;;
    en:sc_after) printf '%s\n' 'after' ;;
    en:sc_waits) printf '%s\n' 'waits for' ;;
    en:sc_unlocks_after) printf '%s\n' 'Unlocks after' ;;
    en:sc_no_stories) printf '%s\n' 'No stories in this scope' ;;
    # --- end E92_S06_T25 ---
    # --- begin E92_S06_T21 (overlay tree zoom controls and the dashboard Animations toggle labels) ---
    sv:zoom_group) printf '%s\n' 'Zoom' ;;
    sv:zoom_out) printf '%s\n' 'Zooma ut' ;;
    sv:zoom_in) printf '%s\n' 'Zooma in' ;;
    sv:zoom_fit) printf '%s\n' 'Anpassa' ;;
    sv:zoom_actual) printf '%s\n' 'Verklig storlek' ;;
    sv:zoom_percent) printf '%s\n' '%d %%' ;;
    sv:zoom_hint) printf '%s\n' 'Scrolla eller nyp för att zooma · dra för att panorera' ;;
    sv:motion_label) printf '%s\n' 'Animationer' ;;
    sv:motion_auto) printf '%s\n' 'Auto' ;;
    sv:motion_off) printf '%s\n' 'Av' ;;
    sv:motion_activate) printf '%s\n' 'Aktivera för att byta till %s.' ;;
    sv:motion_os_reduced) printf '%s\n' 'systemet: av' ;;
    en:zoom_group) printf '%s\n' 'Zoom' ;;
    en:zoom_out) printf '%s\n' 'Zoom out' ;;
    en:zoom_in) printf '%s\n' 'Zoom in' ;;
    en:zoom_fit) printf '%s\n' 'Fit' ;;
    en:zoom_actual) printf '%s\n' 'Actual size' ;;
    en:zoom_percent) printf '%s\n' '%d %%' ;;
    en:zoom_hint) printf '%s\n' 'Scroll or pinch to zoom · drag to pan' ;;
    en:motion_label) printf '%s\n' 'Animations' ;;
    en:motion_auto) printf '%s\n' 'Auto' ;;
    en:motion_off) printf '%s\n' 'Off' ;;
    en:motion_activate) printf '%s\n' 'Activate to switch to %s.' ;;
    en:motion_os_reduced) printf '%s\n' 'system: off' ;;
    # --- end E92_S06_T21 ---
    # --- begin E92_S07_T02 (fullscreen button labels of the dependency tree view) ---
    sv:fullscreen_enter) printf '%s\n' 'Visa i helskärm' ;;
    sv:fullscreen_exit) printf '%s\n' 'Avsluta helskärm' ;;
    sv:fullscreen_hint) printf '%s\n' 'Tryck Esc för att avsluta' ;;
    sv:fullscreen_layer) printf '%s\n' 'Beroendeträd i helskärm' ;;
    en:fullscreen_enter) printf '%s\n' 'Show full screen' ;;
    en:fullscreen_exit) printf '%s\n' 'Exit full screen' ;;
    en:fullscreen_hint) printf '%s\n' 'Press Esc to exit' ;;
    en:fullscreen_layer) printf '%s\n' 'Dependency tree, full screen' ;;
    # --- end E92_S07_T02 ---
    *) return 1 ;;
  esac
}

# progress_lang: the effective language. Exact match only (no case folding, no trimming).
progress_lang() {
  local l
  for l in $PROGRESS_LABEL_LANGS; do
    if [ "${JENGA_PROGRESS_LANG-}" = "$l" ]; then
      printf '%s\n' "$l"
      return 0
    fi
  done
  printf '%s\n' "$PROGRESS_LABEL_DEFAULT_LANG"
}

# progress_label <key> [<lang>]
progress_label() {
  local key="${1-}" lang
  if [ "$#" -ge 2 ]; then
    lang="$2"
  else
    lang="$(progress_lang)"
  fi
  [ -n "$key" ] && [ -n "$lang" ] || return 1
  _progress_label_raw "$lang" "$key"
}

# --- begin E92_S06_T24 (key list of the j.status overview renderer labels) ---
PROGRESS_LABEL_KEYS="$PROGRESS_LABEL_KEYS ov_board ov_epics ov_tasks ov_pending ov_group_attention ov_group_progress ov_group_started ov_group_notstarted ov_complete ov_hidden ov_rejected_empty ov_footer_scope ov_footer_all"
# --- end E92_S06_T24 ---
# --- begin E92_S06_T23 (key list of the after-story line labels) ---
PROGRESS_LABEL_KEYS="$PROGRESS_LABEL_KEYS sl_failed_one sl_failed_many sl_ready sl_rejected"
# --- end E92_S06_T23 ---
# --- begin E92_S06_T20 (key list of the dependency tree v2 labels) ---
PROGRESS_LABEL_KEYS="$PROGRESS_LABEL_KEYS gate_waiting gate_open group_tasks show_all collapse goal_reached goal_progress tip_depends_on tip_unlocks tip_goal_direct"
# --- end E92_S06_T20 ---

# --- begin E92_S06_T25 (key list of the j.status scope renderer labels) ---
PROGRESS_LABEL_KEYS="$PROGRESS_LABEL_KEYS sc_hidden sc_hidden_one sc_msg_done sc_msg_last sc_msg_almost sc_msg_half sc_msg_going sc_msg_start sc_after sc_waits sc_unlocks_after sc_no_stories"
# --- end E92_S06_T25 ---
# --- begin E92_S06_T21 (key list of the overlay tree zoom controls and the Animations toggle labels) ---
PROGRESS_LABEL_KEYS="$PROGRESS_LABEL_KEYS zoom_group zoom_out zoom_in zoom_fit zoom_actual zoom_percent zoom_hint motion_label motion_auto motion_off motion_activate motion_os_reduced"
# --- end E92_S06_T21 ---
# --- begin E92_S07_T02 (key list of the fullscreen button labels) ---
PROGRESS_LABEL_KEYS="$PROGRESS_LABEL_KEYS fullscreen_enter fullscreen_exit fullscreen_hint fullscreen_layer"
# --- end E92_S07_T02 ---
# --- begin E92_S09_T04 (key list of the epic percent label) ---
PROGRESS_LABEL_KEYS="$PROGRESS_LABEL_KEYS epic_decomposed"
# --- end E92_S09_T04 ---
# --- begin E92_S10_T02 (key list of the failed-story goal labels) ---
PROGRESS_LABEL_KEYS="$PROGRESS_LABEL_KEYS goal_failed goal_failed_more"
# --- end E92_S10_T02 ---
# --- begin E92_S11_T02 (key list of the done-before-dependency labels) ---
PROGRESS_LABEL_KEYS="$PROGRESS_LABEL_KEYS dep_unfinished dep_unfinished_more"
# --- end E92_S11_T02 ---
