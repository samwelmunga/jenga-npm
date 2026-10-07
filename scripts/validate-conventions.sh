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

CONVENTIONS_SCHEMA="$SCHEMA" CONVENTIONS_MODE="$mode" python3 - "$@" <<'PY'
import json
import os
import re
import sys

MODE = os.environ["CONVENTIONS_MODE"]
SCHEMA_PATH = os.environ["CONVENTIONS_SCHEMA"]
VALUE_TYPES = ("string", "boolean", "integer", "string_array")
SPEC_FLAGS = ("type", "required", "single_line", "non_empty")


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
            for cid, cat in doc["categories"].items():
                if not isinstance(cat, dict) or not isinstance(cat.get("values"), dict):
                    problems.append("schema category %s has no values field list" % cid)
                    continue
                for fname, spec in cat["values"].items():
                    if not isinstance(spec, dict) or spec.get("type") not in VALUE_TYPES:
                        problems.append("schema category %s field %s has an unknown type (supported: %s)"
                                        % (cid, fname, ", ".join(VALUE_TYPES)))
    if problems:
        for p in problems:
            sys.stderr.write("%s: %s\n" % (SCHEMA_PATH, p))
        sys.exit(1)
    return doc


SCHEMA = load_schema()
CATEGORIES = SCHEMA["categories"]
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


def check_typed(value, spec, path, errors):
    t = spec["type"]
    if t == "string":
        check_string(value, spec, path, errors)
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


def check_values(values, category_id, path, errors):
    """Validate a values object against the category's field list in the schema."""
    if not isinstance(values, dict):
        errors.append("wrong type: %s must be an object (got %s)" % (path, kind(values)))
        return
    fields = CATEGORIES[category_id]["values"]
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
            if cid not in CATEGORIES:
                errors.append("unknown category: categories.%s (allowed: %s)" % (cid, ", ".join(CATEGORIES)))
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
        if cid not in CATEGORIES:
            errors.append("unknown category: categories.%s (allowed: %s)" % (cid, ", ".join(CATEGORIES)))
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
    walk_forbidden(doc, "", errors)
    return errors


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
