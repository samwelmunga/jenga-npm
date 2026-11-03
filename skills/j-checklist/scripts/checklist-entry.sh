#!/usr/bin/env bash
# checklist-entry.sh - the deterministic mutation engine of the j.checklist skill (E67_S10_T02).
#
# Appends, edits, removes, copies and moves ONE pre-flight checklist item in a registry file. Every write validates a candidate
# with scripts/validate-checklists.sh before an atomic replace, under scripts/with-lock.sh, and never reports
# success on a failed validation. Modelled on skills/j-tools/scripts/tools-entry.sh and
# skills/j-conventions/scripts/conventions-entry.sh. The registry schema is defined in
# project/documentation/preflight-checklists.md; "Editing a registry (E67_S10_T02)" and "Copying and moving between
# registries (E67_S10_T03)" there document this script. The print surface (E67_S10_T01) is checklist-print.sh, not here.
#
# Usage:
#   checklist-entry.sh [--registry PATH] path                 print the registry path in force
#   checklist-entry.sh [--registry PATH] situations           print the situations an item may name, one per line
#   checklist-entry.sh [--registry PATH] show ID              print one item as JSON
#   checklist-entry.sh [--registry PATH] check FIELD VALUE    validate ONE input as it is given (see below)
#   checklist-entry.sh [--registry PATH] check coupling KIND [VERIFY]
#   checklist-entry.sh [--registry PATH] add --id ID --text TEXT --situation S [--situation S]... --kind KIND
#                          [--verify COMMAND] --enforcement LEVEL --tick-scope SCOPE
#   checklist-entry.sh [--registry PATH] edit ID [--text TEXT] [--situation S]... [--kind KIND]
#                          [--verify COMMAND] [--enforcement LEVEL] [--tick-scope SCOPE]
#   checklist-entry.sh [--registry PATH] remove ID
#   checklist-entry.sh [--registry SRC] copy ID --to TARGET   write the item into another registry file
#   checklist-entry.sh [--registry SRC] move ID --to TARGET   the same, then remove it from the source
#   checklist-entry.sh --help                                 print this contract
#
# Option values are a separate argument (`--text "..."`, not `--text=...`). ID may also be given as `--id ID`.
# --registry may appear anywhere. A repeated --situation builds the list; on `edit` it REPLACES the whole list.
# A path with a different name from checklists.json works unchanged (E67_S10_T03 addresses registries by path).
#
# Registry in force, highest priority first: --registry PATH; JENGA_CHECKLISTS_FILE (the same override
# scripts/checklist.sh honours); "<configs>/checklists.json" with <configs> from scripts/resolve-root.sh get
# configs (JENGA_PROJECT_ROOT honoured). The file must already exist: this script never creates a registry, because
# a project instance silently replaces (never merges with) the shipped default, so creating one by appending a single
# item would drop every shipped item. Only copy/move create a registry, and they seed it (see copy/move below).
#
# add:     appends one item to items[]. Pre-existing items stay byte-identical and in order; checklist_version,
#          situations and every other byte of the file are untouched. The new text is spliced in after the last
#          item, in the indentation and array style the file already uses; the file is never re-serialised. The item
#          is written with provenance {"source": "authored"}; a "suggested" provenance or any of its fields is never
#          written. An id prefixed "conv-" is accepted (an ordinary item) with a warning on stderr, because
#          scripts/generate-convention-checklist.sh refuses to generate over a same-id item it does not own.
# edit:    changes the named fields of one item by id; every other item stays byte-identical. The id and
#          provenance are never changed. Changing kind re-checks the verify coupling: flipping to "judgment" drops the
#          now-forbidden verify key (and refuses --verify in the same call); flipping to "machine" needs --verify.
#          An edit that changes nothing writes nothing and reports "changed": false.
# remove:  deletes one item by id, with exactly the comma and whitespace that belonged to it; every other item
#          stays byte-identical. Removing an item does NOT touch its tick records; a stale tick for a deleted item
#          is already handled by the definition-hash binding in scripts/checklist.sh.
# check:   validates ONE input with the same rules `add` and `edit` apply, so a wizard can reject it at the moment it
#          is given. FIELD is id (format, then collision with an existing id), text, situation (one name), situations
#          (comma separated), kind, verify, enforcement or tick-scope. `check coupling KIND [VERIFY]` validates the
#          kind/verify pairing (omit VERIFY for "no verify key"). Prints {"valid": true} or {"valid": false, "reason":
#          "..."}; unlike conventions-entry.sh the exit status is 0 only for a valid input, otherwise the item exit
#          code below (7, or 8 for an id collision).
# show:    prints the item as JSON (exit 9 for an unknown id). path, situations and show never write.
# copy:    writes a complete copy of the item (every key, provenance verbatim: authored stays authored, nothing is
#          rewritten as "suggested") into the registry file named by --to, appended after its last item like `add`.
#          SRC is the registry in force (--registry, JENGA_CHECKLISTS_FILE, else the project instance); when no project
#          instance exists the registry in force is the shipped default and SRC falls back to it (not with --registry).
#          --to is required (there is no default target, so the shipped templates/checklists.json is never one
#          implicitly). Refusals: an id already in the target (exit 8: never overwritten, never renamed); a managed
#          "conv-" item (exit 10); a situation the target does not declare (exit 12); source and target the same file
#          (exit 13). Situations: base situations are valid everywhere, an extension (pre-publish, ...) only in a file
#          that declares it, so the item is REFUSED rather than silently carried; declaring a situation stays a by-hand
#          edit of the target's top-level situations (a splice-only writer never rewrites another key).
#          Seed on first instance: when the --to file does not exist (any path, not only <configs>/checklists.json),
#          it is created from the registry in force for a project with no instance, the shipped default (see
#          JENGA_CHECKLISTS_DEFAULT_FILE below), plus the incoming item, never from the item alone: selection is
#          whole-file, so a bare one-item instance would silently drop every shipped item. The seed is reported on
#          stdout as a line starting "SEEDED:" before the result JSON. --to's directory must exist (exit 14).
#          Shipped default as a target: writing templates/checklists.json is permitted only as an explicit --to, and
#          prints a warning on stderr that it ships downstream and must stay free of project-specific policy.
# move:    copy, then remove the item from the source. The source must not be the shipped default (exit 13: it is only
#          ever written as an explicit --to target), and a managed "conv-" item is refused (exit 10).
#
# Cross-file ordering (move): both files are changed in this order and no other.
#   1. Lock both files with scripts/with-lock.sh, nested, in ascending order of their canonical (realpath) path in byte
#      order, so two processes moving in opposite directions take the locks in the same order and cannot deadlock. The
#      lock is keyed on the path as given (like add/edit/remove); spell a file the same way to exclude another writer.
#      copy locks the target only: the source is just read, and an atomic replace gives a consistent snapshot.
#   2. Under the locks, build the target candidate and (move) the source candidate. Nothing is replaced yet.
#   3. Validate every candidate with scripts/validate-checklists.sh. Any failure ends the run: both files untouched.
#   4. Back up the target (if it exists), then atomically replace the target, THEN (move) atomically replace the
#      source. The source loses the item only after the target write succeeded and validated.
#   5. If replacing the source fails after the target was replaced, the target is restored from the backup (or deleted
#      if this run created it), also on INT/TERM. Every failure therefore leaves both files byte-identical to their
#      start. The one window not covered is SIGKILL between the two replaces; the backup is
#      "<target>.rollback.<pid>" and is left behind in that case.
# Failure injection (tests): JENGA_CHECKLIST_ENTRY_FAIL_AT=<stage> forces a failure at one stage of copy/move; the
# run rolls back exactly as for a real failure and reports the exit code that failure would give. Stages: seed-read
# (14; reached only when the target does not exist), target-candidate (1), source-candidate (1, move only), target-validate (11), source-validate (11, move only),
# target-replace (1), source-replace (1, move only; fails after the target was replaced, so it exercises the
# rollback). Any other value is a usage error (2).
#
# Managed items: an item is managed if and only if its id starts with "conv-" AND its provenance.source is
# "convention" (the two-part test scripts/generate-convention-checklist.sh uses). `edit` and `remove` refuse it (exit
# 10) and name j.conventions as the place to change it. A "conv-" id with other or no provenance is ordinary.
#
# Write discipline (every write): under scripts/with-lock.sh on the registry, read the registry, write a candidate
# "<registry>.candidate.<pid>" in the same directory, validate the CANDIDATE with scripts/validate-checklists.sh, and
# only on PASS `mv -f` it over the registry. On FAIL the candidate is removed, the validator's lines go to stderr
# (naming the registry), the original is untouched and the exit code is 11. On success one JSON line goes to stdout:
#   {"ok":true,"action":"add|edit|remove","id":"...","registry":"...","changed":true|false}
# A lock that cannot be acquired means nothing ran (exit 6). Argument errors are caught before the lock is taken.
#
# Environment (tests): JENGA_PROJECT_ROOT, JENGA_CHECKLISTS_FILE, WITH_LOCK_* (with-lock.sh),
# JENGA_CHECKLISTS_DEFAULT_FILE (the shipped default: the seed source and the file written only as an explicit --to,
# the same override scripts/checklist.sh honours; without it, package-relative templates/checklists.json first, else
# templates/checklists.json or node_modules/@jenga-ai/agent/templates/checklists.json), JENGA_CHECKLIST_ENTRY_FAIL_AT.
#
# Exit codes:
#   0   success (including an `edit` that changed nothing, and a valid `check`)
#   1   internal error: the candidate could not be written or moved into place, or an unexpected failure
#   2   usage error: unknown subcommand or option, a missing required option, nothing to edit
#   3   python3 is not installed
#   4   the registry is unusable: not found, unreadable, not valid JSON, not an object with an items array, or the
#       target id appears more than once
#   5   the project configs path could not be resolved (resolve-root.sh failed)
#   6   the lock could not be acquired; nothing was written
#   7   an input violates a schema rule (id format, empty text, situations, kind, verify coupling, enforcement,
#       tick_scope); each violation is its own stderr line
#   8   id collision: `add` named an id that already exists, or the target of `copy`/`move` already has the id
#   9   unknown id: `edit`, `remove` or `show` named an id that is not in the registry
#   10  managed item refused: `edit`, `remove`, `copy` or `move` targeted a generated conv- item (change it with
#       j.conventions)
#   11  a candidate failed scripts/validate-checklists.sh; no registry was changed (copy/move: neither file)
#   12  situation not declared: `copy`/`move` item names a situation the target does not declare; nothing was written
#   13  transfer refused: source and target are the same file, or `move` would remove from the shipped default
#   14  target unusable: its directory does not exist, it is not a regular file, or the shipped default needed as the
#       seed source was not found
#
# Compatible with macOS bash 3.2 (no associative arrays, mapfile or case-modifying expansions). Needs python3.

