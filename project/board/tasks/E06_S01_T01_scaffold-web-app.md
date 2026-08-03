---
id: E06_S01_T01
story_id: E06_S01
epic_id: E06
title: Scaffold web app with frontend framework
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Scaffold web app with frontend framework

## Description
Bootstrap the dashboard web app using a lightweight frontend framework (React with Vite is preferred for minimal setup). The scaffold should live under `dashboard/` in the project root. Include a basic `index.html`, entry point, and project config (`vite.config.js` or equivalent). Set up `API_BASE_URL` as an environment variable with a default of `http://localhost:3001`, read at build/runtime via `import.meta.env` or equivalent. Include a `.env.example` documenting the variable.

## Prerequisites
None.

## Acceptance Criteria
- [ ] `dashboard/` directory exists with a runnable dev server (`npm run dev`)
- [ ] Framework chosen is lightweight (React/Vite, Vue/Vite, or Svelte)
- [ ] `API_BASE_URL` defaults to `http://localhost:3001` and is overridable via env var
- [ ] `.env.example` documents `API_BASE_URL`
- [ ] `README.md` (or section in root README) documents how to run the dashboard
