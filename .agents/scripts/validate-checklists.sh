#!/usr/bin/env bash
# validate-checklists.sh - validate pre-flight checklist registry files (E67_S01_T02)
#
# Implements the schema in preflight-checklists.md under the project documentation directory. That
# document is the contract: section 3 lists the failure classes, sections 2, 4, 5, 6 and 7 define the
# fields and values. Where this script and that document disagree, the document wins.
#
# Usage: ./scripts/validate-checklists.sh <path-to-checklists.json> [more-files...]
#
# Each file is validated on its own (nothing is inherited from any other file). For every file the script
# prints one verdict line on stdout:
#   PASS <file>
#   FAIL <file>
# and, for a failing file, one line per problem on stderr, in the form "<file>: <message>". Every problem
# in a file is reported, not just the first.
#
# Exit codes:
#   0  every file given is valid
#   1  at least one file is invalid, malformed, or could not be read
#   2  usage error (no arguments)
#   3  python3 is not installed
#
# Failure classes. Each has its own message, which starts with the fixed class token shown. Item-level
# messages name the offending item as  item "<id>"  (or items[<index>] when the item has no usable id).
#
#   malformed JSON               the file does not parse (or is not UTF-8), or its top level is not an object
#   missing required field       a required top-level field (checklist_version, items) or item field
#                                (id, text, situations, kind, enforcement, tick_scope) is absent or of the
#                                wrong type
#   unknown situation            an item names a situation that is neither one of the base vocabulary
#                                (pre-commit, pre-task, pre-release, pre-reconcile) nor declared in this
#                                file's own top-level "situations"
#   unknown kind                 kind is present but is not "machine" or "judgment"
#   missing verify               kind "machine" with no verify, or one that is null, not a string, empty or
#                                whitespace-only
#   verify on a judgment item    kind "judgment" with a verify key present at all, whatever its value
#   bad enforcement              enforcement is present but is not "block", "confirm" or "advisory"
#   bad tick_scope               tick_scope is present but is not "run" or "persistent"
#   duplicate item id            two items in the same file share an id
#
# Structural classes (also rejected, per the schema doc; wording is this script's own):
#   bad checklist_version        checklist_version is present but is not the integer 1
#   bad top-level situations     situations is present but is not an array, or an entry is not a valid
#                                extension name (^[a-z][a-z0-9-]*$), duplicates a base name, or repeats
#   bad item                     an items[] element is not an object
#   malformed id                 id does not match ^[a-z0-9]+(-[a-z0-9]+)*$
#   empty text                   text is empty or whitespace-only
#   empty situations             an item's situations array is empty
#   duplicate situation          an item's situations array repeats an entry
#
# Provenance classes (E67_S05_T01). An item MAY carry a "provenance" object recording where it came from;
# an item with no "provenance" key is validated exactly as before. When the key is present:
#
#   bad provenance               provenance is not a JSON object
#   bad provenance source        provenance.source is absent or is not "authored", "suggested" or "convention"
#   missing provenance field     source is "suggested" and suggested_by, evidence or accepted_on is absent,
#                                not a string, or empty/whitespace-only; or source is "convention" and category
#                                is absent, not a string, or empty/whitespace-only (E69_S03_T01)
#   bad provenance origin        source is "suggested" and origin is absent or not "precautionary" or
#                                "recurrence"
#   bad accepted_on              source is "suggested" and accepted_on is not an ISO 8601 date
#                                (YYYY-MM-DD, optionally followed by a time)
#   recurrence without incident  source is "suggested", origin is "recurrence", and evidence names no
#                                originating incident: a rapport path (rapports/<...>.md), a commit SHA
#                                (7 to 40 hex characters, with at least one digit and one letter), or a task
#                                id (E##_S##_T##). This is checked even when evidence is absent altogether,
#                                in which case "missing provenance field" is reported as well.
#
# For source "convention" (E69_S03_T01) only a non-empty string category is required: the conventions category
# id the item was generated from. Items of this class are written by scripts/generate-convention-checklist.sh
# (id prefix conv-). No suggested_by, origin, evidence or accepted_on is required and no "suggested" rule
# applies. There is deliberately NO enforcement rule here: a hand-edit that raises a generated item to "block"
# must not make the whole registry unreadable; the never-block guarantee belongs to the generator and to
# validate-conventions.sh.
#
# For source "authored" nothing beyond source is required or interpreted. Unknown keys inside provenance are
# ignored, like unknown item keys. Whether a "precautionary" suggestion's evidence is concrete is a review
# judgment made by the Scrum Master; the validator can only require that it is present.
#
# Reading rule for wrong-typed values: an ABSENT field is always "missing required field". For the three
# enum fields (kind, enforcement, tick_scope) a PRESENT value that is not an accepted string, of any JSON
# type, is that field's own class (unknown kind, bad enforcement, bad tick_scope), because the schema says
# "anything other than ..." for those. For id, text and situations a present value of the wrong JSON type is
# "missing required field", as the schema's "(or of the wrong type)" says. Values are case-sensitive.
#
# Unknown top-level keys and unknown item keys are deliberately IGNORED (schema section 1), so later work
# can add keys without a breaking change here. This script does not interpret them. The one item key it does
# interpret beyond the schema's required fields is "provenance" (above); a top-level "provenance" key is
# still just an unknown key and is ignored.
#
# There is no default file: calling with no arguments is a usage error, so no configs-directory lookup is
# needed. Callers that want the project instance resolve it themselves through the root resolver
# (resolve-root.sh get configs) and pass the path.
#
# Compatible with macOS bash 3.2.

