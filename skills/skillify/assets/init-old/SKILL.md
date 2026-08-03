---
name: init
description: Initialize a new project with the standard directory structure, PROJECT_SUMMARY.md, workflow.json, git repo, and gitignore. Follows a defined ordered onboarding sequence. Use when setting up a new or empty project.
---

# Init — Project Setup

## Instructions

Follow these steps in order. Do not skip steps — the sequence matters.

### 1. Initialize git repository
Run `git init` in the project root. Do **not** set up any remote origin.

### 2. Create `.gitignore`
Ignore the following at minimum:
- macOS and Windows system files: `.DS_Store`, `Thumbs.db`, `Desktop.ini`
- Environment files: `.env`, `.env.*`, `*.local`
- Dependency directories: `node_modules/`, `vendor/`, `.venv/`

### 3. Scaffold directory structure

Create the following directories:

```
project/
  board/
    epics/
    stories/
    tasks/
  configs/
  data/
  queue/
  rapports/
    problems/
    analysis/
  logs/
  documentation/
    plans/
    summaries/
```

### 4. Create `project/PROJECT_SUMMARY.md`

Create the file with the following placeholder structure. The scrum master will populate it during the `/pi-plan` flow.

```markdown
# Project Summary

## Overview
_To be completed._

## Architecture & Structure
_To be completed._

## Epics
_To be completed via /pi-plan._

## Conventions
_To be completed._
```

### 5. Create `project/configs/workflow.json`

Write the shared constants file:

```json
{
  "statuses": ["Pending", "In Progress", "Passed", "Passed with remarks", "Failed", "Rejected", "Blocked"],
  "rapport_types": ["conflict", "implementation_blocker", "security_concern", "test_failure", "analysis"],
  "paths": {
    "board": "project/board",
    "epics": "project/board/epics",
    "stories": "project/board/stories",
    "tasks": "project/board/tasks",
    "rapports_problems": "project/rapports/problems",
    "rapports_analysis": "project/rapports/analysis",
    "queue": "project/queue",
    "logs": "project/logs",
    "data": "project/data",
    "configs": "project/configs"
  },
  "agents": ["developer", "tester", "scrum-master"]
}
```

### 6. Create `project/configs/test-config.json` stub

Write a minimal stub so the tester agent knows to configure it:

```json
{
  "_note": "Run the tester agent to configure tools for this project.",
  "tools": []
}
```

### 7. Create `project/data/baselines.json`

Write an empty baselines file:

```json
{}
```

### 8. Create `project/logs/events.json`

Initialize the event log:

```json
[]
```

### 9. Initial commit

Stage and commit all scaffolded files:

```
init: scaffold project structure and workflow config
```

### 10. Prompt next step

Inform the user that setup is complete and suggest running `/pi-plan` to define project goals and epics.
