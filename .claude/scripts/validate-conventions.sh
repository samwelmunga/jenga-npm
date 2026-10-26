#!/usr/bin/env bash
# validate-conventions.sh - validate project conventions files (E69_S01_T02)
#
# Implements the contract in templates/conventions-schema.json (machine-readable, the single source for the
# top-level keys, the category ids, each category's values fields, the allowed source and strength values and the
# 2-3 presets-per-category bound) and project/documentation/project-conventions.md (the human guide). Nothing in
# this script keeps a second copy of the category list: it is read from the schema at run time. Where this script
# and the schema disagree, the schema wins.
#
# Usage:
#   scripts/validate-conventions.sh <file>...              validate conventions instances (conventions.json)
#   scripts/validate-conventions.sh --presets <file>...    validate preset catalogs (conventions-presets.json)
#
# stdout: one "PASS <file>" or "FAIL <file>" line per file. stderr: one "<file>: <message>" line per problem; every
# problem in a file is reported, not just the first. Each message names the offending JSON path
# (e.g. categories.commit-format.values.style, categories.naming[1].id).
#
# Exit codes:
#   0  every file given is valid
#   1  at least one file is invalid, malformed, absent or unreadable (an absent file is never a silent pass); the
#      schema itself could not be read
#   2  usage error (no files, unknown option)
#   3  python3 is not installed
#
# Instance rejections: malformed JSON, duplicate object keys or a non-object top level; unknown top-level key;
# wrong conventions_version; unknown category id; a category entry that is not an object; unknown entry field;
# missing required field (source, summary, values); wrong type; source outside detected|preset|custom; preset
# missing when source is preset, or present when source is custom; an unknown, missing-required or wrong-typed key
# inside values; a multi-line or empty string; and a "block" strength anywhere (the strength field, or any value
# equal to "block" under a key named strength or enforcement, at any depth).
#
# Preset-catalog rejections: malformed JSON; unknown top-level key; wrong presets_version; an unknown category; a
# schema category with no presets, or with fewer than min or more than max (2 and 3 per the schema); a preset
# missing id, label, description or values; a malformed or duplicate preset id inside a category; values that do
# not validate against that category's field list; a preset that sets a "block" strength.
#
# Field-spec vocabulary (E79_S03_T03). A field in a category's "values" list may carry, besides the existing type,
# required, single_line and non_empty flags, these optional properties. They apply to type "string" fields only and are
# checked when the schema is loaded (a malformed one makes the schema, and so every run, fail with exit 1):
#   enum        non-empty array of unique non-empty strings; any other value is rejected, naming the path and the list
#   reserved    object mapping a value to a note; the value is rejected with a message containing the note, distinct
#               from the "not an allowed value" message (a reserved value is accepted by the vocabulary but not yet
#               usable, e.g. "reserved for E79_S08"); a value may not be both in enum and reserved
#   max_length  positive integer; a longer string is rejected
#   pattern     regular expression the WHOLE value must match (re.fullmatch); it must compile
#   default     the value an absent field takes. It must itself satisfy type, non_empty, single_line, enum, reserved,
#               max_length and pattern. The validator never inserts defaults into a file: consumers read them.
# A spec without these properties produces exactly the output it always did. Unknown extra spec properties stay ignored.
#
# Opt-in categories (E79_S03_T03). The schema may carry an optional top-level "opt_in_categories" object, shaped like
# "categories". A category declared there is accepted in an instance's "categories" object and validated exactly like a
# core one (entry fields, source, preset, values, the "block" prohibition at any depth). It is exempt from the preset
# catalog rule: --presets neither requires presets for it nor applies the 2 to 3 count bound, but every preset a
# catalog does provide for it is still validated (shape, id, duplicates, values, "block"). An id declared in both
# "categories" and "opt_in_categories" is a schema error. An "unknown category" message lists the core ids first and
# then the opt-in ones. The category lists are read from the schema only.
#
# Commit-format cross-field rules (E79_S03_T05). When a commit-format values object is validated (an instance entry
# or a preset), these rules run after the per-field checks, and every problem is reported:
#   template        the template is handed, as ONE argument of an argv list (no shell), to
#                   scripts/commit-template.sh validate; that script's message is reported with the JSON path. This
#                   script never parses the template grammar itself.
#   dependent keys  ref_source, ref_pattern, on_unresolved and apply_to_board_commits are rejected ("requires
#                   template") when no template is recorded.
#   ref_pattern     no back-reference (a backslash then a digit); compiles as a POSIX ERE (checked with grep -E, argv
#                   list); and, when the template is valid, accepted by commit-template.sh derive (so a pattern the
#                   commit path would refuse is refused here). The 100-character cap is the schema max_length.
#   on_unresolved   only "fail" (the schema enum); the rejection also says Phase 1 accepts only "fail".
#   subject_max_length  with a template recorded, an integer from 20 to 200; without one the rule is unchanged.
#   message_regex   never reinterpreted or rewritten: it validates exactly as before, with or without a template.
# The commit-trace rules (mode, trailer_key, reserved modes) are the schema's own enum and reserved properties. The
# messages name no board id: they ship to consumers, so they say "a later phase" and "Phase 1".
#
# Environment:
#   JENGA_CONVENTIONS_SCHEMA  read the schema from this file instead of ../templates/conventions-schema.json
#                             relative to this script (tests)
#
# Works from this checkout and from node_modules/@jenga-ai/agent/: the schema is located relative to this script.
# Compatible with macOS bash 3.2.

