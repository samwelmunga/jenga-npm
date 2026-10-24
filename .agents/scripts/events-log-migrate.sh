#!/usr/bin/env bash
# scripts/events-log-migrate.sh — convert the shared event log from a JSON array to JSONL
#
# Usage:
#   scripts/events-log-migrate.sh <events-file>
#
# The shared log (project/logs/events.json) is one JSON value per line (JSONL), not a
# single array. A line-based git merge driver (`merge=union`, set in .gitattributes) can
# only keep both sides of a concurrent append when every record is one self-contained
# line; a multi-line array entry cannot be unioned safely. This script rewrites a legacy
# array-shaped file into that form, in place.
#
# What changes, precisely. Each array element becomes one line. Inside each element:
#   - every string literal is kept byte-for-byte (escapes and raw UTF-8 included);
#   - every number, true/false/null and punctuation token is kept, in the same order;
#   - only whitespace outside string literals changes: a run that contains a line break
#     becomes one space, except directly after "{" or "[" or directly before "}", "]", ","
#     or ":", where it is dropped. Other whitespace is kept as written.
# The array's own "[", "]" and the commas between elements are removed, because they
# are not part of any single record.
#
# Verification, before anything is written. For every element the script checks that the
# converted line parses to the same value as the original element, that the sequence of
# non-whitespace tokens (including every raw string literal) is identical, that no line
# contains a line break, and that the element count is unchanged. Any failure writes
# nothing and exits 3.
#
# Idempotent. A file that is already JSONL (every non-empty line parses as JSON) is left
# alone and exits 0. An empty file is also left alone.
#
# The read, verify and replace all run under scripts/with-lock.sh on the target file, so a
# concurrent writer that uses the same lock cannot interleave with the rewrite. The new
# content goes to a temporary file in the same directory and replaces the original with an
# atomic rename. The original file's permission bits are kept.
#
# Requires python3 (already required by the event-log readers).
#
# Exit codes:
#   0    migrated, or already JSONL / empty (no change needed)
#   1    invalid usage
#   2    refused: the file is neither a JSON array nor JSONL, or is not valid UTF-8; untouched
#   3    verification failed; nothing written
#   4    could not acquire the lock, or a runtime failure (python3 missing, I/O error)

set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WITH_LOCK="$SELF_DIR/with-lock.sh"

usage() {
  echo "Usage: $0 <events-file>" >&2
  exit 1
}

[ "$#" -eq 1 ] || usage
FILE="$1"

if [ ! -e "$FILE" ]; then
  echo "events-log-migrate: no file at $FILE; nothing to migrate" >&2
  exit 0
fi
command -v python3 >/dev/null 2>&1 || { echo "events-log-migrate: python3 is required" >&2; exit 4; }
[ -x "$WITH_LOCK" ] || [ -f "$WITH_LOCK" ] || { echo "events-log-migrate: $WITH_LOCK not found" >&2; exit 4; }

MIGRATE_PY="$(cat <<'PYCODE'
import json
import os
import stat
import sys
import tempfile

WS = " \t\r\n"
REFUSED, VERIFY_FAILED = 10, 11


def fail(code, message):
    sys.stderr.write("events-log-migrate: " + message + "\n")
    sys.exit(code)


def tokenize(text):
    """Split JSON text into ("ws"|"str"|"punct"|"atom", raw) tokens. Raw bytes are preserved."""
    toks = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in WS:
            j = i
            while j < n and text[j] in WS:
                j += 1
            toks.append(("ws", text[i:j]))
        elif c == '"':
            j = i + 1
            while True:
                if j >= n:
                    raise ValueError("unterminated string literal")
                ch = text[j]
                if ch == "\\":
                    j += 2
                    continue
                if ch == '"':
                    j += 1
                    break
                j += 1
            toks.append(("str", text[i:j]))
        elif c in "{}[],:":
            j = i + 1
            toks.append(("punct", c))
        else:
            j = i
            while j < n and text[j] not in WS and text[j] not in '{}[],:"':
                j += 1
            toks.append(("atom", text[i:j]))
        i = j
    return toks


def nonws(toks):
    return [raw for kind, raw in toks if kind != "ws"]


