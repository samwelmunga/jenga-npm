---
id: E04
title: Dataset Conversion Skill (/convert)
status: Done
date_created: 2026-04-30
date_started:
date_completed: 2026-05-10
stories:
  - E04_S01
  - E04_S02
---

# Epic: Dataset Conversion Skill (/convert)

## Purpose
Deliver a standalone `/convert` skill that normalises dataset files into CSV format for consumption by ML training jobs. The skill auto-detects the input format by file extension, flattens nested structures using dot-notation, and passes through files that are already CSV without modification.

The skill operates as a pre-processing step in the `/train` workflow — invoked automatically by the interactive train wizard when a non-CSV data file is provided — and can also be used standalone for general data preparation.

## Definition of Done
- [ ] `/convert` skill exists and is invocable standalone (`convert <path-to-file>`)
- [ ] Supports `.json`, `.jsonl`, `.yaml`, `.yml` → CSV conversion
- [ ] Auto-detects format by file extension
- [ ] Sniffs top-level structure: `[]` array proceeds, `{}` object warns and asks user to confirm
- [ ] Nested structures are flattened with dot-notation (e.g. `user.age`, `user.name`)
- [ ] Pass-through: returns input path as-is if file is already `.csv`
- [ ] `/train` interactive wizard (E01_S08) automatically calls `/convert` when a non-CSV data file is detected
- [ ] Conversion failure surfaces a clear error and aborts the wizard gracefully
