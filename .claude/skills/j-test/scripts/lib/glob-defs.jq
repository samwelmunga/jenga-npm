# ------------------------------------------------------------------------------
# glob-defs.jq — the ONE definition of Jenga's test-path glob dialect (E72_S07_T02)
#
# Extracted verbatim from map-scope.sh's former glob_defs() heredoc so that
# map-scope.sh and narrow-suites.sh share one dialect instead of carrying two
# copies that can drift. Every consumer `cat`s this file into the front of its jq
# program; it defines functions only and produces no output on its own.
#
# The dialect is normative and is documented in full in map-scope.sh's header
# ("GLOB DIALECT") and discover-tests.sh's header ("`paths` glob dialect"). In
# short: paths are root-relative and `/`-separated, matched against the whole
# path, case-sensitive; `*` is any run of characters except `/`; `?` is one
# character except `/`; `**` is only ever a complete segment and matches zero or
# more segments; every other character is literal. A leading `/`, `./` or `!`, a
# `.` or `..` or empty segment, any of `[ ] { } \`, a control character, and `**`
# inside a segment are all rejected. Negation is NOT supported.
#
# Exported functions:
#   globprob      null when the input glob is valid, else a message quoting it
#   seg_re        one path segment -> regex fragment
#   glob_body     a VALID glob -> unanchored regex
#   any_re($gs)   a list of globs -> one anchored alternation, or null when empty
#   matches($re)  test a path against an any_re result; false when it is null
#
# Changing this file changes which test files every scope map and every narrowed
# suite command selects. It has no independent coverage of its own: it is covered
# through tests/map-scope*.bats and tests/scope-gate-narrowing.bats.
# ------------------------------------------------------------------------------

def globprob:
  . as $g
  | if ($g | type) != "string" then "glob is not a string"
    elif $g == "" then "glob is empty"
    elif ($g | startswith("!")) then "glob \($g | tojson) begins with \"!\": negation is not supported in map_version 1"
    elif ($g | test("[\\x00-\\x1f]")) then "glob \($g | tojson) contains a control character"
    elif ($g | startswith("/")) then "glob \($g | tojson) begins with \"/\"; globs are relative to the project root"
    elif ($g | startswith("./")) then "glob \($g | tojson) begins with \"./\"; write the path without it"
    elif ($g | test("[\\[\\]{}\\\\]")) then "glob \($g | tojson) uses one of [ ] { } \\, which the glob dialect does not support"
    else ($g | split("/")) as $s
      | if ($s | index("")) != null then "glob \($g | tojson) has an empty path segment"
        elif ($s | index("..")) != null then "glob \($g | tojson) has a \"..\" segment"
        elif ($s | index(".")) != null then "glob \($g | tojson) has a \".\" segment"
        elif ([ $s[] | select(contains("**") and . != "**") ] | length) > 0
          then "glob \($g | tojson) uses \"**\" inside a segment; it must be a whole segment"
        else null end
    end;

def seg_re:
  split("")
  | map(. as $c
        | if $c == "*" then "[^/]*"
          elif $c == "?" then "[^/]"
          elif (".+()|^$" | index($c)) != null then "\\" + $c
          else $c end)
  | join("");

def glob_body:
  split("/") as $s | ($s | length) as $n
  | [ range(0; $n) as $i | $s[$i] as $g
      | if $g == "**" then (if $i == $n - 1 then ".+" else "(?:[^/]+/)*" end)
        else (($g | seg_re) + (if $i == $n - 1 then "" else "/" end)) end ]
  | join("");

def any_re($globs):
  if ($globs | length) == 0 then null
  else "\\A(?:" + ($globs | map(glob_body) | join("|")) + ")\\z" end;

def matches($re): if $re == null then false else test($re) end;