set -u

SELF="checklist-entry.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SELF_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

# locate_script <name>: the package's scripts/<name>, else the cwd-relative dual-path idiom (a consumer project
# where this script was copied elsewhere).
locate_script() {
  if [ -f "$PACKAGE_ROOT/scripts/$1" ]; then
    printf '%s' "$PACKAGE_ROOT/scripts/$1"
  else
    printf '%s' "$([ -f "scripts/$1" ] && echo "scripts/$1" || echo "node_modules/@jenga-ai/agent/scripts/$1")"
  fi
}
RESOLVE_ROOT="$(locate_script resolve-root.sh)"
VALIDATOR="$(locate_script validate-checklists.sh)"
WITH_LOCK="$(locate_script with-lock.sh)"

die() {
  local code="$1"
  shift
  printf '%s: %s\n' "$SELF" "$*" >&2
  exit "$code"
}

die_usage() {
  printf '%s: %s\n' "$SELF" "$*" >&2
  printf 'run "%s --help" for the contract\n' "$SELF" >&2
  exit 2
}

# The contract is this file's own header (its first comment block).
print_contract() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

command -v python3 >/dev/null 2>&1 || die 3 "python3 is required but was not found on PATH"

# --- the python engine -------------------------------------------------------------------------------------------
#
# engine <op> <registry> <candidate|-> [args...]. Ops: parse-check, path-free argument validation; show; situations;
# check; add; edit; remove. A mutating op writes the candidate only when it changed something, prints its result
# JSON on stdout and exits 0; every refusal prints "checklist-entry.sh: <reason>" on stderr and exits with the
# script's own exit code (see the header), so bash passes the status straight through.
engine() {
  python3 - "$@" <<'PY'
import copy
import json
import os
import re
import shutil
import sys

SELF = "checklist-entry.sh"
BASE_SITUATIONS = ["pre-commit", "pre-task", "pre-release", "pre-reconcile"]
KINDS = ("machine", "judgment")
ENFORCEMENTS = ("block", "confirm", "advisory")
TICK_SCOPES = ("run", "persistent")
ID_RE = re.compile(r"[a-z0-9]+(-[a-z0-9]+)*")

E_INTERNAL, E_USAGE, E_REGISTRY, E_INPUT, E_COLLISION, E_UNKNOWN_ID, E_MANAGED = 1, 2, 4, 7, 8, 9, 10
E_VALIDATION, E_SITUATION, E_REFUSED, E_TARGET = 11, 12, 13, 14
FAIL_ENV = "JENGA_CHECKLIST_ENTRY_FAIL_AT"


def die(code, *lines):
    for line in lines:
        sys.stderr.write("%s: %s\n" % (SELF, line))
    sys.exit(code)


def usage(msg):
    sys.stderr.write("%s: %s\n" % (SELF, msg))
    sys.stderr.write('run "%s --help" for the contract\n' % SELF)
    sys.exit(E_USAGE)


def dumps(v):
    return json.dumps(v, ensure_ascii=False)


# --- field rules (the schema rules of preflight-checklists.md sections 2 and 5) ------------------------------

def rule_id(v):
    if not isinstance(v, str) or not ID_RE.fullmatch(v):
        return ["invalid id: %s is not kebab-case (must match ^[a-z0-9]+(-[a-z0-9]+)*$)" % dumps(v)]
    return []


def rule_text(v):
    if not isinstance(v, str) or v.strip() == "":
        return ["invalid text: must be a non-empty string"]
    if "\n" in v or "\r" in v:
        return ["invalid text: must be a single line (a line break would break the printed checklist form)"]
    return []


def rule_situations(v, allowed):
    if not isinstance(v, list) or len(v) == 0:
        return ["invalid situations: must name at least one situation"]
    out, seen = [], []
    for s in v:
        if not isinstance(s, str) or s not in allowed:
            out.append("invalid situations: unknown situation %s (allowed: %s; a new situation is declared by hand "
                       "in the file's top-level situations)" % (dumps(s), ", ".join(allowed)))
        elif s in seen:
            out.append("invalid situations: duplicate situation %s" % dumps(s))
        seen.append(s)
    return out


def rule_kind(v):
    if not isinstance(v, str) or v not in KINDS:
        return ['invalid kind: %s (must be "machine" or "judgment")' % dumps(v)]
    return []


def rule_verify(v):
    if not isinstance(v, str) or v.strip() == "":
        return ["invalid verify: must be a non-empty command line"]
    return []


def rule_enforcement(v):
    if not isinstance(v, str) or v not in ENFORCEMENTS:
        return ['invalid enforcement: %s (must be "block", "confirm" or "advisory")' % dumps(v)]
    return []


def rule_tick_scope(v):
    if not isinstance(v, str) or v not in TICK_SCOPES:
        return ['invalid tick_scope: %s (must be "run" or "persistent")' % dumps(v)]
    return []


def rule_coupling(kind, has_verify, verify):
    """kind/verify coupling in both directions. Only meaningful for a valid kind."""
    if kind == "machine":
        if not has_verify or not isinstance(verify, str) or verify.strip() == "":
            return ['invalid verify: a "machine" item requires a non-empty verify command']
    elif kind == "judgment":
        if has_verify:
            return ['invalid verify: a "judgment" item must not carry a verify key at all']
    return []


def validate_item(item, allowed):
    """Every field rule against one whole item. Returns a list of messages (empty means valid)."""
    out = []
    for key, rule in (("id", rule_id), ("text", rule_text)):
        out += rule(item[key]) if key in item else ["missing %s" % key]
    out += rule_situations(item["situations"], allowed) if "situations" in item else ["missing situations"]
    if "kind" in item:
        k = rule_kind(item["kind"])
        out += k
        if not k:
            out += rule_coupling(item["kind"], "verify" in item, item.get("verify"))
    else:
        out.append("missing kind")
    out += rule_enforcement(item["enforcement"]) if "enforcement" in item else ["missing enforcement"]
    out += rule_tick_scope(item["tick_scope"]) if "tick_scope" in item else ["missing tick_scope"]
    return out


def is_managed(item):
    prov = item.get("provenance")
    return (isinstance(item.get("id"), str) and item["id"].startswith("conv-")
            and isinstance(prov, dict) and prov.get("source") == "convention")


# --- raw-text scanner: byte spans of the items array and of each of its elements ----------------------------

def scan(text):
    """Return (open_idx, close_idx, [(start, end), ...]) for the top-level "items" array. The scanner is
    string-aware, so brackets, braces, commas and escaped quotes inside strings (verify commands have all of them)
    never confuse it."""
    n = len(text)
    i = 0
    depth = 0
    open_idx = close_idx = None
    elems = []
    elem_start = None
    last = None
    expect_key = False
    pending = False
    in_items = False
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            if j >= n:
                raise ValueError("unterminated string")
            end = j + 1
            if depth == 1 and expect_key:
                expect_key = False
                pending = json.loads(text[i:end]) == "items" and open_idx is None
            else:
                if pending and depth == 1:
                    raise ValueError("items is not an array")
                if in_items and depth == 2:
                    if elem_start is None:
                        elem_start = i
                    last = end
            i = end
            continue
        if c in "{[":
            if pending and depth == 1:
                if c != "[":
                    raise ValueError("items is not an array")
                open_idx = i
                in_items = True
                pending = False
            elif in_items and depth == 2 and elem_start is None:
                elem_start = i
            depth += 1
            if c == "{" and depth == 1:
                expect_key = True
            i += 1
            continue
        if c in "}]":
            depth -= 1
            if in_items and depth == 1 and c == "]":
                if elem_start is not None:
                    elems.append((elem_start, last))
                close_idx = i
                in_items = False
            elif in_items and depth == 2:
                last = i + 1
            i += 1
            continue
        if c == ",":
            if in_items and depth == 2:
                if elem_start is None:
                    raise ValueError("empty element")
                elems.append((elem_start, last))
                elem_start = None
            elif depth == 1:
                expect_key = True
            i += 1
            continue
        if c == ":":
            i += 1
            continue
        if pending and depth == 1:
            raise ValueError("items is not an array")
        if in_items and depth == 2:
            if elem_start is None:
                elem_start = i
            last = i + 1
        i += 1
    if open_idx is None or close_idx is None:
        raise ValueError("no top-level items array")
    return open_idx, close_idx, elems


def eol(text, crlf):
    """Re-terminate generated lines with CRLF for a CRLF file. JSON strings carry no raw line breaks, so every
    newline in generated text is structural."""
    return text.replace("\n", "\r\n") if crlf else text


class Registry:
    def __init__(self, path):
        self.path = path
        try:
            with open(path, "rb") as fh:
                raw = fh.read()
        except OSError as exc:
            hint = ""
            if not os.path.exists(path):
                hint = " (this script never creates a registry; a missing project instance is seeded by copy/move)"
            die(E_REGISTRY, "cannot read registry %s: %s%s" % (path, exc.strerror or exc, hint))
        try:
            self.text = raw.decode("utf-8")
            self.doc = json.loads(self.text)
        except (ValueError, UnicodeDecodeError) as exc:
            die(E_REGISTRY, "registry %s is not valid JSON: %s" % (path, exc))
        if not isinstance(self.doc, dict) or not isinstance(self.doc.get("items"), list):
            die(E_REGISTRY, "registry %s is not a JSON object with an items array" % path)
        try:
            self.open, self.close, self.elems = scan(self.text)
        except ValueError as exc:
            die(E_REGISTRY, "registry %s: cannot locate the items array in the text (%s)" % (path, exc))
        if len(self.elems) != len(self.doc["items"]):
            die(E_REGISTRY, "registry %s: item spans (%d) do not match its items (%d)"
                % (path, len(self.elems), len(self.doc["items"])))
        decl = self.doc.get("situations")
        extra = [s for s in decl if isinstance(s, str) and s not in BASE_SITUATIONS] if isinstance(decl, list) else []
        self.allowed = BASE_SITUATIONS + [s for i, s in enumerate(extra) if s not in extra[:i]]
        self._style()

    def _style(self):
        """Indentation and array style, learnt from the file so new text matches what is already there."""
        t = self.text
        key_line = t.rfind("\n", 0, self.open) + 1
        self.key_indent = re.match(r"[ \t]*", t[key_line:]).group(0)
        self.multiline = "\n" in t
        self.expand = False
        if self.elems:
            s = self.elems[0][0]
            line = t.rfind("\n", 0, s) + 1
            lead = t[line:s]
            self.multiline = line > self.open and lead.strip() == ""
            self.elem_indent = lead if self.multiline else ""
            self.expand = any(re.search(r"\[\s*\n", t[a:b]) for a, b in self.elems)
        else:
            self.elem_indent = self.key_indent + "  "
        if self.elem_indent.startswith(self.key_indent) and len(self.elem_indent) > len(self.key_indent):
            self.unit = self.elem_indent[len(self.key_indent):]
        else:
            self.unit = "  "

    def render(self, v, ind):
        if not self.multiline:
            return json.dumps(v, ensure_ascii=False, separators=(", ", ": "))
        return self._render(v, ind)

    def _render(self, v, ind):
        if isinstance(v, dict):
            if not v:
                return "{}"
            inner = ind + self.unit
            return "{\n" + ",\n".join(inner + dumps(k) + ": " + self._render(x, inner) for k, x in v.items()) \
                + "\n" + ind + "}"
        if isinstance(v, list):
            if not v:
                return "[]"
            scalar = all(not isinstance(x, (dict, list)) for x in v)
            if scalar and not self.expand:
                return "[" + ", ".join(dumps(x) for x in v) + "]"
            inner = ind + self.unit
            return "[\n" + ",\n".join(inner + self._render(x, inner) for x in v) + "\n" + ind + "]"
        return dumps(v)

    def find(self, item_id):
        hits = [i for i, it in enumerate(self.doc["items"]) if isinstance(it, dict) and it.get("id") == item_id]
        if len(hits) > 1:
            die(E_REGISTRY, "registry %s has %d items with id %s; fix the duplicate by hand first"
                % (self.path, len(hits), dumps(item_id)))
        return hits[0] if hits else None

    def spliced(self, kind, index=None, item=None):
        """Return the new file text. Only the bytes belonging to the affected item change. New text uses the
        file's own line ending (CRLF files stay CRLF)."""
        t = self.text
        crlf = "\r\n" in t
        if kind == "add":
            if self.elems:
                end = self.elems[-1][1]
                sep = ",\n" + self.elem_indent if self.multiline else ", "
                return t[:end] + eol(sep + self.render(item, self.elem_indent), crlf) + t[end:]
            body = ("\n" + self.elem_indent + self.render(item, self.elem_indent) + "\n" + self.key_indent
                    if self.multiline else self.render(item, ""))
            return t[:self.open + 1] + eol(body, crlf) + t[self.close:]
        s, e = self.elems[index]
        if kind == "edit":
            return t[:s] + eol(self.render(item, self.elem_indent), crlf) + t[e:]
        # remove
        if len(self.elems) == 1:
            return t[:self.open + 1] + t[self.close:]
        if index < len(self.elems) - 1:
            return t[:s] + t[self.elems[index + 1][0]:]
        return t[:self.elems[index - 1][1]] + t[e:]


def write_candidate(reg, new_text, expected_items, candidate, mode_from=None):
    """Self-check the spliced text (it must parse, with exactly the expected items and every other top-level key
    unchanged), then write it beside the registry with the registry's mode."""
    try:
        parsed = json.loads(new_text)
    except ValueError as exc:
        die(E_INTERNAL, "internal error: the spliced registry does not parse (%s); nothing written" % exc)
    expected = copy.deepcopy(reg.doc)
    expected["items"] = expected_items
    if parsed != expected:
        die(E_INTERNAL, "internal error: the spliced registry differs from the intended result; nothing written")
    try:
        with open(candidate, "wb") as fh:
            fh.write(new_text.encode("utf-8"))
        shutil.copymode(mode_from or reg.path, candidate)
    except OSError as exc:
        die(E_INTERNAL, "cannot write the candidate %s: %s" % (candidate, exc.strerror or exc))


# --- argument parsing --------------------------------------------------------------------------------------------

ADD_FLAGS = {"--id": ("id", False), "--text": ("text", False), "--situation": ("situations", True),
             "--kind": ("kind", False), "--verify": ("verify", False), "--enforcement": ("enforcement", False),
             "--tick-scope": ("tick_scope", False)}
EDIT_FLAGS = dict(ADD_FLAGS)


def parse_flags(argv, spec):
    out, pos, i = {}, [], 0
    while i < len(argv):
        a = argv[i]
        if a in spec:
            if i + 1 >= len(argv):
                usage("option %s needs a value" % a)
            key, multi = spec[a]
            if multi:
                out.setdefault(key, []).append(argv[i + 1])
            elif key in out:
                usage("option %s was given more than once" % a)
            else:
                out[key] = argv[i + 1]
            i += 2
        elif a.startswith("-") and len(a) > 1:
            usage("unknown option: %s" % a)
        else:
            pos.append(a)
            i += 1
    return out, pos


def parse_target(op, argv, spec):
    """For edit/remove/show: the item id comes from --id or a single positional argument."""
    flags, pos = parse_flags(argv, spec)
    if len(pos) > 1:
        usage("%s takes one id, got %d arguments" % (op, len(pos)))
    if pos and "id" in flags:
        usage("%s: give the id once, either positionally or with --id" % op)
    item_id = flags.pop("id", pos[0] if pos else None)
    if item_id is None:
        usage("%s needs the id of the item" % op)
    return item_id, flags


def parse_op(op, argv):
    """Syntax-only parse of a mutating op; returns what the op needs. Exits 2 on a usage error."""
    if op == "add":
        flags, pos = parse_flags(argv, ADD_FLAGS)
        if pos:
            usage("add takes options only, got %s" % dumps(pos[0]))
        missing = [f for f, (k, _) in ADD_FLAGS.items() if f != "--verify" and k not in flags]
        if missing:
            usage("add needs %s" % ", ".join(missing))
        return flags
    if op == "edit":
        item_id, flags = parse_target(op, argv, EDIT_FLAGS)
        if not flags:
            usage("edit needs at least one field to change")
        return item_id, flags
    if op == "remove":
        item_id, flags = parse_target(op, argv, {"--id": ("id", False)})
        return item_id, flags
    if op in ("copy", "move"):
        item_id, flags = parse_target(op, argv, {"--id": ("id", False), "--to": ("to", False)})
        if "to" not in flags or flags["to"] == "":
            usage("%s needs --to TARGET, the registry file to write the item into" % op)
        return item_id, flags
    usage("unknown operation: %s" % op)


# --- operations ---------------------------------------------------------------------------------------------------

def result(action, item_id, path, changed):
    sys.stdout.write(json.dumps({"ok": True, "action": action, "id": item_id, "registry": path,
                                 "changed": changed}, ensure_ascii=False, separators=(",", ":")) + "\n")


def op_add(reg, flags, candidate):
    item = {"id": flags["id"], "text": flags["text"], "situations": flags["situations"], "kind": flags["kind"]}
    if "verify" in flags:
        item["verify"] = flags["verify"]
    item["enforcement"] = flags["enforcement"]
    item["tick_scope"] = flags["tick_scope"]
    problems = validate_item(item, reg.allowed)
    if problems:
        die(E_INPUT, *problems)
    if reg.find(item["id"]) is not None:
        die(E_COLLISION, "id collision: an item with id %s already exists; ids are never reused, so choose another "
            "id or use edit" % dumps(item["id"]))
    item["provenance"] = {"source": "authored"}
    if item["id"].startswith("conv-"):
        sys.stderr.write("%s: warning: ids prefixed conv- are used by generated convention items; "
                         "scripts/generate-convention-checklist.sh will refuse to generate an item with this "
                         "id\n" % SELF)
    new_text = reg.spliced("add", item=item)
    write_candidate(reg, new_text, reg.doc["items"] + [item], candidate)
    result("add", item["id"], reg.path, True)


def refuse_managed(item):
    if is_managed(item):
        die(E_MANAGED, "item %s is a managed convention item generated from conventions.json; change it with "
            "j.conventions, because a hand edit is overwritten on the next j.conventions run" % dumps(item["id"]))


def locate_target(reg, item_id):
    idx = reg.find(item_id)
    if idx is None:
        die(E_UNKNOWN_ID, "unknown id: no item %s in %s" % (dumps(item_id), reg.path))
    return idx


def op_edit(reg, item_id, flags, candidate):
    idx = locate_target(reg, item_id)
    old = reg.doc["items"][idx]
    refuse_managed(old)
    new = dict(old)
    for key in ("text", "situations", "enforcement", "tick_scope"):
        if key in flags:
            new[key] = flags[key]
    if "kind" in flags:
        new["kind"] = flags["kind"]
        if flags["kind"] == "judgment" and "verify" in new and "verify" not in flags:
            del new["verify"]  # the now-forbidden key goes with the flip
    if "verify" in flags:
        if "verify" in new:
            new["verify"] = flags["verify"]
        else:
            rebuilt = {}
            for k, v in new.items():
                rebuilt[k] = v
                if k == "kind":
                    rebuilt["verify"] = flags["verify"]
            if "verify" not in rebuilt:
                rebuilt["verify"] = flags["verify"]
            new = rebuilt
    problems = validate_item(new, reg.allowed)
    if problems:
        die(E_INPUT, *problems)
    if new == old:
        result("edit", item_id, reg.path, False)
        return
    items = copy.deepcopy(reg.doc["items"])
    items[idx] = new
    write_candidate(reg, reg.spliced("edit", index=idx, item=new), items, candidate)
    result("edit", item_id, reg.path, True)


def op_remove(reg, item_id, candidate):
    idx = locate_target(reg, item_id)
    refuse_managed(reg.doc["items"][idx])
    items = copy.deepcopy(reg.doc["items"])
    del items[idx]
    write_candidate(reg, reg.spliced("remove", index=idx), items, candidate)
    result("remove", item_id, reg.path, True)


def inject(stage):
    """Test seam: JENGA_CHECKLIST_ENTRY_FAIL_AT=<stage> forces a failure at the named stage (see the header)."""
    if os.environ.get(FAIL_ENV) == stage:
        code = E_TARGET if stage == "seed-read" else E_INTERNAL
        die(code, "injected failure at stage %s (%s); nothing written" % (stage, FAIL_ENV))


def canon(path):
    return os.path.realpath(path)


def op_transfer(mode, src_path, item_id, flags, tcand):
    """copy/move: build the target candidate (and for move the source candidate). Replacing is bash's job, under
    the locks, after every candidate validated. CE_DEFAULT is the shipped default (the seed source), CE_SHIPPED the
    newline-separated paths that count as the shipped default, CE_SOURCE_CANDIDATE where the move candidate goes."""
    to = flags["to"]
    default = os.environ.get("CE_DEFAULT", "")
    shipped = [canon(p) for p in os.environ.get("CE_SHIPPED", "").split("\n") if p]
    scand = os.environ.get("CE_SOURCE_CANDIDATE", "")

    src = Registry(src_path)
    idx = locate_target(src, item_id)
    item = copy.deepcopy(src.doc["items"][idx])
    if is_managed(item):
        die(E_MANAGED, "item %s is a managed convention item generated from conventions.json and cannot be %s; "
            "it is owned by j.conventions, which generates it in every project that records conventions"
            % (dumps(item_id), "copied" if mode == "copy" else "moved"))
    if canon(src_path) == canon(to):
        die(E_REFUSED, "source and target are the same file (%s); %s needs a different registry" % (src_path, mode))
    if mode == "move" and canon(src_path) in shipped:
        die(E_REFUSED, "refusing to move %s out of the shipped default %s: it is only ever written as an explicit "
            "--to target; use copy, or edit/remove it there on purpose with --registry" % (dumps(item_id), src_path))

    seeded, seeded_items, mode_from = False, 0, to
    if os.path.lexists(to):
        if not os.path.isfile(to):
            die(E_TARGET, "target %s exists but is not a regular file" % to)
        tgt = Registry(to)
    else:
        if not os.path.isdir(os.path.dirname(os.path.abspath(to))):
            die(E_TARGET, "target %s: its directory does not exist; create the directory first" % to)
        inject("seed-read")
        if not default or not os.path.isfile(default):
            die(E_TARGET, "cannot seed %s: the shipped default registry was not found (looked for %s)"
                % (to, default or "templates/checklists.json or node_modules/@jenga-ai/agent/templates/checklists.json"))
        tgt = Registry(default)
        tgt.path = to
        seeded, seeded_items, mode_from = True, len(tgt.doc["items"]), default

    missing = [s for s in item["situations"] if s not in tgt.allowed] if isinstance(item.get("situations"), list) else []
    if missing:
        die(E_SITUATION, "situation not declared by the target: item %s names %s, but %s declares only %s; declare it "
            "in the target's top-level situations by hand (a base situation needs no declaration), then retry"
            % (dumps(item_id), ", ".join(dumps(s) for s in missing), to, ", ".join(tgt.allowed)))
    problems = validate_item(item, tgt.allowed)
    if problems:
        die(E_INPUT, *problems)
    if tgt.find(item_id) is not None:
        die(E_COLLISION, "id collision: %s already has an item %s%s; it is not overwritten and not renamed" % (
            to, dumps(item_id), " (it is one of the %d shipped items it would be seeded with)" % seeded_items
            if seeded else ""))

    inject("target-candidate")
    write_candidate(tgt, tgt.spliced("add", item=item), tgt.doc["items"] + [item], tcand, mode_from=mode_from)
    if mode == "move":
        inject("source-candidate")
        remaining = copy.deepcopy(src.doc["items"])
        del remaining[idx]
        write_candidate(src, src.spliced("remove", index=idx), remaining, scand)

    if canon(to) in shipped:
        sys.stderr.write("%s: warning: %s is the shipped default registry; it ships downstream to every project, so "
                         "keep it free of project-specific policy\n" % (SELF, to))
    out = {"ok": True, "action": mode, "id": item_id, "source": src_path, "target": to, "seeded": seeded,
           "changed": True}
    if seeded:
        out["seed_source"] = default
        out["seeded_items"] = seeded_items
        sys.stdout.write("SEEDED: %s did not exist, so it was created from the registry in force (%s, %d shipped "
                         "items) plus %s; a project instance replaces the shipped default whole and never merges "
                         "with it, so %s now carries those %d items and %s\n"
                         % (to, default, seeded_items, dumps(item_id), to, seeded_items, dumps(item_id)))
    sys.stdout.write(json.dumps(out, ensure_ascii=False, separators=(",", ":")) + "\n")


def op_check(reg_path, argv):
    if not argv:
        usage("check needs a field and a value")
    field, rest = argv[0], argv[1:]
    reg = None

    def registry():
        return reg if reg is not None else Registry(reg_path)

    problems, code = [], E_INPUT
    if field == "coupling":
        if not 1 <= len(rest) <= 2:
            usage("check coupling needs KIND and optionally VERIFY")
        problems = rule_kind(rest[0]) or rule_coupling(rest[0], len(rest) == 2, rest[1] if len(rest) == 2 else None)
    else:
        if len(rest) != 1:
            usage("check %s needs exactly one value" % field)
        v = rest[0]
        if field == "id":
            problems = rule_id(v)
            if not problems and registry().find(v) is not None:
                problems, code = ["id collision: an item with id %s already exists" % dumps(v)], E_COLLISION
        elif field == "text":
            problems = rule_text(v)
        elif field == "situation":
            problems = rule_situations([v], registry().allowed)
        elif field == "situations":
            problems = rule_situations([s.strip() for s in v.split(",")], registry().allowed)
        elif field == "kind":
            problems = rule_kind(v)
        elif field == "verify":
            problems = rule_verify(v)
        elif field == "enforcement":
            problems = rule_enforcement(v)
        elif field in ("tick-scope", "tick_scope"):
            problems = rule_tick_scope(v)
        else:
            usage("unknown check field: %s" % field)
    if problems:
        sys.stdout.write(json.dumps({"valid": False, "reason": "; ".join(problems)}, ensure_ascii=False) + "\n")
        sys.stderr.write("".join("%s: %s\n" % (SELF, p) for p in problems))
        sys.exit(code)
    sys.stdout.write('{"valid": true}\n')


def main():
    if len(sys.argv) < 4:
        usage("internal: engine called without an operation")
    op, reg_path, candidate = sys.argv[1], sys.argv[2], sys.argv[3]
    argv = sys.argv[4:]
    if op == "parse-check":
        parsed = parse_op(argv[0], argv[1:])
        if argv[0] in ("copy", "move"):
            sys.stdout.write(parsed[1]["to"] + "\n")
        return
    if op == "check":
        op_check(reg_path, argv)
        return
    if op == "canon":
        sys.stdout.write(canon(reg_path) + "\n")
        return
    if op == "show":
        item_id, _ = parse_target("show", argv, {"--id": ("id", False)})
        reg = Registry(reg_path)
        idx = locate_target(reg, item_id)
        sys.stdout.write(json.dumps(reg.doc["items"][idx], ensure_ascii=False, indent=2) + "\n")
        return
    if op == "situations":
        sys.stdout.write("\n".join(Registry(reg_path).allowed) + "\n")
        return
    if op == "add":
        flags = parse_op("add", argv)
        op_add(Registry(reg_path), flags, candidate)
    elif op == "edit":
        item_id, flags = parse_op("edit", argv)
        op_edit(Registry(reg_path), item_id, flags, candidate)
    elif op == "remove":
        item_id, _ = parse_op("remove", argv)
        op_remove(Registry(reg_path), item_id, candidate)
    elif op in ("copy", "move"):
        item_id, flags = parse_op(op, argv)
        op_transfer(op, reg_path, item_id, flags, candidate)
    else:
        usage("unknown operation: %s" % op)


main()
PY
}

