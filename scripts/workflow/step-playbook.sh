#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/step-playbook.sh - build the action for a `playbook` workflow step (epic E80, task E80_S03_T05)
#
# A `playbook` step reuses the E53 machinery unchanged. This script resolves the playbook id and prints what the
# agent needs to run it exactly as /jenga's natural-language branch does: render the confirmation with
# skills/jenga/scripts/render-playbook-confirmation.sh, then drive skills/jenga/scripts/run-playbook-step.sh
# (init, then the advance loop), and report ONE overall outcome for the step.
#
# ---------------------------------------------------------------------------
# WHOLE-PLAYBOOK-AS-ONE-UNIT LIMIT
# ---------------------------------------------------------------------------
# Playbook run state is a mktemp file (jenga-playbook-run-*.json) that does not survive the session. A playbook is
# therefore ONE unit of a workflow: it cannot be resumed from the middle. A workflow run interrupted while a
# playbook step was in progress resumes by initialising that playbook step again from its FIRST step. That is what
# --resume reports (reinitialised: true). This script never looks for, reads or reuses an old
# jenga-playbook-run-*.json file, and it never calls run-playbook-step.sh itself.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   step-playbook.sh <playbook_id> [--resume]
#   step-playbook.sh -h | --help        print this usage on stdout, exit 0
#
# The id is resolved with skills/jenga/scripts/load-playbooks.sh lookup <id>, which brings its own consumer-install
# fallback and the JENGA_PLAYBOOKS_TEST_ROOT test override. Nothing under skills/jenga/ is modified.
#
# STDOUT, on success, is one JSON object:
#   {"playbook_id": "<id>", "name": "<name>", "steps": ["<step name>", ...], "reinitialised": false}
# With --resume, "reinitialised" is true and a "note" field is added saying the playbook restarts from its first
# step because playbook state is not durable. "steps" holds the ordered step names (a bare step stays as it is;
# a step object yields its "skill", or its "playbook" name), ready to be joined with commas for
# render-playbook-confirmation.sh.
#
# EXIT CODES
#   0  success, object on stdout
#   1  the id does not resolve (unknown id, or a playbook that failed validation): lookup's message on stderr,
#      nothing on stdout
#   2  usage error (missing id, unknown option, extra argument), or lookup could not run
# ---------------------------------------------------------------------------
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOADER="$SELF_DIR/../../skills/jenga/scripts/load-playbooks.sh"

usage() { sed -n '/^# USAGE$/,$p' "${BASH_SOURCE[0]}" | sed -n '3,/^# ------/p' | sed -e '$d' -e 's/^# \{0,1\}//'; }

ID=""
RESUME=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --resume) RESUME=1; shift ;;
    -*) echo "step-playbook.sh: unknown option '$1'" >&2; exit 2 ;;
    *)
      if [ -n "$ID" ]; then echo "step-playbook.sh: unexpected argument '$1'" >&2; exit 2; fi
      ID="$1"; shift ;;
  esac
done
if [ -z "$ID" ]; then
  echo "step-playbook.sh: missing <playbook_id> (usage: step-playbook.sh <playbook_id> [--resume])" >&2
  exit 2
fi
if [ ! -f "$LOADER" ]; then
  echo "step-playbook.sh: playbook loader not found at $LOADER" >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "step-playbook.sh: python3 is required" >&2; exit 2; }

LOOKUP_OUT="$(bash "$LOADER" lookup "$ID" 2>/dev/null)"
LOOKUP_RC=$?
if [ "$LOOKUP_RC" -ne 0 ]; then
  echo "step-playbook.sh: playbook lookup failed for '$ID' (exit $LOOKUP_RC)" >&2
  exit 2
fi

# Build the object (or the failure message) from lookup's JSON. Prints the object and exits 0, or prints the
# message and exits 1. Output is captured so a failure leaves stdout empty.
OUT="$(printf '%s' "$LOOKUP_OUT" | python3 -c '
import json, sys
resume = sys.argv[2] == "1"
pid = sys.argv[1]
try:
    res = json.load(sys.stdin)
except Exception:
    print("lookup returned unreadable output for playbook \x27%s\x27" % pid)
    sys.exit(3)
status = res.get("status")
if status == "not_found":
    print("unknown playbook \x27%s\x27: no such playbook id" % pid)
    sys.exit(1)
if status == "invalid":
    print("playbook \x27%s\x27 is invalid: %s" % (pid, res.get("reason", "failed validation")))
    sys.exit(1)
if status != "valid" or not isinstance(res.get("playbook"), dict):
    print("lookup returned an unexpected result for playbook \x27%s\x27" % pid)
    sys.exit(3)
pb = res["playbook"]
steps = []
for s in pb.get("steps", []):
    if isinstance(s, str):
        steps.append(s)
    elif isinstance(s, dict):
        steps.append(s.get("skill") or s.get("playbook") or "")
obj = {"playbook_id": pb.get("id", pid), "name": pb.get("name", ""), "steps": steps, "reinitialised": resume}
if resume:
    obj["note"] = ("playbook restarts from its first step: playbook run state is a temp file that does not "
                   "survive the session, so a resumed run re-initialises this playbook step from the beginning")
print(json.dumps(obj))
' "$ID" "$RESUME")"
RC=$?
if [ "$RC" -eq 0 ]; then
  printf '%s\n' "$OUT"
  exit 0
fi
printf 'step-playbook.sh: %s\n' "$OUT" >&2
[ "$RC" -eq 1 ] && exit 1
exit 2
