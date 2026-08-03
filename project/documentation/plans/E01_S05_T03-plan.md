# Plan: E01_S05_T03 — Type-specific dashboard.html templates

## Goal
Create `skills/train/assets/dashboard-templates/` with standalone HTML per type.

## Files
- `skills/train/assets/dashboard-templates/classifiers.html`
- `skills/train/assets/dashboard-templates/transformers.html`
- `skills/train/assets/dashboard-templates/nlp.html`

## Design
Each HTML file:
- Self-contained (no external CDN dependencies that require network)
- Uses inline CSS for styling
- Contains placeholder `{{METRIC}}` tokens for key metrics
- Can be opened standalone in a browser (relative paths only)
- Has a simple table + chart placeholder layout

Placeholders per type:
- classifiers: `{{accuracy}}`, `{{precision}}`, `{{recall}}`, `{{f1_score}}`, `{{job_name}}`
- transformers: `{{perplexity}}`, `{{eval_loss}}`, `{{epochs}}`, `{{job_name}}`
- nlp: `{{f1}}`, `{{precision}}`, `{{recall}}`, `{{job_name}}`
