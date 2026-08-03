---
name: init
description: Initialize a new project with the standard directory structure, PROJECT_SUMMARY.md, workflow.json, git repo, and gitignore. Follows a defined ordered onboarding sequence. Use when setting up a new or empty project.
keywords:
  - init
  - initialize
  - setup
  - new project
  - scaffold
examples:
  - "initialize a new project"
  - "set up a new workspace"
---

# Init — Project Setup

## Instructions

Follow these steps in order. Do not skip steps — the sequence matters.

### 1–9. Run the scaffold script

Execute the init script from the project root:

```bash
chmod +x ./scripts/init.sh && ./scripts/init.sh
```

This script handles all scaffolding in one step:
1. Initializes the git repository
2. Creates `.gitignore`
3. Creates the full directory structure under `project/`
4. Creates `project/PROJECT_SUMMARY.md` with placeholder content
5. Creates `project/configs/workflow.json` with shared constants
6. Creates `project/configs/test-config.json` stub
7. Creates `project/data/baselines.json`
8. Creates `project/logs/events.json`
9. Stages and commits all files with the message `init: scaffold project structure and workflow config`

If the script fails, check that you are in the project root and that git is available.

### 10. Prompt next step

Inform the user that setup is complete and suggest running `/pi-plan` to define project goals and epics.