# --- registry resolution -----------------------------------------------------------------------------------------

REGISTRY=""
EXPLICIT_REGISTRY=0
resolve_registry() {
  local cfg
  [ -z "$REGISTRY" ] || return 0
  if [ -n "${JENGA_CHECKLISTS_FILE:-}" ]; then
    REGISTRY="$JENGA_CHECKLISTS_FILE"
    return 0
  fi
  if ! cfg="$(bash "$RESOLVE_ROOT" get configs 2>/dev/null)" || [ -z "$cfg" ]; then
    die 5 "could not resolve the project configs path via resolve-root.sh"
  fi
  REGISTRY="$cfg/checklists.json"
}

# --- the one write path ------------------------------------------------------------------------------------------

CAND=""
cleanup() {
  [ -z "$CAND" ] || rm -f "$CAND"
}

# apply_locked <registry> <op> [args...]: runs UNDER scripts/with-lock.sh (see locked_write). Engine -> candidate in
# the registry's directory -> validate the candidate -> mv over the registry, only on PASS. This is the single write
# path; E67_S10_T03's copy/move reuse it rather than writing a second one.
apply_locked() {
  local registry="$1" op="$2" result rc out vrc line
  shift 2
  CAND="$registry.candidate.$$"
  trap cleanup EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  rm -f "$CAND"

  result="$(engine "$op" "$registry" "$CAND" "$@")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # Argument errors were caught before the lock was taken, so 2 here would be indistinguishable from the lock
    # wrapper's own 2: report anything unexpected as internal.
    [ "$rc" -ne 2 ] || rc=1
    exit "$rc"
  fi

  if [ ! -f "$CAND" ]; then
    printf '%s\n' "$result"
    exit 0
  fi

  out="$(bash "$VALIDATOR" "$CAND" 2>&1 >/dev/null)"
  vrc=$?
  if [ "$vrc" -ne 0 ]; then
    rm -f "$CAND"
    CAND=""
    if [ "$vrc" -eq 3 ]; then
      die 3 "python3 is required by validate-checklists.sh but was not found on PATH"
    fi
    printf '%s: the candidate registry failed validation; %s was not changed\n' "$SELF" "$registry" >&2
    while IFS= read -r line; do
      [ -z "$line" ] || printf '%s\n' "${line//$registry.candidate.$$/$registry}" >&2
    done <<EOF
$out
EOF
    exit 11
  fi

  if ! mv -f "$CAND" "$registry"; then
    die 1 "could not replace $registry with the validated candidate"
  fi
  CAND=""
  printf '%s\n' "$result"
}