set -u

SELF="$(basename "$0")"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="${JENGA_CONVENTIONS_SCHEMA:-$here/../templates/conventions-schema.json}"

usage() {
  printf 'usage: %s [--presets] <file> [more-files...]\n' "$SELF" >&2
}

mode="instance"
if [ "$#" -ge 1 ] && [ "$1" = "--presets" ]; then
  mode="presets"
  shift
fi

if [ "$#" -lt 1 ]; then
  usage
  exit 2
fi

case "$1" in
  -*)
    printf '%s: unknown option: %s\n' "$SELF" "$1" >&2
    usage
    exit 2
    ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  printf '%s: python3 is required but was not found on PATH\n' "$SELF" >&2
  exit 3
fi

CONVENTIONS_SCHEMA="$SCHEMA" CONVENTIONS_MODE="$mode" CONVENTIONS_TEMPLATE_SCRIPT="$here/commit-template.sh" \
  python3 - "$@" <<'PY'
import json
import os
import re
import subprocess
import sys

MODE = os.environ["CONVENTIONS_MODE"]
SCHEMA_PATH = os.environ["CONVENTIONS_SCHEMA"]
VALUE_TYPES = ("string", "boolean", "integer", "string_array")
SPEC_FLAGS = ("type", "required", "single_line", "non_empty")
TEMPLATE_SCRIPT = os.environ.get("CONVENTIONS_TEMPLATE_SCRIPT", "")
TEMPLATE_DEPENDENT = ("ref_source", "ref_pattern", "on_unresolved", "apply_to_board_commits")
SUBJECT_LENGTH_RANGE = (20, 200)
REF_PATTERN_MAX = 100
SUBPROCESS_TIMEOUT = 10


def reject_constant(name):
    raise ValueError("non-standard JSON constant %s" % name)


def no_duplicates(pairs):
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise ValueError("duplicate object key %s" % json.dumps(key))
        seen[key] = value
    return seen


def show(v):
    return json.dumps(v, ensure_ascii=False)


