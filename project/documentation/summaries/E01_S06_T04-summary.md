# Summary: E01_S06_T04 — Add template_version field to all config.yaml templates

## What was implemented
- Added `template_version: "1.0.0"` to all three template config.yaml files alongside the `workflow:` block
- Created `.training/template/manifest.json` with canonical version registry

## Files modified
- `.training/template/classifiers/input/config.yaml` — added `template_version: "1.0.0"`
- `.training/template/transformers/input/config.yaml` — added `template_version: "1.0.0"`
- `.training/template/nlp/input/config.yaml` — added `template_version: "1.0.0"`
- `.training/template/manifest.json` — created with version `1.0.0` for all three types

## Validation
All three config.yaml files parsed and confirmed `template_version=1.0.0`. Manifest JSON valid.

## Acceptance criteria
- [x] All three config.yaml files contain `template_version` in semver format
- [x] Manifest file exists for `/train` skill to read current version per type
- [x] Field placement is consistent with the `workflow:` block