# locked_write <op> [args...]: the argument syntax is checked first (exit 2 never reaches the lock), then
# apply_locked runs under scripts/with-lock.sh on the registry.
locked_write() {
  local op="$1" rc
  shift
  resolve_registry
  engine parse-check "$REGISTRY" - "$op" "$@" || exit $?
  bash "$WITH_LOCK" "$REGISTRY" -- bash "$SELF_PATH" _apply "$REGISTRY" "$op" "$@"
  rc=$?
  # with-lock.sh exits 2 when the lock could not be acquired (the command never ran); nothing the wrapped command
  # returns is 2, by construction (apply_locked).
  [ "$rc" -ne 2 ] || rc=6
  exit "$rc"
}

# --- copy and move between registries (E67_S10_T03) ---------------------------------------------------------------

# The shipped default registry, found the way scripts/checklist.sh finds it: the explicit override, else package-relative,
# else the dual-path idiom. It is the registry in force for a project with no instance, hence the seed source.
default_registry() {
  if [ -n "${JENGA_CHECKLISTS_DEFAULT_FILE:-}" ]; then
    printf '%s' "$JENGA_CHECKLISTS_DEFAULT_FILE"
  elif [ -f "$PACKAGE_ROOT/templates/checklists.json" ]; then
    printf '%s' "$PACKAGE_ROOT/templates/checklists.json"
  else
    printf '%s' "$([ -f templates/checklists.json ] && echo templates/checklists.json || echo node_modules/@jenga-ai/agent/templates/checklists.json)"
  fi
}

