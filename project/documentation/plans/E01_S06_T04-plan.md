# Plan: E01_S06_T04 — Add template_version field to all config.yaml templates

## What
Add `template_version: "1.0.0"` to each of the three template config.yaml files and create a manifest.json the `/train` skill can read.

## Files to modify
- `.training/template/classifiers/input/config.yaml`
- `.training/template/transformers/input/config.yaml`
- `.training/template/nlp/input/config.yaml`

## Files to create
- `.training/template/manifest.json` — canonical version registry per template type

## Design
- Place `template_version` adjacent to the `workflow:` block (added by E01_S02)
- manifest.json maps type → version, readable by `/train` skill at scaffold and run time
- Start all at "1.0.0"
