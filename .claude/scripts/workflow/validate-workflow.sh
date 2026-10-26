#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# scripts/workflow/validate-workflow.sh - structural validator for a workflow definition file
# (epic E80, tasks E80_S01_T03 structural, E80_S01_T04 semantic)
#
# Checks one workflow definition file against the v1 contract in templates/workflow-schema.json. The rules are
# read from that schema (located through scripts/workflow/lib.sh), not written into this script: the required
# top-level keys, the keys every step carries, each step type's own required fields, the output entry shape and
# kind values, and the substitution pattern. Adding a step type or a required field is therefore a schema edit.
# Output types are resolved in the registry the schema names (templates/playbook-types.json, located through
# lib.sh's workflow_types_path); there is no second type system.
#
# ---------------------------------------------------------------------------
# USAGE
# ---------------------------------------------------------------------------
#   validate-workflow.sh <file>
#   validate-workflow.sh -h | --help      print this header's usage on stdout, exit 0
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0   the definition is valid. Nothing is printed on stdout or stderr.
#   1   the definition is not valid. One line per problem on stderr (format below). All problems found in the
#       file are reported in the one run, not just the first.
#   2   the validator could not run: wrong argument count, jq not installed, the file is missing or unreadable,
#       the file is not valid JSON (an empty file and a file with more than one JSON value count as invalid),
#       the schema cannot be located or is unusable, or the definition declares an output and the type registry
#       cannot be read or has no `types` object. One message on stderr, naming the file, schema or registry.
#
# ---------------------------------------------------------------------------
# STDERR LINE FORMAT
# ---------------------------------------------------------------------------
#   <file>: <field path>: <reason>
#   e.g.  wf.json: steps[2].type: unknown step type 'branch'
#         wf.json: steps[1].prompt: missing required field 'prompt' for confirm step 'ask'
#   <file> is the path exactly as given. <field path> is a jq-like path from the definition root (`id`,
#   `steps`, `steps[3].command`); `(root)` when the problem is the whole document. Stdout is always empty.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE CHECKS (structural)
# ---------------------------------------------------------------------------
#   - the document is a JSON object;
#   - every key in the schema's top_level.required is present and not null (id, steps, ...);
#   - `steps` is a non-empty array of objects;
#   - every key in the schema's step_common.required is present on each step (id, type);
#   - the step `type` is one of the schema's step_types;
#   - no two steps share an `id`;
#   - every key in step_types.<type>.required is present on a step of that type, named with the step id.
#   Not checked: id and name patterns, field kinds (string, array, map).
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE CHECKS (semantic, validate_semantic below; E80_S01_T04)
# ---------------------------------------------------------------------------
#   Outputs (a step's optional `outputs` array):
#   - `outputs` is an array of objects, each carrying every key in the schema's outputs.entry_required;
#   - `kind` is one of the schema's outputs.kind_values (artifact, data);
#   - `type` is a string and a key of `types` in the type registry. The message names the step id, the output
#     name and the type;
#   - no two outputs of one step share a `name`.
#   References, in every string value of every step except `id`, `type`, `skill`, `playbook`, `outputs` and
#   `checkpoint` (args, options, prompt, command, template, a render step's inputs values):
#   - `${inputs.<name>}` must name an input declared in the definition's `inputs`;
#   - `${steps.<step_id>.outputs.<output_name>}` must name an output declared by a step that appears strictly
#     EARLIER in `steps`. A reference to an unknown step, to the step itself, to a later step, or to an output
#     the step does not declare is rejected, naming the step id, the field path and the reference;
#   - a token in the `inputs` or `steps` namespace that does not match the schema's substitution.pattern (for
#     example `${inputs.Bad}`) is reported as malformed. Any other `${...}` (a shell variable in a compute
#     command, say) is not a reference and is left alone.
#   The semantic pass runs even when the structural pass found problems, and reports nothing for a part of the
#   document whose shape it cannot read, so both sets of problems appear in the one run.
#
# ---------------------------------------------------------------------------
# Needs jq. macOS bash 3.2 compatible. Does not create or modify any file.
# Test override: JENGA_WORKFLOWS_TEST_ROOT (see lib.sh) points the schema and registry lookup at a synthetic tree.
# ---------------------------------------------------------------------------

_VW_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

