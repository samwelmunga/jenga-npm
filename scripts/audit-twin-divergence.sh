#!/usr/bin/env bash
# scripts/audit-twin-divergence.sh — report UNEXPECTED content divergence between
# each skills/<name>/ source and its skills/j-<name>/ twin (E50_S19_T01).
#
# Why this exists
# ---------------
# Every skills/j-<name>/ twin differs from its skills/<name>/ source. Most of that
# difference is produced deliberately by scripts/generate-j-alias.sh and is CORRECT.
# Some of it is missing content — a fix that landed in a bare directory and never
# reached its twin. That second class is invisible in this repo (a bare path still
# resolves, because the bare directory is still here) but is fatal downstream:
# .publicignore blocks the bare-name directories, so the public mirror ships ONLY the
# twins. A gap in a twin is a gap for every consumer.
#
# Confirmed instance, and this script's primary fixture: E22_S09_T07 (commit f3daaa8)
# added parse_stage_id_from_text() to skills/publish/scripts/npm_stage_pipeline.sh and
# a CI-log capture block to skills/publish/adapters/npm-ci.md. Neither reached
# skills/j-publish/. A public-mirror consumer reported it as "E22_S09_T07 has not been
# addressed" while the board read Merged. Both were right.
#
# This script is READ-ONLY. It reports; it never writes. Back-fill is E50_S19_T02.
#
# Classification rules — derived from the generator, not from observed diffs
# -------------------------------------------------------------------------
# Every rule below is a port of what scripts/generate-j-alias.sh actually does, with
# its source line references. Inferring the rules from observed diffs instead would
# let a transform the generator performs be misread as a gap and — far worse — let a
# genuine gap be waved through as "probably just a path rewrite."
#
#   Transform 1 (generate-j-alias.sh L180-182): full rmtree + copytree of
#     skills/<name>/ into skills/j-<name>/.
#     => Audited as a FILE-SET comparison. A file in the source with no counterpart in
#        the twin is MISSING_FILE; the reverse is EXTRA_FILE. Both are unexpected.
#
#   Transform 2 (L176-177, L184-195): literal substring replace of "skills/<name>/"
#     with "skills/j-<name>/" across every copied file. This is also what rewrites the
#     .claude/skills/<name>/ and .agents/skills/<name>/ mirrored-install fallback
#     paths — they fall out of the same replace.
#     => Audited by reconstructing the expected twin file as
#        source.replace("skills/<name>/", "skills/j-<name>/") and comparing. A
#        mismatch is CONTENT_DRIFT. Note this is directional in both senses: a twin
#        that still carries a bare "skills/<name>/" self-reference fails here too,
#        which is the same defect class E50_S11 exists to remove.
#
#   Transform 3 (L262): frontmatter rewrite name: j.<name> -> name: j.j-<name>.
#     => TOLERATED IN BOTH DIRECTIONS. The generator emits j.j-<name>, but E50_S10's
#        settled contract keeps the canonical twin at j.<name>, and E50_S15 lands that
#        rewrite. This audit must not force either value, so it accepts j.j-<name> or
#        j.<name> and reports neither. Any OTHER name: value is unexpected.
#
#   Transform 4 (L264-308): description: reframed as a polyfill alias; keywords: gets
#     j-<name> and polyfill appended (list created if absent); examples: gets a
#     "j-<name>" entry appended if that list already exists; and a generated
#     lockstep/duplicate-alias note inserted just below the body's first H1.
#     => Reconstructed byte-for-byte and compared. A mismatch is SKILL_DRIFT.
#
# Anything a transform above does not explain is UNEXPECTED and is a candidate content
# gap. That is the entire output of this script.
#
# Scope decisions
# ---------------
# Three bare-name directories have no twin and are skipped, reported as informational:
#   - skills/index/                   — not a skill, has no SKILL.md; the generator
#                                       hard-errors on it (L118-121).
#   - skills/jenga/                   — hard-excluded from twin generation (L110-113,
#   - skills/jenga-permission-level/     E50_S06_T01). A twin must never exist.
# A j-<name> directory with no bare source is likewise skipped and reported: it is
# already at its sole canonical name (e.g. skills/j-playbook/, renamed by E50_S13), so
# there is no source to diverge from.
#
# The skills/init/ <-> skills/j-init/ pair IS AUDITED. This is a deliberate decision,
# recorded here because the generator refuses that pair (L97-100) as hand-maintained
# and predating it, so one could argue for skipping it outright. Skipping is the wrong
# call: j-init's scripts/ tree is shipped to the public mirror exactly like every other
# twin's, so it can carry exactly the content gap this script hunts, and excluding it
# would create a blind spot precisely where nothing else is watching.
#
# Because the generator never runs on that pair, its SKILL.md's generator-authored
# regions are hand-written by design and reconstruction is not the specification for
# them. For a hand-maintained pair only, SKILL.md is compared as:
#   - frontmatter: every field EXCEPT name/description/keywords/examples must match the
#     source after transform 2 (this still catches, say, a frontmatter field added to
#     the source and never mirrored);
#   - body: compared from the first "## " heading onward, since the H1 and the
#     alias note above it are hand-authored.
# The preamble between H1 and the first "## " heading is therefore not compared — so
# to stop that becoming a silent blind spot, the script asserts the SOURCE's preamble
# is empty and reports PREAMBLE_UNCOMPARED if it ever stops being empty. Everything
# outside SKILL.md in that pair is compared with no tolerance at all.
#
# Usage:
#   scripts/audit-twin-divergence.sh [repo-root] [--diff]
#
#   repo-root  Root of the tree to audit. Defaults to $JENGA_PROJECT_DIR. Passing it
#              explicitly is what lets E50_S19_T03 run this against a
#              public-mirror-shaped tree (bare-name directories absent) rather than
#              only against the private repo, where the surviving bare directories
#              mask this whole defect class.
#   --diff     Also print a unified diff for every unexpected divergence.
#   --min-pairs <n>
#              Fail unless at least <n> twinned pairs were actually audited.
#              Default 0 (no constraint).
#
#              This exists because a clean exit here is otherwise fail-open in a
#              specific and easily-missed way: a tree containing NO twinned pairs at
#              all audits nothing, finds nothing, and reports success. E50_S19_T03 hit
#              exactly that — run against a public-mirror-shaped tree, where the
#              bare-name sources are stripped by .publicignore, this script audits 0
#              pairs and exits 0. That is a true statement and a worthless one, and it
#              would read as a green gate to anyone not checking the pair count. Pass
#              --min-pairs to assert the audit examined the population you expected.
#
# Exit codes:
#   0  no unexpected divergence — usable as a gate
#   1  at least one unexpected divergence
#   2  usage or environment error, including --min-pairs not being met

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_ROOT=""
OPT_DIFF="0"
OPT_MIN_PAIRS="0"