# Every path that counts as "the shipped default" (newline separated), so a /tmp copy used as an override and the real
# package file are both protected from being a move source or an unwarned target.
shipped_paths() {
  default_registry
  printf '\n'
  if [ -f "$PACKAGE_ROOT/templates/checklists.json" ]; then printf '%s\n' "$PACKAGE_ROOT/templates/checklists.json"; fi
}

canon_path() {
  engine canon "$1" -
}

is_shipped() {
  local c="$1" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$(canon_path "$p")" != "$c" ] || return 0
  done <<EOF
$(shipped_paths)
EOF
  return 1
}

# validate_candidate <candidate> <registry>: 0 on PASS; otherwise prints the validator's lines (candidate path rewritten
# to the registry it stands for) and returns 11 (3 when python3 vanished).
validate_candidate() {
  local cand="$1" real="$2" out vrc line
  out="$(bash "$VALIDATOR" "$cand" 2>&1 >/dev/null)"
  vrc=$?
  [ "$vrc" -ne 0 ] || return 0
  if [ "$vrc" -eq 3 ]; then
    printf '%s: python3 is required by validate-checklists.sh but was not found on PATH\n' "$SELF" >&2
    return 3
  fi
  printf '%s: the candidate registry failed validation; no registry was changed (%s)\n' "$SELF" "$real" >&2
  while IFS= read -r line; do
    [ -z "$line" ] || printf '%s\n' "${line//$cand/$real}" >&2
  done <<EOF
$out
EOF
  return 11
}

