<!-- Template for the critical-error table (E64_S01_T02). Rendered by skills/j-smoke-test/scripts/render-error-table.sh. -->
<!-- Single-line HTML comments are stripped on render. {{COUNT}} becomes the number of rows; the {{ROWS}} line becomes one -->
<!-- row per critical finding, each shaped `Feature | Error | Consequences` (the registered `error_table` type in -->
<!-- templates/playbook-types.json). The two lines under the heading are the table header and separator: because a row has -->
<!-- no outer pipes, it is also a valid Markdown table row under that header. Edit the heading or header here, not in the script. -->
## Critical errors ({{COUNT}})

Feature | Error | Consequences
--- | --- | ---
{{ROWS}}
