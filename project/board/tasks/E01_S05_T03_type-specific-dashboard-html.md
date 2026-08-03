---
id: E01_S05_T03
story_id: E01_S05
epic_id: E01
title: Implement type-specific dashboard.html templates
status: Done
date_created: 2026-04-29
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement type-specific dashboard.html templates

## Description
Generate a `dashboard.html` file inside `<job_dir>/` after training. The dashboard must be a self-contained HTML file (no external CDN dependencies — inline or bundle all JS/CSS) that presents results visually. Each training type has a distinct layout:

- **classifiers**: confusion matrix heatmap + feature importance bar chart
- **transformers**: training/validation loss curves (line chart) + eval metrics table
- **nlp**: entity/label distribution bar chart + F1 per class table

Data is read from `results.json` (produced by E01_S05_T02). The HTML file must render correctly when opened directly in a browser (no server required).

Use a lightweight charting library (e.g. Chart.js inlined, or pure SVG/D3 subset) — no React, no build step.

## Prerequisites
- E01_S05_T02 (`results.json`) must be complete — the dashboard reads from it

## Acceptance Criteria
- [ ] `dashboard.html` is generated for each training type
- [ ] Each type renders its specific visualisations correctly in a browser
- [ ] File is fully self-contained — opens offline without errors
- [ ] Missing or empty `results.json` renders a clear "no results" message rather than a broken page
- [ ] `auto_summarize: false` suppresses dashboard generation