usage() {
  echo "Usage: $(basename "$0") [repo-root] [--diff] [--min-pairs <n>]" >&2
  echo "  Reports unexpected divergence between skills/<name>/ and skills/j-<name>/." >&2
  echo "  Exits 0 when none remain, 1 when any do, 2 on a usage/environment error." >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --diff)
      OPT_DIFF="1"
      ;;
    --min-pairs)
      shift
      if [ "$#" -eq 0 ]; then
        echo "audit-twin-divergence.sh: error: --min-pairs requires a number" >&2
        usage
        exit 2
      fi
      case "$1" in
        ''|*[!0-9]*)
          echo "audit-twin-divergence.sh: error: --min-pairs expects a non-negative integer, got '$1'" >&2
          exit 2
          ;;
      esac
      OPT_MIN_PAIRS="$1"
      ;;
    -*)
      echo "audit-twin-divergence.sh: error: unknown option '$1'" >&2
      usage
      exit 2
      ;;
    *)
      if [ -n "$REPO_ROOT" ]; then
        echo "audit-twin-divergence.sh: error: more than one repo-root given ('$REPO_ROOT', '$1')" >&2
        usage
        exit 2
      fi
      REPO_ROOT="$1"
      ;;
  esac
  shift
done

if [ -z "$REPO_ROOT" ]; then
  # Only fall back to the resolver when no explicit root was given, so this script
  # stays runnable against a tree that is not a Jenga project checkout at all (the
  # mirror-shaped-tree case in E50_S19_T03).
  # SC1091 is disabled rather than left as an accepted info-level finding: this
  # script's AC requires a clean default-level shellcheck run, and the sourced file
  # does exist — shellcheck simply will not follow it without -x.
  # shellcheck source=lib/resolve-project-dir.sh disable=SC1091
  source "$SCRIPT_DIR/../lib/resolve-project-dir.sh"
  REPO_ROOT="$JENGA_PROJECT_DIR"
