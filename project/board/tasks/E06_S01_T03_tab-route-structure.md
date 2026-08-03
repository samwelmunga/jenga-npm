---
id: E06_S01_T03
story_id: E06_S01
epic_id: E06
title: Implement tab/route structure
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Implement tab/route structure

## Description
Add a top-level navigation shell to the app with three tabs: **Board**, **History**, and **Architecture**. Use hash-based routing or a lightweight router (e.g. `wouter`, `react-router`, or built-in Svelte routing) to swap the active view without a full page reload. Each tab should render a placeholder component initially. The active tab should be highlighted in the nav bar. The default route should point to the Board tab.

## Prerequisites
- E06_S01_T01 (scaffold) must be complete.

## Acceptance Criteria
- [ ] Nav bar with Board, History, and Architecture tabs is rendered at the top of the app
- [ ] Clicking a tab changes the active view without a full page reload
- [ ] Active tab is visually highlighted
- [ ] Default route lands on the Board tab
- [ ] Each tab renders its own placeholder/stub component (ready for content in subsequent stories)