def is_str(v):
    return isinstance(v, str)


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def kind(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "boolean"
    if is_int(v):
        return "integer"
    if isinstance(v, float):
        return "number"
    if is_str(v):
        return "string"
    if isinstance(v, list):
        return "array"
    return "object"


def read_json(path):
    """Return (doc, error_message). Exactly one is not None."""
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        return None, "cannot read file: %s" % (exc.strerror or exc)
    try:
        return json.loads(raw.decode("utf-8"), parse_constant=reject_constant,
                          object_pairs_hook=no_duplicates), None
    except (ValueError, UnicodeDecodeError) as exc:
        return None, "malformed JSON: %s" % exc


def check_schema_group(group, noun, problems):
    """Structure check shared by categories and opt_in_categories: a values field list with known types."""
    for cid, cat in group.items():
        if not isinstance(cat, dict) or not isinstance(cat.get("values"), dict):
            problems.append("schema %s %s has no values field list" % (noun, cid))
            continue
        for fname, spec in cat["values"].items():
            if not isinstance(spec, dict) or spec.get("type") not in VALUE_TYPES:
                problems.append("schema %s %s field %s has an unknown type (supported: %s)"
                                % (noun, cid, fname, ", ".join(VALUE_TYPES)))


def load_schema():
    doc, err = read_json(SCHEMA_PATH)
    if err:
        sys.stderr.write("%s: %s\n" % (SCHEMA_PATH, err))
        sys.exit(1)
    problems = []
    required_top = ("top_level_keys", "sources", "strength", "entry_fields", "presets", "categories")
    if not isinstance(doc, dict):
        problems.append("schema top level must be a JSON object")
    else:
        for key in required_top:
            if key not in doc:
                problems.append("schema is missing %s" % key)
    if not problems:
        if not isinstance(doc["categories"], dict) or not doc["categories"]:
            problems.append("schema categories must be a non-empty object")
        else:
            check_schema_group(doc["categories"], "category", problems)
        if "opt_in_categories" in doc:
            if not isinstance(doc["opt_in_categories"], dict):
                problems.append("schema opt_in_categories must be an object")
            else:
                check_schema_group(doc["opt_in_categories"], "opt-in category", problems)
                if isinstance(doc["categories"], dict):
                    for cid in doc["opt_in_categories"]:
                        if cid in doc["categories"]:
                            problems.append("schema category %s is declared in both categories and "
                                            "opt_in_categories" % cid)
    if problems:
        for p in problems:
            sys.stderr.write("%s: %s\n" % (SCHEMA_PATH, p))
        sys.exit(1)
    return doc


SCHEMA = load_schema()
CATEGORIES = SCHEMA["categories"]
OPT_IN = SCHEMA.get("opt_in_categories", {})
ALL_CATEGORIES = dict(CATEGORIES)
ALL_CATEGORIES.update(OPT_IN)
ALLOWED_IDS = ", ".join(list(CATEGORIES) + list(OPT_IN))
SOURCES = SCHEMA["sources"]
STRENGTH = SCHEMA["strength"]
ENTRY_FIELDS = SCHEMA["entry_fields"]
PRESETS = SCHEMA["presets"]
PRESET_FIELDS = PRESETS["preset_fields"]
BLOCK_MSG = 'strength "block" is not allowed for conventions (use "advisory" or "confirm")'


def check_string(value, spec, path, errors):
    """Type/shape checks shared by every free-text string. Returns True when value is a usable string."""
    if not is_str(value):
        errors.append("wrong type: %s must be a string (got %s)" % (path, kind(value)))
        return False
    if spec.get("non_empty") and value.strip() == "":
        errors.append("empty value: %s must not be empty or whitespace-only" % path)
    if spec.get("single_line") and ("\n" in value or "\r" in value):
        errors.append("multi-line value: %s must be a single line (no newline characters)" % path)
    return True


def check_spec_string(value, spec, path, errors):
    """Optional spec properties of a string field: reserved, enum, max_length, pattern (E79_S03_T03)."""
    if spec.get("non_empty") and value.strip() == "":
        return  # already reported as an empty value
    reserved = spec.get("reserved")
    if isinstance(reserved, dict) and value in reserved:
        errors.append("reserved value: %s is %s - %s" % (path, show(value), reserved[value]))
        return
    enum = spec.get("enum")
    if isinstance(enum, list) and value not in enum:
        errors.append("not an allowed value: %s is %s (allowed: %s)" % (path, show(value), ", ".join(enum)))
    max_length = spec.get("max_length")
    if is_int(max_length) and len(value) > max_length:
        errors.append("too long: %s is %d characters (maximum %d)" % (path, len(value), max_length))
    pattern = spec.get("pattern")
    if is_str(pattern) and not re.fullmatch(pattern, value):
        errors.append("bad format: %s %s does not match the required pattern %s" % (path, show(value), pattern))


def check_typed(value, spec, path, errors):
    t = spec["type"]
    if t == "string":
        if check_string(value, spec, path, errors):
            check_spec_string(value, spec, path, errors)
    elif t == "boolean":
        if not isinstance(value, bool):
            errors.append("wrong type: %s must be a boolean (got %s)" % (path, kind(value)))
    elif t == "integer":
        if not is_int(value):
            errors.append("wrong type: %s must be an integer (got %s)" % (path, kind(value)))
    elif t == "string_array":
        if not isinstance(value, list):
            errors.append("wrong type: %s must be an array of strings (got %s)" % (path, kind(value)))
        else:
            if spec.get("non_empty") and not value:
                errors.append("empty value: %s must not be an empty array" % path)
            for i, item in enumerate(value):
                check_string(item, spec, "%s[%d]" % (path, i), errors)


def run_argv(argv):
    """Run a fixed program with a list of arguments: no shell, stdin closed, bounded time. Returns (rc, stderr_line).

    Every recorded value reaches the program as a single argv element, so it is data and never part of a command
    line. rc is None when the program could not be run at all (stderr_line then says why)."""
    try:
        proc = subprocess.run(argv, shell=False, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=SUBPROCESS_TIMEOUT,
                              env=dict(os.environ, LC_ALL="C"))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        return None, str(exc).splitlines()[0] if str(exc) else exc.__class__.__name__
    text = proc.stderr.decode("utf-8", "replace").strip().splitlines()
    return proc.returncode, (text[0] if text else "")


def template_script(*args):
    return run_argv(["bash", TEMPLATE_SCRIPT] + list(args))


def script_reason(line):
    """The reason part of a commit-template.sh message ("commit-template: invalid template: <reason>")."""
    for prefix in ("commit-template: invalid template: ", "commit-template: invalid option value: ",
                   "commit-template: "):
        if line.startswith(prefix):
            return line[len(prefix):]
    return line


def check_commit_format(values, path, errors):
    """Cross-field rules for commit-format values (E79_S03_T05). Runs after the per-field checks."""
    tpath = path + ".template"
    has_template = "template" in values
    template_ok = False

    if has_template and is_str(values["template"]):
        template = values["template"]
        if "\x00" in template:
            errors.append("invalid template: %s - the template contains a NUL character" % tpath)
        else:
            rc, line = template_script("validate", template)
            if rc == 0:
                template_ok = True
            elif rc is None:
                errors.append("template check unavailable: %s could not be checked (%s)" % (tpath, line))
            else:
                errors.append("invalid template: %s - %s" % (tpath, script_reason(line) or "rejected"))

    if not has_template:
        for name in TEMPLATE_DEPENDENT:
            if name in values:
                errors.append("requires template: %s.%s is recorded but %s is not (it has no effect without a "
                              "template)" % (path, name, tpath))

    # ref_pattern: back-reference, ERE compile, then the commit path's own acceptance.
    rpath = path + ".ref_pattern"
    if "ref_pattern" in values and is_str(values["ref_pattern"]):
        pattern = values["ref_pattern"]
        ref_ok = True
        if "\x00" in pattern:
            errors.append("invalid ref_pattern: %s contains a NUL character" % rpath)
            ref_ok = False
        elif re.search(r"\\[0-9]", pattern):
            errors.append("invalid ref_pattern: %s contains a back-reference (a backslash followed by a digit)"
                          % rpath)
            ref_ok = False
        elif pattern.strip() != "" and len(pattern) <= REF_PATTERN_MAX \
                and not any(ord(ch) < 32 or ord(ch) == 127 for ch in pattern):
            rc, line = run_argv(["grep", "-E", "-e", pattern, os.devnull])
            if rc is not None and rc >= 2:
                errors.append("invalid ref_pattern: %s does not compile as a POSIX extended regular expression"
                              % rpath)
                ref_ok = False
        else:
            ref_ok = False  # empty, over-long or multi-line: reported by the per-field checks
        if ref_ok and template_ok:
            rc, line = template_script("derive", values["template"], "--ref-pattern", pattern)
            if rc is not None and rc != 0:
                errors.append("invalid ref_pattern: %s - %s" % (rpath, script_reason(line).replace(
                    "--ref-pattern", "the pattern") or "rejected"))

    # on_unresolved: name the phase in the schema's own "not an allowed value" message.
    upath = path + ".on_unresolved"
    prefix = "not an allowed value: %s " % upath
    for i, message in enumerate(errors):
        if message.startswith(prefix):
            errors[i] = message + '; Phase 1 accepts only "fail" (other policies belong to a later phase)'

    # subject_max_length: with a template the derived budget needs room for the prefix.
    if has_template and is_int(values.get("subject_max_length")):
        lo, hi = SUBJECT_LENGTH_RANGE
        n = values["subject_max_length"]
        if n < lo or n > hi:
            errors.append("out of range: %s.subject_max_length is %d (with a template it must be from %d to %d)"
                          % (path, n, lo, hi))


def check_values(values, category_id, path, errors):
    """Validate a values object against the category's field list in the schema."""
    if not isinstance(values, dict):
        errors.append("wrong type: %s must be an object (got %s)" % (path, kind(values)))
        return
    fields = ALL_CATEGORIES[category_id]["values"]
    for key in values:
        if key not in fields:
            errors.append("unknown key in values: %s.%s (allowed for %s: %s)"
                          % (path, key, category_id, ", ".join(fields)))
    for key, spec in fields.items():
        if key not in values:
            if spec.get("required"):
                errors.append("missing required field: %s.%s" % (path, key))
            continue
        check_typed(values[key], spec, "%s.%s" % (path, key), errors)
    if "template" in fields:
        # the category declares a commit template (selected by its field list, not by id: the ids live in the schema)
        check_commit_format(values, path, errors)


def check_strength_field(entry, path, errors):
    """The strength field's own type/enum check. A forbidden value is reported by walk_forbidden instead."""
    if "strength" not in entry:
        return
    value = entry["strength"]
    spath = path + ".strength"
    if not is_str(value):
        errors.append("wrong type: %s must be a string (got %s)" % (spath, kind(value)))
    elif value not in STRENGTH["forbidden"] and value not in STRENGTH["allowed"]:
        errors.append('bad strength: %s is %s (must be one of: %s)'
                      % (spath, show(value), ", ".join(STRENGTH["allowed"])))


def walk_forbidden(node, path, errors):
    """Report every forbidden strength value under a strength/enforcement key at any depth."""
    if isinstance(node, dict):
        for key, value in node.items():
            sub = key if path == "" else "%s.%s" % (path, key)
            if key in STRENGTH["forbidden_keys"] and is_str(value) and value in STRENGTH["forbidden"]:
                errors.append("block strength: %s is %s - %s" % (sub, show(value), BLOCK_MSG))
            walk_forbidden(value, sub, errors)
    elif isinstance(node, list):
        for i, item in enumerate(node):
            walk_forbidden(item, "%s[%d]" % (path, i), errors)


def check_string_field(entry, name, spec, path, errors, required):
    if name not in entry:
        if required:
            errors.append("missing required field: %s.%s" % (path, name))
        return
    check_string(entry[name], spec, "%s.%s" % (path, name), errors)


def check_top_level_keys(doc, allowed, errors):
    for key in doc:
        if key not in allowed:
            errors.append("unknown top-level key: %s (allowed: %s)" % (key, ", ".join(allowed)))


def check_version(doc, key, expected, errors):
    if key not in doc:
        errors.append("missing required field: %s" % key)
    elif not is_int(doc[key]) or doc[key] != expected:
        errors.append("bad %s: %s must be the integer %d (got %s)" % (key, key, expected, show(doc[key])))


def check_entry(cid, entry, errors):
    path = "categories.%s" % cid
    if not isinstance(entry, dict):
        errors.append("wrong type: %s must be an object (got %s)" % (path, kind(entry)))
        return
    for key in entry:
        if key not in ENTRY_FIELDS:
            errors.append("unknown field: %s.%s (allowed: %s)" % (path, key, ", ".join(ENTRY_FIELDS)))

    source = entry.get("source")
    source_ok = False
    if "source" not in entry:
        errors.append("missing required field: %s.source" % path)
    elif not is_str(source):
        errors.append("wrong type: %s.source must be a string (got %s)" % (path, kind(source)))
    elif source not in SOURCES:
        errors.append("bad source: %s.source is %s (must be one of: %s)" % (path, show(source), ", ".join(SOURCES)))
    else:
        source_ok = True

    if "preset" in entry:
        check_string(entry["preset"], ENTRY_FIELDS["preset"], path + ".preset", errors)
        pattern = ENTRY_FIELDS["preset"].get("pattern")
        if is_str(entry["preset"]) and pattern and entry["preset"].strip() != "" \
                and not re.fullmatch(pattern, entry["preset"]):
            errors.append("malformed preset id: %s.preset %s must be kebab-case (%s)"
                          % (path, show(entry["preset"]), pattern))
        if source_ok and source == "custom":
            errors.append('unexpected preset: %s.preset is not allowed when source is "custom"' % path)
    elif source_ok and source == "preset":
        errors.append('missing preset: %s.preset is required when source is "preset"' % path)

    check_string_field(entry, "summary", ENTRY_FIELDS["summary"], path, errors, True)

    if "values" not in entry:
        errors.append("missing required field: %s.values" % path)
    else:
        check_values(entry["values"], cid, path + ".values", errors)

    check_strength_field(entry, path, errors)


def validate_instance(doc):
    errors = []
    if not isinstance(doc, dict):
        return ["malformed JSON: top level must be a JSON object"]
    check_top_level_keys(doc, SCHEMA["top_level_keys"], errors)
    check_version(doc, "conventions_version", SCHEMA["conventions_version"], errors)
    if "categories" not in doc:
        errors.append("missing required field: categories")
    elif not isinstance(doc["categories"], dict):
        errors.append("wrong type: categories must be an object (got %s)" % kind(doc["categories"]))
    else:
        for cid, entry in doc["categories"].items():
            if cid not in ALL_CATEGORIES:
                errors.append("unknown category: categories.%s (allowed: %s)" % (cid, ALLOWED_IDS))
                continue
            check_entry(cid, entry, errors)
    walk_forbidden(doc, "", errors)
    return errors


def check_preset(cid, index, preset, seen_ids, errors):
    path = "categories.%s[%d]" % (cid, index)
    if not isinstance(preset, dict):
        errors.append("wrong type: %s must be an object (got %s)" % (path, kind(preset)))
        return
    for key in preset:
        if key not in PRESET_FIELDS:
            errors.append("unknown field: %s.%s (allowed: %s)" % (path, key, ", ".join(PRESET_FIELDS)))
    for name in ("id", "label", "description"):
        check_string_field(preset, name, PRESET_FIELDS[name], path, errors, PRESET_FIELDS[name].get("required"))
    pid = preset.get("id")
    if is_str(pid) and pid.strip() != "":
        pattern = PRESET_FIELDS["id"].get("pattern")
        if pattern and not re.fullmatch(pattern, pid):
            errors.append("malformed preset id: %s.id %s must be kebab-case (%s)" % (path, show(pid), pattern))
        if pid in seen_ids:
            errors.append("duplicate preset id: %s.id %s already used by categories.%s[%d]"
                          % (path, show(pid), cid, seen_ids[pid]))
        else:
            seen_ids[pid] = index
    if "values" not in preset:
        errors.append("missing required field: %s.values" % path)
    else:
        check_values(preset["values"], cid, path + ".values", errors)
    check_strength_field(preset, path, errors)


def validate_presets(doc):
    errors = []
    if not isinstance(doc, dict):
        return ["malformed JSON: top level must be a JSON object"]
    check_top_level_keys(doc, PRESETS["top_level_keys"], errors)
    check_version(doc, "presets_version", PRESETS["presets_version"], errors)
    lo, hi = PRESETS["min_per_category"], PRESETS["max_per_category"]
    if "categories" not in doc:
        errors.append("missing required field: categories")
        return errors
    cats = doc["categories"]
    if not isinstance(cats, dict):
        errors.append("wrong type: categories must be an object (got %s)" % kind(cats))
        return errors
    for cid in cats:
        if cid not in ALL_CATEGORIES:
            errors.append("unknown category: categories.%s (allowed: %s)" % (cid, ALLOWED_IDS))
    for cid in CATEGORIES:
        if cid not in cats:
            errors.append("category with no presets: categories.%s is absent (need %d to %d presets)"
                          % (cid, lo, hi))
            continue
        plist = cats[cid]
        if not isinstance(plist, list):
            errors.append("wrong type: categories.%s must be an array of presets (got %s)" % (cid, kind(plist)))
            continue
        if len(plist) == 0:
            errors.append("category with no presets: categories.%s has no presets (need %d to %d)" % (cid, lo, hi))
        elif len(plist) < lo or len(plist) > hi:
            errors.append("wrong preset count: categories.%s has %d preset%s (need %d to %d)"
                          % (cid, len(plist), "" if len(plist) == 1 else "s", lo, hi))
        seen_ids = {}
        for index, preset in enumerate(plist):
            check_preset(cid, index, preset, seen_ids, errors)
    # Opt-in categories are exempt from the presets rule: not required, no count bound, but whatever a catalog
    # provides for one is validated like any other preset.
    for cid in OPT_IN:
        if cid not in cats:
            continue
        plist = cats[cid]
        if not isinstance(plist, list):
            errors.append("wrong type: categories.%s must be an array of presets (got %s)" % (cid, kind(plist)))
            continue
        seen_ids = {}
        for index, preset in enumerate(plist):
            check_preset(cid, index, preset, seen_ids, errors)
    walk_forbidden(doc, "", errors)
    return errors


STRING_ONLY_PROPS = ("enum", "reserved", "max_length", "pattern")


def check_field_spec(where, spec, problems):
    """Check one field spec's optional properties, then its default against the rest of the spec."""
    own = []
    if spec["type"] != "string":
        for prop in STRING_ONLY_PROPS:
            if prop in spec:
                own.append("%s: %s is only supported on string fields (type is %s)" % (where, prop, spec["type"]))
    else:
        enum = spec.get("enum")
        if "enum" in spec:
            if not isinstance(enum, list) or not enum or not all(is_str(v) and v.strip() != "" for v in enum):
                own.append("%s: enum must be a non-empty array of non-empty strings" % where)
            elif len(set(enum)) != len(enum):
                own.append("%s: enum must not repeat a value" % where)
        reserved = spec.get("reserved")
        if "reserved" in spec:
            if not isinstance(reserved, dict) or not reserved:
                own.append("%s: reserved must be a non-empty object mapping a value to a note" % where)
            else:
                for rv, note in reserved.items():
                    if rv.strip() == "" or not is_str(note) or note.strip() == "" or "\n" in note or "\r" in note:
                        own.append("%s: reserved %s needs a non-empty single-line note" % (where, show(rv)))
                    elif isinstance(enum, list) and rv in enum:
                        own.append("%s: reserved value %s must not also be in enum" % (where, show(rv)))
        if "max_length" in spec and (not is_int(spec["max_length"]) or spec["max_length"] < 1):
            own.append("%s: max_length must be a positive integer" % where)
        if "pattern" in spec:
            if not is_str(spec["pattern"]) or spec["pattern"] == "":
                own.append("%s: pattern must be a non-empty string" % where)
            else:
                try:
                    re.compile(spec["pattern"])
                except re.error as exc:
                    own.append("%s: pattern does not compile: %s" % (where, exc))
    problems.extend(own)
    if own or "default" not in spec:
        return
    errs = []
    check_typed(spec["default"], spec, "default", errs)
    for message in errs:
        problems.append("%s has an invalid default: %s" % (where, message))


def check_schema_specs():
    problems = []
    for noun, group in (("category", CATEGORIES), ("opt-in category", OPT_IN)):
        for cid, cat in group.items():
            for fname, spec in cat["values"].items():
                check_field_spec("schema %s %s field %s" % (noun, cid, fname), spec, problems)
    if problems:
        for p in problems:
            sys.stderr.write("%s: %s\n" % (SCHEMA_PATH, p))
        sys.exit(1)


check_schema_specs()

validate = validate_presets if MODE == "presets" else validate_instance

failed = False
for path in sys.argv[1:]:
    doc, load_error = read_json(path)
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
