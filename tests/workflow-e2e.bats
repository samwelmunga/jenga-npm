#!/usr/bin/env bats
#
# E80_S06_T04: end-to-end proof that the shipped workflow scripts, driven the way skills/j-workflow/SKILL.md drives
# them, run the example workflow and a workflow with all five step types.
#
# The test plays the agent. It calls only what the skill calls: run-state.sh start, then a loop of next-step.sh and
# complete-step.sh, plus step-confirm.sh reply for a gate. Every call goes through wf_fresh (tests/helpers/
# workflow-fixture.bash), one clean process per call, so no state travels between calls except what the run file holds.
#
#   1. Catalog           the example validates, the loader lists it, the skill's list sub-command reaches the loader
#   2. Example run       example-report on the fixture items file: compute, gate, compute, render, to completed
#   3. Five step types   all-step-types: compute, skill, confirm, playbook, compute, render, to completed
#   4. No skip-ahead     next-step.sh is idempotent for a pending step; complete-step.sh refuses a non-current step
#
# Isolation: wf_setup builds a throwaway tree under $BATS_TEST_TMPDIR; the repository is only read. No test here
# starts a nested bats or whole-suite run, so the nested-suite guard (tests/helpers/nested-suite.bash) is not needed.
#
# Mirror safety: wf_require / wf_setup skip, naming the path, when a file this suite needs is not in the tree.

bats_require_minimum_version 1.5.0

load helpers/assertions
load helpers/workflow-fixture

setup() { wf_setup; }

# need_example: the example workflow and its compute scripts are shipped by a sibling task; skip when absent.
need_example() {
  wf_require templates/workflows/example-report.json
  wf_require templates/workflows/example-report.md
  wf_require scripts/workflow/examples/example-report-select.sh
  wf_require scripts/workflow/examples/example-report-summarize.sh
  wf_require tests/fixtures/workflow/example-report/items.json
}

# jqe <json> <expression>: succeeds when the expression is true for the JSON, and shows both when it is not.
jqe() {
  printf '%s' "$1" | jq -e "$2" >/dev/null || { echo "json: $1"; echo "does not satisfy: $2"; return 1; }
}

# run_status <run id>: the run's status, read through run-state.sh status in its own process.
run_status() { wf_status "$1" | jq -r .status; }

# step_state <run id> <step id>: the step's status in the run file.
step_state() { wf_status "$1" | jq -r --arg s "$2" '.steps[] | select(.id == $s) | .status'; }

# step_statuses <run id>: every step's id and status on one line, to compare states before and after a call.
step_statuses() { wf_status "$1" | jq -c '[.run_id? // empty, .status, [.steps[] | [.id, .status]]]'; }

@test "1. catalog: the example validates, the loader lists it and the skill's list sub-command reaches the loader" {
  need_example
  wf_require skills/j-workflow/scripts/workflow-cli.sh

  run wf_fresh sess-a bash "$(wf_script validate-workflow.sh)" "$PROJ/templates/workflows/example-report.json"
  [ "$status" -eq 0 ]

  run wf_fresh sess-a bash "$(wf_script load-workflows.sh)"
  [ "$status" -eq 0 ]
  ids="$(printf '%s' "$output" | jq -r '.[].id')"
  assert_contains "$ids" "example-report"
  assert_contains "$ids" "all-step-types"

  run wf_fresh sess-a bash "$(wf_script load-workflows.sh)" lookup example-report
  [ "$status" -eq 0 ]
  jqe "$output" '.id == "example-report" and .source == "builtin"'

  # the skill's list sub-command is wired to the loader: it runs the CLI's list-render, and the CLI's default loader
  # is load-workflows.sh. The skill file is absent from a public-mirror tree, so skip with a reason there.
  wf_require skills/j-workflow/SKILL.md
  skill_text="$(cat "$WF_REPO_ROOT/skills/j-workflow/SKILL.md")"
  assert_contains "$skill_text" 'list-render'
  cli_text="$(cat "$WF_REPO_ROOT/skills/j-workflow/scripts/workflow-cli.sh")"
  assert_contains "$cli_text" 'default_script load-workflows.sh'
}