def compact(elem_toks):
    """Render one element on one line, touching only whitespace outside string literals."""
    s, e = 0, len(elem_toks)
    while s < e and elem_toks[s][0] == "ws":
        s += 1
    while e > s and elem_toks[e - 1][0] == "ws":
        e -= 1
    toks = elem_toks[s:e]
    out = []
    last = (None, None)  # previous non-whitespace token, as (kind, raw)
    for idx, (kind, raw) in enumerate(toks):
        if kind != "ws":
            out.append(raw)
            last = (kind, raw)
            continue
        if "\n" in raw or "\r" in raw:
            nxt = next((t for t in toks[idx + 1:] if t[0] != "ws"), (None, None))
            drop = (last[0] == "punct" and last[1] in ("{", "[")) or (
                nxt[0] == "punct" and nxt[1] in ("}", "]", ",", ":")
            )
            if not drop:
                out.append(" ")
        else:
            out.append(raw)
    return "".join(out)


def main(path):
    with open(path, "rb") as fh:
        data = fh.read()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        fail(REFUSED, "%s is not valid UTF-8 (%s); refused, file untouched" % (path, exc.reason))

    if not text.strip():
        print("events-log-migrate: %s is empty; nothing to migrate" % path)
        return 0

    if text.lstrip()[0] != "[":
        for lineno, line in enumerate(text.split("\n"), 1):
            if not line.strip():
                continue
            try:
                json.loads(line)
            except ValueError as exc:
                fail(
                    REFUSED,
                    "%s is neither a JSON array nor JSONL (line %d: %s); refused, file untouched"
                    % (path, lineno, exc),
                )
        print("events-log-migrate: %s is already JSONL; nothing to migrate" % path)
        return 0

    try:
        original = json.loads(text)
    except ValueError as exc:
        fail(REFUSED, "%s is not valid JSON (%s); refused, file untouched" % (path, exc))
    if not isinstance(original, list):
        fail(REFUSED, "%s top-level value is not an array; refused, file untouched" % path)

    toks = tokenize(text)
    sig = [i for i, (kind, _) in enumerate(toks) if kind != "ws"]
    body_start, body_end = sig[0] + 1, sig[-1]
    elements, depth, cur = [], 0, body_start
    for i in range(body_start, body_end):
        kind, raw = toks[i]
        if kind != "punct":
            continue
        if raw in "[{":
            depth += 1
        elif raw in "]}":
            depth -= 1
        elif raw == "," and depth == 0:
            elements.append(toks[cur:i])
            cur = i + 1
    if any(kind != "ws" for kind, _ in toks[cur:body_end]):
        elements.append(toks[cur:body_end])

    if len(elements) != len(original):
        fail(
            VERIFY_FAILED,
            "element count mismatch: tokenised %d, parsed %d; nothing written" % (len(elements), len(original)),
        )

    lines = []
    for index, elem in enumerate(elements):
        line = compact(elem)
        orig_text = "".join(raw for _, raw in elem).strip(WS)
        if "\n" in line or "\r" in line:
            fail(VERIFY_FAILED, "element %d still contains a line break; nothing written" % index)
        if json.loads(line) != json.loads(orig_text) or json.loads(line) != original[index]:
            fail(VERIFY_FAILED, "element %d changed value; nothing written" % index)
        if nonws(tokenize(line)) != nonws(elem):
            fail(VERIFY_FAILED, "element %d changed a non-whitespace token; nothing written" % index)
        lines.append(line)

    out_text = "".join(line + "\n" for line in lines)
    reparsed = [json.loads(line) for line in out_text.splitlines()]
    if reparsed != original:
        fail(VERIFY_FAILED, "re-parsed output differs from the original array; nothing written")

    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".events-migrate.")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(out_text.encode("utf-8"))
        os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode))
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise

    print(
        "events-log-migrate: migrated %d entries in %s (%d bytes -> %d bytes); values, string literals and token order verified"
        % (len(lines), path, len(data), len(out_text.encode("utf-8")))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
PYCODE
)"

"$WITH_LOCK" "$FILE" -- python3 -c "$MIGRATE_PY" "$FILE"
rc=$?
case "$rc" in
  0) exit 0 ;;
  10) exit 2 ;;
  11) exit 3 ;;
  *) echo "events-log-migrate: could not migrate $FILE (lock or runtime failure, exit $rc)" >&2; exit 4 ;;
esac