fi

if [ ! -d "$REPO_ROOT" ]; then
  echo "audit-twin-divergence.sh: error: repo root '$REPO_ROOT' is not a directory." >&2
  exit 2
fi

if [ ! -d "$REPO_ROOT/skills" ]; then
  echo "audit-twin-divergence.sh: error: '$REPO_ROOT' has no skills/ directory — not a tree this audit understands." >&2
  exit 2
fi

export REPO_ROOT OPT_DIFF OPT_MIN_PAIRS

# Implemented as a python heredoc for the same reason generate-j-alias.sh is: the
# classification is a byte-exact port of that generator's frontmatter/body rewrite,
# which is written in python. Keeping both in one language is what makes "traceable to
# the generator" checkable by reading rather than by trusting a re-derivation in awk.
python3 - <<'PY'
import difflib
import os
import re
import sys

repo_root = os.environ["REPO_ROOT"]
want_diff = os.environ.get("OPT_DIFF") == "1"
min_pairs = int(os.environ.get("OPT_MIN_PAIRS") or "0")
skills_dir = os.path.join(repo_root, "skills")

# Pairs the generator refuses outright. See generate-j-alias.sh L110-113 (hard error,
# E50_S06_T01) and L118-121 (no SKILL.md).
NEVER_TWINNED = ("jenga", "jenga-permission-level", "index")

# Pairs the generator refuses because they are hand-maintained and predate it
# (generate-j-alias.sh L97-100). Audited anyway — see this file's Scope decisions.
HAND_MAINTAINED = ("init",)

key_re = re.compile(r"^([A-Za-z_][\w-]*):(.*)$")

findings = []   # (pair, relpath, code, detail, expected_text, actual_text)
notes = []      # informational, never affects exit status


def record(pair, relpath, code, detail, expected=None, actual=None):
    findings.append((pair, relpath, code, detail, expected, actual))