@test "2. example run: select, a gate answered in its own process, summarise and report end completed with the 3 ids" {
  need_example
  WF_ID=example-report
  items="$WF_FIXTURES/example-report/items.json"

  RUN="$(wf_start --input "source=$items")"
  [ -n "$RUN" ]
  [ "$(run_status "$RUN")" = "running" ]

  # select (compute) ran inside next-step.sh; the first action handed to the agent is the gate
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  jqe "$output" '.signal == "step" and .step_id == "approve" and .type == "confirm"'
  [ "$(step_state "$RUN" select)" = "completed" ]

  # the next call returns the persisted prompt and the run waits
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  jqe "$output" '.signal == "awaiting_confirmation" and .step_id == "approve"'
  jqe "$output" '.payload.prompt | contains("E90_S01_T01") and contains("E90_S02_T01") and contains("E90_S03_T01")'
  [ "$(run_status "$RUN")" = "awaiting_confirmation" ]

  # a separate invocation (a different session id) answers the gate
  WF_SESSION=sess-b
  run wf_reply "$RUN" approve 1
  [ "$status" -eq 0 ]
  jqe "$output" '.option == "Proceed"'

  # summarise (compute) and report (render) run inside the next call, which ends the run
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  jqe "$output" '.signal == "complete" and .payload.status == "completed"'
  [ "$(run_status "$RUN")" = "completed" ]

  ids_in_order="$(wf_status "$RUN" | jq -c '[.steps[] | [.id, .status]]')"
  [ "$ids_in_order" = '[["select","completed"],["approve","completed"],["summarise","completed"],["report","completed"]]' ]

  # the rendered artifact contains the three expected ids, and not the ones the compute step left out
  artifact_rel="$(wf_status "$RUN" | jq -r '.steps[] | select(.id == "report") | .outputs.report')"
  [ -n "$artifact_rel" ]
  artifact="$PROJ/project/data/workflow-artifacts/$artifact_rel"
  [ -f "$artifact" ]
  text="$(cat "$artifact")"
  assert_contains "$text" "E90_S01_T01"
  assert_contains "$text" "E90_S02_T01"
  assert_contains "$text" "E90_S03_T01"
  assert_not_contains "$text" "E90_S01_T02"
  assert_not_contains "$text" "E90_S02_T02"
}