set -u

SELF="$(basename "$0")"

if [ "$#" -lt 1 ]; then
  printf 'usage: %s <path-to-checklists.json> [more-files...]\n' "$SELF" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s: python3 is required but was not found on PATH\n' "$SELF" >&2
  exit 3
fi

python3 - "$@" <<'PY'
import json
import re
import sys

BASE_SITUATIONS = ["pre-commit", "pre-task", "pre-release", "pre-reconcile"]
KINDS = ("machine", "judgment")
ENFORCEMENTS = ("block", "confirm", "advisory")
TICK_SCOPES = ("run", "persistent")
ID_RE = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")
EXT_RE = re.compile(r"[a-z][a-z0-9-]*")
PROVENANCE_SOURCES = ("authored", "suggested", "convention")
PROVENANCE_ORIGINS = ("precautionary", "recurrence")
DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}([T ].*)?")
# An originating incident named in free-text evidence: a rapport path, a commit SHA, or a task id.
RAPPORT_PATH_RE = re.compile(r"rapports/\S+\.md")
SHA_RE = re.compile(r"(?<![0-9A-Za-z])(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}(?![0-9A-Za-z])")
TASK_ID_RE = re.compile(r"(?<![0-9A-Za-z])E\d+_S\d+_T\d+(?![0-9A-Za-z])")


def reject_constant(name):
    raise ValueError("non-standard JSON constant %s" % name)


def is_str(v):
    return isinstance(v, str)


def blank(v):
    return (not is_str(v)) or v.strip() == ""


def show(v):
    return json.dumps(v, ensure_ascii=False)


def declared_extensions(doc):
    """Valid extension names declared by the file's top-level situations (errors reported separately)."""
    raw = doc.get("situations", [])
    out = []
    if isinstance(raw, list):
        for s in raw:
            if is_str(s) and EXT_RE.fullmatch(s) and s not in BASE_SITUATIONS and s not in out:
                out.append(s)
    return out