# inject_stage <stage>: the failure-injection seam (JENGA_CHECKLIST_ENTRY_FAIL_AT). True, with a message, when it is set
# to this stage.
inject_stage() {
  [ "${JENGA_CHECKLIST_ENTRY_FAIL_AT:-}" = "$1" ] || return 1
  printf '%s: injected failure at stage %s (JENGA_CHECKLIST_ENTRY_FAIL_AT); rolling back\n' "$SELF" "$1" >&2
  return 0
}

TCAND=""
SCAND=""
BACKUP=""
TARGET_FILE=""
TGT_EXISTED=0
TGT_REPLACED=0
TXN_DONE=0

# Runs on every exit of _transfer (including INT/TERM): removes the candidates and, if the target was already replaced
# but the transaction did not finish, restores the target (or deletes it when this run created it).
cleanup_transfer() {
  local rc=$?
  [ -z "$TCAND" ] || rm -f "$TCAND"
  [ -z "$SCAND" ] || rm -f "$SCAND"
  if [ "$TGT_REPLACED" -eq 1 ] && [ "$TXN_DONE" -eq 0 ]; then
    if [ "$TGT_EXISTED" -eq 1 ]; then
      if ! mv -f "$BACKUP" "$TARGET_FILE"; then
        printf '%s: ROLLBACK FAILED: could not restore %s; its original is kept as %s\n' "$SELF" "$TARGET_FILE" "$BACKUP" >&2
        exit 1
      fi
    elif ! rm -f "$TARGET_FILE"; then
      printf '%s: ROLLBACK FAILED: could not remove the newly created %s\n' "$SELF" "$TARGET_FILE" >&2
      exit 1
    fi
    TGT_REPLACED=0
  fi
  [ -z "$BACKUP" ] || [ "$TGT_REPLACED" -eq 1 ] || rm -f "$BACKUP"
  return "$rc"
}