@test "3. five step types: all six steps run in order, each action matches the definition, an invalid reply re-prompts" {
  WF_ID=all-step-types
  RUN="$(wf_start)"
  [ -n "$RUN" ]

  # prep (compute) runs inside next-step.sh; the first action is the skill step, carrying the stub skill name
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  jqe "$output" '.signal == "step" and .step_id == "ask_skill" and .type == "skill"'
  jqe "$output" '.payload.skill == "j.stub-step" and .payload.invoke_as == "j.stub-step"'
  jqe "$output" '.payload.args.scope == "E80_S06" and (.payload.args.ids | contains("E80_S06_T01"))'
  [ "$(step_state "$RUN" prep)" = "completed" ]

  # the agent reports the skill as passed
  run wf_complete "$RUN" ask_skill passed
  [ "$status" -eq 0 ]
  [ "$(step_state "$RUN" ask_skill)" = "completed" ]

  # the gate: dispatched as a step, then awaiting
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  jqe "$output" '.signal == "step" and .step_id == "gate" and .type == "confirm"'
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  jqe "$output" '.signal == "awaiting_confirmation" and .step_id == "gate"'
  jqe "$output" '.payload.prompt == "Publish the report for E80_S06?"'
  [ "$(run_status "$RUN")" = "awaiting_confirmation" ]

  # an invalid reply re-prompts (exit 3, the stored rendering) and changes nothing
  before="$(step_statuses "$RUN")"
  history_before="$(wf_status "$RUN" | jq -c '.history | length')"
  run wf_reply "$RUN" gate "not an option"
  [ "$status" -eq 3 ]
  assert_output_contains "Invalid reply"
  assert_output_contains "Publish the report for E80_S06?"
  assert_output_contains "1. Publish"
  [ "$(step_statuses "$RUN")" = "$before" ]
  [ "$(wf_status "$RUN" | jq -c '.history | length')" = "$history_before" ]
  [ "$(run_status "$RUN")" = "awaiting_confirmation" ]
  [ "$(step_state "$RUN" gate)" = "in_progress" ]

  # a complete-step report cannot answer a gate either
  run wf_complete "$RUN" gate passed
  [ "$status" -eq 1 ]
  [ "$(step_state "$RUN" gate)" = "in_progress" ]

  # the valid answer, in another process and session
  WF_SESSION=sess-b
  run wf_reply "$RUN" gate 1
  [ "$status" -eq 0 ]
  jqe "$output" '.option == "Publish"'
  [ "$(step_state "$RUN" gate)" = "completed" ]

  # the playbook step carries the stub playbook id that the playbook loader resolves
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  jqe "$output" '.signal == "step" and .step_id == "run_playbook" and .type == "playbook"'
  pb_id="$(printf '%s' "$output" | jq -r .payload.playbook_id)"
  [ "$pb_id" = "stub-playbook" ]
  run wf_fresh sess-b bash "$PROJ/skills/jenga/scripts/load-playbooks.sh" lookup "$pb_id"
  [ "$status" -eq 0 ]
  jqe "$output" '.status == "valid" and .playbook.id == "stub-playbook"'
  run wf_complete "$RUN" run_playbook passed
  [ "$status" -eq 0 ]

  # derive (compute) and publish (render) run inside the final next call
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  jqe "$output" '.signal == "complete" and .payload.status == "completed"'
  [ "$(run_status "$RUN")" = "completed" ]

  # step order and types match the definition, and every step is completed
  def_pairs="$(jq -c '[.steps[] | [.id, .type]]' "$PROJ/project/.workflows/all-step-types.json")"
  run_pairs="$(wf_status "$RUN" | jq -c '[.steps[] | [.id, .type]]')"
  [ "$run_pairs" = "$def_pairs" ]
  [ "$run_pairs" = '[["prep","compute"],["ask_skill","skill"],["gate","confirm"],["run_playbook","playbook"],["derive","compute"],["publish","render"]]' ]
  not_done="$(wf_status "$RUN" | jq -r '[.steps[] | select(.status != "completed")] | length')"
  [ "$not_done" = "0" ]

  # the render step's artifact exists and carries the scope and the ids
  artifact_rel="$(wf_status "$RUN" | jq -r '.steps[] | select(.id == "publish") | .outputs.report')"
  [ -n "$artifact_rel" ]
  [ -f "$PROJ/project/data/workflow-artifacts/$artifact_rel" ]
  text="$(cat "$PROJ/project/data/workflow-artifacts/$artifact_rel")"
  assert_contains "$text" "Report for E80_S06"
  assert_contains "$text" "E80_S06_T01"

  # both compute steps really ran, once each, in definition order
  [ "$(cat "$PROJ/wf-count.log")" = "$(printf 'prep\nderive')" ]
}

@test "4. no silent skip-ahead: next-step.sh repeats the same step, and complete-step.sh refuses a non-current step" {
  WF_ID=all-step-types
  RUN="$(wf_start)"
  [ -n "$RUN" ]

  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  first="$output"
  jqe "$first" '.signal == "step" and .step_id == "ask_skill"'
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  second="$output"
  [ "$(printf '%s' "$first" | jq -r .step_id)" = "$(printf '%s' "$second" | jq -r .step_id)" ]
  [ "$(printf '%s' "$second" | jq -r .step_id)" = "ask_skill" ]
  [ "$(step_state "$RUN" ask_skill)" = "in_progress" ]
  [ "$(step_state "$RUN" gate)" = "pending" ]

  before="$(step_statuses "$RUN")"

  # a step that was never handed out, a later step and an already completed step are all refused
  run wf_complete "$RUN" gate passed
  [ "$status" -ne 0 ]
  run wf_complete "$RUN" derive passed
  [ "$status" -ne 0 ]
  run wf_complete "$RUN" prep passed
  [ "$status" -ne 0 ]
  [ "$(step_statuses "$RUN")" = "$before" ]
  [ "$(step_state "$RUN" derive)" = "pending" ]

  # the current step is still ask_skill, and only reporting it moves the run on to the gate
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "ask_skill" ]
  run wf_complete "$RUN" ask_skill passed
  [ "$status" -eq 0 ]
  run wf_next "$RUN"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r .step_id)" = "gate" ]
}