def check_top_level(doc, errors):
    if "checklist_version" not in doc:
        errors.append("missing required field: checklist_version")
    else:
        v = doc["checklist_version"]
        if type(v) is not int or v != 1:
            errors.append("bad checklist_version: must be the integer 1 (got %s)" % show(v))

    if "situations" in doc:
        raw = doc["situations"]
        if not isinstance(raw, list):
            errors.append("bad top-level situations: must be an array of strings (got %s)" % show(raw))
        else:
            seen = []
            for i, s in enumerate(raw):
                where = "situations[%d]" % i
                if not is_str(s) or not EXT_RE.fullmatch(s):
                    errors.append(
                        "bad top-level situations: %s %s is not a valid extension name (must match ^[a-z][a-z0-9-]*$)"
                        % (where, show(s)))
                elif s in BASE_SITUATIONS:
                    errors.append(
                        "bad top-level situations: %s %s duplicates a base situation (base: %s)"
                        % (where, show(s), ", ".join(BASE_SITUATIONS)))
                elif s in seen:
                    errors.append("bad top-level situations: %s %s is repeated" % (where, show(s)))
                else:
                    seen.append(s)

    if "items" not in doc:
        errors.append("missing required field: items")
        return False
    if not isinstance(doc["items"], list):
        errors.append("missing required field: items (must be an array, got %s)" % show(doc["items"]))
        return False
    return True


def names_incident(evidence):
    return bool(RAPPORT_PATH_RE.search(evidence) or SHA_RE.search(evidence) or TASK_ID_RE.search(evidence))


def check_provenance(prov, at, errors):
    if not isinstance(prov, dict):
        errors.append("bad provenance: %s provenance must be an object (got %s)" % (at, show(prov)))
        return
    source = prov.get("source")
    if not is_str(source) or source not in PROVENANCE_SOURCES:
        errors.append('bad provenance source %s in %s (must be "authored", "suggested" or "convention")'
                      % (show(source) if "source" in prov else "(absent)", at))
        return
    if source == "convention":
        if "category" not in prov or blank(prov["category"]):
            errors.append("missing provenance field: category in %s has source \"convention\" but no non-empty "
                          "category" % at)
        return
    if source != "suggested":
        return

    for field in ("suggested_by", "evidence", "accepted_on"):
        if field not in prov or blank(prov[field]):
            errors.append("missing provenance field: %s in %s has source \"suggested\" but no non-empty %s"
                          % (field, at, field))
    accepted = prov.get("accepted_on")
    if is_str(accepted) and accepted.strip() != "" and not DATE_RE.fullmatch(accepted.strip()):
        errors.append("bad accepted_on %s in %s (must be an ISO 8601 date, YYYY-MM-DD)" % (show(accepted), at))

    origin = prov.get("origin")
    if not is_str(origin) or origin not in PROVENANCE_ORIGINS:
        errors.append('bad provenance origin %s in %s (must be "precautionary" or "recurrence")'
                      % (show(origin) if "origin" in prov else "(absent)", at))
    elif origin == "recurrence":
        evidence = prov.get("evidence")
        if not is_str(evidence) or not names_incident(evidence):
            errors.append("recurrence without incident: %s is a suggested \"recurrence\" item but its evidence "
                          "names no originating incident (a rapport path, a commit SHA, or a task id such as "
                          "E##_S##_T##)" % at)