# apply_transfer <source> <op> ID --to TARGET: runs UNDER the lock(s) (see locked_transfer). The order is the contract
# documented in the header: build every candidate, validate every candidate, only then replace (target first), and
# roll the target back if the source replace fails.
apply_transfer() {
  local source="$1" op="$2" result rc
  shift 2
  TARGET_FILE="$(engine parse-check "$source" - "$op" "$@")" || exit 1
  TCAND="$TARGET_FILE.candidate.$$"
  BACKUP="$TARGET_FILE.rollback.$$"
  [ "$op" != move ] || SCAND="$source.candidate.$$"
  trap cleanup_transfer EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  rm -f "$TCAND" "$BACKUP"
  [ -z "$SCAND" ] || rm -f "$SCAND"

  CE_DEFAULT="$(default_registry)"
  CE_SHIPPED="$(shipped_paths)"
  CE_SOURCE_CANDIDATE="$SCAND"
  export CE_DEFAULT CE_SHIPPED CE_SOURCE_CANDIDATE
  result="$(engine "$op" "$source" "$TCAND" "$@")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -ne 2 ] || rc=1
    exit "$rc"
  fi

  if inject_stage target-validate; then exit 11; fi
  validate_candidate "$TCAND" "$TARGET_FILE" || exit $?
  if [ -n "$SCAND" ]; then
    if inject_stage source-validate; then exit 11; fi
    validate_candidate "$SCAND" "$source" || exit $?
  fi

  if [ -e "$TARGET_FILE" ]; then
    cp -p "$TARGET_FILE" "$BACKUP" || die 1 "could not back up $TARGET_FILE before replacing it; nothing was changed"
    TGT_EXISTED=1
  fi
  if inject_stage target-replace; then exit 1; fi
  mv -f "$TCAND" "$TARGET_FILE" || die 1 "could not replace $TARGET_FILE with the validated candidate; nothing was changed"
  TCAND=""
  TGT_REPLACED=1
  if [ -n "$SCAND" ]; then
    if inject_stage source-replace; then exit 1; fi
    mv -f "$SCAND" "$source" || die 1 "could not replace $source after writing $TARGET_FILE; the target is being rolled back"
    SCAND=""
  fi
  TXN_DONE=1
  TGT_REPLACED=0
  printf '%s\n' "$result"
}