def read_text(path):
    """Returns (text, is_text). Binary/unreadable files fall back to byte compare."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return fh.read(), True
    except (UnicodeDecodeError, OSError):
        return None, False


def read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def walk_files(root):
    out = set()
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            out.add(os.path.relpath(os.path.join(dirpath, fn), root))
    return out


def split_frontmatter(text, label):
    """Returns (opening_line, fields, closing_line, body_lines).

    Field parsing is the same informal line-oriented approach generate-j-alias.sh
    L217-234 uses — deliberately, so the two agree on what a 'field' is.
    """
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        return None, None, None, None
    close_idx = None
    for idx in range(1, len(lines)):
        if lines[idx].strip() == "---":
            close_idx = idx
            break
    if close_idx is None:
        return None, None, None, None

    fields = []
    i = 1
    while i < close_idx:
        line = lines[i]
        m = key_re.match(line)
        if not m:
            i += 1
            continue
        block = [line]
        j = i + 1
        if m.group(2).strip() == "":
            while j < close_idx and lines[j].startswith(" "):
                block.append(lines[j])
                j += 1
        fields.append({"key": m.group(1), "lines": block})
        i = j
    return lines[0], fields, lines[close_idx], lines[close_idx + 1:]


def find_field(fields, key):
    for f in fields:
        if f["key"] == key:
            return f
    return None


def build_expected_skill_md(src_text, name):
    """Byte-for-byte port of generate-j-alias.sh's transforms 2-4 on SKILL.md.

    Mirrors L176-195 (path replace), L262 (name), L264-271 (description),
    L273-286 (keywords/examples), L292-327 (note insertion + reassembly).
    """
    old_ref = "skills/%s/" % name
    new_ref = "skills/j-%s/" % name

    opening, fields, closing, body_lines = split_frontmatter(
        src_text.replace(old_ref, new_ref), "source"
    )
    if fields is None:
        return None

    name_field = find_field(fields, "name")
    desc_field = find_field(fields, "description")
    if name_field is None or len(name_field["lines"]) != 1:
        return None
    if desc_field is None or len(desc_field["lines"]) != 1:
        return None

    # L262
    name_field["lines"][0] = "name: j.j-%s\n" % name

    # L264-271
    original_desc = (
        key_re.match(desc_field["lines"][0]).group(2).strip().strip("\"'").rstrip(".")
    )
    desc_field["lines"][0] = (
        "description: Polyfill alias of the {n} skill under a collision-safe directory "
        "name. Identical behavior to /{n} — {d}. Use when the bare /{n} form is "
        "shadowed by another tool's own built-in command of the same name.\n"
    ).format(n=name, d=original_desc)

    # L273-286
    keywords_field = find_field(fields, "keywords")
    if keywords_field is not None:
        keywords_field["lines"].append("  - j-%s\n" % name)
        keywords_field["lines"].append("  - polyfill\n")
    else:
        fields.append({
            "key": "keywords",
            "lines": ["keywords:\n", "  - j-%s\n" % name, "  - polyfill\n"],
        })
    examples_field = find_field(fields, "examples")
    if examples_field is not None:
        examples_field["lines"].append('  - "j-%s"\n' % name)

    new_frontmatter = []
    for f in fields:
        new_frontmatter.extend(f["lines"])

    # L294-308
    note_text = (
        "This skill is a literal-directory-name duplicate of `skills/{n}/`. It exists "
        "so that `/j-{n}` (and `j.j-{n}`) give a guaranteed-unshadowed way to reach "
        "the same flow as `/{n}`, even if a host tool's own built-in command of the "
        "same name would otherwise shadow or override the bare `/{n}` alias (Claude "
        "Code's native skill resolution is a literal-string, directory-name-based "
        "match — see `docs/skill-authoring.md`'s \"Invocation Convention\").\n\n"
        "This file is generated/synced by `scripts/generate-j-alias.sh {n}` from "
        "`skills/{n}/SKILL.md` — do not hand-edit it; re-run the generator instead to "
        "pick up source changes."
    ).format(n=name)
    note_block = []
    for para in note_text.split("\n\n"):
        note_block.append(para + "\n")
        note_block.append("\n")

    heading_idx = None
    for idx, bl in enumerate(body_lines):
        if bl.startswith("# "):
            heading_idx = idx
            break
    if heading_idx is not None:
        insert_at = heading_idx + 1
        if insert_at < len(body_lines) and body_lines[insert_at].strip() == "":
            insert_at += 1
        prefix = body_lines[:insert_at]
        if prefix and prefix[-1].strip() != "":
            prefix = prefix + ["\n"]
        new_body = prefix + note_block + body_lines[insert_at:]
    else:
        new_body = note_block + body_lines

    return "".join([opening] + new_frontmatter + [closing] + new_body)


def normalize_name_line(text, name):
    """Applies the transform-3 tolerance: j.j-<name> and j.<name> are both accepted.

    Rewrites the twin's `name:` line to the generator's j.j-<name> form purely for the
    purpose of comparison, and only when it holds one of the two accepted values. Any
    third value is left alone so the diff surfaces it as unexpected.
    """
    accepted = ("j.j-%s" % name, "j.%s" % name)
    out = []
    seen = False
    for line in text.splitlines(keepends=True):
        if not seen:
            m = key_re.match(line)
            if m and m.group(1) == "name":
                seen = True
                value = m.group(2).strip().strip("\"'")
                if value in accepted:
                    out.append("name: j.j-%s\n" % name)
                    continue
        out.append(line)
    return "".join(out)


def body_from_first_h2(body_lines):
    for idx, bl in enumerate(body_lines):
        if bl.startswith("## "):
            return "".join(body_lines[idx:])
    return ""


def preamble_between_h1_and_h2(body_lines):
    """Body text between the first H1 and the first H2, exclusive of both."""
    start = None
    for idx, bl in enumerate(body_lines):
        if bl.startswith("# "):
            start = idx + 1
            break
    if start is None:
        start = 0
    end = len(body_lines)
    for idx in range(start, len(body_lines)):
        if body_lines[idx].startswith("## "):
            end = idx
            break
    return "".join(body_lines[start:end]).strip()


def audit_skill_md_hand_maintained(pair, src_text, twin_text):
    """SKILL.md comparison for a pair the generator refuses (L97-100).

    Compares every frontmatter field except the four transform-3/4 rewrites, and the
    body from the first H2 onward. See this file's Scope decisions for why.
    """
    old_ref = "skills/%s/" % pair
    new_ref = "skills/j-%s/" % pair
    src_text = src_text.replace(old_ref, new_ref)

    _o1, src_fields, _c1, src_body = split_frontmatter(src_text, "source")
    _o2, twin_fields, _c2, twin_body = split_frontmatter(twin_text, "twin")
    if src_fields is None or twin_fields is None:
        record(pair, "SKILL.md", "FRONTMATTER_UNPARSEABLE",
               "SKILL.md frontmatter could not be parsed on one or both sides")
        return

    generator_owned = ("name", "description", "keywords", "examples")
    for f in src_fields:
        if f["key"] in generator_owned:
            continue
        twin_f = find_field(twin_fields, f["key"])
        if twin_f is None:
            record(pair, "SKILL.md", "FRONTMATTER_FIELD_MISSING",
                   "twin frontmatter has no '%s:' field, but the source does" % f["key"],
                   "".join(f["lines"]), "")
        elif "".join(twin_f["lines"]) != "".join(f["lines"]):
            record(pair, "SKILL.md", "FRONTMATTER_FIELD_DRIFT",
                   "twin frontmatter field '%s:' differs from the source" % f["key"],
                   "".join(f["lines"]), "".join(twin_f["lines"]))

    # The uncompared region must stay empty, or this tolerance becomes a blind spot.
    src_preamble = preamble_between_h1_and_h2(src_body)
    if src_preamble:
        record(pair, "SKILL.md", "PREAMBLE_UNCOMPARED",
               "source now has body text between its H1 and its first '## ' heading, "
               "which this pair's hand-maintained tolerance does not compare — review "
               "by hand and mirror it into the twin if it belongs there",
               src_preamble, "")

    src_rest = body_from_first_h2(src_body)
    twin_rest = body_from_first_h2(twin_body)
    if src_rest != twin_rest:
        record(pair, "SKILL.md", "SKILL_DRIFT",
               "twin body (from the first '## ' heading onward) differs from the source",
               src_rest, twin_rest)


def audit_pair(pair):
    src_dir = os.path.join(skills_dir, pair)
    twin_dir = os.path.join(skills_dir, "j-%s" % pair)
    old_ref = "skills/%s/" % pair
    new_ref = "skills/j-%s/" % pair

    src_files = walk_files(src_dir)
    twin_files = walk_files(twin_dir)

    for rel in sorted(src_files - twin_files):
        record(pair, rel, "MISSING_FILE",
               "present in skills/%s/ but absent from the twin the mirror ships" % pair)
    for rel in sorted(twin_files - src_files):
        record(pair, rel, "EXTRA_FILE",
               "present in the twin but absent from skills/%s/" % pair)

    for rel in sorted(src_files & twin_files):
        src_path = os.path.join(src_dir, rel)
        twin_path = os.path.join(twin_dir, rel)

        src_text, src_is_text = read_text(src_path)
        twin_text, twin_is_text = read_text(twin_path)

        if not (src_is_text and twin_is_text):
            if read_bytes(src_path) != read_bytes(twin_path):
                record(pair, rel, "BINARY_DRIFT",
                       "binary (or non-UTF-8) file differs; the generator copies it verbatim")
            continue

        if rel == "SKILL.md":
            if pair in HAND_MAINTAINED:
                audit_skill_md_hand_maintained(pair, src_text, twin_text)
                continue
            expected = build_expected_skill_md(src_text, pair)
            if expected is None:
                record(pair, rel, "FRONTMATTER_UNPARSEABLE",
                       "source SKILL.md frontmatter does not have the single-line "
                       "name:/description: shape the generator requires (L247-250)")
                continue
            actual = normalize_name_line(twin_text, pair)
            if expected != actual:
                record(pair, rel, "SKILL_DRIFT",
                       "twin SKILL.md differs from the source after the generator's "
                       "transforms 2-4 are applied",
                       expected, actual)
            continue

        expected = src_text.replace(old_ref, new_ref)
        if expected != twin_text:
            record(pair, rel, "CONTENT_DRIFT",
                   "twin differs from skills/%s/%s after transform 2 (the "
                   "skills/%s/ -> skills/j-%s/ path rewrite)" % (pair, rel, pair, pair),
                   expected, twin_text)


# ---- discover pairs -------------------------------------------------------------

if not os.path.isdir(skills_dir):
    sys.exit("audit-twin-divergence.sh: error: %s is not a directory" % skills_dir)

entries = sorted(
    d for d in os.listdir(skills_dir) if os.path.isdir(os.path.join(skills_dir, d))
)
bare_dirs = [d for d in entries if not d.startswith("j-")]
twin_dirs = [d for d in entries if d.startswith("j-")]

pairs = []
for d in twin_dirs:
    bare = d[2:]
    if bare in bare_dirs:
        pairs.append(bare)
    else:
        notes.append(
            "skipped skills/%s/ — no skills/%s/ source; already at its sole canonical "
            "name, so there is nothing to diverge from" % (d, bare)
        )

for d in bare_dirs:
    if ("j-%s" % d) in twin_dirs:
        continue
    if d in NEVER_TWINNED:
        notes.append(
            "skipped skills/%s/ — hard-excluded from twin generation by the generator; "
            "a twin must never exist for it" % d
        )
    else:
        notes.append(
            "skipped skills/%s/ — no skills/j-%s/ twin exists" % (d, d)
        )

for pair in pairs:
    audit_pair(pair)

# ---- report ---------------------------------------------------------------------

for note in notes:
    print("note: %s" % note)
if notes:
    print("")

if findings:
    current_pair = None
    for pair, rel, code, detail, expected, actual in findings:
        if pair != current_pair:
            print("skills/j-%s/" % pair)
            current_pair = pair
        print("  %-26s %s" % (code, "skills/j-%s/%s" % (pair, rel)))
        print("      %s" % detail)
        if want_diff and expected is not None and actual is not None:
            diff = difflib.unified_diff(
                expected.splitlines(keepends=True),
                actual.splitlines(keepends=True),
                fromfile="expected (from skills/%s/%s)" % (pair, rel),
                tofile="actual   (skills/j-%s/%s)" % (pair, rel),
                n=2,
            )
            for line in diff:
                sys.stdout.write("      | " + line if line.endswith("\n")
                                 else "      | " + line + "\n")
    print("")

affected = sorted({f[0] for f in findings})
print("audit-twin-divergence.sh: audited %d twinned pair(s) under %s"
      % (len(pairs), skills_dir))

# Checked before the findings verdict: "I audited fewer pairs than you expected" is a
# statement about whether this run means anything at all, which has to be settled
# before "and I found nothing wrong" is worth printing as a pass.
if len(pairs) < min_pairs:
    print("audit-twin-divergence.sh: error: only %d twinned pair(s) were audited, but "
          "--min-pairs %d was required. A clean result over too small a population is "
          "not a pass — check the tree actually contains the pairs you expected."
          % (len(pairs), min_pairs))
    sys.exit(2)

if findings:
    print("audit-twin-divergence.sh: %d unexpected divergence(s) across %d pair(s): %s"
          % (len(findings), len(affected), ", ".join(affected)))
    print("audit-twin-divergence.sh: each of the above is a candidate content gap — "
          "back-fill it into the twin, or record it as an intentional twin-only "
          "difference with a stated reason (E50_S19_T02).")
    sys.exit(1)

print("audit-twin-divergence.sh: no unexpected divergence — every difference between "
      "each source and its twin is explained by the generator's transforms.")
sys.exit(0)
PY