def check_item(item, index, allowed, errors):
    if not isinstance(item, dict):
        errors.append("bad item: items[%d] must be an object (got %s)" % (index, show(item)))
        return None

    has_id = "id" in item and is_str(item["id"])
    at = 'item "%s"' % item["id"] if has_id else "items[%d]" % index

    # id
    if "id" not in item:
        errors.append("missing required field: id in %s" % at)
    elif not is_str(item["id"]):
        errors.append("missing required field: id in %s (must be a string, got %s)" % (at, show(item["id"])))
    elif not ID_RE.fullmatch(item["id"]):
        errors.append("malformed id: %s (must match ^[a-z0-9]+(-[a-z0-9]+)*$ and be kebab-case)" % at)

    # text
    if "text" not in item:
        errors.append("missing required field: text in %s" % at)
    elif not is_str(item["text"]):
        errors.append("missing required field: text in %s (must be a string, got %s)" % (at, show(item["text"])))
    elif item["text"].strip() == "":
        errors.append("empty text: %s has an empty or whitespace-only text" % at)

    # situations
    if "situations" not in item:
        errors.append("missing required field: situations in %s" % at)
    elif not isinstance(item["situations"], list):
        errors.append("missing required field: situations in %s (must be an array, got %s)"
                      % (at, show(item["situations"])))
    elif len(item["situations"]) == 0:
        errors.append("empty situations: %s has an empty situations array" % at)
    else:
        seen = []
        for s in item["situations"]:
            if not is_str(s) or s not in allowed:
                errors.append("unknown situation %s in %s (allowed: %s)" % (show(s), at, ", ".join(allowed)))
            if is_str(s) and s in seen:
                errors.append("duplicate situation %s in %s" % (show(s), at))
            else:
                seen.append(s)

    # kind and its verify coupling
    kind = item.get("kind")
    if "kind" not in item:
        errors.append("missing required field: kind in %s" % at)
    elif not is_str(kind) or kind not in KINDS:
        errors.append('unknown kind %s in %s (must be "machine" or "judgment")' % (show(kind), at))
    elif kind == "machine":
        if "verify" not in item or blank(item["verify"]):
            errors.append("missing verify: %s has kind \"machine\" but no non-empty verify command" % at)
    else:  # judgment
        if "verify" in item:
            errors.append("verify on a judgment item: %s has kind \"judgment\" but carries a verify key" % at)

    # enforcement
    if "enforcement" not in item:
        errors.append("missing required field: enforcement in %s" % at)
    elif not is_str(item["enforcement"]) or item["enforcement"] not in ENFORCEMENTS:
        errors.append('bad enforcement %s in %s (must be "block", "confirm" or "advisory")'
                      % (show(item["enforcement"]), at))

    # tick_scope
    if "tick_scope" not in item:
        errors.append("missing required field: tick_scope in %s" % at)
    elif not is_str(item["tick_scope"]) or item["tick_scope"] not in TICK_SCOPES:
        errors.append('bad tick_scope %s in %s (must be "run" or "persistent")' % (show(item["tick_scope"]), at))

    # provenance (optional; absent means authored, and nothing below runs)
    if "provenance" in item:
        check_provenance(item["provenance"], at, errors)

    return item["id"] if has_id else None


def validate(doc):
    errors = []
    if not isinstance(doc, dict):
        return ["malformed JSON: top level must be a JSON object"]

    items_ok = check_top_level(doc, errors)
    if not items_ok:
        return errors

    allowed = BASE_SITUATIONS + declared_extensions(doc)
    ids = {}
    for index, item in enumerate(doc["items"]):
        item_id = check_item(item, index, allowed, errors)
        if item_id is not None:
            ids.setdefault(item_id, []).append(index)

    for item_id, positions in ids.items():
        if len(positions) > 1:
            errors.append("duplicate item id: %s appears %d times in this file (items[%s])"
                          % (show(item_id), len(positions), ", ".join(str(p) for p in positions)))
    return errors


def load(path):
    """Return (doc, error_message). Exactly one is not None."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        return None, "cannot read file: %s" % (exc.strerror or exc)
    try:
        return json.loads(raw.decode("utf-8"), parse_constant=reject_constant), None
    except (ValueError, UnicodeDecodeError) as exc:
        return None, "malformed JSON: %s" % exc


failed = False
for path in sys.argv[1:]:
    doc, load_error = load(path)
    errors = [load_error] if load_error else validate(doc)
    if errors:
        failed = True
        for message in errors:
            sys.stderr.write("%s: %s\n" % (path, message))
        sys.stdout.write("FAIL %s\n" % path)
    else:
        sys.stdout.write("PASS %s\n" % path)
    sys.stdout.flush()
    sys.stderr.flush()

sys.exit(1 if failed else 0)
PY
