"""Shared reader for the per-session execution ledger (E44_S09, shared by E92_S02_T04).

The ledger is <queue>/execution-ledger.jsonl, appended to by skills/j-break/scripts/record-execution.sh. This module is
the ONE place that reads it, so render-execution-status.sh ("ran this session") and run-progress.sh (the task ids a
progress bar must include) agree by construction.

It also owns the terminal status sets, because "has a terminal entry under this session key" is defined by them:
render-execution-status.sh imports TERMINAL_OK / TERMINAL_BAD from here for its own board-status marks.

Library use:  read_session_ledger(queue_dir, session_key) -> (ledger_present, item_ids, malformed_line_count)

  - an entry counts when its session_key equals the (non-empty) session key and its status is in TERMINAL_OK | TERMINAL_BAD
  - malformed lines (invalid JSON or not an object) are skipped and counted
  - a missing or unreadable file gives ledger_present False and no items

Command line (used by run-progress.sh):
  ledger_reader.py --queue <dir> --session <key>
    prints one item id per line, in order of first appearance. Exit 0 ok (also when there is no ledger file);
    3 when malformed lines were found (a message goes to stderr and the ids found are still printed);
    2 usage error.
"""
import json
import os
import sys

TERMINAL_OK = {"Passed", "Passed with remarks", "Merged", "Done", "Deployed to Stage", "Deployed to Prod", "Publicized"}
TERMINAL_BAD = {"Failed", "Rejected"}
LEDGER_FILE = "execution-ledger.jsonl"


def read_session_ledger(queue_dir, session_key):
    """Return (ledger_present, item_ids, malformed_lines); item_ids is a list, de-duplicated, in first-seen order."""
    ledger_file = os.path.join(queue_dir, LEDGER_FILE)
    present = os.path.isfile(ledger_file)
    items, bad = [], 0
    if not present:
        return False, items, bad
    seen = set()
    try:
        with open(ledger_file, encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    entry = json.loads(raw)
                    if not isinstance(entry, dict):
                        raise ValueError("not an object")
                except ValueError:
                    bad += 1
                    continue
                if (session_key and entry.get("session_key") == session_key
                        and entry.get("status") in TERMINAL_OK | TERMINAL_BAD):
                    item = entry.get("item_id")
                    if item not in seen:
                        seen.add(item)
                        items.append(item)
    except OSError:
        return False, [], 0
    return present, items, bad


def _main(argv):
    queue = session = None
    i = 0
    while i < len(argv):
        if argv[i] in ("--queue", "--session") and i + 1 < len(argv):
            if argv[i] == "--queue":
                queue = argv[i + 1]
            else:
                session = argv[i + 1]
            i += 2
        else:
            sys.stderr.write("ledger_reader.py: usage: ledger_reader.py --queue <dir> --session <key>\n")
            return 2
    if queue is None or session is None:
        sys.stderr.write("ledger_reader.py: usage: ledger_reader.py --queue <dir> --session <key>\n")
        return 2
    _present, items, bad = read_session_ledger(queue, session)
    for item in items:
        if isinstance(item, str):
            print(item)
    if bad:
        sys.stderr.write("ledger_reader.py: %d malformed ledger line(s) in %s\n" % (bad, os.path.join(queue, LEDGER_FILE)))
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