# locked_transfer <copy|move> ID --to TARGET: syntax and pre-lock refusals first (nothing here reaches a lock), then
# the locks in canonical order, then apply_transfer.
locked_transfer() {
  local op="$1" rc source target c_src c_tgt first second d
  shift
  case "${JENGA_CHECKLIST_ENTRY_FAIL_AT:-}" in
    "" | seed-read | target-candidate | source-candidate | target-validate | source-validate | target-replace | source-replace) ;;
    *) die_usage "JENGA_CHECKLIST_ENTRY_FAIL_AT=${JENGA_CHECKLIST_ENTRY_FAIL_AT} is not a stage (see --help)" ;;
  esac
  resolve_registry
  target="$(engine parse-check "$REGISTRY" - "$op" "$@")" || exit $?
  source="$REGISTRY"
  if [ ! -f "$source" ] && [ "$EXPLICIT_REGISTRY" -eq 0 ]; then
    d="$(default_registry)"
    if [ -f "$d" ]; then source="$d"; fi
  fi
  if [ -d "$target" ]; then die 14 "target $target is a directory; name the registry file"; fi
  d="$(dirname "$target")"
  [ -d "$d" ] || die 14 "target $target: its directory does not exist; create the directory first"
  c_src="$(canon_path "$source")"
  c_tgt="$(canon_path "$target")"
  [ "$c_src" != "$c_tgt" ] || die 13 "source and target are the same file ($source); $op needs a different registry"
  if [ "$op" = move ] && is_shipped "$c_src"; then
    die 13 "refusing to move out of the shipped default $source: it is only ever written as an explicit --to target; use copy"
  fi

  if [ "$op" = copy ]; then
    bash "$WITH_LOCK" "$target" -- bash "$SELF_PATH" _transfer "$source" "$op" "$@"
  else
    first="$source"
    second="$target"
    if [ "$(printf '%s\n%s\n' "$c_src" "$c_tgt" | LC_ALL=C sort | head -n 1)" = "$c_tgt" ]; then
      first="$target"
      second="$source"
    fi
    bash "$WITH_LOCK" "$first" -- bash "$WITH_LOCK" "$second" -- bash "$SELF_PATH" _transfer "$source" "$op" "$@"
  fi
  rc=$?
  # either with-lock.sh exits 2 when its lock could not be acquired (the command never ran); apply_transfer never
  # exits 2 by construction.
  [ "$rc" -ne 2 ] || rc=6
  exit "$rc"
}

# --- dispatch ----------------------------------------------------------------------------------------------------

REST=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --registry)
      [ "$#" -ge 2 ] || die_usage "option --registry needs a value"
      REGISTRY="$2"
      EXPLICIT_REGISTRY=1
      shift 2
      ;;
    *)
      REST+=("$1")
      shift
      ;;
  esac
done
if [ "${#REST[@]}" -gt 0 ]; then set -- "${REST[@]}"; else set --; fi

[ "$#" -ge 1 ] || die_usage "a subcommand is required (path, situations, show, check, add, edit, remove, copy, move)"
CMD="$1"
shift

case "$CMD" in
  -h | --help | help) print_contract ;;
  path)
    resolve_registry
    printf '%s\n' "$REGISTRY"
    ;;
  situations | show | check)
    resolve_registry
    engine "$CMD" "$REGISTRY" - "$@"
    exit $?
    ;;
  add | edit | remove) locked_write "$CMD" "$@" ;;
  copy | move) locked_transfer "$CMD" "$@" ;;
  _transfer)
    # internal: the body run under the lock(s)
    [ "$#" -ge 3 ] || die_usage "_transfer is internal"
    apply_transfer "$@"
    ;;
  _apply)
    # internal: the body run under the lock
    [ "$#" -ge 2 ] || die_usage "_apply is internal"
    apply_locked "$@"
    ;;
  *) die_usage "unknown subcommand: $CMD" ;;
esac