_vw_usage() {
  printf 'Usage: validate-workflow.sh <file>\n'
}

if [ "$#" -eq 1 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; then
  _vw_usage
  exit 0
fi
if [ "$#" -ne 1 ]; then
  _vw_usage >&2
  exit 2
fi
FILE="$1"

if ! command -v jq >/dev/null 2>&1; then
  printf 'validate-workflow.sh: jq is required but was not found on PATH\n' >&2
  exit 2
fi

# shellcheck source=lib.sh
. "$_VW_DIR/lib.sh" || exit 2

SCHEMA="$(workflow_schema_path)" || {
  printf 'validate-workflow.sh: cannot locate the workflow schema\n' >&2
  exit 2
}
if [ ! -f "$SCHEMA" ] || [ ! -r "$SCHEMA" ]; then
  printf '%s: workflow schema not found or unreadable\n' "$SCHEMA" >&2
  exit 2
fi
if ! jq -e '(.top_level.required | type) == "array"
            and (.step_common.required | type) == "array"
            and (.step_types | type) == "object"' "$SCHEMA" >/dev/null 2>&1; then
  printf '%s: workflow schema is not valid JSON or lacks top_level.required, step_common.required or step_types\n' "$SCHEMA" >&2
  exit 2
fi

if [ ! -f "$FILE" ] || [ ! -r "$FILE" ]; then
  printf '%s: file not found or unreadable\n' "$FILE" >&2
  exit 2
fi
if ! jq -e -s 'length == 1' "$FILE" >/dev/null 2>&1; then
  printf '%s: not a valid JSON document\n' "$FILE" >&2
  exit 2
fi

# The type registry is needed only when the definition declares an output, so a definition without outputs
# validates with nothing but the schema in place. Set _VW_TYPES stays empty otherwise.
_VW_TYPES=""
if jq -e '.steps? | arrays | map(objects | .outputs? | select(. != null)) | length > 0' "$FILE" >/dev/null 2>&1; then
  _VW_TYPES="$(workflow_types_path)" || {
    printf '%s: cannot locate the output type registry\n' "$FILE" >&2
    exit 2
  }
  if [ ! -f "$_VW_TYPES" ] || [ ! -r "$_VW_TYPES" ]; then
    printf '%s: output type registry not found or unreadable\n' "$_VW_TYPES" >&2
    exit 2
  fi
  if ! jq -e '(.types | type) == "object"' "$_VW_TYPES" >/dev/null 2>&1; then
    printf '%s: output type registry is not valid JSON or has no types object\n' "$_VW_TYPES" >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# Structural checks. One jq program; each problem is one output line "<field path><TAB><reason>".
# Strings interpolated into a reason pass through q so a hostile value cannot break the one-line-per-problem
# format.
# ---------------------------------------------------------------------------
_VW_STRUCTURAL='
def q: tostring | gsub("[\n\r\t]"; " ");
def quoted: $sq + q + $sq;
def absent($o; $k): ($o | has($k) | not) or ($o[$k] == null);

def step_problems($i; $s):
  if ($s | type) != "object" then
    ["steps[\($i)]\tstep must be an object"]
  else
    ($s.id | if . == null then "(no id)" else q end) as $sid
    | [ $schema.step_common.required[] as $k
        | select(absent($s; $k))
        | "steps[\($i)].\($k)\tmissing required field" ]
    + ( if absent($s; "type") then []
        elif ($s.type | type) != "string" then
          ["steps[\($i)].type\tstep type must be a string"]
        elif ($schema.step_types | has($s.type) | not) then
          ["steps[\($i)].type\tunknown step type \($s.type | quoted)"]
        else
          $s.type as $t
          | [ $schema.step_types[$t].required[] as $k
              | select(absent($s; $k))
              | "steps[\($i)].\($k)\tmissing required field \($k | quoted) for \($t) step \($sid | quoted)" ]
        end )
  end;

def duplicate_problems($es):
  [ $es[] | select((.value | type) == "object" and (.value | absent(.; "id") | not))
    | {i: .key, id: .value.id} ] as $ids
  | [ $ids[] as $e
      | ([ $ids[] | select(.id == $e.id and .i < $e.i) ] | .[0]) as $first
      | select($first != null)
      | "steps[\($e.i)].id\tduplicate step id \($e.id | quoted) (first used at steps[\($first.i)])" ];

. as $d
| if ($d | type) != "object" then
    ["(root)\tdefinition must be a JSON object"]
  else
    [ $schema.top_level.required[] as $k
      | select(absent($d; $k))
      | "\($k)\tmissing required field" ]
    + ( if absent($d; "steps") then []
        elif ($d.steps | type) != "array" then ["steps\tmust be an array of steps"]
        elif ($d.steps | length) == 0 then ["steps\tmust not be empty"]
        else
          ($d.steps | to_entries) as $es
          | ([ $es[] | step_problems(.key; .value) ] | add) + duplicate_problems($es)
        end )
  end
| .[]
'

# ---------------------------------------------------------------------------
# Semantic checks (E80_S01_T04): output type registry, output kind, duplicate output name, and `${...}`
# references to run inputs and earlier step outputs. See the header for the rules.
#
# Contract of validate_semantic:
#   - $1 is the definition file, $2 is the schema file, $_VW_TYPES is the type registry file (all validated
#     above, the registry only when the definition declares an output);
#   - prints problems on stdout, one per line, as "<field path><TAB><reason>" (the same shape the structural jq
#     program emits); prints nothing for a valid file and keeps stderr quiet;
#   - is called even when the structural pass found problems, so it tolerates a structurally invalid document
#     and reports nothing for any part whose shape it cannot read;
#   - returns 0 (a non-zero return is treated as an internal failure, exit 2).
# ---------------------------------------------------------------------------
_VW_SEMANTIC='
def q: tostring | gsub("[\n\r\t]"; " ");
def quoted: $sq + q + $sq;
def absent($o; $k): ($o | has($k) | not) or ($o[$k] == null);
def named: if type == "string" then quoted else "(no name)" end;

# Table of the steps whose id is readable: position, id, and the names of the outputs they declare.
def step_table($es):
  [ $es[]
    | select((.value | type) == "object" and (.value.id | type) == "string")
    | { idx: .key, id: .value.id,
        outs: ( if (.value.outputs | type) == "array"
                then [ .value.outputs[] | select(type == "object" and (.name | type) == "string") | .name ]
                else [] end ) } ];

def output_problems($i; $s; $sid):
  if absent($s; "outputs") then []
  elif ($s.outputs | type) != "array" then
    ["steps[\($i)].outputs\tstep \($sid) outputs must be an array of output declarations"]
  else
    ($s.outputs | to_entries) as $os
    | [ $os[] as $e
        | $e.key as $j
        | $e.value as $o
        | "steps[\($i)].outputs[\($j)]" as $at
        | if ($o | type) != "object" then
            ["\($at)\tstep \($sid) output must be an object with \($schema.outputs.entry_required | join(", "))"]
          else
            ($o.name | named) as $oname
            | [ $schema.outputs.entry_required[] as $k
                | select(absent($o; $k))
                | "\($at).\($k)\tmissing required field \($k | quoted) for output \($oname) of step \($sid)" ]
            + ( if absent($o; "kind") then []
                elif ($o.kind | type) != "string" or ($schema.outputs.kind_values | index([$o.kind])) == null then
                  ["\($at).kind\tstep \($sid) output \($oname) has invalid kind \($o.kind | quoted) (expected one of: \($schema.outputs.kind_values | join(", ")))"]
                else [] end )
            + ( if absent($o; "type") then []
                elif ($o.type | type) != "string" then
                  ["\($at).type\tstep \($sid) output \($oname) type must be a string naming a type in \($schema.outputs.type_registry)"]
                elif ($types | has($o.type) | not) then
                  ["\($at).type\tstep \($sid) output \($oname) has unknown type \($o.type | quoted) (not a key of \($sq)types\($sq) in \($schema.outputs.type_registry))"]
                else [] end )
            + ( if ($o.name | type) != "string" then []
                else
                  ([ $os[] | select(.key < $j and (.value | type) == "object" and .value.name == $o.name) | .key ] | .[0]) as $first
                  | if $first == null then []
                    else ["\($at).name\tstep \($sid) declares output \($oname) more than once (first at outputs[\($first)])"] end
                end )
          end
      ] | add // []
  end;

def reference_problems($i; $s; $sid; $tbl; $inputs):
  ($s | del(.id, .type, .skill, .playbook, .outputs, .checkpoint)) as $body
  | [ $body | paths(type == "string") as $p
      | ($p | map(if type == "number" then "[\(.)]" else ".\(.)" end) | join("") | q) as $suffix
      | ($body | getpath($p)) as $str
      | [ $str | scan("\\$\\{(?:inputs|steps)(?:\\.[^}]*)?\\}") ] | unique[] as $ref
      | "steps[\($i)]\($suffix)" as $at
      | if ($ref | test("^" + $schema.substitution.pattern + "$") | not) then
          "\($at)\tstep \($sid) has malformed reference \($ref | quoted) (expected ${inputs.<name>} or ${steps.<step_id>.outputs.<output_name>})"
        else
          ($ref[2:-1] | split(".")) as $parts
          | if $parts[0] == "inputs" then
              if ($inputs | index($parts[1])) == null then
                "\($at)\tstep \($sid) reference \($ref | quoted) names an undeclared run input \($parts[1] | quoted)"
              else empty end
            else
              ([ $tbl[] | select(.id == $parts[1]) ] | .[0]) as $t
              | if $t == null then
                  "\($at)\tstep \($sid) reference \($ref | quoted) names an unknown step \($parts[1] | quoted)"
                elif $t.idx == $i then
                  "\($at)\tstep \($sid) reference \($ref | quoted) refers to its own step; only outputs of earlier steps can be used"
                elif $t.idx > $i then
                  "\($at)\tstep \($sid) reference \($ref | quoted) refers to later step \($parts[1] | quoted); only outputs of earlier steps can be used"
                elif ($t.outs | index($parts[3])) == null then
                  "\($at)\tstep \($sid) reference \($ref | quoted) names an output that step \($parts[1] | quoted) does not declare"
                else empty end
            end
        end
    ];

. as $d
| if ($d | type) != "object" or ($d.steps | type) != "array" then empty
  else
    ($d.steps | to_entries) as $es
    | step_table($es) as $tbl
    | ( if ($d.inputs | type) == "array"
        then [ $d.inputs[] | select(type == "object" and (.name | type) == "string") | .name ]
        else [] end ) as $inputs
    | $es[]
    | select((.value | type) == "object")
    | .key as $i
    | .value as $s
    | ($s.id | if type == "string" then quoted else "(no id)" end) as $sid
    | (output_problems($i; $s; $sid) + reference_problems($i; $s; $sid; $tbl; $inputs))[]
  end
'

validate_semantic() {
  local _file="$1" _schema="$2" _types='{}'
  if [ -n "${_VW_TYPES:-}" ]; then
    _types="$(jq -c '.types' "$_VW_TYPES")" || return 1
  fi
  jq -r --arg sq "$_VW_SQ" --argjson types "$_types" --slurpfile schema_doc "$_schema" \
    '$schema_doc[0] as $schema | '"$_VW_SEMANTIC" "$_file" 2>/dev/null
}

_VW_SQ="'"
STRUCTURAL_OUT="$(jq -r --arg sq "$_VW_SQ" --slurpfile schema_doc "$SCHEMA" '$schema_doc[0] as $schema | '"$_VW_STRUCTURAL" "$FILE" 2>/dev/null)" || {
  printf '%s: validation could not run (unexpected jq failure)\n' "$FILE" >&2
  exit 2
}

SEMANTIC_OUT="$(validate_semantic "$FILE" "$SCHEMA")" || {
  printf '%s: validation could not run (semantic checks failed)\n' "$FILE" >&2
  exit 2
}

ALL_OUT="$STRUCTURAL_OUT"
if [ -n "$SEMANTIC_OUT" ]; then
  if [ -n "$ALL_OUT" ]; then
    ALL_OUT="$ALL_OUT"$'\n'"$SEMANTIC_OUT"
  else
    ALL_OUT="$SEMANTIC_OUT"
  fi
fi

if [ -z "$ALL_OUT" ]; then
  exit 0
fi

_VW_TAB=$'\t'
while IFS= read -r _vw_line; do
  [ -n "$_vw_line" ] || continue
  printf '%s: %s: %s\n' "$FILE" "${_vw_line%%"$_VW_TAB"*}" "${_vw_line#*"$_VW_TAB"}" >&2
done <<EOF
$ALL_OUT
EOF
exit 1
