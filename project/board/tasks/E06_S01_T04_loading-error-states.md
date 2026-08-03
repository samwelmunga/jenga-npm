---
id: E06_S01_T04
story_id: E06_S01
epic_id: E06
title: Add loading and error state components
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Add loading and error state components

## Description
Create reusable `<LoadingSpinner />` and `<ErrorMessage />` components (or equivalent for the chosen framework) that all data-fetching tab views must use. `<LoadingSpinner />` shows a visual indicator while a fetch is in-flight. `<ErrorMessage />` accepts an error object `{ status, message }` and renders a human-readable message with an optional retry callback. Document the component API with a brief comment. Wire both components into the tab shell so they are available for use in E06_S02 and beyond.

## Prerequisites
- E06_S01_T01 (scaffold) must be complete.

## Acceptance Criteria
- [ ] `<LoadingSpinner />` component exists and renders a visible loading indicator
- [ ] `<ErrorMessage error={...} onRetry={...} />` component exists and renders error details
- [ ] Both components are exported from a shared `components/` directory
- [ ] Components are demonstrated (or at minimum imported) in at least one tab view
- [ ] No raw `if (loading) return <div>Loading...</div>` patterns exist outside these components
