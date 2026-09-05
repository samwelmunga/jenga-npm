<!--
  skills/j-mirror-public/assets/inventory-template.md

  Report layout for `mirror.sh --inventory`. Rendered entirely by
  skills/j-mirror-public/scripts/mirror.sh — this file only defines the shape
  of the output, never generates it.

  Two marker-delimited blocks below:
    - SECTION_TEMPLATE : rendered once per feature-type category
    - SUMMARY_TEMPLATE  : rendered once, after all category sections

  Placeholders are substituted with bash `${var//search/replace}` string
  substitution (not sed) because ship-list entries are file paths containing
  "/", which would otherwise require fragile delimiter escaping. Do not add
  placeholders containing regex/glob metacharacters ('*', '?', '[').

  SECTION_TEMPLATE placeholders:
    {{CATEGORY_NAME}}   - human-readable category label (e.g. "Skills")
    {{CATEGORY_COUNT}}  - number of files shipped in this category
    {{CATEGORY_FILES}}  - newline-separated file list, or "  (none)"

  SUMMARY_TEMPLATE placeholders:
    {{SKILLS_COUNT}} {{MCP_COUNT}} {{AGENTS_COUNT}} {{HOOKS_COUNT}}
    {{SCRIPTS_COUNT}} {{TEMPLATES_COUNT}} {{DOCS_COUNT}} {{OTHER_COUNT}}
    {{GRAND_TOTAL}}     - sum of all category counts
    {{PUBLIC_URL}}      - configured publicRepoUrl
    {{DEFAULT_BRANCH}}  - configured defaultBranch
-->

<!-- SECTION_TEMPLATE_START -->
### {{CATEGORY_NAME}} ({{CATEGORY_COUNT}})
{{CATEGORY_FILES}}
<!-- SECTION_TEMPLATE_END -->

<!-- SUMMARY_TEMPLATE_START -->
================ mirror-public inventory summary ================
Skills        : {{SKILLS_COUNT}}
MCP           : {{MCP_COUNT}}
Agents        : {{AGENTS_COUNT}}
Hooks         : {{HOOKS_COUNT}}
Scripts       : {{SCRIPTS_COUNT}}
Templates     : {{TEMPLATES_COUNT}}
Docs          : {{DOCS_COUNT}}
Other         : {{OTHER_COUNT}}
-------------------------------------------------------------------
grand total   : {{GRAND_TOTAL}} files
public URL    : {{PUBLIC_URL}}
remote branch : {{DEFAULT_BRANCH}}
read-only inventory — no push, no commit, no remote mutation
===================================================================
<!-- SUMMARY_TEMPLATE_END -->
